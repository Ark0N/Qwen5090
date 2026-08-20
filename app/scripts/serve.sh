#!/usr/bin/env bash
# Serve Qwen3.8-27B-NVFP4 with vLLM, tuned for a single RTX 5090 (32 GB).
# Every knob is env-overridable, e.g.:  CTX=262144 PORT=8080 bash scripts/serve.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-build-tools.sh
source "$SCRIPT_DIR/lib-build-tools.sh"

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"   # or sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
# The model's native maximum. It does not fit with an fp8 KV cache on a 32 GB
# card (that window wants ~9.1 GiB against the ~6.2 GiB free after the weights),
# so the KV precision is chosen further down to match the context asked for.
CTX="${CTX:-262144}"
PORT="${PORT:-8000}"
GPU_UTIL_EXPLICIT="${GPU_UTIL+set}"
GPU_UTIL="${GPU_UTIL:-0.90}"  # leave headroom: on WSL the same GPU drives the Windows desktop
MTP="${MTP:-1}"               # multi-token prediction (speculative decoding); set 0 to disable
# How many requests may be in flight at once. vLLM defaults to 256, which this
# hybrid model cannot honour at a long context: its GDN/Mamba layers need one
# cache block per decode sequence, and a big KV cache leaves few spare blocks -
# "max_num_seqs (256) exceeds available Mamba cache blocks" aborts the start.
# This is a personal server; a handful of concurrent chats is plenty.
MAX_SEQS="${MAX_SEQS:-16}"

# Mirror all output (vLLM included) to a persistent log for diagnostics.
LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/serve-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: serve.sh failed at line $LINENO (exit $?)"' ERR
echo ">> logging to $LOG_FILE"

# vLLM is exec'd below by absolute path rather than through an activated venv,
# so the venv's bin/ never makes it onto PATH. FlashInfer's JIT shells out to
# `ninja` by bare name, and ninja ships *in the venv* - without this the build
# dies with "FileNotFoundError: [Errno 2] No such file or directory: 'ninja'"
# even though the file is right there.
export PATH="$VENV/bin:$PATH"

if [[ ! -x "$VENV/bin/vllm" ]]; then
  echo "vLLM venv not found at $VENV — run install.ps1 (or scripts/setup-wsl.sh) first." >&2
  exit 1
fi

# Triton compiles this model's kernels (and its own CUDA driver module) with a
# C compiler, at runtime, the first time they are used. Machines set up before
# the installer started installing one still have none, and the failure lands
# 60 s in, as a 200-line traceback ending in "Failed to find C compiler".
# No-op once build-essential is there.
ensure_build_tools || exit 1

# Second half of the same problem, and the nastier half. build-essential gives
# Triton its C compiler, but FlashInfer JITs *CUDA* kernels, and nvcc ships in
# the CUDA toolkit - not in the driver. A stock Ubuntu WSL rootfs therefore has
# no nvcc, and FlashInfer dies with:
#
#     RuntimeError: Could not find nvcc and default cuda_home='/usr/local/cuda'
#     doesn't exist
#
# It bites twice, and the second one is easy to miss:
#   1. the top-k/top-p sampler, during KV-cache sizing at startup;
#   2. the batch *prefill* attention kernel, which is only built when the first
#      real request arrives - so the server reaches "Application startup
#      complete", answers /v1/models with 200, and then kills its own engine on
#      the first chat message with a 500.
#
# Ubuntu's own toolkit is no use (24.04 ships CUDA 12.0, which cannot target
# Blackwell), but nothing needs downloading: torch's CUDA wheels already vendor
# a complete toolkit inside the venv, nvcc included. Point CUDA_HOME at it.
# Two details keep that from working out of the box - the wheel lays libraries
# out in lib/ while FlashInfer links -L$CUDA_HOME/lib64, and it ships
# libcudart.so.NN with no bare .so symlink for -lcudart - so hand FlashInfer a
# small directory of symlinks (including the driver's libcuda.so, which lives
# under /usr/lib/wsl/lib and not in the wheel at all) via its own ldflags hook.
ATTN_BACKEND="${ATTN_BACKEND-}"   # empty = let vLLM pick

