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
#   bash deepseek-harness.sh share       # publish it on the tailnet over HTTPS
#   bash deepseek-harness.sh unshare     # take it off the tailnet again
#   bash deepseek-harness.sh uninstall   # remove the unit, the shim and the runtime
#
# Client-side only - it never touches the serving path, and works against a
# server on another machine:
#
#   QWEN_URL=http://<5090-ip>:8000 bash deepseek-harness.sh start
set -euo pipefail

# ---------------------------------------------------------------- knobs -----
# Where the servers are. Two routes because the two backends cannot share a GPU:
# vLLM serves the Qwen NVFP4 builds on 8000, llama.cpp serves the DeepSeek GGUF
# builds on 8001. Both are configured whenever they can be reached; whichever is
# actually up is the one you pick in the model selector.
QWEN_URL="${QWEN_URL:-http://localhost:8000}"
DEEPSEEK_URL="${DEEPSEEK_URL:-http://localhost:8001}"

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

# ------------------------------------------------------------- discovery ----
# Ask each server what it is serving rather than making the user type a model id
# that has to match exactly. Prints "<id>\t<ctx>" and returns 1 when nothing
# answers, so a caller can tell "server is down" from "server said something
# unexpected".
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
# vLLM reports the window; llama.cpp does not, and its /v1/models carries a
# filesystem path as the id. Fall back rather than guessing wrong by a factor
# of eight - the route profile can always be corrected by hand afterwards.
ctx = d.get("max_model_len") or d.get("context_length") or 0
print(f"{mid}\t{ctx}")' 2>/dev/null || return 1
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
  ( cd "$DSH_RUNTIME" && pnpm add "@deepseek-ai/dsh@${DSH_VERSION:-latest}" ) \
    || die "pnpm add failed - see the output above"
  [[ -x "$DSH_BIN" ]] || die "pnpm finished but $DSH_BIN is missing"
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
  local qwen_id="$1" qwen_ctx="$2" ds_id="$3" ds_ctx="$4"
  mkdir -p "$DSH_HOME"
  QWEN_ROUTE="$QWEN_ROUTE" DEEPSEEK_ROUTE="$DEEPSEEK_ROUTE" \
  QWEN_URL="$QWEN_URL" DEEPSEEK_URL="$DEEPSEEK_URL" \
  QWEN_ID="$qwen_id" QWEN_CTX="$qwen_ctx" DS_ID="$ds_id" DS_CTX="$ds_ctx" \
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

def route(key, url, model_id, ctx, display, efforts, compat, default_ctx=0):
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
# The chat template accepts low, medium and xhigh ONLY - it answers 400 to
# "high", which is the level most clients send by default. Declaring the map
# explicitly is what keeps a selector from offering one that cannot be served:
# the key is what the selector shows, the value is what goes on the wire.
if route(os.environ["QWEN_ROUTE"], os.environ["QWEN_URL"],
         os.environ["QWEN_ID"], os.environ["QWEN_CTX"], "Qwen 5090",
         {"low": "low", "medium": "medium", "xhigh": "xhigh"},
         dict(BASE_COMPAT)):
    wrote.append(os.environ["QWEN_ROUTE"])

# DeepSeek V4's own tiers: non-think, think high, think max. No `off` key and
# no thinkingFormat until the GGUF chat template's own spelling for them is
# measured against a running llama-server rather than guessed - the wrong guess
# is a silent one, since the server answers 200 either way.
if route(os.environ["DEEPSEEK_ROUTE"], os.environ["DEEPSEEK_URL"],
         os.environ["DS_ID"], os.environ["DS_CTX"], "DeepSeek V4-Flash 5090",
         {"high": "high", "max": "max"},
         dict(BASE_COMPAT),
         default_ctx=int(os.environ.get("DEEPSEEK_CTX") or 0)):
    wrote.append(os.environ["DEEPSEEK_ROUTE"])

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
  local qwen_id="" qwen_ctx="" ds_id="" ds_ctx="" line
  if line=$(discover_route "$QWEN_URL"); then
    qwen_id=${line%%	*}; qwen_ctx=${line##*	}
    say "$QWEN_URL serves $qwen_id (${qwen_ctx:-unknown} ctx)"
  else
    say "$QWEN_URL is not answering - leaving that route as it is"
  fi
  if line=$(discover_route "$DEEPSEEK_URL"); then
    ds_id=${line%%	*}; ds_ctx=${line##*	}
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
  merge_settings "$qwen_id" "$qwen_ctx" "$ds_id" "$ds_ctx"
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
  local line
  if line=$(discover_route "$QWEN_URL"); then
    say "qwen     : ${line%%	*} @ $QWEN_URL"
  else
    say "qwen     : not answering at $QWEN_URL"
  fi
  if line=$(discover_route "$DEEPSEEK_URL"); then
    say "deepseek : ${line%%	*} @ $DEEPSEEK_URL"
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
  share)     cmd_share "$@" ;;
  unshare)   cmd_unshare "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  -h|--help|help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' - try: install config start stop status doctor service" ;;
esac
