#!/usr/bin/env bash
# Lifecycle control for the ninfer model server on port 8000 (optimization use).
#
#   serve_ctl.sh status   # is it up? what flags?
#   serve_ctl.sh stop     # kill the server and wait for the port to close
#   serve_ctl.sh start    # start from server.flags (one flag per line), wait until ready
#
# The live server started by the product (serve-ninfer.sh) is stopped the same
# way: pkill on the artifact path, then wait for the port.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NINFER=/root/.qwen5090/ninfer/bin/ninfer-serve
ARTIFACT=/root/.qwen5090/ninfer/models/qwen3_8_27b_nvfp4.ninfer
FLAGS_FILE="$ROOT/server.flags"
LOG_DIR="$ROOT/logs"
PORT=8000
MODEL_ID=qwen3.8-27b

mkdir -p "$LOG_DIR"

port_open() {
  curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -q 200
}

wait_open() {
  local secs="${1:-120}" i
  for i in $(seq 1 "$secs"); do
    port_open && return 0
    sleep 1
  done
  return 1
}

wait_closed() {
  local secs="${1:-30}" i
  for i in $(seq 1 "$secs"); do
    port_open || return 0
    sleep 1
  done
  return 1
}

live_flags() {
  # Current command line of the live server, one flag per line (for status).
  local pid
  pid="$(pgrep -f "ninfer-serve $ARTIFACT" | head -1 || true)"
  [[ -n "$pid" ]] && tr ' ' '\n' < "/proc/$pid/cmdline" | sed '/^$/d'
}

case "${1:-status}" in
  status)
    if port_open; then
      echo "server: UP on :$PORT"
      curl -s -m 3 "http://127.0.0.1:$PORT/v1/models"
      echo
      echo "--- live cmdline ---"
      live_flags
    else
      echo "server: DOWN"
    fi
    ;;
  stop)
    pkill -f "ninfer-serve $ARTIFACT" 2>/dev/null || true
    pkill -f 'app/scripts/serve-ninfer.sh' 2>/dev/null || true
    if wait_closed 30; then
      echo "server: stopped (port $PORT closed)"
    else
      echo "ERROR: port $PORT still open 30s after stop" >&2
      exit 1
    fi
    ;;
  start)
    [[ -f "$FLAGS_FILE" ]] || { echo "ERROR: no flags file at $FLAGS_FILE" >&2; exit 1; }
    mapfile -t FLAGS < "$FLAGS_FILE"
    local_ts="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="$LOG_DIR/server-$local_ts.log"
    nohup "$NINFER" "${FLAGS[@]}" >> "$LOG_FILE" 2>&1 &
    echo "server: starting (pid $!) -> $LOG_FILE"
    if wait_open 120; then
      # Warm-up request so the first benchmark turn does not pay cold costs.
      curl -s -m 90 "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'content-type: application/json' \
        -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"warmup\"}],\"max_tokens\":4}" \
        > /dev/null || true
      echo "server: up on :$PORT"
    else
      echo "ERROR: server did not come up within 120s" >&2
      # The specific failure line (e.g. a VRAM reservation error) comes
      # BEFORE a long usage block, so tail alone misses it - grep it first.
      grep -m1 -E '\[(error|fatal)\]' "$LOG_FILE" >&2 || true
      tail -8 "$LOG_FILE" >&2 || true
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 {status|stop|start}" >&2
    exit 2
    ;;
esac