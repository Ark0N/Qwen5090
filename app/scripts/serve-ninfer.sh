#!/usr/bin/env bash
# Serve a Qwen artifact with NInfer - the third backend, and the fast one.
# serve.sh execs this when the model catalog says the checkpoint is an NInfer
# one; it also runs standalone:
#
#   MODEL=neroued/Qwen3.8-27B-nvfp4-NInfer bash scripts/serve-ninfer.sh
#   CTX=262144 bash scripts/serve-ninfer.sh
#
# NInfer is a from-scratch C++/CUDA engine compiled for sm_120a and nothing
# else, so unlike vLLM there is no JIT, no Triton and no FlashInfer here: the
# kernels were built at install time. That removes most of what the vLLM path
# spends its startup on, and most of what can go wrong on the first request.
#
# What it buys, from NInfer's published RTX 5090 measurements against this
# toolkit's own vLLM numbers, same card and same underlying weights:
#
#              decode (1 request)   prefill @ ~90K+ prompt
#   vLLM       ~80 tok/s            371 tok/s, and 139K aborted after 7 min
#   NInfer     151-195 tok/s        2,203 tok/s at 260,096 tokens
#
# The prefill column is the important one. The 262K window on the vLLM path is
# real but barely usable - see the prefill cliff in CLAUDE.md - and here it
# simply is not a cliff.
#
# What it costs: a closed set of five artifacts, so no abliterated build, and
# an ahead-of-time CUDA compile the first time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-build-tools.sh
source "$SCRIPT_DIR/lib-build-tools.sh"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"
# shellcheck source=lib-model-catalog.sh
source "$SCRIPT_DIR/lib-model-catalog.sh"
# shellcheck source=lib-gpu.sh
source "$SCRIPT_DIR/lib-gpu.sh"
# shellcheck source=lib-ninfer.sh
source "$SCRIPT_DIR/lib-ninfer.sh"

MODEL="${MODEL:-neroued/Qwen3.8-27B-nvfp4-NInfer}"
# Kept at the product-wide default rather than raised, so switching backends
# does not silently change the window. 262144 is genuinely usable on this
# backend though, which it is not on the vLLM one - ask for it and it is
# clamped only by what the artifact fits on the card.
CTX="${CTX:-131072}"
# The same port vLLM uses. NInfer replaces that server rather than running
# beside it - both want the whole GPU - so every existing client, the GUI's
# health ping and the Claude Code bridge included, keeps working untouched.
PORT="${PORT:-8000}"
MTP="${MTP:-1}"
SPEC_TOKENS="${SPEC_TOKENS:-3}"     # NInfer accepts 1..5 for MTP
# NInfer's shared KV pool. "auto" takes everything left after the weights,
# minus 1 GiB of its own sizing headroom.
KV_CAPACITY="${KV_CAPACITY:-auto}"
PREFILL_CHUNK="${PREFILL_CHUNK:-1024}"
# 1..8, and NInfer fixes it at startup. Two is enough for a personal server
# and leaves the KV pool alone; the vLLM path's 16 is not a legal value here.
MAX_SEQS="${MAX_SEQS:-2}"
# Prefix reuse is on by default in NInfer, which is the right default for an
# agent client resending the same system prompt every turn.
PREFIX_CACHE="${PREFIX_CACHE:-1}"
# --preserve-thinking retains closed-turn assistant reasoning in later prompts
# (NInfer's own wording). On by default because the self-optimization loop
# promoted it on a 16/16 and the production server has run with it since; set
# PRESERVE_THINKING=0 to strip reasoning between turns instead.
PRESERVE_THINKING="${PRESERVE_THINKING:-1}"
VISION="${VISION:-0}"
API_KEY="${API_KEY:-}"
DOWNLOAD="${DOWNLOAD:-1}"

LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/serve-ninfer-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: serve-ninfer.sh failed at line $LINENO (exit $?)"' ERR
echo ">> logging to $LOG_FILE"

