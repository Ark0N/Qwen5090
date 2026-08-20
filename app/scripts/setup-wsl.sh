#!/usr/bin/env bash
# One-time setup inside WSL2 Ubuntu: uv + Python 3.13 venv + NVFP4-capable vLLM
# + Qwen3.8-27B-NVFP4 model download. Normally invoked by install.ps1, but safe
# to run directly from a WSL shell too. Re-running is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-build-tools.sh
source "$SCRIPT_DIR/lib-build-tools.sh"

VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
MODEL="${MODEL:-unsloth/Qwen3.8-27B-NVFP4}"   # or sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
# Most repos need no account. A gated one (orcarouter's) needs HF_TOKEN once; it
# is then saved where huggingface_hub looks by default, so vLLM reuses it later.

# Mirror all output to a persistent log so failed runs can be diagnosed later
# (bundled by collect-logs.ps1 / the GUI's "Collect diagnostics" button).
LOG_DIR="$HOME/.qwen5090/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: setup-wsl.sh failed at line $LINENO (exit $?)"' ERR
echo "(logging to $LOG_FILE)"

echo "== [1/6] Checking the GPU is visible inside WSL =="
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi failed inside WSL." >&2
  echo "Install/update the *Windows* NVIDIA driver (>= 570; Game Ready or Studio)," >&2
  echo "then run 'wsl --shutdown' from Windows and try again." >&2
  echo "Never install a Linux NVIDIA driver inside WSL — it shadows the Windows one." >&2
  exit 1
fi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

echo "== [2/6] Checking model access =="
# The uncensored (abliterated) checkpoint is a gated Hugging Face repo. Catch a
# missing token here, in five seconds, instead of after the ten-minute vLLM
# install. Everything else is public and needs no account.
# Only repos that Hugging Face actually gates go in this list - the community
# NVFP4 re-quants of the abliterated weights are public downloads.
IS_GATED=0
SIZE_HINT="~22 GB"
case "$MODEL" in
  orcarouter/Qwen3.8-27B-Uncensored-NVFP4)
    IS_GATED=1
    SIZE_HINT="~23 GB"
    ;;
  *[Aa]bliterated*|*[Uu]ncensored*)
    SIZE_HINT="~19 GB"
    ;;
esac
if [[ "$IS_GATED" == "0" ]]; then
  echo "$MODEL is a public repo - no Hugging Face account needed."
elif [[ -n "${HF_TOKEN:-}" ]]; then
  echo "$MODEL is gated; using the Hugging Face token that was passed in."
elif [[ -s "$HOME/.cache/huggingface/token" ]]; then
  echo "$MODEL is gated; using the Hugging Face token saved by an earlier run."
elif [[ "${SKIP_DOWNLOAD:-0}" == "1" ]]; then
  echo "$MODEL is gated and no token was given, but SKIP_DOWNLOAD=1 - continuing."
  echo "The server cannot fetch the weights until you supply one."
else
  cat >&2 <<EOF
$MODEL is a GATED repository: Hugging Face releases nothing without a token,
so there is no point downloading yet. One-time setup, about 2 minutes:

  1. Open https://huggingface.co/$MODEL , sign in, and accept the terms
     (access is granted automatically).
  2. Create a READ token at https://huggingface.co/settings/tokens
  3. Paste it into the "HF token" box on the app's Setup tab and click
     Install / Repair again - or from PowerShell:
         .\app\install.ps1 -Uncensored -HfToken hf_xxxxxxxx
     - or from this WSL shell:
         HF_TOKEN=hf_xxxxxxxx MODEL=$MODEL bash scripts/setup-wsl.sh

The token is stored inside WSL afterwards; you only do this once.
EOF
  exit 1
fi

echo "== [3/6] Installing build tools (vLLM compiles GPU kernels at runtime) =="
ensure_build_tools || exit 1

echo "== [4/6] Installing uv (Python package manager) =="
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

echo "== [5/6] Creating venv + installing vLLM (downloads CUDA wheels; takes a while) =="
UV_FLAGS=()
if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  UV_FLAGS+=(--no-progress)   # keep GUI logs readable (no \r progress bars)
fi
mkdir -p "$(dirname "$VENV")"
# uv >= 0.12 refuses to create a venv over an existing one (exit 2), which would
# make every re-run of the installer fail. Reuse what is already there instead:
# --clear would work too, but it throws away ~200 cached packages / several GB.
if [[ -x "$VENV/bin/python" ]]; then
  echo "Reusing the existing Python environment at $VENV"
else
  rm -rf "$VENV"   # nothing usable in there; a half-made venv would block uv too
  uv venv "${UV_FLAGS[@]}" "$VENV" --python 3.13
