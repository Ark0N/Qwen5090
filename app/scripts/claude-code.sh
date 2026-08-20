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
#   bash claude-code.sh status|stop|doctor
#
# Works on Linux, macOS and inside WSL, against a local or a remote server:
#   QWEN_URL=http://<5090-ip>:8000 bash claude-code.sh run
set -euo pipefail

# ---------------------------------------------------------------- knobs -----
QWEN_URL="${QWEN_URL:-http://localhost:8000}"     # where vLLM is listening
BRIDGE_PORT="${BRIDGE_PORT:-4000}"                # where the bridge listens
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"           # loopback: this is not an auth boundary
BRIDGE_KEY="${BRIDGE_KEY:-sk-qwen5090-local}"     # local-only shared secret
BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.qwen5090/bridge}"
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

  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV" >/dev/null
    VIRTUAL_ENV="$VENV" uv pip install --quiet "${BRIDGE_PINS[@]}"
  else
    command -v python3 >/dev/null 2>&1 || die "need python3 (or uv) to install the bridge"
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
  local drop='      additional_drop_params: ["reasoning_effort"]'
  local main_extra="      extra_body: {\"reasoning_effort\": \"$QWEN_EFFORT\"}"

  # The fast alias turns thinking off entirely instead - reasoning tokens count
  # against max_tokens, and Claude Code's background calls use a small cap, so
  # with thinking on they come back empty behind an HTTP 200.
  local fast_extra="      extra_body: {\"chat_template_kwargs\": {\"enable_thinking\": false}}"
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
export ANTHROPIC_BASE_URL="$BRIDGE_URL"
export ANTHROPIC_AUTH_TOKEN="$BRIDGE_KEY"
export ANTHROPIC_MODEL="qwen5090"
export ANTHROPIC_SMALL_FAST_MODEL="qwen5090-fast"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="qwen5090-fast"
export ANTHROPIC_DEFAULT_SONNET_MODEL="qwen5090"
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

case "${1:-run}" in
  start)  shift; cmd_start "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  restart) shift; cmd_stop; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  env)    shift; cmd_env "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  run)    shift; cmd_run "$@" ;;
  -h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)      cmd_run "$@" ;;
esac
