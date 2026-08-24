#!/usr/bin/env bash
# Point the DeepSeek Harness (dsh) at this network's Qwen 5090 server.
#
# The harness speaks the OpenAI API natively through its pi-ai adapter, so
# unlike the Claude Code bridge there is nothing to translate: this script only
# installs dsh, writes the provider routes into its settings document, and runs
# the Web UI.
#
#   bash deepseek-harness.sh install     # install dsh itself (needs Node >= 22.19)
#   bash deepseek-harness.sh config      # write the provider routes, nothing else
#   bash deepseek-harness.sh start       # config, then start the Web UI
#   bash deepseek-harness.sh status|stop|restart|doctor|env
#   bash deepseek-harness.sh service     # systemd --user unit, survives a reboot
#   bash deepseek-harness.sh minimal     # compose the `minimal` agent preset
#                                        # for the headless profile (2 tools,
#                                        # not 25) - what the published
#                                        # Terminal-Bench figure was measured on
#   bash deepseek-harness.sh share       # publish it on the tailnet over HTTPS
#   bash deepseek-harness.sh unshare     # take it off the tailnet again
#   bash deepseek-harness.sh uninstall   # remove the unit, the shim and the runtime
#
# Client-side only - it never touches the serving path, and works against a
# server on another machine:
#
#   QWEN_URL=http://<5090-ip>:8000 bash deepseek-harness.sh start
#
# The Qwen route follows whichever backend is answering on that port - vLLM or
# NInfer - and it reads the backend off /v1/models rather than being told. Only
# vLLM publishes its context window there, so on NInfer the window is probed;
# QWEN_CTX pins it if that probe cannot run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"

# ---------------------------------------------------------------- knobs -----
# Where the servers are. Two routes because the two backends cannot share a GPU:
# vLLM serves the Qwen NVFP4 builds on 8000, llama.cpp serves the DeepSeek GGUF
# builds on 8001. Both are configured whenever they can be reached; whichever is
# actually up is the one you pick in the model selector.
QWEN_URL="${QWEN_URL:-http://localhost:8000}"
# Resolved by resolve_deepseek_url() below - the right default depends on the
# platform, and probing costs a round trip we should not pay on every call.
DEEPSEEK_URL="${DEEPSEEK_URL:-}"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"                # the harness's own state
DSH_RUNTIME="${DSH_RUNTIME:-$HOME/.dsh-runtime}"  # where npm puts dsh itself
# The Web UI's own schema accepts exactly two bind addresses - 127.0.0.1 and
# 0.0.0.0 - and refuses anything else at boot with
#   $.host expected "127.0.0.1" | "0.0.0.0" but got "..."
# so "bind it to the tailnet address only" is not expressible here. Loopback
# plus `share` (tailscale serve) gives the same reach with a smaller blast
# radius: the harness runs shell commands, and 0.0.0.0 would offer that to the
# whole LAN.
DSH_HOST="${DSH_HOST:-127.0.0.1}"
DSH_PORT="${DSH_PORT:-3080}"
# Extra authorities the UI should accept in a Host header, space-separated.
# Anything reaching it through a proxy needs to be named here.
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-}"
INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"

# pi-ai refuses a route that names no credential, so a keyless local server
# still needs a placeholder. These are references to environment variables, not
# the secrets themselves - the values land in $DSH_HOME/.env.
QWEN_KEY="${QWEN_KEY:-sk-qwen5090-local}"
DEEPSEEK_KEY="${DEEPSEEK_KEY:-sk-qwen5090-local}"

# What to tell the harness a route holds when the server does not say. vLLM
# reports max_model_len and this is never used for it; llama.cpp reports
# nothing, and pi-ai's own fallback is 262,144 - which would let the harness
# pack a prompt far past whatever -c the server was actually started with, and
# the truncation that follows is silent. Match it to serve-gguf.sh's default.
DEEPSEEK_CTX="${DEEPSEEK_CTX:-131072}"

# Same problem, different backend. NInfer's /v1/models carries id, object,
# created and owned_by and nothing else - no max_model_len - so discovery
# cannot read the window off it the way it can with vLLM. Left unsolved the
# route would inherit pi-ai's own 262,144 fallback while the server was
# actually started at 252,928 (the Qwen3.8 NVFP4 artifact's ceiling), and the
# harness would pack prompts past the end of it.
#
# So the window is probed instead - see probe_max_context() - and this
# overrides that probe when it is set. Needed when the server is reached
# through something that rewrites error bodies, or to declare a window
# deliberately smaller than the server's.
QWEN_CTX="${QWEN_CTX:-}"

LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
LOG_FILE="$LOG_DIR/deepseek-harness.log"
PID_FILE="$DSH_RUNTIME/dsh-web.pid"
SETTINGS="$DSH_HOME/settings.yaml"
ENV_FILE="$DSH_HOME/.env"
DSH_URL="http://$DSH_HOST:$DSH_PORT"

