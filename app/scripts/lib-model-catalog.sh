#!/usr/bin/env bash
# The one place that knows what a checkpoint is: which backend can serve it,
# how much memory it wants, and what it costs to run. Sourced by serve.sh (to
# refuse a model it cannot serve rather than failing three minutes in),
# setup-wsl.sh (to download the right thing) and serve-gguf.sh.
#
# Three backends, because they do not overlap:
#
#   vllm      the NVFP4 Qwen checkpoints. Weights live entirely in VRAM, the
#             whole product was built around it, and it is what "fast" means
#             here - 80 tok/s at 131072. It is also the only backend that can
#             serve an arbitrary Hugging Face repo, which is why it stays the
#             default and the only one the abliterated builds can use.
#   ninfer    the same Qwen3.8-27B NVFP4 weights, repacked into NInfer's own
#             container and served by a from-scratch C++/CUDA engine built for
#             sm_120a and nothing else. Roughly twice vLLM's decode rate and
#             about six times its prefill rate at a long prompt, which is what
#             makes the 262K window usable rather than theoretical. The price
#             is a closed set of five artifacts (no abliterated build), a
#             separate ~20 GiB download, and a CUDA compile at install time.
#   llamacpp  the DeepSeek V4-Flash GGUF builds. 284B total / 13B active, so
#             the weights do NOT fit in 32 GB of VRAM at any quantization and
#             most of them live in system RAM (and, below the resident floor,
#             on the SSD). Slow by construction - this is the price of running
#             a 284B model on one consumer card.
#
# qwen5090_model_info <model-id> sets, and always sets, every MODEL_* below.