use_bundled_cuda_toolkit() {
  # Already have a real toolkit? Leave everything alone. Written out longhand
  # rather than as 'cmd && return': a trailing '&&' that fails would take the
  # whole script down with it under 'set -e' if this is ever called outside an
  # 'if' condition.
  if command -v nvcc >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "${CUDA_HOME:-/usr/local/cuda}/bin/nvcc" ]]; then
    return 0
  fi

  # 'ls' of a non-matching glob fails, and under 'set -e' a bare assignment
  # would inherit that status and abort the server: swallow it.
  local cu
  cu=$(ls -d "$VENV"/lib/python*/site-packages/nvidia/cu[0-9]* 2>/dev/null | head -1 || true)
  [[ -n "$cu" && -x "$cu/bin/nvcc" ]] || return 1

  local linkdir="$HOME/.qwen5090/cudalink"
  mkdir -p "$linkdir" || return 1
  local cudart
  cudart=$(ls "$cu"/lib/libcudart.so.* 2>/dev/null | head -1 || true)
  [[ -n "$cudart" ]] || return 1
  ln -sf "$cudart" "$linkdir/libcudart.so"
  local c
  for c in /usr/lib/wsl/lib/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so; do
    if [[ -e "$c" ]]; then
      ln -sf "$c" "$linkdir/libcuda.so"
      break
    fi
  done
  [[ -e "$linkdir/libcuda.so" ]] || return 1

  export CUDA_HOME="$cu"
  export FLASHINFER_EXTRA_LDFLAGS="-L$linkdir ${FLASHINFER_EXTRA_LDFLAGS:-}"
  # The wheel's nvcc is a patch release ahead of the CUDA headers torch was
  # built against (13.3 vs 13.2 at the time of writing), and CCCL hard-errors
  # when the two differ - "CUDA compiler and CUDA toolkit headers are
  # incompatible". It ships this exact switch for the case, and a patch-level
  # skew is covered by CUDA's minor version compatibility.
  export FLASHINFER_EXTRA_CFLAGS="-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK ${FLASHINFER_EXTRA_CFLAGS:-}"
  export FLASHINFER_EXTRA_CUDAFLAGS="-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK ${FLASHINFER_EXTRA_CUDAFLAGS:-}"
  echo ">> CUDA toolkit for FlashInfer's JIT: $cu ($("$cu/bin/nvcc" --version 2>/dev/null | tail -1 || true))"
  return 0
}

if ! use_bundled_cuda_toolkit; then
  # No toolkit anywhere. Fall back to the paths that only need the C compiler:
  # vLLM's native sampler, and Triton attention. Note the backend has to go in
  # as a vllm *flag* below - the VLLM_ATTENTION_BACKEND env var was removed in
  # v0.27 and is now silently ignored, which looks exactly like a fix that does
  # not work. This still leaves MTP's draft model on FlashInfer, so drop
  # speculative decoding too rather than fail on the first message.
  echo ">> no CUDA toolkit found - using the native sampler and Triton attention." >&2
  export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
  ATTN_BACKEND="${ATTN_BACKEND:-TRITON_ATTN}"
  MTP=0
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

  local shard_gib=$(( shard / 1073741824 ))
  local budget_gib=$(( budget / 1073741824 ))
  local total_gib=$(( ($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024) / 1073741824 ))
  local need_gib=$(( shard_gib + 6 ))   # weights + the loader's own working set
  cat >&2 <<EOF

ERROR: this WSL virtual machine is too small to load the model weights.

  largest weights file : ${shard_gib} GiB
  usable RAM + swap    : ${budget_gib} GiB   (this VM has ${total_gib} GiB of RAM)
  needed               : ${need_gib} GiB of RAM + swap

Windows gives WSL half the PC's RAM by default, and Linux refuses to map a file
it cannot back with memory. The fix is on the WINDOWS side, in PowerShell:

     .\app\install.ps1 -WslMemoryOnly

That reads how much RAM this PC has, writes matching memory/swap limits into
%USERPROFILE%\.wslconfig and restarts WSL. Clicking "Install / Repair" in the
Qwen 5090 app does the same thing.

By hand instead: put this in %USERPROFILE%\.wslconfig - keep ~8 GB for Windows
and make up any shortfall with swap - then run  wsl --shutdown  :

     [wsl2]
     memory=${need_gib}GB
     swap=8GB

(Override this check with QWEN5090_SKIP_MEMCHECK=1 to let vLLM try anyway.)
EOF
  exit 1
}
check_wsl_memory

# Per-checkpoint quirks, each overridable from the environment. Checkpoints that
# need something unusual are matched by their exact repo id; anything else that
# looks abliterated gets the llm-compressor defaults, which is what the
# community NVFP4 re-quants of the abliterated weights all use.
# Whether the caller pinned the KV precision themselves. Checked before the
# case block below fills in a default, so the automatic 4-bit switch further
# down never overrides an explicit choice.
KV_DTYPE_EXPLICIT="${KV_CACHE_DTYPE+set}"

case "$MODEL" in
  orcarouter/Qwen3.8-27B-Uncensored-NVFP4)
    # Carries its own KV-cache scheme in config.json (passing --kv-cache-dtype
    # on top of it is rejected) and ships a 2-token MTP head.
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE-}"
    SPEC_TOKENS="${SPEC_TOKENS:-2}"
    TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-1}"
    ;;
  *[Aa]bliterated*|*[Uu]ncensored*)
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE-fp8}"
    SPEC_TOKENS="${SPEC_TOKENS:-3}"
    TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-1}"
    ;;
  *)
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE-fp8}"
    SPEC_TOKENS="${SPEC_TOKENS:-3}"
    TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"
    ;;