# Route keys. They are permanent: sessions, model defaults and credential
# references all address a provider by this name, so renaming one orphans
# everything that pointed at it.
QWEN_ROUTE="qwen5090"
DEEPSEEK_ROUTE="deepseek5090"

# uv and the npm shim both land here, and neither writes anything a
# non-interactive `bash -c` will read.
export PATH="$INSTALL_BIN:$PATH"

case "$DSH_HOST" in
  127.0.0.1|0.0.0.0) ;;
  *) printf 'ERROR: DSH_HOST must be 127.0.0.1 or 0.0.0.0 (got "%s").\n' "$DSH_HOST" >&2
     printf '       The Web UI refuses any other bind address. To reach it from another\n' >&2
     printf '       machine, keep it on loopback and publish it on the tailnet:\n' >&2
     printf '           bash deepseek-harness.sh share\n' >&2
     exit 1 ;;
esac

say()  { printf '>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

DSH_BIN="$DSH_RUNTIME/node_modules/.bin/dsh"

# The DeepSeek server is not inside WSL, and that is by design: serve.sh refuses
# the llama.cpp path in there because the distro gets a fixed slice of RAM
# (.wslconfig, 20 GB on a 32 GB PC) and a 62 GB model cannot be served from it -
# so it runs natively on Windows and this distro's "localhost" is its own
# loopback, not the host's. Which address reaches the host depends on the
# networking mode: `mirrored` shares the host's stack, so localhost works, while
# the default NAT mode puts the host on this distro's default gateway. Probe
# instead of guessing, and only when the caller has not already said.
#
# QWEN_URL needs none of this - vLLM is Linux-only and runs *inside* WSL, so
# its localhost default is already right. The asymmetry is the whole point.
resolve_deepseek_url() {
  [[ -n "$DEEPSEEK_URL" ]] && return 0
  local host gw ns
  if qwen5090_is_wsl; then
    gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)"
    ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
    for host in localhost "$gw" "$ns"; do
      [[ -n "$host" ]] || continue
      if curl -fsS -m 2 -o /dev/null "http://$host:8001/health" 2>/dev/null; then
        DEEPSEEK_URL="http://$host:8001"
        [[ "$host" == localhost ]] || say "DeepSeek answered on the Windows host: $DEEPSEEK_URL"
        return 0
      fi
    done
    warn "no DeepSeek server answered on this distro's loopback, gateway or nameserver."
    warn "If it is running on Windows, allow port 8001 through the firewall for the"
    warn "WSL adapter, or set it explicitly: DEEPSEEK_URL=http://<host-ip>:8001"
  fi
  DEEPSEEK_URL="http://localhost:8001"
}


# ------------------------------------------------------------- discovery ----
# Ask each server what it is serving rather than making the user type a model id
# that has to match exactly. Prints "<id>\t<ctx>\t<owner>" and returns 1 when
# nothing answers, so a caller can tell "server is down" from "server said
# something unexpected".
#
# `owner` is owned_by, and it is how the three backends are told apart without
# a second round trip: vLLM says "vllm", NInfer says "ninfer", llama.cpp says
# "llamacpp". The effort tiers and the window discovery both depend on which
# one answered.
discover_route() {
  local url="$1" json
  json=$(curl -sf -m 8 "$url/v1/models" 2>/dev/null || true)
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"][0]
except Exception:
    sys.exit(1)
mid = d.get("id")
if not mid:
    sys.exit(1)
# vLLM reports the window; NInfer and llama.cpp do not, and llama.cpp carries a
# filesystem path as the id. Fall back rather than guessing wrong by a factor
# of eight - probe_max_context() has a second try, and the route profile can
# always be corrected by hand afterwards.
ctx = d.get("max_model_len") or d.get("context_length") or 0
owner = d.get("owned_by") or ""
print(f"{mid}\t{ctx}\t{owner}")' 2>/dev/null || return 1
}

# Ask a server that publishes no window what its window is, by overrunning it.
#
# NInfer refuses an oversized prompt with the number in the message:
#   prepared prompt has 300052 tokens, exceeding Engine max_context 252928
# and it refuses at tokenization, before any prefill - measured at 0.18-0.21 s
# over three trials on the 5090, for a 1.5 MB body on loopback. That is cheap
# enough to spend once at config time and far better than the alternative,
# which is pi-ai's 262,144 fallback silently overflowing a 252,928 server.
#
# Deliberately not clever about the filler size: it only has to exceed the
# largest window any of these artifacts can hold (262,144), and "word " is one
# token, so 300k words clears every one of them with margin.
# The real model id has to be passed in, not a placeholder: NInfer validates
# the id before it measures the prompt, so a made-up one answers 404
# model_not_found and the probe learns nothing.
probe_max_context() {
  local url="$1" model="$2" ctx
  ctx=$(URL="$url" MODEL_ID="$model" python3 - <<'PY' 2>/dev/null || true
import json, os, re, urllib.error, urllib.request
body = json.dumps({
    "model": os.environ["MODEL_ID"], "max_tokens": 1,
    "messages": [{"role": "user", "content": "word " * 300000}],
}).encode()
req = urllib.request.Request(os.environ["URL"].rstrip("/") + "/v1/chat/completions",
                             data=body, headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=60).read()
except urllib.error.HTTPError as exc:
    try:
        msg = json.loads(exc.read())["error"]["message"]
    except Exception:
        raise SystemExit(1)
    m = re.search(r"max_context\s+(\d+)", msg)
    if m:
        print(m.group(1))
except Exception:
    raise SystemExit(1)
PY
)
  [[ "$ctx" =~ ^[0-9]+$ ]] && printf '%s' "$ctx"
}