# Model ids for the GGUF builds carry the quant tag after a colon, which is the
# spelling llama.cpp's own -hf flag uses:
#     teamblobfish/DeepSeek-V4-Flash-GGUF:IQ1_S-XL
qwen5090_model_info() {
  local model="${1:?qwen5090_model_info needs a model id}"

  MODEL_BACKEND="vllm"      # vllm | ninfer | llamacpp
  MODEL_LABEL="$model"      # what a human should see
  MODEL_SIZE_GB=0           # weights on disk
  MODEL_RESIDENT_GB=0       # RAM+VRAM below which it pages off the SSD
  MODEL_GGUF_REPO=""        # repo id, GGUF builds only
  MODEL_GGUF_QUANT=""       # quant tag within that repo
  MODEL_NINFER_FILE=""      # artifact filename, NInfer builds only
  MODEL_NINFER_BYTES=0      # exact published size, so a truncated download is caught
  MODEL_NINFER_SHA256=""    # published digest, verified once after download
  MODEL_NINFER_MAXCTX=0     # largest window this artifact fits on a 32 GB card
  MODEL_NOTES=""

  case "$model" in
    # ------------------------------------------------------------ NInfer ----
    # A closed set of five artifact identities - NInfer refuses anything else,
    # so this table is the whole product surface and an exact match is right.
    # The sizes and digests are the ones published in NInfer's README; both are
    # checked after download, because a silently truncated 20 GiB file
    # otherwise surfaces as an unreadable container an hour later.
    #
    # MODEL_NINFER_MAXCTX is the largest window that still fits on this card
    # after the weights, not the model's native 262,144. Only the Qwen3.8
    # NVFP4 artifact is actually short of the native maximum: at 20.02 GiB it
    # is the largest of the five, and NInfer's own evaluation runs cap it at
    # 252,928 for exactly this reason.
    neroued/Qwen3.8-27B-nvfp4-NInfer)
      MODEL_BACKEND="ninfer"
      MODEL_LABEL="Qwen3.8-27B NVFP4 (NInfer)"
      MODEL_SIZE_GB=21
      MODEL_NINFER_FILE="qwen3_8_27b_nvfp4.ninfer"
      MODEL_NINFER_BYTES=21492695040
      MODEL_NINFER_SHA256="bb3360522a06e136e0367f5703414d26272b7285c8a6ab6194135c17dbd81b32"
      MODEL_NINFER_MAXCTX=252928
      MODEL_NOTES="the same unsloth NVFP4 weights vLLM serves, repacked for NInfer: ~2x the decode rate and a 262K window whose prefill does not collapse. Needs the NInfer build."
      ;;
    neroued/Qwen3.8-27B-NInfer)
      MODEL_BACKEND="ninfer"
      MODEL_LABEL="Qwen3.8-27B groupwise-int (NInfer)"
      MODEL_SIZE_GB=18
      MODEL_NINFER_FILE="qwen3_8_27b.ninfer"
      MODEL_NINFER_BYTES=18210531328
      MODEL_NINFER_SHA256="eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e"
      MODEL_NINFER_MAXCTX=262144
      MODEL_NOTES="smaller than the NVFP4 artifact and scores the same on reasoning, but NInfer publishes no throughput campaign for it."
      ;;
    neroued/Qwen3.6-27B-nvfp4-NInfer)
      MODEL_BACKEND="ninfer"
      MODEL_LABEL="Qwen3.6-27B NVFP4 (NInfer)"
      MODEL_SIZE_GB=18
      MODEL_NINFER_FILE="qwen3_6_27b_nvfp4.ninfer"
      MODEL_NINFER_BYTES=18324064000
      MODEL_NINFER_SHA256="bce5f00d066c0f20f1317bf1fdcb458264cf95837c3b1f3fbec163694627893a"
      MODEL_NINFER_MAXCTX=262144
      MODEL_NOTES="the previous Qwen generation. Faster than the 3.8 artifact and its MTP acceptance is far better (69% against 46%), but the weights are a release older."
      ;;
    neroued/Qwen3.6-27B-NInfer)
      MODEL_BACKEND="ninfer"
      MODEL_LABEL="Qwen3.6-27B groupwise-int (NInfer)"
      MODEL_SIZE_GB=17
      MODEL_NINFER_FILE="qwen3_6_27b.ninfer"
      MODEL_NINFER_BYTES=17495365888
      MODEL_NINFER_SHA256="7b51600ffd10632b9660f56085efdd9b751d79733ad32036a652234b64bebe7b"
      MODEL_NINFER_MAXCTX=262144
      MODEL_NOTES="the smallest artifact, and the slowest of the 27B profiles at prefill."
      ;;
    neroued/Qwen3.6-35B-A3B-NInfer)
      MODEL_BACKEND="ninfer"
      MODEL_LABEL="Qwen3.6-35B-A3B (NInfer)"
      MODEL_SIZE_GB=22
      MODEL_NINFER_FILE="qwen3_6_35b_a3b.ninfer"
      MODEL_NINFER_BYTES=22783246080
      MODEL_NINFER_SHA256="1fb9ea0b5b8561e49d9604115ec89e5d9f2b6f6434e32c37c57fffd480a325d2"
      MODEL_NINFER_MAXCTX=262144
      MODEL_NOTES="35B total / 3B active, so it decodes far faster than any dense build here - 593 tok/s at one request. It is the only target with DFlash speculative decoding, and it is text-only."
      ;;

    # ------------------------------------------------ DeepSeek V4-Flash ----
    # The 0731 retrain, which is the checkpoint every published agent number
    # refers to - the earlier Flash preview scored 61.8 on Terminal-Bench 2.1
    # against 0731's 82.7, so serving the older one and comparing to that
    # number would be measuring the wrong model.
    */DeepSeek-V4-Flash*:*)
      MODEL_BACKEND="llamacpp"
      MODEL_GGUF_REPO="${model%%:*}"
      MODEL_GGUF_QUANT="${model##*:}"
      case "$MODEL_GGUF_QUANT" in
        # The only 0731-lineage build under 70 GB, and it gets there by
        # pruning: REAP drops the least-used experts, 284B down to ~150B,
        # before quantizing. A different model from the one the published
        # numbers describe - but the alternative at this memory budget is a
        # 1-bit quantization of the intact weights, which damages tool calling
        # harder than dropping experts does, and does not fit either.
        Q2_K)
          MODEL_LABEL="DeepSeek V4-Flash 0731 REAP-150B - 2-bit (Q2_K)"
          MODEL_SIZE_GB=63
          MODEL_RESIDENT_GB=69
          MODEL_NOTES="experts pruned 284B -> ~150B, then 2-bit. The only build in reach of a 32 GB machine. Pin a slice of the experts in VRAM (N_CPU_MOE=30) or every request re-reads them from the SSD: 4.5 tok/s becomes 13-21 tok/s. Not the model the 82.7 Terminal-Bench figure was measured on."
          ;;
        IQ3_XXS)
          MODEL_LABEL="DeepSeek V4-Flash 0731 REAP-150B - 3-bit (IQ3_XXS)"
          MODEL_SIZE_GB=67
          MODEL_RESIDENT_GB=73
          MODEL_NOTES="the pruned build at 3-bit. Wants ~73 GB resident."
          ;;
        UD-IQ1_S)
          MODEL_LABEL="DeepSeek V4-Flash 0731 - 1-bit (UD-IQ1_S)"
          MODEL_SIZE_GB=83
          MODEL_RESIDENT_GB=89
          MODEL_NOTES="the intact 284B weights at their smallest. 1-bit costs tool-calling reliability, which is what an agent depends on."
          ;;
        UD-IQ2_XXS)
          MODEL_LABEL="DeepSeek V4-Flash 0731 - 2-bit (UD-IQ2_XXS)"
          MODEL_SIZE_GB=91
          MODEL_RESIDENT_GB=98
          MODEL_NOTES="intact weights, middle tier, for a 96 GB+ machine."
          ;;
        UD-IQ3_XXS)
          MODEL_LABEL="DeepSeek V4-Flash 0731 - 3-bit (UD-IQ3_XXS)"
          MODEL_SIZE_GB=105
          MODEL_RESIDENT_GB=112
          MODEL_NOTES="unsloth's recommended tier and the closest of these to the published numbers. Needs a 128 GB RAM machine."
          ;;
        *)
          MODEL_LABEL="DeepSeek V4-Flash 0731 - $MODEL_GGUF_QUANT"
          MODEL_NOTES="an unlisted quant: sizes unknown, so the preflight cannot warn about them."
          ;;
      esac
      ;;

    # ------------------------------------------------------------ Qwen ----
    orcarouter/Qwen3.8-27B-Uncensored-NVFP4)
      MODEL_LABEL="Qwen3.8-27B uncensored (gated)"
      MODEL_SIZE_GB=23
      MODEL_RESIDENT_GB=32
      MODEL_NOTES="gated on Hugging Face: accept its terms there and supply a read token."
      ;;
    *[Aa]bliterated*NVFP4|*[Uu]ncensored*NVFP4)
      MODEL_LABEL="Qwen3.8-27B uncensored"
      MODEL_SIZE_GB=19
      MODEL_RESIDENT_GB=32
      MODEL_NOTES="the default: fits in VRAM, ~80 tok/s at 131072."
      ;;
    *NVFP4*)
      MODEL_LABEL="Qwen3.8-27B standard"
      MODEL_SIZE_GB=22
      MODEL_RESIDENT_GB=32
      MODEL_NOTES="fits in VRAM, ~80 tok/s at 131072."
      ;;
    *.gguf|*.GGUF|*[Gg][Gg][Uu][Ff]*)
      # Any other GGUF: llama.cpp can serve it, we just know nothing about it.
      MODEL_BACKEND="llamacpp"
      MODEL_GGUF_REPO="${model%%:*}"
      MODEL_GGUF_QUANT="${model##*:}"
      MODEL_NOTES="not a checkpoint this toolkit knows - serving it anyway, with no preflight."
      ;;
    *)
      MODEL_NOTES="not a checkpoint this toolkit knows - assuming vLLM can load it."
      ;;
  esac
}

