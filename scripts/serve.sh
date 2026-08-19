#!/usr/bin/env bash
# Serve Qwen3.8-27B-NVFP4 with vLLM, tuned for a single RTX 5090 (32 GB).
# Every knob is env-overridable, e.g.:  CTX=262144 PORT=8080 bash scripts/serve.sh
set -euo pipefail

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"
CTX="${CTX:-131072}"          # native max is 262144; 128K is the safe default on 32 GB
PORT="${PORT:-8000}"
GPU_UTIL="${GPU_UTIL:-0.90}"  # leave headroom: on WSL the same GPU drives the Windows desktop
MTP="${MTP:-1}"               # multi-token prediction (speculative decoding); set 0 to disable

# Mirror all output (vLLM included) to a persistent log for diagnostics.
LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/serve-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: serve.sh failed at line $LINENO (exit $?)"' ERR
echo ">> logging to $LOG_FILE"

if [[ ! -x "$VENV/bin/vllm" ]]; then
  echo "vLLM venv not found at $VENV — run install.ps1 (or scripts/setup-wsl.sh) first." >&2
  exit 1
fi

ARGS=(
  serve "$MODEL"
  --host 0.0.0.0 --port "$PORT"
  --max-model-len "$CTX"
  --kv-cache-dtype fp8
  --gpu-memory-utilization "$GPU_UTIL"
  --reasoning-parser qwen3
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
)
if [[ "$MTP" == "1" ]]; then
  ARGS+=(--speculative-config '{"method":"mtp","num_speculative_tokens":3}')
fi

echo ">> model=$MODEL ctx=$CTX port=$PORT gpu_util=$GPU_UTIL mtp=$MTP"
echo ">> OpenAI-compatible endpoint: http://localhost:$PORT/v1"
exec "$VENV/bin/vllm" "${ARGS[@]}"