# ---------------------------------------------------------------- install ---
NODE_MIN="22.19.0"

check_node() {
  command -v node >/dev/null 2>&1 || die "the harness needs Node.js >= $NODE_MIN and none is installed.
Install it with your package manager, or:
    curl -fsSL https://fnm.vercel.app/install | bash   # then: fnm install 22"
  local have
  have=$(node -v | sed 's/^v//')
  python3 - "$have" "$NODE_MIN" <<'PY' || die "Node $have is too old - the harness needs >= $NODE_MIN"
import sys
def parts(v):
    return [int(x) for x in v.split("-")[0].split(".")]
sys.exit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
}

# pnpm, not npm, and not as a preference: `npm install @deepseek-ai/dsh` does
# not finish here. Measured 2026-08-22 on a 29 GB box - twelve minutes at 97%
# CPU, 3.3 GB resident and climbing, with not one file written; pnpm resolved
# the same 503 packages in about a minute. dsh is also a pnpm project itself
# (`packageManager: pnpm@11.7.0`), and `dsh plugin` shells out to pnpm by name,
# so it has to be on PATH regardless.
ensure_pnpm() {
  export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
  export PATH="$PNPM_HOME:$PNPM_HOME/bin:$PATH"
  command -v pnpm >/dev/null 2>&1 && return 0
  say "installing pnpm into $PNPM_HOME (one time)"
  # The official installer, into the user's own directory - the npm global
  # prefix here is /usr, which would need root.
  curl -fsSL https://get.pnpm.io/install.sh | SHELL=/bin/bash sh - >/dev/null 2>&1 || true
  command -v pnpm >/dev/null 2>&1 || die "could not install pnpm - install it yourself and re-run:
    curl -fsSL https://get.pnpm.io/install.sh | sh -"
}

# pnpm 11 will not finish while a dependency's install script is undecided. It
# writes an `allowBuilds` map into pnpm-workspace.yaml full of "set this to
# true or false" placeholders, prints ERR_PNPM_IGNORED_BUILDS and exits
# non-zero - after having installed everything correctly. dsh pulls five such
# packages and not one of them needs to run here: they ship prebuilt binaries
# for linux-x64. Verified 2026-08-24 by loading node-pty's own prebuild and
# spawning a pty with it, and koffi resolves to @koromix/koffi-linux-x64.
#
# So the policy is written before pnpm is asked to install, rather than left
# for pnpm to interrupt over. Explicit `false` per package, not a blanket
# setting: a future dsh that adds a sixth native dependency should raise the
# question again instead of being silently overruled.
#
# Field name tracks pnpm 11.23. If a later pnpm renames it the install still
# succeeds - it just asks again - which is why the check below looks for the
# binary rather than trusting pnpm's exit status.
write_pnpm_build_policy() {
  cat > "$DSH_RUNTIME/pnpm-workspace.yaml" <<'EOF'
# Generated by app/scripts/deepseek-harness.sh
# These all ship linux-x64 prebuilds; none needs its install script to run.
allowBuilds:
  '@deepseek-ai/dsh-subprocess-local': false
  '@google/genai': false
  koffi: false
  node-pty: false
  protobufjs: false
EOF
}

ensure_dsh_installed() {
  if [[ -x "$DSH_BIN" ]]; then
    return 0
  fi
  check_node
  ensure_pnpm
  say "installing @deepseek-ai/dsh into $DSH_RUNTIME (one time, about a minute)"
  mkdir -p "$DSH_RUNTIME"
  [[ -f "$DSH_RUNTIME/package.json" ]] || \
    printf '{\n  "name": "dsh-runtime",\n  "private": true\n}\n' > "$DSH_RUNTIME/package.json"
  # Every published version is a prerelease, and a bare `pnpm add` picks one by
  # a rule that is not "the latest tag": asking for the package by name
  # resolved 0.1.0-rc.8 while the latest tag pointed at 0.1.1-rc.2 (measured
  # 2026-08-22). Name the tag.
  write_pnpm_build_policy
  # The binary is the ground truth, not pnpm's exit status: pnpm exits non-zero
  # on an undecided build script having already installed everything, and
  # dying there would throw away a working install (measured 2026-08-24, pnpm
  # 11.23.0). A real failure still lands on the die() below.
  local rc=0
  ( cd "$DSH_RUNTIME" && pnpm add "@deepseek-ai/dsh@${DSH_VERSION:-latest}" ) || rc=$?
  if [[ -x "$DSH_BIN" ]]; then
    (( rc == 0 )) || warn "pnpm exited $rc but $DSH_BIN is present and runnable - continuing."
  else
    die "pnpm add failed (exit $rc) and $DSH_BIN is missing - see the output above"
  fi
  # node-pty, koffi and friends ship prebuilt binaries for linux-x64, so pnpm
  # declining to run their install scripts is not a problem here. It would be
  # on a platform with no prebuild - `pnpm approve-builds` in that directory is
  # the fix, and pnpm 11 reads the allowlist from pnpm-workspace.yaml, not from
  # package.json, which it ignores with a warning.
  say "dsh installed: $("$DSH_BIN" --version 2>/dev/null || echo '(version unknown)')"
}

