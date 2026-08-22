#!/usr/bin/env bash
# Serve a GGUF model with llama.cpp - the second backend, for models too big
# for VRAM. The Linux twin of app/serve-gguf.ps1; serve.sh execs this when the
# model catalog says the checkpoint is a llama.cpp one and we are NOT on WSL.
#
# On WSL, serve.sh refuses instead and points at the PowerShell script: WSL2
# takes a fixed slice of RAM, and a model bigger than that slice cannot be
# served from inside it. Windows maps the file and lets the page cache shrink
# under pressure; that is the difference between slow and impossible.
#
#   MODEL=puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:Q2_K bash serve-gguf.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-build-tools.sh
source "$SCRIPT_DIR/lib-build-tools.sh"
# shellcheck source=lib-platform.sh
source "$SCRIPT_DIR/lib-platform.sh"
# shellcheck source=lib-model-catalog.sh
source "$SCRIPT_DIR/lib-model-catalog.sh"

MODEL="${MODEL:-puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:Q2_K}"
CTX="${CTX:-131072}"
PORT="${PORT:-8001}"
MODEL_DIR="${QWEN5090_MODEL_DIR:-$HOME/.qwen5090/models}"
LLAMA_HOME="${QWEN5090_LLAMA_HOME:-$HOME/.qwen5090/llamacpp}"
VENV="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
# 0 = every layer's experts stay on the CPU, which is the setting that always
# starts. Lowering it moves experts onto the GPU and is the first knob worth
# turning once it runs at all.
N_CPU_MOE="${N_CPU_MOE:-0}"
DOWNLOAD="${DOWNLOAD:-1}"
API_KEY="${API_KEY:-}"
DRAFT="${DRAFT:-}"

LOG_DIR="${QWEN5090_LOG_DIR:-$HOME/.qwen5090/logs}"
mkdir -p "$LOG_DIR" "$MODEL_DIR"
LOG_FILE="$LOG_DIR/serve-gguf-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: serve-gguf.sh failed at line $LINENO (exit $?)"' ERR
echo ">> logging to $LOG_FILE"