# How much memory the machine can actually give a model: VRAM the GPU reports
# free, plus MemAvailable. Deliberately not "total RAM" - the desktop, the
# browser and the page cache are already spending some of it, and a floor
# computed against a number nobody can reach is a floor that lies.
# Sets MEM_VRAM_GB, MEM_RAM_GB, MEM_TOTAL_GB.
qwen5090_available_memory() {
  MEM_VRAM_GB=0
  MEM_RAM_GB=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    local mib
    mib=$(timeout 10 nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    [[ "$mib" =~ ^[0-9]+$ ]] && MEM_VRAM_GB=$(( mib / 1024 ))
  fi
  if [[ -r /proc/meminfo ]]; then
    local kb
    kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
    [[ "$kb" =~ ^[0-9]+$ ]] && MEM_RAM_GB=$(( kb / 1024 / 1024 ))
  fi
  MEM_TOTAL_GB=$(( MEM_VRAM_GB + MEM_RAM_GB ))
}

# Say plainly what will happen before an hour of downloading, rather than after.
# Returns 0 to go ahead, 1 when the model cannot be served here at all.
qwen5090_model_preflight() {
  local model="$1"
  qwen5090_model_info "$model"
  qwen5090_available_memory

  printf '>> %s\n' "$MODEL_LABEL"
  [[ -n "$MODEL_NOTES" ]] && printf '   %s\n' "$MODEL_NOTES"
  printf '   weights %s GB | this machine can offer %s GB (%s VRAM + %s RAM)\n' \
    "${MODEL_SIZE_GB:-?}" "$MEM_TOTAL_GB" "$MEM_VRAM_GB" "$MEM_RAM_GB"

  # NInfer keeps every byte of the artifact in VRAM, so the question is not
  # "does it page off the SSD" but "does it fit at all". There is no offload
  # path to fall back on: too little free VRAM is a refusal, not a slowdown.
  # Checked against free VRAM rather than the card's 32 GB, because on WSL the
  # Windows desktop is already spending some of it.
  if [[ "$MODEL_BACKEND" == "ninfer" ]]; then
    if (( MEM_VRAM_GB > 0 && MEM_VRAM_GB < MODEL_SIZE_GB + 2 )); then
      printf 'WARNING: only %s GB of VRAM is free and the artifact alone is %s GB.\n' \
        "$MEM_VRAM_GB" "$MODEL_SIZE_GB" >&2
      printf '         Close whatever else is on the GPU, or the KV cache will have nothing left.\n' >&2
    fi
    return 0
  fi

  if [[ "$MODEL_BACKEND" != "llamacpp" || "$MODEL_RESIDENT_GB" -eq 0 ]]; then
    return 0
  fi

  if (( MEM_TOTAL_GB >= MODEL_RESIDENT_GB )); then
    printf '   fits in memory - no SSD paging\n'
    return 0
  fi

  local short=$(( MODEL_RESIDENT_GB - MEM_TOTAL_GB ))
  if (( MEM_TOTAL_GB * 100 < MODEL_SIZE_GB * 70 )); then
    printf 'ERROR: %s GB short of the %s GB this build needs resident.\n' "$short" "$MODEL_RESIDENT_GB" >&2
    printf '       Under about 70%% of the weights in memory, every token waits on the SSD\n' >&2
    printf '       and the server reads as hung rather than slow. Pick a smaller quant, or\n' >&2
    printf '       add RAM. Set QWEN5090_FORCE_OFFLOAD=1 to try it anyway.\n' >&2
    [[ "${QWEN5090_FORCE_OFFLOAD:-0}" == "1" ]] || return 1
    printf 'WARNING: QWEN5090_FORCE_OFFLOAD=1 - going ahead.\n' >&2
    return 0
  fi

  printf 'WARNING: %s GB short of resident, so about %s GB of experts page off the SSD\n' \
    "$short" "$short" >&2
  printf '         on every token. It works; it will not be fast.\n' >&2
  return 0
}