# A shim rather than a symlink: dsh resolves its bundles relative to the
# installation, and a symlinked bin that lands in a different node_modules
# parent walk finds the profile templates but not the packages they name.
install_shim() {
  mkdir -p "$INSTALL_BIN"
  cat > "$INSTALL_BIN/dsh" <<EOF
#!/usr/bin/env bash
# Generated by app/scripts/deepseek-harness.sh
export DSH_HOME="\${DSH_HOME:-$DSH_HOME}"
export PNPM_HOME="\${PNPM_HOME:-${PNPM_HOME:-$HOME/.local/share/pnpm}}"
export PATH="\$PNPM_HOME:\$PNPM_HOME/bin:\$PATH"
exec "$DSH_BIN" "\$@"
EOF
  chmod +x "$INSTALL_BIN/dsh"
  say "shim installed: $INSTALL_BIN/dsh"
}

# ----------------------------------------------------------- credentials ----
# The harness reads $DSH_HOME/.env as a launch environment layer, which is what
# makes a credential reference resolve for the systemd unit too - it inherits no
# login shell. Written 0600 and never into the logs directory: collect-logs.ps1
# zips that up for bug reports.
write_env_file() {
  mkdir -p "$DSH_HOME"
  local tmp
  tmp=$(mktemp "$DSH_HOME/.env.XXXXXX")
  {
    echo "# Generated by app/scripts/deepseek-harness.sh - local placeholders."
    echo "# pi-ai refuses a route naming no credential, so a keyless server"
    echo "# still needs one of these. They are not secrets today; they become"
    echo "# real the moment serve.sh is started with an API key."
    echo "QWEN5090_API_KEY=$QWEN_KEY"
    echo "DEEPSEEK5090_API_KEY=$DEEPSEEK_KEY"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# -------------------------------------------------------------- settings ----
# settings.yaml is the harness's own document - the Models page writes to it,
# and every other plugin keeps its settings there too. So this merges our two
# routes into llm-pi-ai.providers and leaves the rest of the file alone; a
# wholesale render would delete whatever the user configured in the Web UI.
merge_settings() {
  local qwen_id="$1" qwen_ctx="$2" qwen_owner="$3" ds_id="$4" ds_ctx="$5"
  mkdir -p "$DSH_HOME"
  # QWEN_WINDOW, not QWEN_CTX: the knob of that name is the caller's override
  # and this is the value that survived resolution, which may have come from
  # the probe instead.
  QWEN_ROUTE="$QWEN_ROUTE" DEEPSEEK_ROUTE="$DEEPSEEK_ROUTE" \
  QWEN_URL="$QWEN_URL" DEEPSEEK_URL="$DEEPSEEK_URL" \
  QWEN_ID="$qwen_id" QWEN_WINDOW="$qwen_ctx" QWEN_OWNER="$qwen_owner" \
  DS_ID="$ds_id" DS_CTX="$ds_ctx" \
  DEEPSEEK_CTX="$DEEPSEEK_CTX" SETTINGS="$SETTINGS" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.exit("ERROR: this needs PyYAML to edit the harness settings document.\n"
             "       sudo apt install -y python3-yaml   (or: pip install pyyaml)")

path = os.environ["SETTINGS"]
doc = {}
if os.path.exists(path):
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict):
        sys.exit(f"ERROR: {path} is not a YAML mapping - refusing to overwrite it")

providers = doc.setdefault("llm-pi-ai", {}).setdefault("providers", {})

def route(key, url, model_id, ctx, display, efforts, compat, default_ctx=0,
          timeouts=None, retry=None):
    profile = providers.get(key)
    if not isinstance(profile, dict):
        profile = {}
    # The endpoint is configuration; the model id is discovery. So a server
    # that is switched off must not pin the route to wherever it used to live
    # - keep the models already configured, but move the address.
    if not model_id:
        existing = profile.get("models") or []
        if not existing:
            return False
        profile["baseURL"] = url.rstrip("/") + "/v1"
        providers[key] = profile
        return True
    profile.update({
        "displayName": display,
        "apiKeyEnv": key.upper().replace("-", "_") + "_API_KEY",
        "api": "openai-completions",
        "baseURL": url.rstrip("/") + "/v1",
        "compat": compat,
    })
    if default_ctx:
        profile["defaultContextWindow"] = default_ctx
    if timeouts:
        profile.update(timeouts)
    if retry:
        profile["retryPolicy"] = retry
    model = {"id": model_id, "name": display}
    # "0" is what a server that reports no window looks like after the shell
    # is done with it, and it is truthy. A zero here would declare a model that
    # holds nothing.
    try:
        ctx = int(ctx or 0)
    except ValueError:
        ctx = 0
    if ctx > 0:
        model["contextWindow"] = ctx
    if efforts:
        model["reasoningEfforts"] = efforts
    profile["models"] = [model]
    providers[key] = profile
    return True

# pi-ai shapes a request from the baseURL, and an address it does not
# recognise is addressed as though it were OpenAI itself: the system prompt as
# `developer`, the cap as `max_completion_tokens`. Both are refused by vLLM and
# by llama.cpp, so both are corrected here rather than left to detection.
#
# Naming no thinkingFormat is deliberate: pi-ai's fallback path sends a bare
# `reasoning_effort`, which is exactly what vLLM hands the chat template. The
# `qwen` format would send a top-level `enable_thinking` instead, and
# `qwen-chat-template` sends chat_template_kwargs but drops the effort
# entirely - neither is what this server reads.
BASE_COMPAT = {
    "supportsDeveloperRole": False,
    "maxTokensField": "max_tokens",
    "supportsReasoningEffort": True,
}

wrote = []
# The chat template answers 400 to "high", which is the level most clients send
# by default. Declaring the map explicitly is what keeps a selector from
# offering a tier that cannot be served: the key is what the selector shows,
# the value is what goes on the wire.
QWEN_EFFORTS = {"low": "low", "medium": "medium", "xhigh": "xhigh"}
# NInfer validates the effort itself before the template sees it, and its own
# vocabulary is wider than vLLM's. Measured against the running server
# (2026-08-24, qwen3.8-27b on NInfer): "none" is accepted and genuinely
# disables thinking - the reply carries no reasoning_content at all - while
# "minimal", "high" and "max" are all refused by the loaded template with
#   reasoning effort '<x>' is not supported by the loaded chat template
# So NInfer gets a real off switch that the vLLM path has never had, and it is
# worth exposing: reasoning tokens are billed against max_tokens on this model,
# so a small-cap chore with thinking on returns an empty string behind a 200.
#
# Only for NInfer. "none" is unverified on vLLM, and offering a tier that 400s
# is exactly what this map exists to prevent.
if os.environ.get("QWEN_OWNER") == "ninfer":
    QWEN_EFFORTS = {"off": "none", **QWEN_EFFORTS}

if route(os.environ["QWEN_ROUTE"], os.environ["QWEN_URL"],
         os.environ["QWEN_ID"], os.environ["QWEN_WINDOW"], "Qwen 5090",
         QWEN_EFFORTS, dict(BASE_COMPAT)):
    wrote.append(os.environ["QWEN_ROUTE"])

# DeepSeek V4's own tiers, read off the chat template rather than guessed: it
# validates the value itself and raises on anything outside these three -
#   deepseek-v4 chat template: reasoning_effort must be low, high or max
# with `low` the default. Thinking itself is a separate boolean the template
# calls `enable_thinking`, which is what `off` has to send; the two
# chat-template thinking formats are the ones that carry it, and
# `qwen-chat-template` emits exactly {enable_thinking: bool}.
DS_COMPAT = dict(BASE_COMPAT)
# `chat-template`, not `qwen-chat-template`: the latter sends only
# enable_thinking and drops the effort entirely, so every tier would be the
# same request. This one carries both variables the template actually reads.
DS_COMPAT["thinkingFormat"] = "chat-template"
DS_COMPAT["chatTemplateKwargs"] = {
    "enable_thinking": {"$var": "thinking.enabled"},
    "reasoning_effort": {"$var": "thinking.effort"},
}
# llama.cpp does not take OpenAI's `strict` in a tool definition.
DS_COMPAT["supportsStrictMode"] = False
# `off` maps to `low` rather than to nothing, and that is not cosmetic: the
# template validates reasoning_effort OUTSIDE its `if thinking` guard, so a
# null one raises even with thinking disabled. Measured against the server -
# null and "medium" both fail the request, low/high/max all render.
if route(os.environ["DEEPSEEK_ROUTE"], os.environ["DEEPSEEK_URL"],
         os.environ["DS_ID"], os.environ["DS_CTX"], "DeepSeek V4-Flash 5090",
         {"off": "low", "low": "low", "high": "high", "max": "max"},
         DS_COMPAT,
         default_ctx=int(os.environ.get("DEEPSEEK_CTX") or 0),
         # pi-ai gives up after five minutes without a token and then retries
         # five times, which is right for a cloud API and wrong for this. The
         # weights live in system RAM, so prefill of an agent's system prompt
         # and tool definitions - thousands of tokens - takes longer than that
         # before the first token appears. Measured: one dsh task spent 25
         # minutes on five identical timeouts and never reached the model's
         # answer, while a direct 17-token request answered in 14 seconds.
         # One retry, not five: at these durations a retry storm hides the
         # failure instead of surviving it.
         timeouts={"streamIdleTimeoutMs": 1800000, "timeoutMs": 1800000},
         retry={"mode": "normal", "maxRetries": 1}):
    wrote.append(os.environ["DEEPSEEK_ROUTE"])

# Configuring a route is not the same as selecting it, and the default is not
# ours: the agent-default-model plugin ships pointing at `deepseek-official`,
# DeepSeek's hosted API. So a first run against a perfectly good local server
# still dies with
#   MISSING_CREDENTIAL: llm-deepseek: no API key for provider route
#   "deepseek-official"
# which reads as a broken install and is really an unselected model. The Web
# UI has a selector to fix that by hand; `dsh --profile headless` has none, so
# it cannot be driven at all until this is set.
#
# Only when the user has not chosen: an absent key means the plugin default is
# in force and nobody picked it, which is safe to replace. A key that is
# already there was written by the Models page or by hand, and this merge does
# not overrule the user - the same rule that keeps the rest of the document
# intact. Local first, and the Qwen route ahead of the local DeepSeek one when
# both answer.
selection = doc.get("agent-default-model")
if not isinstance(selection, dict) or not selection.get("provider"):
    for key in (os.environ["QWEN_ROUTE"], os.environ["DEEPSEEK_ROUTE"]):
        models = (providers.get(key) or {}).get("models") or []
        if models and models[0].get("id"):
            doc["agent-default-model"] = {"provider": key, "model": models[0]["id"]}
            print(f"default model: {key}/{models[0]['id']}")
            break

if not providers:
    doc["llm-pi-ai"].pop("providers", None)
    if not doc["llm-pi-ai"]:
        doc.pop("llm-pi-ai")

# Nothing to say and nothing there before: leave the harness to create its own
# document on first run rather than planting an empty mapping in its way.
if not doc and not os.path.exists(path):
    print("configured: (nothing - no server answered)")
    raise SystemExit(0)

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
os.replace(tmp, path)
print("configured: " + (", ".join(wrote) if wrote else "(nothing - no server answered)"))
PY
}

cmd_config() {
  local qwen_id="" qwen_ctx="" qwen_owner="" ds_id="" ds_ctx="" ds_owner="" line
  if line=$(discover_route "$QWEN_URL"); then
    IFS=$'\t' read -r qwen_id qwen_ctx qwen_owner <<<"$line"
    # Only vLLM publishes the window. On NInfer, ask the server to refuse an
    # oversized prompt and read the ceiling out of the refusal - a declared
    # window that is too large is the one failure mode that is silent.
    if [[ -n "$QWEN_CTX" ]]; then
      qwen_ctx="$QWEN_CTX"
      say "$QWEN_URL serves $qwen_id (${qwen_owner:-unknown}), window pinned to $qwen_ctx by QWEN_CTX"
    else
      if [[ -z "$qwen_ctx" || "$qwen_ctx" == "0" ]]; then
        local probed
        probed=$(probe_max_context "$QWEN_URL" "$qwen_id")
        if [[ -n "$probed" ]]; then
          qwen_ctx="$probed"
          say "$QWEN_URL serves $qwen_id (${qwen_owner:-unknown}), window $qwen_ctx (probed - it publishes none)"
        else
          warn "$qwen_id publishes no context window and would not reveal one.
         pi-ai will assume 262,144, which overflows a server started below that.
         Pin it:  QWEN_CTX=<tokens> bash deepseek-harness.sh config"
        fi
      else
        say "$QWEN_URL serves $qwen_id (${qwen_owner:-unknown}), window $qwen_ctx"
      fi
    fi
  else
    say "$QWEN_URL is not answering - leaving that route as it is"
  fi
  if line=$(discover_route "$DEEPSEEK_URL"); then
    IFS=$'\t' read -r ds_id ds_ctx ds_owner <<<"$line"
    say "$DEEPSEEK_URL serves $ds_id (${ds_ctx:-unknown} ctx)"
  else
    say "$DEEPSEEK_URL is not answering - leaving that route as it is"
  fi
  if [[ -z "$qwen_id" && -z "$ds_id" ]]; then
    warn "no server answered, so no route was written.
         Start one first (on the RTX 5090 PC: \"Start Qwen 5090.cmd\", or app/run.ps1),
         and if it is on another machine point this at it:
             QWEN_URL=http://<host>:8000 bash deepseek-harness.sh config"
  fi
  write_env_file
  merge_settings "$qwen_id" "$qwen_ctx" "$qwen_owner" "$ds_id" "$ds_ctx"
  say "settings: $SETTINGS"
}

# ------------------------------------------------------------- lifecycle ----
dsh_up() { curl -sf -o /dev/null -m 5 "$DSH_URL/" 2>/dev/null; }

# The proxy in front of the UI passes the client's Host through, so every name
# it can be reached by has to be an accepted authority.
trusted_host_args() {
  printf -- '--trusted-host\n%s\n' "$DSH_HOST:$DSH_PORT"
  local h
  for h in $DSH_TRUSTED_HOSTS; do
    printf -- '--trusted-host\n%s\n' "$h"
  done
}

cmd_start() {
  ensure_dsh_installed
  install_shim
  cmd_config

  if dsh_up; then
    say "harness already running on $DSH_URL"
    return 0
  fi
  mkdir -p "$LOG_DIR"
  # --no-open because there is no browser on a headless box, and the trusted
  # host because the Host header carries whatever address the client typed.
  local trusted=()
  while IFS= read -r arg; do trusted+=("$arg"); done < <(trusted_host_args)
  DSH_HOME="$DSH_HOME" nohup "$DSH_BIN" web \
      --host "$DSH_HOST" --port "$DSH_PORT" --no-open \
      "${trusted[@]}" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  local i
  for i in $(seq 1 90); do
    if dsh_up; then
      say "harness up on $DSH_URL (log: $LOG_FILE)"
      return 0
    fi
    sleep 1
  done
  die "the harness did not come up within 90s - check $LOG_FILE"
}

# Synchronous, for the same reason the Claude Code bridge's stop is: returning
# while the old process still holds the port makes the next start believe it is
# healthy, and the first request then dies with "connection refused".
cmd_stop() {
  local pid=""
  [[ -f "$PID_FILE" ]] && pid=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  else
    pkill -f "$DSH_BIN web" 2>/dev/null || true
  fi
  local i
  for i in $(seq 1 20); do
    if ! dsh_up; then
      rm -f "$PID_FILE"
      say "harness stopped"
      return 0
    fi
    sleep 1
  done
  [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null || true
  pkill -9 -f "$DSH_BIN web" 2>/dev/null || true
  rm -f "$PID_FILE"
  if dsh_up; then
    warn "something is still listening on $DSH_URL and it is not ours"
  else
    say "harness stopped"
  fi
}

cmd_status() {
  if dsh_up; then
    say "harness  : running on $DSH_URL"
  else
    say "harness  : not running"
  fi
  # No window probe here: status is meant to be cheap, and the probe posts
  # 1.5 MB. `config` is where the window gets resolved.
  local line id ctx owner
  if line=$(discover_route "$QWEN_URL"); then
    IFS=$'\t' read -r id ctx owner <<<"$line"
    # A backend that publishes no window reports 0 here, which is not a window.
    [[ "$ctx" == "0" ]] && ctx=""
    say "qwen     : $id @ $QWEN_URL [${owner:-unknown}]${ctx:+ ctx=$ctx}"
  else
    say "qwen     : not answering at $QWEN_URL"
  fi
  if line=$(discover_route "$DEEPSEEK_URL"); then
    IFS=$'\t' read -r id ctx owner <<<"$line"
    say "deepseek : $id @ $DEEPSEEK_URL"
  else
    say "deepseek : not answering at $DEEPSEEK_URL"
  fi
}

cmd_env() {
  echo "export DSH_HOME='$DSH_HOME'"
  echo "export PATH=\"$INSTALL_BIN:\$PATH\""
}

cmd_doctor() {
  echo "dsh binary : $DSH_BIN"
  echo "DSH_HOME   : $DSH_HOME"
  echo "settings   : $SETTINGS"
  echo "env file   : $ENV_FILE"
  echo "web UI     : $DSH_URL"
  echo "log        : $LOG_FILE"
  echo
  cmd_status
  echo
  if [[ -f "$SETTINGS" ]]; then
    say "configured routes:"
    SETTINGS="$SETTINGS" python3 - <<'PY' || warn "could not read $SETTINGS"
import os, yaml
d = yaml.safe_load(open(os.environ["SETTINGS"])) or {}
for name, prof in (d.get("llm-pi-ai", {}).get("providers", {}) or {}).items():
    models = ", ".join(m.get("id", "?") for m in prof.get("models", []) or [])
    print("   {}: {}  [{}]".format(name, prof.get("baseURL"), models))
PY
  fi
}

# --------------------------------------------------------------- service ----
# A user unit, not a system one: it runs as this user, inherits $DSH_HOME, and
# needs no root. Lingering is what makes it start at boot rather than at login.
UNIT_NAME="deepseek-harness.service"
UNIT_PATH="$HOME/.config/systemd/user/$UNIT_NAME"

cmd_service() {
  ensure_dsh_installed
  install_shim
  cmd_config
  command -v systemctl >/dev/null 2>&1 || die "no systemd here - use 'start' instead"
  # A hand-started instance still owns the port, and the unit would sit in
  # `activating` forever behind it - hand the port over before enabling.
  if dsh_up; then
    say "stopping the instance already on $DSH_PORT so the unit can take it"
    cmd_stop
  fi
  mkdir -p "$(dirname "$UNIT_PATH")" "$LOG_DIR"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=DeepSeek Harness (dsh) Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DSH_HOME=$DSH_HOME
# A unit inherits no login shell, so PATH has to be spelled out - dsh shells
# out to node by bare name.
Environment=PATH=$INSTALL_BIN:${PNPM_HOME:-$HOME/.local/share/pnpm}:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$HOME
ExecStart=$DSH_BIN web --host $DSH_HOST --port $DSH_PORT --no-open $(trusted_host_args | paste -d' ' - - | tr '\n' ' ')
Restart=on-failure
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  loginctl enable-linger "$USER" >/dev/null 2>&1 || \
    warn "could not enable lingering - the unit will only start at login"
  say "service installed and started: systemctl --user status $UNIT_NAME"
  say "web UI: $DSH_URL"
}

# --------------------------------------------------------------- minimal ---
# The harness ships a `minimal` agent preset - one-sentence system prompt,
# persistent bash and str_replace_editor and nothing else - and that is the
# configuration DeepSeek's published Terminal-Bench number was measured with.
# It cannot simply be selected here: presets are a Web-surface concept and the
# headless profile mounts no preset roster, so it gets composed instead.
#
# It matters most on the llama.cpp backend, where every tool schema is
# prefilled at tens of tokens per second: dsh declares 25 tools by default, and
# the first step of a two-step task took 828 seconds because of it.
#
# Scoped to the headless profile deliberately - the Web UI keeps its full set.
MINIMAL_DROP="tool-pwsh tool-jobs tool-fs tool-fs-search tool-skill
tool-subagent-control tool-subagent-list-agents tool-subagent tool-subagent-fork
tool-subagent-report tool-workflow tool-todo tool-goal tool-ralph tool-web"

cmd_minimal() {
  local prof="$DSH_HOME/profiles/headless"
  mkdir -p "$prof"
  {
    echo "# Generated by deepseek-harness.sh - reproduces the harness's"
    echo "# \`minimal\` agent preset for the headless profile."
    echo "- id: system-prompt"
    echo "  config:"
    echo "    persona: You are a helpful software engineer assistant."
    local row
    for row in $MINIMAL_DROP; do
      echo "- id: $row"
      echo "  disabled: true"
    done
  } > "$prof/cordis.patch.yml"
  say "minimal preset composed: $prof/cordis.patch.yml"
  # Checkable rather than asserted: ask the harness what it actually composed.
  DSH_HOME="$DSH_HOME" "$DSH_BIN" --profile headless --dump-config 2>/dev/null \
    | python3 -c '
import re, sys
rows, cur = [], None
for line in sys.stdin:
    m = re.match(r"^- id: (\S+)", line)
    if m:
        rows.append([m.group(1), False]); cur = rows[-1]
    elif cur and re.match(r"^\s+disabled: true\s*$", line):
        cur[1] = True
live = [r for r, off in rows if r.startswith("tool-") and not off]
print(">> tools still registered: " + (", ".join(live) if live else "(none)"))' || true
}

# ----------------------------------------------------------------- share ---
# Tailnet only, and over HTTPS with Tailscale terminating TLS. The UI itself
# stays on loopback: this is a proxy in front of it, not a second bind address,
# so nothing on the LAN can reach it even by accident.
cmd_share() {
  command -v tailscale >/dev/null 2>&1 || die "tailscale is not installed here"
  tailscale serve --bg --https="$DSH_PORT" "http://127.0.0.1:$DSH_PORT" \
    || die "tailscale serve failed - if it asks for permission, run:  tailscale set --operator=\$USER"
  local name
  name=$(tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
  if [[ -n "$name" ]]; then
    say "tailnet URL: https://$name:$DSH_PORT/"
    say "re-run start with DSH_TRUSTED_HOSTS=\"$name:$DSH_PORT\" so the UI accepts that Host header"
  fi
}

cmd_unshare() {
  command -v tailscale >/dev/null 2>&1 || die "tailscale is not installed here"
  tailscale serve --https="$DSH_PORT" off && say "tailnet proxy removed"
}

cmd_uninstall() {
  if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNIT_PATH" ]]; then
    systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_PATH"
    systemctl --user daemon-reload 2>/dev/null || true
    say "service removed"
  fi
  cmd_stop 2>/dev/null || true
  rm -f "$INSTALL_BIN/dsh"
  rm -rf "$DSH_RUNTIME"
  say "dsh runtime removed - $DSH_HOME kept (sessions and settings live there)"
}

cmd="${1:-status}"
if (( $# > 0 )); then shift; fi

# Only the commands that actually address a server pay for the probe.
case "$cmd" in
  config|start|restart|status|doctor|env|minimal) resolve_deepseek_url ;;
esac

case "$cmd" in
  install)   ensure_dsh_installed; install_shim ;;
  config)    cmd_config "$@" ;;
  start)     cmd_start "$@" ;;
  stop)      cmd_stop "$@" ;;
  restart)   cmd_stop; cmd_start "$@" ;;
  status)    cmd_status "$@" ;;
  env)       cmd_env "$@" ;;
  doctor)    cmd_doctor "$@" ;;
  service)   cmd_service "$@" ;;
  minimal)   cmd_minimal "$@" ;;
  share)     cmd_share "$@" ;;
  unshare)   cmd_unshare "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  -h|--help|help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' - try: install config start stop status doctor service minimal" ;;
esac
