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
#
# Works on Linux, macOS and inside WSL, against a local or a remote server:
#   QWEN_URL=http://<host>:8000 bash claude-code.sh run
set -euo pipefail

# ---------------------------------------------------------------- knobs -----
QWEN_URL="${QWEN_URL:-http://localhost:8000}"     # where vLLM is listening
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
# How hard the model thinks. The chat template accepts low, medium and xhigh
# ONLY - it rejects "high" outright, and "high" is exactly what Claude Code
# sends when extended thinking is on, so the bridge drops the client's value and
# substitutes this one. See the reasoning_effort note in the config below.
QWEN_EFFORT="${QWEN_EFFORT:-xhigh}"

VENV="$BRIDGE_HOME/venv"
CONFIG="$BRIDGE_HOME/config.yaml"
LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
LOG_FILE="$LOG_DIR/bridge.log"
PID_FILE="$BRIDGE_HOME/bridge.pid"
BRIDGE_URL="http://$BRIDGE_HOST:$BRIDGE_PORT"

case "$QWEN_EFFORT" in
  low|medium|xhigh) ;;
  *) printf 'ERROR: QWEN_EFFORT must be low, medium or xhigh (got "%s").\n' "$QWEN_EFFORT" >&2
     printf '       The chat template rejects every other value, "high" included.\n' >&2
     exit 1 ;;
esac

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
print(d.get("max_model_len") or 262144)' 2>/dev/null || true)

  [[ -n "${MODEL_ID:-}" ]] || die "could not read a model id from $QWEN_URL/v1/models"
  MODEL_CTX="${MODEL_CTX:-262144}"
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

  # setup-wsl.sh puts uv in ~/.local/bin, and uv's own installer only appends
  # that to ~/.bashrc - which `bash -c` never reads, because it is not a login
  # or interactive shell. Every route into this script is a `bash -c` (the GUI,
  # claude-code.ps1, the generated launcher), so without this line `command -v
  # uv` misses a uv that is sitting right there, and we fall through to the
  # python3 -m venv branch - which cannot work either. Same line setup-wsl.sh
  # uses before its own uv check.
  export PATH="$HOME/.local/bin:$PATH"

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
  local rendered current=""
  rendered=$(render_config)
  [[ -f "$CONFIG" ]] && current=$(cat "$CONFIG" 2>/dev/null || true)

  if bridge_up; then
    if [[ "$rendered" == "$current" ]]; then
      say "bridge already running on $BRIDGE_URL"
      return 0
    fi
    say "settings changed - restarting the bridge"
    cmd_stop
  fi

  say "server at $QWEN_URL is serving $MODEL_ID (${MODEL_CTX} ctx)"
  mkdir -p "$BRIDGE_HOME" "$LOG_DIR"
  printf '%s\n' "$rendered" > "$CONFIG"

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
  command -v claude >/dev/null 2>&1 || die "Claude Code is not installed or not on PATH.

Install it with:   npm install -g @anthropic-ai/claude-code
Then re-run:       bash claude-code.sh run"
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
# Override the server with QWEN_URL, the thinking depth with QWEN_EFFORT
# (low|medium|xhigh).
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
  -h|--help|help)
    # print the header block, stopping at the first line that is not a comment
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  # Anything else is a Claude Code flag: put it back and launch.
  *)         cmd_run "$cmd" "$@" ;;
esac
