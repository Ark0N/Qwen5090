#!/usr/bin/env bash
# One-time setup for the NInfer backend: compile the engine, fetch the
# artifact, and record it as this machine's default so later starts pick it up
# on their own.
#
#   bash app/scripts/setup-ninfer.sh                       # the Qwen3.8 NVFP4 artifact
#   bash app/scripts/setup-ninfer.sh neroued/Qwen3.6-35B-A3B-NInfer
#   bash app/scripts/setup-ninfer.sh --no-default          # install it, keep vLLM as the default
#   bash app/scripts/setup-ninfer.sh status                # what is installed here
#   bash app/scripts/setup-ninfer.sh --rebuild             # recompile after an upstream change
#
# This is separate from setup-wsl.sh on purpose. That script provisions the
# vLLM venv and downloads Hugging Face weights, which is the path every ZIP
# user takes; this one compiles C++/CUDA for sm_120a and downloads a ~20 GiB
# container, which is worth an explicit decision. Nothing here touches the
# vLLM install, and reverting is one command:
#
#   bash app/scripts/setup-ninfer.sh --default-vllm
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-build-tools.sh
source "$SCRIPT_DIR/lib-build-tools.sh"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"
# shellcheck source=lib-model-catalog.sh
source "$SCRIPT_DIR/lib-model-catalog.sh"
# shellcheck source=lib-ninfer.sh
source "$SCRIPT_DIR/lib-ninfer.sh"

MODEL="${MODEL:-neroued/Qwen3.8-27B-nvfp4-NInfer}"
SET_DEFAULT=1
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
ACTION="install"

while (( $# )); do
  case "$1" in
    status)          ACTION="status" ;;
    --no-default)    SET_DEFAULT=0 ;;
    --default-vllm)  ACTION="default-vllm" ;;
    --rebuild)       export NINFER_REBUILD=1 ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    -*)              printf 'ERROR: unknown option %s\n' "$1" >&2; exit 1 ;;
    *)               MODEL="$1" ;;
  esac
  shift
done

say() { printf '>> %s\n' "$*"; }

if [[ "$ACTION" == "default-vllm" ]]; then
  qwen5090_set_default_model "$QWEN5090_FALLBACK_MODEL"
  say "default model is now $QWEN5090_FALLBACK_MODEL (vLLM). The NInfer build is left in place."
  exit 0
fi

qwen5090_model_info "$MODEL"
if [[ "$MODEL_BACKEND" != "ninfer" ]]; then
  cat >&2 <<EOF
ERROR: $MODEL is not an NInfer artifact.

NInfer accepts a closed set of five, and nothing else:

  neroued/Qwen3.8-27B-nvfp4-NInfer     Qwen3.8-27B NVFP4      21 GB   (the default)
  neroued/Qwen3.8-27B-NInfer           Qwen3.8-27B int        18 GB
  neroued/Qwen3.6-27B-nvfp4-NInfer     Qwen3.6-27B NVFP4      18 GB
  neroued/Qwen3.6-27B-NInfer           Qwen3.6-27B int        17 GB
  neroued/Qwen3.6-35B-A3B-NInfer       Qwen3.6-35B-A3B        22 GB

There is no abliterated build among them. Keep using vLLM for that one.
EOF
  exit 1
fi

if [[ "$ACTION" == "status" ]]; then
  printf 'NInfer engine:  '
  if ninfer_have_build; then
    printf '%s\n' "$NINFER_SERVE"
    [[ -r "$NINFER_HOME/built-from.txt" ]] && printf '                built from %s\n' "$(cat "$NINFER_HOME/built-from.txt")"
  else
    printf 'not built\n'
  fi
  printf 'Artifact:       '
  artifact=$(ninfer_artifact_path "$MODEL")
  if [[ -s "$artifact" ]]; then
    printf '%s (%s GB)\n' "$artifact" "$(( $(stat -c %s "$artifact") / 1000000000 ))"
  else
    printf 'not downloaded (%s)\n' "$MODEL_NINFER_FILE"
  fi
  printf 'Default model:  %s\n' "$(qwen5090_default_model)"
  ninfer_installed "$MODEL" && exit 0 || exit 1
fi

# --------------------------------------------------------------- install ----
say "Setting up the NInfer backend"
say "  model:    $MODEL_LABEL"
say "  artifact: $MODEL_NINFER_FILE (${MODEL_SIZE_GB} GB)"
say "  engine:   compiled from source for sm_120a"
echo

qwen5090_model_preflight "$MODEL" || exit 1
echo

say "[1/2] Building the engine"
ninfer_ensure_build || exit 1
echo

if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
  say "[2/2] Skipping the download (SKIP_DOWNLOAD=1)"
else
  say "[2/2] Fetching the artifact"
  ninfer_ensure_artifact "$MODEL" || exit 1
fi
echo

if [[ "$SET_DEFAULT" == "1" ]] && ninfer_installed "$MODEL"; then
  qwen5090_set_default_model "$MODEL"
  say "Recorded $MODEL as this machine's default model."
  say "Every later start uses it - no flag needed. Undo with:"
  say "    bash app/scripts/setup-ninfer.sh --default-vllm"
else
  say "Left the default model alone. Start NInfer explicitly with:"
  say "    MODEL='$MODEL' bash app/scripts/serve.sh"
fi

echo
say "Done."
qwen5090_start_hint
