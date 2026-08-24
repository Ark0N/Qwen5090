#!/usr/bin/env bash
# Start the local status dashboard - the Linux answer to the Windows GUI's
# status pills.
#
#   bash app/scripts/dashboard.sh                    # http://127.0.0.1:8600
#   DASH_PORT=9000 bash app/scripts/dashboard.sh
#   DASH_HOST=0.0.0.0 bash app/scripts/dashboard.sh  # reachable from the LAN
#   QWEN_URL=http://otherbox:8000 bash app/scripts/dashboard.sh
#
# It is read-only: it shows what is loaded and what the machine is doing, and
# has no button that starts, stops or reconfigures anything. That is deliberate
# - serve.sh and install-service.sh own those paths and carry the safeguards.
#
# Runs in the foreground so Ctrl-C stops it. To leave one running:
#     nohup bash app/scripts/dashboard.sh >/dev/null 2>&1 &
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"

DASH_HOST="${DASH_HOST:-127.0.0.1}"
DASH_PORT="${DASH_PORT:-8600}"

# Deliberately the system python3, not the vLLM venv's. dashboard.py imports
# nothing outside the standard library precisely so it still runs when the venv
# is missing or half-rebuilt - which is one of the times you most want to look
# at it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is not installed, and the dashboard is a python script." >&2
  echo "       sudo apt-get install -y python3" >&2
  exit 1
fi

# A dashboard that exposes host telemetry should not land on the LAN by
# accident, so say plainly when it has been asked to.
if [[ "$DASH_HOST" == "0.0.0.0" ]]; then
  echo ">> WARNING: binding to all interfaces - anyone who can reach this box on" >&2
  echo ">>          port $DASH_PORT can see its model, load and GPU telemetry." >&2
fi

# -u because python buffers stdout when it is not a terminal, and the usual way
# to leave this running is `nohup ... &` - without it the startup banner, the
# one place the URL is printed, never reaches the log file.
exec python3 -u "$SCRIPT_DIR/dashboard.py" --host "$DASH_HOST" --port "$DASH_PORT" "$@"
