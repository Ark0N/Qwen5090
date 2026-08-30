#!/usr/bin/env bash
# Point Claude Code (or anything else that speaks the Anthropic API) at this
# machine's Qwen 5090 server.
#
# vLLM serves the OpenAI API; Claude Code speaks the Anthropic API. Neither
# bends, so this runs a small LiteLLM process in between that translates both
# directions, streaming and tool calls included.
#
#   bash claude-code.sh run          # start the bridge, then launch Claude Code
#   bash claude-code.sh start        # just start the bridge
#   bash claude-code.sh env          # print exports for your own shell
#   bash claude-code.sh status|stop|restart|doctor
#   bash claude-code.sh install      # add a `qwen-claude` command to your PATH
#   bash claude-code.sh uninstall    # remove it again
#   bash claude-code.sh install-claude   # install Claude Code itself (no Node needed)
#
# Works on Linux, macOS and inside WSL, against a local or a remote server:
#   QWEN_URL=http://<host>:8000 bash claude-code.sh run
set -euo pipefail

# ---------------------------------------------------------------- knobs -----
QWEN_URL="${QWEN_URL:-http://localhost:8000}"     # where the server is listening
# The context window to tell Claude Code about. Normally discovered from
# /v1/models, which is right for vLLM - but only vLLM publishes max_model_len
# there. NInfer's model object carries id/object/created/owned_by and nothing
# else. llama.cpp publishes none either, but does answer /props, which the
# discovery below now asks; NInfer answers neither, so set this to the CTX the
# server was started with when serving through NInfer at a longer context.
# Getting it wrong is not symmetric: too low wastes the window, too high lets
# Claude Code pack a prompt the server will refuse.
QWEN_CTX="${QWEN_CTX:-}"
BRIDGE_PORT="${BRIDGE_PORT:-4000}"                # where the bridge listens
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"           # loopback: this is not an auth boundary
BRIDGE_KEY="${BRIDGE_KEY:-sk-qwen5090-local}"     # local-only shared secret
BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.qwen5090/bridge}"
INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"    # where `install` puts the command
INSTALL_NAME="${INSTALL_NAME:-qwen-claude}"
# Claude Code fires a second, cheaper model for background chores (conversation
# titles, and so on) with a small token budget. Reasoning tokens are billed
# against max_tokens on this model, so those requests come back EMPTY unless
# thinking is off - hence a separate alias rather than one model for both.
FAST_THINKING="${FAST_THINKING:-0}"
# How hard the model thinks. The bridge drops the client's value and
# substitutes this one, because Claude Code sends "high" when extended thinking
# is on and the Qwen template rejects that outright.
#
# Which levels are legal depends on the checkpoint, not on this script: the
# Qwen templates take low|medium|xhigh and 400 on anything else, while DeepSeek
# V4's takes low|high|max. Left unset it resolves after discovery, to whichever
# template's own default applies - xhigh for Qwen, low for DeepSeek V4 - and a
# value that the served model cannot accept is refused there rather than
# turning every request into a 400.
QWEN_EFFORT="${QWEN_EFFORT:-}"
# Debugging aid, off by default: record every request and reply the bridge
# handles, as JSONL. That is the full text of your prompts, your files and the
# model's answers, so it is opt-in per bridge start and never on by accident.
# It writes to $HOME/.qwen5090/debug/ deliberately, NOT the logs directory -
# collect-logs.ps1 bundles ~/.qwen5090/logs/*.log into the ZIP people attach to
# bug reports, and prompts must not ride along uninvited.
QWEN_LOG_PAYLOADS="${QWEN_LOG_PAYLOADS:-0}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$HOME/.qwen5090/debug}"

VENV="$BRIDGE_HOME/venv"
CONFIG="$BRIDGE_HOME/config.yaml"
# LiteLLM resolves a callbacks entry against the config file's own directory, so
# the module has to sit next to config.yaml and be named the same as the entry.
HOOKS="$BRIDGE_HOME/qwen_hooks.py"
LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
LOG_FILE="$LOG_DIR/bridge.log"
PID_FILE="$BRIDGE_HOME/bridge.pid"
BRIDGE_URL="http://$BRIDGE_HOST:$BRIDGE_PORT"