say()  { printf '>> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO="${MODEL%%:*}"
QUANT=""
[[ "$MODEL" == *:* ]] && QUANT="${MODEL##*:}"

qwen5090_model_preflight "$MODEL" || exit 1

# ------------------------------------------------------------- llama.cpp ----
# The release page ships no CUDA build for Linux - only CPU, Vulkan and SYCL -
# so a GPU-capable llama-server has to be compiled. nvcc does not need
# installing: torch's CUDA wheels vendor a complete toolkit inside the venv,
# which is the same trick serve.sh uses for FlashInfer.
LLAMA_SERVER="$LLAMA_HOME/bin/llama-server"

find_cuda_home() {
  local cu
  for cu in "$VENV"/lib/python*/site-packages/nvidia/cu13 "$VENV"/lib/python*/site-packages/nvidia/cu12; do
    [[ -x "$cu/bin/nvcc" ]] && { echo "$cu"; return 0; }
  done
  [[ -x /usr/local/cuda/bin/nvcc ]] && { echo /usr/local/cuda; return 0; }
  return 1
}

ensure_llama_server() {
  if command -v llama-server >/dev/null 2>&1; then
    LLAMA_SERVER=$(command -v llama-server)
    say "using the llama-server already on PATH: $LLAMA_SERVER"
    return 0
  fi
  [[ -x "$LLAMA_SERVER" ]] && { say "using $LLAMA_SERVER"; return 0; }

  ensure_build_tools || exit 1
  command -v cmake >/dev/null 2>&1 || die "cmake is needed to build llama.cpp:  sudo apt-get install -y cmake"
  command -v git   >/dev/null 2>&1 || die "git is needed to build llama.cpp"

  local cuda_home
  if ! cuda_home=$(find_cuda_home); then
    die "no nvcc found - install the CUDA toolkit, or run setup-wsl.sh first so
       torch's vendored toolkit is available inside $VENV."
  fi
  say "building llama.cpp with CUDA (sm120) using $cuda_home - this takes a while"

  local src="$LLAMA_HOME/src"
  mkdir -p "$LLAMA_HOME"
  if [[ -d "$src/.git" ]]; then
    git -C "$src" fetch --depth 1 origin master && git -C "$src" reset --hard FETCH_HEAD
  else
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$src"
  fi
  # 120 is Blackwell. Naming it explicitly keeps the build from compiling every
  # architecture ever shipped, which triples the build time for nothing.
  CUDAToolkit_ROOT="$cuda_home" PATH="$cuda_home/bin:$PATH" \
    cmake -S "$src" -B "$src/build" \
      -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 \
      -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$src/build" --config Release -j "$(nproc)" --target llama-server
  mkdir -p "$LLAMA_HOME/bin"
  cp "$src/build/bin/llama-server" "$LLAMA_SERVER"
  say "built $LLAMA_SERVER"
}

# ----------------------------------------------------------- model files ----
# Enumerated through the Hub API rather than guessed: one build is a single
# 62 GB file, the next is four shards under a quant subfolder.
hub_files() {
  curl -sf -m 60 "https://huggingface.co/api/models/$REPO" | REPO="$REPO" QUANT="$QUANT" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
q = os.environ.get("QUANT") or ""
for f in d.get("siblings", []):
    p = f.get("rfilename", "")
    if p.endswith(".gguf") and "dspark" not in p.lower() and (not q or q in p):
        print(p)'
}

LOCAL_DIR="$MODEL_DIR/${REPO//\//--}"
if [[ "$DOWNLOAD" == "1" ]]; then
  say "listing $REPO ($QUANT)"
  mapfile -t FILES < <(hub_files)
  (( ${#FILES[@]} )) || die "no GGUF matching '$QUANT' in $REPO"
  say "${#FILES[@]} file(s) - tens of gigabytes, and each resumes if interrupted"
  for f in "${FILES[@]}"; do
    dest="$LOCAL_DIR/$f"
    if [[ -s "$dest" ]]; then
      say "  have $f"
      continue
    fi
    say "  get  $f"
    mkdir -p "$(dirname "$dest")"
    auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
    curl -L --fail --retry 5 --retry-delay 5 -C - "${auth[@]}" \
      -o "$dest" "https://huggingface.co/$REPO/resolve/main/$f" \
      || die "download failed: $f"
  done
fi

shopt -s nullglob globstar
CANDIDATES=("$LOCAL_DIR"/**/*.gguf)
shopt -u nullglob globstar
(( ${#CANDIDATES[@]} )) || die "no weights under $LOCAL_DIR - run again with DOWNLOAD=1"

FIRST=""
for f in "${CANDIDATES[@]}"; do
  [[ "$f" == *dspark* ]] && continue
  [[ -n "$QUANT" && "$f" != *"$QUANT"* ]] && continue
  # llama.cpp finds the siblings itself when handed shard one.
  if [[ "$f" == *-00001-of-* ]]; then FIRST="$f"; break; fi
  [[ -z "$FIRST" ]] && FIRST="$f"
done
[[ -n "$FIRST" ]] || die "no usable GGUF under $LOCAL_DIR"

ensure_llama_server

ARGS=(
  -m "$FIRST"
  --host 0.0.0.0 --port "$PORT"
  -c "$CTX"
  -ngl 999          # every layer on the GPU...
  --jinja           # ...and tool calling needs the real chat template
  -fa on
  -ub 128           # prefill against RAM-resident experts is bandwidth-bound;
                    # a large micro-batch just thrashes the page cache
)
# ...except the experts, which do not fit.
if (( N_CPU_MOE > 0 )); then ARGS+=(--n-cpu-moe "$N_CPU_MOE"); else ARGS+=(--cpu-moe); fi
[[ -n "$DRAFT"   ]] && ARGS+=(-md "$DRAFT")
[[ -n "$API_KEY" ]] && ARGS+=(--api-key "$API_KEY")

# mmap stays on (the default): the weights are mapped, not read, so the pages
# that do not fit are simply not resident. --no-mmap would try to read the
# whole file into RAM and fail.
say "model=$(basename "$FIRST") ctx=$CTX port=$PORT cpu_moe=${N_CPU_MOE:-all}"
say "first load reads ${MODEL_SIZE_GB:-?} GB off the disk - give it a few minutes"
exec "$LLAMA_SERVER" "${ARGS[@]}"
