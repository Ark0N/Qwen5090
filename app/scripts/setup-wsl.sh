#!/usr/bin/env bash
# One-time setup inside WSL2 Ubuntu: uv + Python 3.13 venv + NVFP4-capable vLLM
# + Qwen3.8-27B-NVFP4 model download. Normally invoked by install.ps1, but safe
# to run directly from a WSL shell too. Re-running is idempotent.
set -euo pipefail

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"

# Mirror all output to a persistent log so failed runs can be diagnosed later
# (bundled by collect-logs.ps1 / the GUI's "Collect diagnostics" button).
LOG_DIR="$HOME/.qwen5090/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: setup-wsl.sh failed at line $LINENO (exit $?)"' ERR
echo "(logging to $LOG_FILE)"

echo "== [1/4] Checking the GPU is visible inside WSL =="
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi failed inside WSL." >&2
  echo "Install/update the *Windows* NVIDIA driver (>= 570; Game Ready or Studio)," >&2
  echo "then run 'wsl --shutdown' from Windows and try again." >&2
  echo "Never install a Linux NVIDIA driver inside WSL — it shadows the Windows one." >&2
  exit 1
fi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

echo "== [2/4] Installing uv (Python package manager) =="
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

echo "== [3/4] Creating venv + installing vLLM (downloads CUDA wheels; takes a while) =="
UV_FLAGS=()
if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  UV_FLAGS+=(--no-progress)   # keep GUI logs readable (no \r progress bars)
fi
mkdir -p "$(dirname "$VENV")"
uv venv "${UV_FLAGS[@]}" "$VENV" --python 3.13
uv pip install "${UV_FLAGS[@]}" --python "$VENV/bin/python" \
  "vllm>=0.25.0" \
  "flashinfer-python>=0.6.13" \
  "nvidia-cutlass-dsl>=4.5.2" \
  "openai>=1.60" \
  --torch-backend=auto

echo "== [4/4] Downloading model weights: $MODEL (~17 GB) =="
if [[ "${SKIP_DOWNLOAD:-0}" == "1" ]]; then
  echo "SKIP_DOWNLOAD=1 set — skipping. vLLM will download on first serve instead."
elif [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  # No tqdm bars in GUI mode; report cache growth every 15s instead.
  export HF_HUB_DISABLE_PROGRESS_BARS=1
  CACHE_DIR="$HOME/.cache/huggingface/hub/models--${MODEL//\//--}"
  "$VENV/bin/python" - "$MODEL" <<'PY' &
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("Model cached.")
PY
  DL_PID=$!
  while kill -0 "$DL_PID" 2>/dev/null; do
    SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    echo "   ... downloaded ${SIZE:-0} of ~17G"
    sleep 15
  done
  wait "$DL_PID"
else
  "$VENV/bin/python" - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("Model cached.")
PY
fi

echo
echo "Setup complete."
echo "  Start the server from Windows:  double-click 'Start Qwen 5090.cmd' (or .\\app\\run.ps1)"
echo "  ...or from this WSL shell:      bash app/scripts/serve.sh"