# A cheap spelling check here; which of these the *served* model actually
# accepts is settled in resolve_effort() once discovery knows what it is.
case "$QWEN_EFFORT" in
  ""|low|medium|xhigh|high|max) ;;
  *) printf 'ERROR: QWEN_EFFORT="%s" is not a level any of these templates knows.\n' "$QWEN_EFFORT" >&2
     printf '       Qwen takes low|medium|xhigh; DeepSeek V4 takes low|high|max.\n' >&2
     exit 1 ;;
esac

# setup-wsl.sh puts uv in ~/.local/bin, and the Claude Code installer puts
# `claude` there too - but neither writes anything a `bash -c` will read: uv's
# installer only appends to ~/.bashrc, which is skipped for a shell that is
# neither login nor interactive. Every route into this script is a `bash -c`
# (the GUI, claude-code.ps1, the generated launcher), so without this line
# `command -v uv` misses a uv sitting right there, and a `claude` that was
# installed seconds ago is still "not installed".
export PATH="$HOME/.local/bin:$PATH"

say()  { printf '>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- discovery ----
# Ask the server what it is serving rather than making the user type a model id
# and a context length that have to match exactly. Sets MODEL_ID and MODEL_CTX.
discover_model() {
  local json
  json=$(curl -sf -m 10 "$QWEN_URL/v1/models" 2>/dev/null || true)
  [[ -n "$json" ]] || die "no Qwen server answering at $QWEN_URL

Start it first (on the RTX 5090 PC: double-click \"Start Qwen 5090.cmd\", or
run app/run.ps1), and if the server is on another machine point this at it:

    QWEN_URL=http://<host>:8000 bash claude-code.sh ${1:-run}

A server on another machine also has to be shared off localhost - on the
Windows host that is  .\\app\\share.ps1  (or the GUI's share checkbox)."

  MODEL_ID=$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"][0]
print(d["id"])' 2>/dev/null || true)
  MODEL_CTX=$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"][0]
print(d.get("max_model_len") or 131072)' 2>/dev/null || true)

  [[ -n "${MODEL_ID:-}" ]] || die "could not read a model id from $QWEN_URL/v1/models"

  # llama.cpp publishes no max_model_len, but it does answer /props, where
  # default_generation_settings.n_ctx is the window a slot actually has. Left
  # to the 131072 fallback, a server started with -c 65536 had Claude Code
  # told it has twice the room it does, and Claude Code packs to the number it
  # is given. Only asked when /v1/models came back without one.
  if [[ -z "${MODEL_CTX:-}" || "$MODEL_CTX" == "131072" ]]; then
    local props
    props=$(curl -sf -m 10 "$QWEN_URL/props" 2>/dev/null || true)
    if [[ -n "$props" ]]; then
      local probed
      probed=$(printf '%s' "$props" | python3 -c '
import json,sys
d=json.load(sys.stdin)
g=d.get("default_generation_settings") or {}
n=g.get("n_ctx") or d.get("n_ctx")
print(n if isinstance(n,int) and n>0 else "")' 2>/dev/null || true)
      [[ -n "$probed" ]] && MODEL_CTX="$probed"
    fi
  fi

  # An explicit QWEN_CTX wins over discovery: on a backend that advertises its
  # window nowhere - NInfer answers neither /v1/models nor /props with one -
  # discovery cannot do better than the fallback.
  [[ -n "$QWEN_CTX" ]] && MODEL_CTX="$QWEN_CTX"
  MODEL_CTX="${MODEL_CTX:-131072}"

  resolve_effort
}

# The legal thinking levels are a property of the loaded chat template, so this
# can only run once discovery knows which checkpoint is being served. Both
# lists are enforced by the template itself, with a hard 400 for anything else
# - which, injected on every request, would mean nothing worked at all.
resolve_effort() {
  local levels default
  case "$MODEL_ID" in
    *[Dd]eep[Ss]eek*) levels="low high max";      default=low ;;
    *)                levels="low medium xhigh";  default=xhigh ;;
  esac
  if [[ -z "$QWEN_EFFORT" ]]; then QWEN_EFFORT="$default"; return 0; fi
  case " $levels " in
    *" $QWEN_EFFORT "*) ;;
    *) die "QWEN_EFFORT=$QWEN_EFFORT is not a level $MODEL_ID accepts.

