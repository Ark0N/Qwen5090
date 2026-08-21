#!/usr/bin/env bash
# Install a systemd **user** service so the vLLM server comes back by itself
# after a reboot, instead of needing someone to run serve.sh by hand.
#
#   bash install-service.sh install     # write the unit + config, enable, start
#   bash install-service.sh uninstall   # stop, disable, remove the unit
#   bash install-service.sh status      # unit state + whether the API answers
#   bash install-service.sh logs        # follow the journal
#
# A *user* unit (not a system one) on purpose: it needs no root, runs as you,
# and inherits your $HOME - the venv, the model cache and the logs all live
# under ~/.qwen5090. The one catch is that user services normally stop at
# logout and only start at boot if lingering is enabled for the account, so
# `install` turns that on (and says so if it cannot).
#
# Settings live in ~/.qwen5090/server.env, not in the unit, so you can change
# the context or the model with an edit and a restart instead of regenerating
# anything. Linux only - the Windows build starts the server from the GUI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"

UNIT_NAME="qwen5090.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/$UNIT_NAME"
ENV_FILE="$HOME/.qwen5090/server.env"
SERVE="$SCRIPT_DIR/serve.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found - this needs systemd."
  systemctl --user is-system-running >/dev/null 2>&1 || \
    systemctl --user show-environment >/dev/null 2>&1 || \
    die "no systemd user session (systemctl --user is not answering)."
  if qwen5090_is_wsl; then
    echo "NOTE: this looks like WSL. systemd works there only if /etc/wsl.conf has"
    echo "      [boot] systemd=true - and on Windows the GUI starts the server anyway."
  fi
}

write_env() {
  mkdir -p "$(dirname "$ENV_FILE")"
  if [[ -f "$ENV_FILE" ]]; then
    echo "keeping existing $ENV_FILE"
    return
  fi
  cat > "$ENV_FILE" <<'ENVEOF'
# Settings for the qwen5090 systemd service. Restart to apply:
#     systemctl --user restart qwen5090
# Every name here is just a serve.sh environment variable; see that script's
# comments for the full list and what each one costs.

# Which checkpoint to serve. The abliterated build is the uncensored one.
MODEL=unsloth/Qwen3.8-27B-NVFP4
#MODEL=sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4

# Context window. 131072 is the default for a reason: it keeps an fp8 KV cache,
# which keeps MTP, which is ~80 tok/s against ~49 - and it keeps concurrency.
CTX=131072
PORT=8000

# --- Full 262,144-token window -----------------------------------------------
# Above 131072 the KV cache switches to 4-bit and MTP is forced off, because
# stock vLLM garbles output with that combination. To run the full window fast,
# first apply the upstream fix:
#     bash app/scripts/patch-mtp.sh apply
# then uncomment all four of these. MAX_SEQS=1 and GPU_UTIL=0.93 are not
# optional there - at MAX_SEQS=16 the KV cache comes up short and vLLM refuses
# to start. Expect ~139 tok/s, and exactly one session at a time.
#CTX=262144
#MTP=1
#QWEN5090_MTP_TQ_PATCHED=1
#MAX_SEQS=1
#GPU_UTIL=0.93
ENVEOF
  echo "wrote $ENV_FILE"
}

write_unit() {
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT" <<UNITEOF
[Unit]
Description=Qwen5090 vLLM server (OpenAI-compatible API)
Documentation=https://github.com/Ark0N/Qwen5090
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
# FlashInfer's JIT links with 'c++' by that exact name, and Triton shells out
# to a C compiler on the first CUDA call. A systemd unit does not inherit a
# login shell's PATH, so name the system paths explicitly and keep ~/.local/bin
# for uv.
Environment=PATH=/usr/local/bin:/usr/bin:/bin:%h/.local/bin
ExecStart=/bin/bash $SERVE
# Weights load, torch.compile and cudagraph capture take a few minutes cold;
# do not let systemd call that a failed start.
TimeoutStartSec=900
TimeoutStopSec=120
Restart=on-failure
RestartSec=20
# The GPU is a single exclusive resource - never let two of these overlap.
KillMode=mixed

[Install]
WantedBy=default.target
UNITEOF
  echo "wrote $UNIT"
}

case "${1:-status}" in
  install)
    require_systemd
    [[ -f "$SERVE" ]] || die "serve.sh not found next to this script"
    write_env
    write_unit
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT_NAME" >/dev/null
    echo "enabled $UNIT_NAME"

    # Without lingering, a user unit dies at logout and does not start at boot.
    if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
      echo "lingering already on - the server will start at boot"
    elif loginctl enable-linger "$USER" 2>/dev/null; then
      echo "lingering enabled - the server will start at boot"
    else
      echo
      echo "NOTE: could not enable lingering (it needs authentication)."
      echo "      Without it the service starts when you log in, not at boot."
      echo "      To fix:   sudo loginctl enable-linger $USER"
    fi

    systemctl --user restart "$UNIT_NAME"
    echo
    echo "starting - first boot takes a few minutes (weights + compile)."
    echo "  watch:   bash $0 logs"
    echo "  check:   bash $0 status"
    ;;

  uninstall)
    require_systemd
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl --user daemon-reload
    echo "removed $UNIT"
    echo "(left $ENV_FILE alone - delete it by hand if you want it gone)"
    ;;

  status)
    require_systemd
    systemctl --user status "$UNIT_NAME" --no-pager --lines=0 2>&1 | head -6 || true
    echo
    port="$( { grep -E '^PORT=' "$ENV_FILE" 2>/dev/null || echo PORT=8000; } | tail -1 | cut -d= -f2)"
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "API: answering on http://127.0.0.1:${port}/v1"
    else
      echo "API: not answering yet on port ${port} (still loading, or stopped)"
    fi
    ;;

  logs)
    require_systemd
    journalctl --user -u "$UNIT_NAME" -f -n 60
    ;;

  *)
    echo "usage: bash install-service.sh [install|uninstall|status|logs]" >&2
    exit 2
    ;;
esac
