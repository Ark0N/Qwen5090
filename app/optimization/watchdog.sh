#!/usr/bin/env bash
# Watchdog: keeps the optimization loop alive. Pure bash - no model
# dependency. The control plane is: this (bash) keeps loop.py (python)
# alive; loop.py keeps the model server alive; the dsh retryPolicy keeps the
# harness (LLM-driven) alive across server swaps.
#
# Liveness is judged by the loop's own PID file (never by command-line
# pattern matching: a shell that merely mentions "loop.py" in its own
# command line once fooled the old pgrep-based check).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$ROOT/.watchdog.lock"

# single instance
if [[ -f "$LOCK" ]]; then
  oldpid="$(cat "$LOCK" 2>/dev/null)"
  if [[ -n "${oldpid:-}" ]] && kill -0 "$oldpid" 2>/dev/null; then
    echo "watchdog already running (pid $oldpid)"
    exit 0
  fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

loop_alive() {
  [[ -f "$ROOT/.loop.pid" ]] || return 1
  local pid
  pid="$(cat "$ROOT/.loop.pid" 2>/dev/null)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # guard against pid reuse: the process must actually be the loop
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'loop[.]py' || return 1
  return 0
}

echo "[$(date '+%F %T')] watchdog started (pid $$)" >> "$ROOT/logs/watchdog.log"
while true; do
  if [[ ! -f "$ROOT/STOP" ]] && ! loop_alive; then
    # double-check before restarting (avoid racing another start)
    sleep 5
    if [[ ! -f "$ROOT/STOP" ]] && ! loop_alive; then
      echo "[$(date '+%F %T')] watchdog: loop not running - restarting" >> "$ROOT/logs/watchdog.log"
      (cd "$ROOT" && setsid nohup python3 loop.py >> logs/loop.out 2>&1 &)
    fi
  fi
  sleep 30
done