esac
# Pick the KV precision that makes the requested context fit, rather than
# refusing to start. An fp8 KV cache holds about 171,000 tokens on a 32 GB card
# once the weights are in place - fine up to 128K, but the model's native
# 262,144-token window needs ~9.1 GiB against the ~6.2 GiB actually free, and
# vLLM only says so three minutes in. A 4-bit KV cache halves the per-token cost
# and fits the full window with room to spare: measured 2026-08-21 on the 5090,
# 344,616 tokens of capacity at the 0.85 this path drops to (1.31x the window)
# and 441,815 at 0.90 (1.69x). It costs speed rather than saving it - ~49 tok/s
# against fp8+MTP's ~80 - because the switch also forces MTP off, see the
# interlock below. Only applied to the checkpoints that default to fp8 - the
# gated one carries its own scheme in
# config.json, where passing --kv-cache-dtype at all is an error.
if [[ -z "$KV_DTYPE_EXPLICIT" && "$KV_CACHE_DTYPE" == "fp8" && "$CTX" -gt 131072 ]]; then
  KV_CACHE_DTYPE="turboquant_4bit_nc"
fi

# ...and then hand a slice of that VRAM straight back. vLLM's profiler claims
# *everything* inside gpu_memory_utilization for the KV cache: at 0.90 it sized
# 7.21 GiB / 441,815 tokens, 1.7x more than a 262,144-token window can ever use,
# and left the Windows desktop ~3.2 GiB. That margin is too thin. The desktop's
# own VRAM footprint moves between vLLM's profiling pass and its allocation
# pass, and when it grows in between, the allocation dies part-way through:
#   Available KV cache memory: 7.21 GiB          <- profiling said it fit
#   torch.OutOfMemoryError: ... Tried to allocate 462.00 MiB
# The same command had started cleanly an hour earlier with byte-identical
# profiling numbers, so this is a race against the desktop, not a bad setting.
# 0.85 still sizes ~344,000 tokens (1.3x the full window) and leaves ~4.8 GiB
# for Windows. Only on the 4-bit path - an fp8 cache at 131072 has no slack to
# give up, it needs nearly all of the 0.90 budget to hold its 131,072 tokens.
if [[ -z "$GPU_UTIL_EXPLICIT" ]]; then
  case "$KV_CACHE_DTYPE" in
    turboquant*) GPU_UTIL=0.85 ;;
  esac
fi

# Recommended by the OOM message itself, and free of downsides here: expandable
# segments let the caching allocator grow a mapping instead of needing a fresh
# contiguous reserved block, which is exactly what a 462 MiB failure alongside
# "8.40 GiB is free" looks like. (It is incompatible with --enable-sleep-mode,
# which this script never passes.)
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

# Interlock, and not a preference: a TurboQuant KV cache combined with MTP
# speculative decoding makes this model emit garbage - empty content, or
# "The final answer: : : : : :" until it hits the token limit - while still
# returning HTTP 200, so it looks like it works. Verified both ways at 262144:
# with MTP on, 0 of 3 trivial questions came back sane; with MTP off, 3 of 3
# ("Tokyo", "408", "red, blue, yellow"). Correctness wins over the speed-up.
case "$KV_CACHE_DTYPE" in
  turboquant*)
    if [[ "$MTP" == "1" ]]; then
      echo ">> MTP disabled: it produces corrupt output with a $KV_CACHE_DTYPE KV cache." >&2
      echo "   (drop the context to 131072 or lower to get fp8 + MTP back)" >&2
      MTP=0
    fi
    ;;
esac

# vLLM resolves "mtp" to this architecture's MTP head; some cards spell it
# qwen3_5_mtp. Override with SPEC_METHOD if a checkpoint insists on the latter.
SPEC_METHOD="${SPEC_METHOD:-mtp}"

ARGS=(
  serve "$MODEL"
  --host 0.0.0.0 --port "$PORT"
  --max-model-len "$CTX"
  --gpu-memory-utilization "$GPU_UTIL"
  --reasoning-parser qwen3
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --max-num-seqs "$MAX_SEQS"
)
if [[ -n "$KV_CACHE_DTYPE" ]]; then
  ARGS+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
fi
if [[ -n "$ATTN_BACKEND" ]]; then
  ARGS+=(--attention-backend "$ATTN_BACKEND")
fi
if [[ "$TRUST_REMOTE_CODE" == "1" ]]; then
  ARGS+=(--trust-remote-code)
fi
if [[ "$MTP" == "1" ]]; then
  ARGS+=(--speculative-config "{\"method\":\"$SPEC_METHOD\",\"num_speculative_tokens\":$SPEC_TOKENS}")
fi

echo ">> model=$MODEL ctx=$CTX port=$PORT gpu_util=$GPU_UTIL mtp=$MTP kv=${KV_CACHE_DTYPE:-from-config} attn=${ATTN_BACKEND:-auto}"
echo ">> OpenAI-compatible endpoint: http://localhost:$PORT/v1"
exec "$VENV/bin/vllm" "${ARGS[@]}"