fi
uv pip install "${UV_FLAGS[@]}" --python "$VENV/bin/python" \
  "vllm>=0.25.0" \
  "flashinfer-python>=0.6.13" \
  "nvidia-cutlass-dsl>=4.5.2" \
  "openai>=1.60" \
  --torch-backend=auto

# Prove Triton can actually build against this machine's CUDA driver now, and
# warm its cache, rather than discovering a broken toolchain a minute into the
# first server start. Warn only - the weights are still worth downloading, and
# nothing here is fatal to the rest of the install.
if ! "$VENV/bin/python" - <<'TRITON_PY'
import sys
try:
    import triton
    triton.runtime.driver.active.get_current_device()
except Exception as exc:                      # noqa: BLE001 - report anything
    sys.exit(f"{type(exc).__name__}: {exc}")
print("Triton kernel compiler OK.")
TRITON_PY
then
  echo "WARNING: Triton could not build its CUDA kernels (see the error above)." >&2
  echo "         vLLM will fail at startup until that is fixed. Usual causes: no" >&2
  echo "         C compiler (apt-get install build-essential) or a WSL that cannot" >&2
  echo "         see the GPU (wsl --shutdown, then update the Windows driver)." >&2
fi

echo "== [6/6] Downloading model weights: $MODEL ($SIZE_HINT) =="
if [[ -n "${HF_TOKEN:-}" ]]; then
  # Saved to ~/.cache/huggingface/token, which vLLM also reads at serve time.
  "$VENV/bin/python" - <<'TOKEN_PY'
import os
from huggingface_hub import login
login(token=os.environ["HF_TOKEN"], add_to_git_credential=False)
print("Hugging Face token saved - later runs will not ask for it again.")
TOKEN_PY
fi

# One copy of the download logic for both the GUI and the interactive path.
# "read -d ''" always ends at EOF with status 1, which 'set -e' would take as
# fatal, hence the '|| true'.
read -r -d '' DL_PY <<'DOWNLOAD_PY' || true
import sys
from huggingface_hub import snapshot_download
try:
    from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError
except ImportError:   # huggingface_hub < 0.24
    from huggingface_hub.utils import GatedRepoError, RepositoryNotFoundError

repo = sys.argv[1]
try:
    snapshot_download(repo)
except (GatedRepoError, RepositoryNotFoundError):
    sys.exit(
        f"\nERROR: Hugging Face refused to serve {repo}.\n"
        f"Sign in at https://huggingface.co/{repo} and accept the terms, then\n"
        "re-run the installer with a READ token from\n"
        "https://huggingface.co/settings/tokens (the Setup tab has a field for it).\n"
    )
print("Model cached.")
DOWNLOAD_PY

# An aborted download leaves its partial blob behind as <sha>.<id>.incomplete.
# It wastes gigabytes and it is counted by the 'du' progress line below, which is
# why that line could read "downloaded 21G of ~19 GB". huggingface_hub *resumes*
# from these files, so only remove ones no live download could still be writing:
# untouched for an hour. The '|| true' matters - under 'set -euo pipefail' a
# find over a missing cache dir would otherwise abort the whole install.
find "$HOME/.cache/huggingface/hub" -name '*.incomplete' -mmin +60 -delete 2>/dev/null || true

if [[ "${SKIP_DOWNLOAD:-0}" == "1" ]]; then
  echo "SKIP_DOWNLOAD=1 set - skipping. vLLM will download on first serve instead."
elif [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  # No tqdm bars in GUI mode; report cache growth every 15s instead.
  export HF_HUB_DISABLE_PROGRESS_BARS=1
  CACHE_DIR="$HOME/.cache/huggingface/hub/models--${MODEL//\//--}"
  "$VENV/bin/python" -c "$DL_PY" "$MODEL" &
  DL_PID=$!
  while kill -0 "$DL_PID" 2>/dev/null; do
    # 'du' exits non-zero until the cache dir exists, and under 'set -e' a bare
    # assignment inherits that status and would kill the install a split second
    # after the download starts. Swallow it inside the substitution.
    SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || true)
    echo "   ... downloaded ${SIZE:-0} of $SIZE_HINT"
    sleep 15
  done
  wait "$DL_PID"
else
  "$VENV/bin/python" -c "$DL_PY" "$MODEL"
fi

echo
echo "Setup complete."
echo "  Start the server from Windows:  double-click 'Start Qwen 5090.cmd' (or .\\app\\run.ps1)"
echo "  ...or from this WSL shell:      bash app/scripts/serve.sh"