Its chat template takes: ${levels// /, }.
That is a hard 400 from the server, and the bridge injects this value on every
request - so the session would fail on the first message." ;;
  esac
}

# ---------------------------------------------------------------- install ---
# FastAPI 0.140.7 deleted get_flat_dependant, which LiteLLM's proxy imports at
# startup - but LiteLLM's own metadata still claims fastapi>=0.136.3,<1.0, so a
# plain install resolves to a broken pair. It fails at launch, not at install
# time, and the traceback says "No module named 'proxy_server'" rather than
# naming the real import. Upper-bound it here.
#   verified 2026-08-20: get_flat_dependant present <=0.140.6, gone from 0.140.7
BRIDGE_PINS=('litellm[proxy]>=1.97,<2' 'fastapi>=0.136.3,<0.140.7')

ensure_bridge_installed() {
  if [[ -x "$VENV/bin/litellm" ]]; then
    return 0
  fi
  say "installing the LiteLLM bridge into $VENV (one time, ~1 min)"
  mkdir -p "$BRIDGE_HOME"

  # PATH already carries ~/.local/bin from the top of this file - without it the
  # uv that setup-wsl.sh installed is invisible here and we fall through to the
  # python3 -m venv branch, which cannot work either.
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV" >/dev/null
    VIRTUAL_ENV="$VENV" uv pip install --quiet "${BRIDGE_PINS[@]}"
  else
    command -v python3 >/dev/null 2>&1 || die "need python3 (or uv) to install the bridge"
    # Ubuntu's WSL rootfs ships python3 without ensurepip, so `python3 -m venv`
    # dies half-way and leaves a venv with no pip in it. Say so here rather than
    # letting venv's own "ensurepip is not available" wall of text be the answer.
    python3 -c 'import ensurepip' >/dev/null 2>&1 || die "python3 here cannot create a virtualenv (no ensurepip), and uv was not found.
Install either one and re-run:
    curl -LsSf https://astral.sh/uv/install.sh | sh      # what the installer uses
    sudo apt install -y python3-venv                     # or the distro package"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet "${BRIDGE_PINS[@]}"
  fi
  [[ -x "$VENV/bin/litellm" ]] || die "bridge install failed - see the output above"
  say "bridge installed"
}