say() { printf '>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

qwen5090_model_info "$MODEL"
[[ "$MODEL_BACKEND" == "ninfer" ]] || die "$MODEL is not an NInfer artifact - run scripts/serve.sh instead."

# NInfer is Linux-only and this whole tree already runs inside WSL on Windows,
# so there is nothing to refuse here the way serve.sh refuses llama.cpp: the
# weights are VRAM-resident, and WSL's RAM slice is irrelevant to them.
qwen5090_model_preflight "$MODEL" || exit 1

ninfer_ensure_build || exit 1
if [[ "$DOWNLOAD" == "1" ]]; then
  ninfer_ensure_artifact "$MODEL" || exit 1
fi
ARTIFACT=$(ninfer_artifact_path "$MODEL")
[[ -s "$ARTIFACT" ]] || die "no artifact at $ARTIFACT - run scripts/setup-ninfer.sh, or set DOWNLOAD=1."

# Each artifact has its own ceiling, and it is not always the model's native
# 262,144: the Qwen3.8 NVFP4 container is the largest of the five at 20.02 GiB
# and leaves room for 252,928. Asking for more is not a slow start, it is a
# refusal several minutes in, so clamp rather than forward it.
if (( MODEL_NINFER_MAXCTX > 0 && CTX > MODEL_NINFER_MAXCTX )); then
  say "$CTX exceeds what $MODEL_LABEL fits on this card - using $MODEL_NINFER_MAXCTX"
  CTX="$MODEL_NINFER_MAXCTX"
fi

# NInfer fixes concurrency at startup and accepts 1..8. The vLLM path's
# default of 16 is a legal value there and an immediate refusal here.
if (( MAX_SEQS < 1 )); then MAX_SEQS=1; fi
if (( MAX_SEQS > 8 )); then
  say "NInfer allows at most 8 concurrent requests - using 8 instead of $MAX_SEQS"
  MAX_SEQS=8
fi

# KV precision. The project-wide knob speaks vLLM's vocabulary (fp8,
# turboquant_4bit_nc); NInfer offers bf16 or int8 group-64 and nothing else.
# int8 is both the default here and what every published NInfer measurement
# used, so any request for a quantized cache lands there and only an explicit
# bf16 opts out.
case "${KV_CACHE_DTYPE:-int8}" in
  bf16|bfloat16|auto) KV_DTYPE="bf16" ;;
  int8|fp8|*4bit*|*turboquant*) KV_DTYPE="int8" ;;
  *) die "KV_CACHE_DTYPE='$KV_CACHE_DTYPE' means nothing to NInfer - use int8 or bf16." ;;
esac

# GPU_UTIL has no counterpart. NInfer sizes the KV pool from the memory left
# after the weights and keeps 1 GiB back itself, rather than claiming a
# fraction of the card up front the way vLLM does. Say so instead of ignoring
# it silently - it is forwarded by run.ps1 whenever -GpuUtil is bound.
if [[ -n "${GPU_UTIL:-}" ]]; then
  say "note: GPU_UTIL=$GPU_UTIL does not apply to NInfer (it sizes the KV pool from what is left, see --kv-capacity)."
fi

ARGS=(
  "$ARTIFACT"
  # 0.0.0.0 for the same reason vLLM binds it: WSL's localhost relay only
  # forwards ports bound to all interfaces, so a 127.0.0.1 server is invisible
  # to the GUI's Windows-side health ping.
  --host 0.0.0.0 --port "$PORT"
  --max-context "$CTX"
  --kv-capacity "$KV_CAPACITY"
  --kv-dtype "$KV_DTYPE"
  --max-concurrency "$MAX_SEQS"
  --prefill-chunk "$PREFILL_CHUNK"
)

# Speculative residency is frozen at startup - a later request cannot turn it
# on - so this is decided here or not at all. --lm-head-draft loads the
# optimized proposal head, which every published MTP figure was measured with.
if [[ "$MTP" == "1" ]]; then
  if (( SPEC_TOKENS < 1 || SPEC_TOKENS > 5 )); then
    say "NInfer's MTP draft window is 1..5 - using 3 instead of $SPEC_TOKENS"
    SPEC_TOKENS=3
  fi
  ARGS+=(--spec mtp --draft-tokens "$SPEC_TOKENS" --lm-head-draft)
fi

# Unlike the vLLM path there is no interlock tying MTP to the KV precision:
# the garbling that forces MTP off above 128K there is a TurboQuant/vLLM
# interaction, and NInfer's own campaign runs MTP3 over an int8 cache at every
# concurrency from 1 to 8.

[[ "$PREFIX_CACHE" == "1" ]] || ARGS+=(--no-prefix-reuse)
# The flag is newer than the first NInfer builds this script installed, so
# probe the binary's help rather than passing it blind - an unknown flag is a
# refusal at startup, not a warning.
if [[ "$PRESERVE_THINKING" == "1" ]]; then
  if "$NINFER_SERVE" --help 2>&1 | grep -q -- '--preserve-thinking'; then
    ARGS+=(--preserve-thinking)
  else
    say "note: this NInfer build predates --preserve-thinking - rerun scripts/setup-ninfer.sh to rebuild if you want it."
  fi
fi
# Vision is likewise startup-frozen, and off by default because it costs its
# weights and a frozen scratch allocation whether or not an image ever arrives.
[[ "$VISION" == "1" ]] && ARGS+=(--vision)
[[ -n "$API_KEY" ]] && ARGS+=(--api-key "$API_KEY")

qwen5090_apply_power_limit
qwen5090_start_telemetry "$LOG_DIR"

say "model=$MODEL_LABEL ctx=$CTX port=$PORT kv=$KV_DTYPE mtp=$MTP concurrency=$MAX_SEQS prefix_reuse=$PREFIX_CACHE preserve_thinking=$PRESERVE_THINKING vision=$VISION"
say "OpenAI-compatible endpoint:   http://localhost:$PORT/v1"
say "Anthropic-compatible endpoint: http://localhost:$PORT/v1/messages"
# The server binds 0.0.0.0, so on native Linux the LAN and the tailnet reach
# it with no portproxy step (that is a WSL-on-Windows need, share.ps1's job).
# Print the tailnet URL when there is one, so "is it shared?" needs no digging.
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -n "$TS_IP" ]] && say "Tailscale:                     http://$TS_IP:$PORT/v1"
fi
exec "$NINFER_SERVE" "${ARGS[@]}"
