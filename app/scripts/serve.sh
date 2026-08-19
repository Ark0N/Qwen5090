#!/usr/bin/env bash
# Serve Qwen3.8-27B-NVFP4 with vLLM, tuned for a single RTX 5090 (32 GB).
# Every knob is env-overridable, e.g.:  CTX=262144 PORT=8080 bash scripts/serve.sh
set -euo pipefail

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"
CTX="${CTX:-262144}"          # the model's native max; drop to 131072 if the KV cache will not fit
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

check_wsl_memory() {
  # vLLM loads each weights shard through one private, writable mmap of the
  # whole file. Linux heuristic overcommit (vm.overcommit_memory=0, the WSL
  # default) refuses a mapping larger than MemAvailable + free swap, so the
  # ~21 GiB shard dies with "unable to mmap ...: Cannot allocate memory (12)"
  # about 40 s into startup — Windows gives the WSL VM only half the PC's RAM
  # by default. Catch it here, where the fix can be explained in five lines
  # instead of a 200-line traceback.
  [[ "${QWEN5090_SKIP_MEMCHECK:-0}" == "1" ]] && return 0
  [[ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo 0)" == "0" ]] || return 0

  local model_dir shard avail_kib swap_kib budget
  if [[ -d "$MODEL" ]]; then
    model_dir="$MODEL"
  else
    model_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}"
  fi
  [[ -d "$model_dir" ]] || return 0   # not downloaded yet — vLLM will fetch it

  # Every fallible substitution needs '|| true': under 'set -e' a bare
  # assignment inherits the pipeline's exit status and would abort the server.
  shard=$(find -L "$model_dir" -name '*.safetensors' -printf '%s\n' 2>/dev/null | sort -n | tail -1 || true)
  avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo || true)
  swap_kib=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo || true)
  [[ -n "${shard:-}" && -n "${avail_kib:-}" ]] || return 0
  budget=$(( (avail_kib + ${swap_kib:-0}) * 1024 ))
  (( shard > budget )) || return 0

  local shard_gib="$((shard / 1073741824))" budget_gib="$((budget / 1073741824))"
  cat >&2 <<EOF

ERROR: this WSL virtual machine is too small to load the model weights.

  largest weights file : ${shard_gib} GiB
  usable RAM + swap    : ${budget_gib} GiB

Windows gives WSL half the PC's RAM by default, and Linux refuses to map a file
it cannot back with memory. Fix it on the WINDOWS side:

  1. Open the Qwen 5090 app and click "Install / Repair" — it sizes WSL for you.

  Or by hand: create %USERPROFILE%\.wslconfig containing

       [wsl2]
       memory=24GB
       swap=24GB

  2. Then run   wsl --shutdown   in PowerShell and start the server again.

(Override this check with QWEN5090_SKIP_MEMCHECK=1 to let vLLM try anyway.)
EOF
  exit 1
}
check_wsl_memory

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