# ------------------------------------------------------------------ hooks ---
# Claude Code's WebSearch is a *server-side* Anthropic tool - it arrives as
# {"type": "web_search_20250305", "name": "web_search"} with no input_schema, so
# there is no OpenAI function for LiteLLM to translate it into and it drops the
# tool. What it does not drop is tool_choice, and vLLM rejects that pair outright:
#
#   400 When using `tool_choice`, `tools` must be set. (parameter=tool_choice)
#
# which reaches the session as a dead turn ("API Error: 400 ... BadRequestError").
# Only WebSearch trips it: Read/Edit/Bash are ordinary function tools and survive
# translation intact, so the session works right up until the model reaches for
# the web. There is no config primitive for "drop this param only sometimes" -
# putting tool_choice in additional_drop_params would also silently defang a
# genuinely forced tool call - so it takes a pre-call hook.
render_hooks() {
  # The payload switch is baked into the module rather than read from the
  # environment, so that flipping it changes this file - which is what makes
  # cmd_start notice and restart. An env var alone would be silently ignored by
  # a bridge that is already up.
  local payload_log="None"
  if [[ "$QWEN_LOG_PAYLOADS" == "1" ]]; then
    payload_log="\"$PAYLOAD_DIR\""
  fi

  cat <<PYHEAD
# Generated by app/scripts/claude-code.sh - edits are overwritten on next start.
"""Bridge-side compatibility hooks, plus an opt-in traffic recorder."""

# None disables recording. A path turns it on: every request and reply is
# appended there as JSONL, prompts and file contents included.
PAYLOAD_LOG = $payload_log
PYHEAD

  cat <<'PY'

import json
import os
import time

from litellm.integrations.custom_logger import CustomLogger

# Anything that would put the shared secret in a file people mail around, plus
# the objects that are noise in a transcript. Matched at ANY depth: LiteLLM
# tucks the raw request headers - x-api-key included - inside secret_fields,
# which a top-level filter walks straight past (measured 2026-08-21).
_SECRETS = ("api_key", "authorization", "x-api-key", "master_key",
            "secret_fields", "raw_headers", "proxy_server_request",
            "litellm_metadata", "metadata", "litellm_logging_obj")


def _scrub(obj):
    if isinstance(obj, dict):
        return {k: _scrub(v) for k, v in obj.items() if str(k).lower() not in _SECRETS}
    if isinstance(obj, (list, tuple)):
        return [_scrub(v) for v in obj]
    return obj


def _plain(obj):
    """Pydantic models serialise as a one-line repr through default=str, which
    is unreadable exactly when you need to read it."""
    for attr in ("model_dump", "dict"):
        fn = getattr(obj, attr, None)
        if callable(fn):
            try:
                return fn()
            except Exception:
                pass
    return obj


def _record(kind, obj):
    """Best effort by design: a debugging aid must never break a session."""
    if not PAYLOAD_LOG:
        return
    try:
        os.makedirs(PAYLOAD_LOG, exist_ok=True)
        path = os.path.join(PAYLOAD_LOG, "payloads-%s.jsonl" % time.strftime("%Y%m%d"))
        line = json.dumps({"time": time.strftime("%H:%M:%S"), "kind": kind, "data": obj},
                          default=str, ensure_ascii=False)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


def _is_callable_tool(tool):
    """True for an Anthropic client tool (input_schema) or an OpenAI function
    tool. False for the server-side tool types, which is the whole point: they
    are the ones that vanish before the request reaches vLLM."""
    if not isinstance(tool, dict):
        return False
    return bool(tool.get("input_schema") or tool.get("function"))


class QwenCompat(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # The hook can see the request in either shape depending on the route it
        # came in on, so count what is actually callable rather than trusting an
        # empty list to mean "no tools".
        if data.get("tool_choice") is not None and not any(
            _is_callable_tool(t) for t in (data.get("tools") or [])
        ):
            data.pop("tool_choice", None)
        # Recorded after the rewrite, so the file shows what vLLM was actually
        # asked for - the whole point when the two disagree.
        _record("request", _scrub(data))
        return data

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        # Fires once per request, streamed or not, with the assembled reply.
        try:
            secs = (end_time - start_time).total_seconds()
        except Exception:
            secs = None
        _record("response", _scrub({"model": kwargs.get("model"), "secs": secs,
                                    "reply": _plain(response_obj)}))

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        _record("failure", _scrub({"model": kwargs.get("model"),
                                   "error": _plain(response_obj)}))


proxy_handler_instance = QwenCompat()
PY
}

# ---------------------------------------------------------- claude code ------
# Claude Code itself, which is not ours to ship. The native installer is a
# single checksum-verified binary under $HOME: no Node, no npm, no root. That
# matters here - `npm install -g @anthropic-ai/claude-code` needs a Node
# toolchain, and Ubuntu's WSL rootfs ships neither node nor npm, so the npm
# route would mean apt-installing a whole toolchain first.
CLAUDE_INSTALLER_URL="${CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

ensure_claude_installed() {
  if command -v claude >/dev/null 2>&1; then
    say "Claude Code is already installed ($(command -v claude))"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "need curl to install Claude Code"
  say "installing Claude Code (one time, about 30s)"

  # Downloaded, then run - not piped straight into bash - so a download that
  # fails halfway is a clear error here instead of a truncated script that
  # half-runs. The installer verifies the binary's sha256 itself.
  local tmp
  tmp=$(mktemp) || die "could not create a temp file"
  if ! curl -fsSL -m 120 "$CLAUDE_INSTALLER_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "could not download the Claude Code installer from $CLAUDE_INSTALLER_URL
Check that this machine can reach the internet, then try again."
  fi
  if ! bash "$tmp"; then
    rm -f "$tmp"
    die "the Claude Code installer failed - see the output above"
  fi
  rm -f "$tmp"

  # It lands in ~/.local/bin, which is on PATH from the top of this file - but
  # bash caches command lookups, so without this the shell still insists it is
  # not there.
  hash -r 2>/dev/null || true
  command -v claude >/dev/null 2>&1 || die "the installer finished but 'claude' is still not on PATH.
Look for it under $HOME/.local/bin."
  say "Claude Code installed: $(command -v claude)"
}

cmd_install_claude() { ensure_claude_installed; }

# ----------------------------------------------------------------- config ---
render_config() {
  # Claude Code sends reasoning_effort="high" whenever extended thinking is on.
  # This chat template only knows low/medium/xhigh and returns a hard 400 for
  # anything else, which surfaces mid-session as a dead conversation. There is
  # no rename primitive in LiteLLM config, so the client's value is dropped and
  # QWEN_EFFORT is injected in its place.
  #
  # It has to go in via chat_template_kwargs, NOT as a top-level field:
  # additional_drop_params runs AFTER extra_body merges, so a top-level
  # reasoning_effort is stripped right back out again and nothing reaches vLLM
  # (measured <absent> for every value). Inside chat_template_kwargs the drop
  # list cannot see it. Measured against the real model 2026-08-21: medium
  # yields 497 chars of thinking by either route vs 151 for the xhigh default,
  # so the template honours it there exactly as it does top-level.
  local drop='      additional_drop_params: ["reasoning_effort"]'
  local main_extra="      extra_body: {\"chat_template_kwargs\": {\"reasoning_effort\": \"$QWEN_EFFORT\"}}"

  # The fast and classifier aliases turn thinking off entirely instead -
  # reasoning tokens count against max_tokens, and Claude Code's background
  # calls use a small cap, so with thinking on they come back empty behind an
  # HTTP 200. FAST_THINKING re-enables it for the fast alias only: the
  # classifier's 60-second budget has no room for it under any setting.
  local nothink_extra="      extra_body: {\"chat_template_kwargs\": {\"enable_thinking\": false}}"
  local fast_extra="$nothink_extra"
  if [[ "$FAST_THINKING" == "1" ]]; then
    fast_extra="$main_extra"
  fi

  cat <<YAML
# Generated by app/scripts/claude-code.sh - edits are overwritten on next start.
# Anthropic /v1/messages  ->  OpenAI /v1/chat/completions on $QWEN_URL
model_list:
  # What Claude Code drives itself with.
  - model_name: qwen5090
    litellm_params:
      model: hosted_vllm/$MODEL_ID
      api_base: $QWEN_URL/v1
      api_key: "none"
$drop
$main_extra
    model_info:
      max_input_tokens: $MODEL_CTX
      max_output_tokens: 32768
      supports_function_calling: true

  # Background chores (conversation titles and the like).
  - model_name: qwen5090-fast
    litellm_params:
      model: hosted_vllm/$MODEL_ID
      api_base: $QWEN_URL/v1
      api_key: "none"
$drop
$fast_extra
    model_info:
      max_input_tokens: $MODEL_CTX
      max_output_tokens: 8192
      supports_function_calling: true

  # Auto mode's permission classifier. Every tool call that is not plainly
  # read-only costs one extra request - non-streaming, ~115 KB of rules in the
  # system prompt, and a hard 60-second timeout on the client side. An xhigh
  # thinking pass does not land inside that budget, so thinking is off here and
  # the cap is generous enough for the classifier's second stage (10240).
  - model_name: qwen5090-classifier
    litellm_params:
      model: hosted_vllm/$MODEL_ID
      api_base: $QWEN_URL/v1
      api_key: "none"
$drop
$nothink_extra
    model_info:
      max_input_tokens: $MODEL_CTX
      max_output_tokens: 16384
      supports_function_calling: true

  # Anything else Claude Code asks for lands on the same server instead of 404.
  - model_name: "*"
    litellm_params:
      model: hosted_vllm/$MODEL_ID
      api_base: $QWEN_URL/v1
      api_key: "none"
$drop
$main_extra

litellm_settings:
  drop_params: true      # discard sampling params vLLM will not accept
  callbacks: qwen_hooks.proxy_handler_instance   # WebSearch tool_choice fix
  telemetry: false

general_settings:
  master_key: $BRIDGE_KEY
YAML
}

# ------------------------------------------------------------ lifecycle -----
bridge_up() { curl -sf -o /dev/null -m 2 "$BRIDGE_URL/health/liveliness" 2>/dev/null; }

cmd_start() {
  discover_model start
  ensure_bridge_installed

  # Render first and compare: a bridge left running from an earlier invocation
  # is serving the OLD settings, and silently ignoring a changed QWEN_URL or
  # QWEN_EFFORT is worse than a two-second restart.
  # The hooks module is compared too: LiteLLM imports it once at startup, so a
  # bridge left running from before this file existed keeps 400ing on WebSearch
  # until something notices the difference.
  local rendered current="" rendered_hooks current_hooks=""
  rendered=$(render_config)
  rendered_hooks=$(render_hooks)
  [[ -f "$CONFIG" ]] && current=$(cat "$CONFIG" 2>/dev/null || true)
  [[ -f "$HOOKS" ]] && current_hooks=$(cat "$HOOKS" 2>/dev/null || true)

  if bridge_up; then
    if [[ "$rendered" == "$current" && "$rendered_hooks" == "$current_hooks" ]]; then
      say "bridge already running on $BRIDGE_URL"
      return 0
    fi
    say "settings changed - restarting the bridge"
    cmd_stop
  fi

  say "server at $QWEN_URL is serving $MODEL_ID (${MODEL_CTX} ctx)"
  if [[ "$QWEN_LOG_PAYLOADS" == "1" ]]; then
    warn "traffic recording is ON - every prompt, file and reply goes to $PAYLOAD_DIR
         Start the bridge again without QWEN_LOG_PAYLOADS=1 to stop, and delete that
         directory when you are done. Do not attach those files to a bug report."
  fi
  mkdir -p "$BRIDGE_HOME" "$LOG_DIR"
  printf '%s\n' "$rendered" > "$CONFIG"
  printf '%s\n' "$rendered_hooks" > "$HOOKS"

  nohup "$VENV/bin/litellm" --config "$CONFIG" \
      --host "$BRIDGE_HOST" --port "$BRIDGE_PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  local i
  for i in $(seq 1 60); do
    if bridge_up; then
      say "bridge up on $BRIDGE_URL (log: $LOG_FILE)"
      return 0
    fi
    sleep 1
  done
  die "bridge did not come up within 60s - check $LOG_FILE"
}

# Stopping has to be synchronous. Returning while the old process still holds
# the port makes the next start believe the bridge is healthy, and the session
# then dies with "connection refused" once the shutdown completes.
cmd_stop() {
  local pid=""
  [[ -f "$PID_FILE" ]] && pid=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  else
    pkill -f "litellm --config $CONFIG" 2>/dev/null || true
  fi

  local i
  for i in $(seq 1 20); do
    if ! bridge_up; then
      rm -f "$PID_FILE"
      say "bridge stopped"
      return 0
    fi
    sleep 1
  done

  # Still answering after 20s - stop being polite.
  if [[ -n "${pid:-}" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  pkill -9 -f "litellm --config $CONFIG" 2>/dev/null || true
  sleep 1
  rm -f "$PID_FILE"
  if bridge_up; then
    warn "something is still listening on $BRIDGE_URL and it is not ours"
  else
    say "bridge stopped"
  fi
}

cmd_status() {
  if bridge_up; then
    say "bridge   : running on $BRIDGE_URL"
  else
    say "bridge   : not running"
  fi
  if curl -sf -o /dev/null -m 5 "$QWEN_URL/v1/models" 2>/dev/null; then
    discover_model status
    say "qwen     : $MODEL_ID @ $QWEN_URL (${MODEL_CTX} ctx)"
  else
    say "qwen     : not answering at $QWEN_URL"
  fi
}

# The env Claude Code needs. Every model slot is mapped, so /model inside a
# session cannot accidentally reach for something that is not there.
emit_env() {
  cat <<ENV
# WARNING: these override Claude Code for EVERY 'claude' started from the shell
# you eval them in - including your normal cloud session, which will silently
# run against Qwen instead. Never put them in ~/.bashrc, ~/.zshrc or a profile.
# To keep the two apart, do not eval this at all: 'claude-code.sh run' (or the
# 'qwen-claude' command that 'install' drops on your PATH) sets them inside its
# own process and execs Claude Code there, leaving your shell - and plain
# 'claude' - untouched.
export ANTHROPIC_BASE_URL="$BRIDGE_URL"
export ANTHROPIC_AUTH_TOKEN="$BRIDGE_KEY"
export ANTHROPIC_MODEL="qwen5090"
export ANTHROPIC_SMALL_FAST_MODEL="qwen5090-fast"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="qwen5090-fast"
# Auto mode asks for "claude-sonnet-5" to classify tool calls, so the sonnet
# slot is the only lever that reaches its classifier - CLAUDE_CODE_AUTO_MODE_MODEL
# exists but is ignored (measured against 2.1.238, env and settings.json alike).
# Left on the main alias, every classification is an xhigh thinking pass against
# a 60-second timeout, and each tool fails with "qwen5090 is temporarily
# unavailable (timed out), so auto mode cannot determine the safety of ...".
# Side effect: /model sonnet picks that alias too - same weights, no thinking.
export ANTHROPIC_DEFAULT_SONNET_MODEL="qwen5090-classifier"
export ANTHROPIC_DEFAULT_OPUS_MODEL="qwen5090"
# Claude Code does not know this model, so it would assume a 200K window and
# start compacting long before the real limit.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$MODEL_CTX"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
ENV
}

cmd_env() {
  discover_model env
  emit_env
}

cmd_run() {
  cmd_start
  # Same deal as the bridge venv: install it rather than telling the user to.
  ensure_claude_installed
  # shellcheck disable=SC1090
  eval "$(emit_env)"
  say "starting Claude Code on $MODEL_ID"
  exec claude "$@"
}

cmd_doctor() {
  echo "QWEN_URL     : $QWEN_URL"
  echo "bridge       : $BRIDGE_URL"
  echo "venv         : $VENV"
  echo "config       : $CONFIG"
  echo "hooks        : $HOOKS"
  echo "log          : $LOG_FILE"
  echo
  cmd_status
  echo
  if bridge_up; then
    say "end-to-end test through the bridge:"
    curl -s -m 120 "$BRIDGE_URL/v1/messages" \
      -H "x-api-key: $BRIDGE_KEY" -H 'anthropic-version: 2023-06-01' \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen5090","max_tokens":512,"messages":[{"role":"user","content":"Reply with exactly: BRIDGE OK"}]}' \
      | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("   could not parse the reply - see the log"); sys.exit(1)
blocks = d.get("content") or []
text = "".join(b.get("text","") for b in blocks if b.get("type")=="text").strip()
print("   reply:", repr(text) if text else "(empty - the model spent its budget thinking)")
print("   usage:", d.get("usage"))' || warn "the test request failed"
  fi
}

# --------------------------------------------------------------- install ----
# Copies this script to a stable home and drops a launcher on PATH, so a session
# can be opened from any directory without remembering where the repo is. The
# server URL in effect right now is baked into the launcher - someone installing
# from a laptop is pointing at a server across the network, and having to repeat
# QWEN_URL= on every invocation would defeat the point.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
INSTALLED_SCRIPT="$HOME/.qwen5090/claude-code.sh"
LAUNCHER="$INSTALL_BIN/$INSTALL_NAME"

cmd_install() {
  mkdir -p "$HOME/.qwen5090" "$INSTALL_BIN"

  # Re-installing from the installed copy would be cp onto itself.
  if [[ "$SELF" != "$INSTALLED_SCRIPT" ]]; then
    cp "$SELF" "$INSTALLED_SCRIPT"
  fi
  chmod +x "$INSTALLED_SCRIPT"

  # Quoted heredoc, then substitute: an unquoted one would need $ escaped in
  # every line, and getting that subtly wrong produces a launcher that looks
  # fine and is not valid shell.
  local tmp="$LAUNCHER.tmp.$$"
  cat > "$tmp" <<'LAUNCH'
#!/usr/bin/env bash
# Generated by claude-code.sh install - re-run it to update.
# Opens a Claude Code session driven by the Qwen server below.
#
#   NAME                 interactive session in the current directory
#   NAME -p "..."        one-shot
#   NAME status|doctor|stop|restart
#
# Override the server with QWEN_URL, its context window with QWEN_CTX,
# the thinking depth with QWEN_EFFORT (low|medium|xhigh on the Qwen
# checkpoints, low|high|max on DeepSeek V4; left unset, each template's
# own default).
set -euo pipefail
: "${QWEN_URL:=@@URL@@}"
export QWEN_URL
exec bash "@@SCRIPT@@" "$@"
LAUNCH

  # sed -i is not portable to macOS, so rewrite through another temp file.
  sed -e "s|@@URL@@|$QWEN_URL|" -e "s|@@SCRIPT@@|$INSTALLED_SCRIPT|" \
      -e "s|NAME|$INSTALL_NAME|" "$tmp" > "$tmp.2"
  mv "$tmp.2" "$tmp"
  rm -f "$tmp.2"

  # Never leave a broken launcher on PATH.
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    die "generated launcher is not valid shell - not installing it"
  fi
  mv "$tmp" "$LAUNCHER"
  chmod +x "$LAUNCHER"

  say "installed $LAUNCHER -> $QWEN_URL"

  case ":$PATH:" in
    *":$INSTALL_BIN:"*) say "run '$INSTALL_NAME' from any directory" ;;
    *)  warn "$INSTALL_BIN is not on your PATH. Add this to ~/.bashrc or ~/.zshrc:"
        printf '\n    export PATH="%s:$PATH"\n\n' "$INSTALL_BIN" >&2 ;;
  esac
}

cmd_uninstall() {
  rm -f "$LAUNCHER"
  say "removed $LAUNCHER"
  say "the bridge venv is still at $BRIDGE_HOME - delete it by hand if you are done with it"
}

# `shift` returns non-zero when there are no positional parameters, and under
# `set -e` that kills the script before it prints anything - so a bare
# `claude-code.sh` (the most common way to run it) exited 1 in silence. Resolve
# the verb first, and only shift when there is actually something to shift.
cmd="${1:-run}"
if (( $# > 0 )); then shift; fi

case "$cmd" in
  start)     cmd_start "$@" ;;
  stop)      cmd_stop "$@" ;;
  restart)   cmd_stop; cmd_start "$@" ;;
  status)    cmd_status "$@" ;;
  env)       cmd_env "$@" ;;
  doctor)    cmd_doctor "$@" ;;
  run)       cmd_run "$@" ;;
  install)   cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  install-claude) cmd_install_claude "$@" ;;
  -h|--help|help)
    # print the header block, stopping at the first line that is not a comment
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  # Anything else is a Claude Code flag: put it back and launch.
  *)         cmd_run "$cmd" "$@" ;;
esac
