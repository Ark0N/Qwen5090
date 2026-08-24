#!/usr/bin/env bash
# Shared helper, meant to be *sourced* by setup-ninfer.sh and serve-ninfer.sh.
# Everything about getting NInfer onto this machine: the toolchain it needs,
# the CUDA toolkit it compiles against, the build itself, and the artifact
# download.
#
# NInfer ships no binaries and has no install target - the README says plainly
# that it runs from its source build tree - so "installing" it means compiling
# C++/CUDA for sm_120a. That is the one genuinely expensive step in this whole
# integration, and the reason the NInfer path is opt-in rather than the
# shipped default.
#
#   ninfer_ensure_build              clone + compile, idempotent
#   ninfer_ensure_artifact <model>   download + verify the .ninfer container
#   ninfer_artifact_path <model>     where that container lives
#   ninfer_installed <model>         both of the above already done?

NINFER_HOME="${QWEN5090_NINFER_HOME:-$HOME/.qwen5090/ninfer}"
NINFER_SRC="$NINFER_HOME/src"
NINFER_BUILD_DIR="$NINFER_HOME/build"
NINFER_BIN_DIR="$NINFER_HOME/bin"
NINFER_SERVE="$NINFER_BIN_DIR/ninfer-serve"
NINFER_CLI="$NINFER_BIN_DIR/ninfer"
NINFER_MODEL_DIR="${QWEN5090_NINFER_MODEL_DIR:-$NINFER_HOME/models}"
NINFER_GIT="${QWEN5090_NINFER_GIT:-https://github.com/Neroued/ninfer.git}"
# Empty tracks the default branch. Pin a tag or sha here when a rebuild starts
# behaving differently from the one that was measured.
NINFER_REF="${QWEN5090_NINFER_REF:-}"

_ninfer_say() { printf '>> %s\n' "$*"; }
_ninfer_err() { printf 'ERROR: %s\n' "$*" >&2; }

# ------------------------------------------------------------ toolchain ----
# Ubuntu 24.04 has all of these; none is present in a fresh WSL rootfs. The
# ffmpeg and curl development packages are not optional even for a text-only
# deployment: NInfer's CMakeLists does an unconditional pkg_check_modules on
# them, so configure fails before it compiles anything.
NINFER_APT_PACKAGES=(
  cmake ninja-build pkg-config git
  libavformat-dev libavcodec-dev libavutil-dev libswscale-dev
  libcurl4-openssl-dev
)

ninfer_have_deps() {
  command -v cmake >/dev/null 2>&1 || return 1
  command -v ninja >/dev/null 2>&1 || return 1
  command -v git   >/dev/null 2>&1 || return 1
  pkg-config --exists 'libavformat >= 60' 'libavcodec >= 60' \
                      'libavutil >= 58' 'libswscale >= 7' 'libcurl >= 7.85' 2>/dev/null || return 1
  # 3.28 is a hard floor in NInfer's own CMakeLists; 24.04 ships 3.28.3, so
  # this only fires on an older distro.
  local v
  v=$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
  [[ -n "$v" ]] || return 1
  awk -v v="$v" 'BEGIN { split(v, a, "."); exit !(a[1] > 3 || (a[1] == 3 && a[2] >= 28)) }' || return 1
  return 0
}

ninfer_ensure_deps() {
  if ninfer_have_deps; then
    return 0
  fi
  _ninfer_say "installing NInfer's build dependencies (cmake, ninja, ffmpeg and curl headers)"
  if ! qwen5090_apt update -qq -o Acquire::Retries=3; then
    echo "   (apt-get update failed - trying the install anyway)" >&2
  fi
  qwen5090_apt install -y -qq -o DPkg::Lock::Timeout=180 "${NINFER_APT_PACKAGES[@]}" || true
  if ninfer_have_deps; then
    return 0
  fi
  cat >&2 <<MSG

ERROR: could not install what NInfer needs to compile.

Install these by hand and run this again:

     sudo apt-get update
     sudo apt-get install -y ${NINFER_APT_PACKAGES[*]}

cmake must be 3.28 or newer - that floor is NInfer's own, not this toolkit's.
MSG
  return 1
}

# ----------------------------------------------------------------- CUDA ----
# NInfer needs a real CUDA toolkit at 13.1 or newer, and it needs it at build
# time rather than at first request: this is an ahead-of-time compile for
# sm_120a, not a JIT like FlashInfer's. Three places one can turn up, in
# descending order of how well the resulting build is understood:
#
#   1. a system toolkit (/usr/local/cuda, or nvcc on PATH). What NInfer's own
#      Dockerfile uses, and the only layout its CMakeLists was written
#      against. On the native Linux box this is already there.
#   2. a versioned system toolkit under /usr/local/cuda-13.x.
#   3. the toolkit torch's CUDA wheels vendor inside the vLLM venv. The same
#      trick serve.sh uses for FlashInfer and serve-gguf.sh for llama.cpp, and
#      the only one available in a stock WSL rootfs - but the wheel puts its
#      libraries in lib/ where CMake's FindCUDAToolkit looks in lib64/, and it
#      ships no driver library at all, so it is handed over through a shim
#      directory rather than directly.
_ninfer_nvcc_ok() {
  local nvcc="$1"
  [[ -x "$nvcc" ]] || return 1
  local rel
  rel=$("$nvcc" --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -1 | awk '{print $2}' || true)
  [[ -n "$rel" ]] || return 1
  awk -v v="$rel" 'BEGIN { split(v, a, "."); exit !(a[1] > 13 || (a[1] == 13 && a[2] >= 1)) }'
}

# nvcc and the CTK headers next to it have to agree on a version, or CCCL
# refuses to compile anything that includes it:
#
#   cccl/cuda/std/__cccl/cuda_toolkit.h:41: error "CUDA compiler and CUDA
#   toolkit headers are incompatible, please check your include paths"
#
# torch's CUDA wheels ship exactly that pair - measured here 2026-08-24, nvcc
# 13.3.73 beside a cuda_runtime_api.h declaring CUDART_VERSION 13020 (13.2) -
# so the wheel path hits this roughly 130 files into a 423-file build, which is
# an expensive way to find out. It is the same mismatch CLAUDE.md already
# records for FlashInfer's JIT on this machine, and it has the same escape
# hatch, which CCCL provides precisely for a newer CTK than the compiler ships.
#
# Detected rather than assumed: a system toolkit assembled from mixed packages
# can disagree too, and a wheel whose versions happen to line up should be
# compiled with the check left on.
_ninfer_ctk_header_version() {
  local hdr="$1/include/cuda_runtime_api.h"
  [[ -r "$hdr" ]] || return 1
  local raw
  raw=$(grep -m1 -oE '^#define[[:space:]]+CUDART_VERSION[[:space:]]+[0-9]+' "$hdr" \
        | grep -oE '[0-9]+$' || true)
  [[ -n "$raw" ]] || return 1
  printf '%s.%s\n' "$(( raw / 1000 ))" "$(( (raw % 1000) / 10 ))"
}

# 0 when the two disagree (i.e. the check has to go), 1 when they match or
# either version cannot be read - an unreadable version is not evidence of a
# mismatch, and silently disabling a safety check on a guess is worse than
# letting the build say what is wrong.
_ninfer_needs_cccl_override() {
  local root="$1"
  local hdr_ver nvcc_ver
  hdr_ver=$(_ninfer_ctk_header_version "$root") || return 1
  nvcc_ver=$("$root/bin/nvcc" --version 2>/dev/null \
             | grep -oE 'release [0-9]+\.[0-9]+' | head -1 | awk '{print $2}' || true)
  [[ -n "$nvcc_ver" ]] || return 1
  NINFER_CTK_HEADER_VERSION="$hdr_ver"
  NINFER_CTK_NVCC_VERSION="$nvcc_ver"
  [[ "$hdr_ver" != "$nvcc_ver" ]]
}

# Build a shadow prefix so a pip-wheel toolkit looks like a system one:
# lib64 alongside lib, and the driver library the wheel does not ship linked
# in from wherever this platform keeps it (/usr/lib/wsl/lib under WSL).
_ninfer_wheel_shim() {
  local cu="$1"
  local shim="$NINFER_HOME/cuda"
  rm -rf "$shim"
  mkdir -p "$shim/lib64" || return 1
  local d
  for d in bin include nvvm; do
    [[ -e "$cu/$d" ]] && ln -sfn "$cu/$d" "$shim/$d"
  done
  ln -sfn "$cu/lib" "$shim/lib"
  # Mirror lib/ into lib64/ rather than symlinking the directory: CMake probes
  # for individual libraries there, and some builds want a bare .so name that
  # the wheel only ships versioned.
  local f base
  for f in "$cu"/lib/*.so*; do
    [[ -e "$f" ]] || continue
    ln -sf "$f" "$shim/lib64/$(basename "$f")"
    base=$(basename "$f")
    base="${base%%.so*}.so"
    [[ -e "$shim/lib64/$base" ]] || ln -sf "$f" "$shim/lib64/$base"
  done
  local c
  for c in /usr/lib/wsl/lib/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so \
           /usr/lib/wsl/lib/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so.1; do
    if [[ -e "$c" ]]; then
      ln -sf "$c" "$shim/lib64/libcuda.so"
      break
    fi
  done
  [[ -e "$shim/lib64/libcuda.so" ]] || return 1
  echo "$shim"
}

# Sets NINFER_CUDA_ROOT and NINFER_CUDA_KIND ("system" or "wheel"), or
# returns 1. Deliberately not an echoing function: the caller needs both
# values, and $(...) would run this in a subshell and throw the kind away.
ninfer_cuda_home() {
  NINFER_CUDA_ROOT=""
  NINFER_CUDA_KIND=""
  local cand
  if cand=$(command -v nvcc 2>/dev/null) && _ninfer_nvcc_ok "$cand"; then
    NINFER_CUDA_ROOT=$(dirname "$(dirname "$cand")")
    NINFER_CUDA_KIND="system"
    return 0
  fi
  local root
  for root in "${CUDA_HOME:-}" /usr/local/cuda /usr/local/cuda-13.*; do
    [[ -n "$root" ]] || continue
    if _ninfer_nvcc_ok "$root/bin/nvcc"; then
      NINFER_CUDA_ROOT="$root"
      NINFER_CUDA_KIND="system"
      return 0
    fi
  done

  local venv="${QWEN5090_VENV:-$HOME/.qwen5090/venv}"
  local cu shim
  for cu in "$venv"/lib/python*/site-packages/nvidia/cu1[0-9]; do
    if _ninfer_nvcc_ok "$cu/bin/nvcc"; then
      if shim=$(_ninfer_wheel_shim "$cu"); then
        NINFER_CUDA_ROOT="$shim"
        NINFER_CUDA_KIND="wheel"
        return 0
      fi
    fi
  done
  return 1
}

# --------------------------------------------------------------- build -----
# One nvcc per job, and each one is not cheap on memory. nproc alone will
# happily start 16 of them inside a WSL VM that Windows has capped at 20 GB,
# and the OOM killer takes the build down 40 minutes in. Budget ~2 GB a job.
_ninfer_build_jobs() {
  if [[ -n "${NINFER_BUILD_JOBS:-}" ]]; then
    echo "$NINFER_BUILD_JOBS"
    return 0
  fi
  local cpus mem_gb jobs
  cpus=$(nproc 2>/dev/null || echo 4)
  mem_gb=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 8)
  jobs=$(( mem_gb / 2 ))
  (( jobs < 1 )) && jobs=1
  (( jobs > cpus )) && jobs=$cpus
  echo "$jobs"
}

ninfer_have_build() { [[ -x "$NINFER_SERVE" ]]; }

ninfer_ensure_build() {
  if ninfer_have_build && [[ "${NINFER_REBUILD:-0}" != "1" ]]; then
    _ninfer_say "using $NINFER_SERVE"
    return 0
  fi

  ensure_build_tools || return 1
  ninfer_ensure_deps || return 1

  if ! ninfer_cuda_home; then
    cat >&2 <<'MSG'

ERROR: NInfer needs a CUDA toolkit at 13.1 or newer and there is none here.

Unlike vLLM, NInfer compiles its kernels ahead of time, so this is a build
requirement rather than something that can be worked around at runtime.

Two ways to get one:

  * Install NVIDIA's toolkit (the reliable route, ~3 GB):
        https://developer.nvidia.com/cuda-downloads
  * Or run the vLLM setup first - torch's CUDA wheels vendor a complete
    toolkit inside the venv, and this script will find and use it:
        bash app/scripts/setup-wsl.sh

The GPU driver on its own is not enough: nvcc ships in the toolkit.
MSG
    return 1
  fi
  local cuda_home="$NINFER_CUDA_ROOT"
  _ninfer_say "CUDA toolkit: $cuda_home ($("$cuda_home/bin/nvcc" --version 2>/dev/null | tail -1 || true))"
  if [[ "$NINFER_CUDA_KIND" == "wheel" ]]; then
    _ninfer_say "   that is torch's vendored toolkit, reshaped to look like a system one."
    _ninfer_say "   If the build fails oddly, install the real CUDA toolkit and try again."
  fi

  mkdir -p "$NINFER_HOME" || return 1
  if [[ -d "$NINFER_SRC/.git" ]]; then
    _ninfer_say "updating the NInfer checkout"
    git -C "$NINFER_SRC" fetch --depth 1 origin "${NINFER_REF:-HEAD}" \
      && git -C "$NINFER_SRC" reset --hard FETCH_HEAD
  else
    _ninfer_say "cloning NInfer from $NINFER_GIT"
    if [[ -n "$NINFER_REF" ]]; then
      git clone --depth 1 --branch "$NINFER_REF" "$NINFER_GIT" "$NINFER_SRC" || return 1
    else
      git clone --depth 1 "$NINFER_GIT" "$NINFER_SRC" || return 1
    fi
  fi

  local jobs
  jobs=$(_ninfer_build_jobs)
  _ninfer_say "compiling NInfer for sm_120a with $jobs job(s) - this takes a long while,"
  _ninfer_say "   and it is a one-off: the build is reused on every later start."

  # Safe to set: NInfer never touches CMAKE_CUDA_FLAGS itself - it applies
  # -lineinfo through target_compile_options - so nothing here is overwritten.
  local cuda_flags=""
  if _ninfer_needs_cccl_override "$cuda_home"; then
    _ninfer_say "nvcc is $NINFER_CTK_NVCC_VERSION but the toolkit headers are $NINFER_CTK_HEADER_VERSION;"
    _ninfer_say "   disabling CCCL's compiler/header version check for this build."
    cuda_flags="-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK"
  fi

  # CMAKE_CUDA_ARCHITECTURES is left alone deliberately. NInfer defaults it to
  # 120a and hard-errors on any other value, so passing it can only ever break
  # the build - and 120a is Blackwell, which is the only card this product
  # runs on anyway.
  CUDAToolkit_ROOT="$cuda_home" \
  CUDACXX="$cuda_home/bin/nvcc" \
  PATH="$cuda_home/bin:$PATH" \
    cmake -S "$NINFER_SRC" -B "$NINFER_BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_FLAGS="$cuda_flags" \
      -DNINFER_BUILD_APPS=ON \
      -DBUILD_TESTING=OFF \
      -DNINFER_BUILD_BENCHMARKS=OFF || {
        _ninfer_err "the NInfer CMake configure step failed - see the output above."
        return 1
      }

  CUDAToolkit_ROOT="$cuda_home" PATH="$cuda_home/bin:$PATH" \
    cmake --build "$NINFER_BUILD_DIR" --parallel "$jobs" --target ninfer ninfer-serve || {
      _ninfer_err "the NInfer build failed - see the output above."
      if [[ "$NINFER_CUDA_KIND" == "wheel" ]]; then
        _ninfer_err "It compiled against torch's vendored CUDA toolkit. Installing the real"
        _ninfer_err "toolkit from https://developer.nvidia.com/cuda-downloads is the first thing to try."
      fi
      return 1
    }

  mkdir -p "$NINFER_BIN_DIR" || return 1
  # Copied out rather than symlinked so a later `git reset --hard` in the
  # checkout cannot leave a dangling server behind.
  cp "$NINFER_BUILD_DIR/apps/ninfer-serve" "$NINFER_SERVE" || return 1
  cp "$NINFER_BUILD_DIR/apps/ninfer" "$NINFER_CLI" 2>/dev/null || true
  git -C "$NINFER_SRC" rev-parse HEAD > "$NINFER_HOME/built-from.txt" 2>/dev/null || true
  _ninfer_say "built $NINFER_SERVE"
  return 0
}

# ------------------------------------------------------------ artifacts ----
ninfer_artifact_path() {
  local model="${1:?ninfer_artifact_path needs a model id}"
  qwen5090_model_info "$model"
  [[ -n "$MODEL_NINFER_FILE" ]] || return 1
  echo "$NINFER_MODEL_DIR/$MODEL_NINFER_FILE"
}

# NInfer artifacts are one big file per model, published public, with an exact
# byte count and a SHA-256 in the project README. Both are checked: a resumed
# curl that reconnected to a truncated response produces a file that looks
# present and fails hours later as an unreadable container.
#
# The digest is checked once and stamped, because hashing 20 GiB costs a
# minute or two and there is no reason to pay it on every server start.
ninfer_ensure_artifact() {
  local model="${1:?ninfer_ensure_artifact needs a model id}"
  qwen5090_model_info "$model"
  if [[ "$MODEL_BACKEND" != "ninfer" || -z "$MODEL_NINFER_FILE" ]]; then
    _ninfer_err "$model is not an NInfer artifact."
    return 1
  fi

  local dest="$NINFER_MODEL_DIR/$MODEL_NINFER_FILE"
  local stamp="$dest.verified"
  if [[ -f "$stamp" && -s "$dest" ]]; then
    _ninfer_say "have $MODEL_NINFER_FILE (verified earlier)"
    return 0
  fi

  mkdir -p "$NINFER_MODEL_DIR" || return 1
  local url="https://huggingface.co/$model/resolve/main/$MODEL_NINFER_FILE"
  local have=0
  [[ -f "$dest" ]] && have=$(stat -c %s "$dest" 2>/dev/null || echo 0)

  if (( have != MODEL_NINFER_BYTES )); then
    _ninfer_say "downloading $MODEL_NINFER_FILE ($(( MODEL_NINFER_BYTES / 1000000000 )) GB) from $model"
    (( have > 0 )) && _ninfer_say "   resuming from $(( have / 1000000 )) MB"
    local auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")

    # The resume loop lives here rather than in curl's own --retry, and both
    # halves of that are deliberate. curl retries only what it considers
    # transient - timeouts, HTTP 408/429/5xx - so a mid-transfer TLS or recv
    # error (exit 56, seen here 2.4 GB into a 21 GB transfer as
    # "SSL_read: ... bad record mac") aborts the whole thing instead. And even
    # with --retry-all-errors it would not help much: `-C -` resolves its
    # offset once, when curl starts, so an in-process retry does not pick the
    # resume point back up. Re-invoking curl does, because the offset is read
    # off the file on disk each time.
    #
    # Bounded by attempts that made no progress, not by attempts: a transfer
    # inching forward across a flaky link should keep going, one that cannot
    # move a byte should not spin forever.
    local attempt=0 stalled=0 rc=0 before=0
    local max_stalled="${NINFER_DOWNLOAD_STALL_LIMIT:-5}"
    while (( have != MODEL_NINFER_BYTES )); do
      attempt=$(( attempt + 1 ))
      before="$have"
      rc=0
      curl -L --fail --retry 5 --retry-delay 5 --retry-all-errors -C - "${auth[@]}" \
        -o "$dest" "$url" || rc=$?
      have=0
      [[ -f "$dest" ]] && have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
      (( have == MODEL_NINFER_BYTES )) && break

      # A server that ignored the Range header and restarted from zero, or a
      # file that grew past the published size, is not something to retry into.
      if (( have > MODEL_NINFER_BYTES )); then
        _ninfer_err "$MODEL_NINFER_FILE grew past the published size ($have > $MODEL_NINFER_BYTES)."
        _ninfer_err "Delete it and run this again: rm '$dest'"
        return 1
      fi

      if (( have > before )); then
        stalled=0
      else
        stalled=$(( stalled + 1 ))
      fi
      if (( stalled >= max_stalled )); then
        _ninfer_err "download failed: $MODEL_NINFER_FILE (curl rc=$rc, no progress in $stalled attempts)"
        _ninfer_err "   got $(( have / 1000000 )) MB of $(( MODEL_NINFER_BYTES / 1000000 )) MB."
        _ninfer_err "   The partial file is kept - running this again resumes from there."
        return 1
      fi
      _ninfer_say "   transfer interrupted (curl rc=$rc) at $(( have / 1000000 )) MB - resuming (attempt $(( attempt + 1 )))"
      sleep 5
    done
  fi

  local size
  size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
  if (( size != MODEL_NINFER_BYTES )); then
    _ninfer_err "$MODEL_NINFER_FILE is $size bytes; the published artifact is $MODEL_NINFER_BYTES."
    _ninfer_err "Delete it and run this again: rm '$dest'"
    return 1
  fi

  if [[ -n "$MODEL_NINFER_SHA256" ]] && command -v sha256sum >/dev/null 2>&1; then
    _ninfer_say "verifying the download (SHA-256 over $(( size / 1000000000 )) GB, a minute or two)"
    local got
    got=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "$got" != "$MODEL_NINFER_SHA256" ]]; then
      _ninfer_err "$MODEL_NINFER_FILE failed its checksum."
      _ninfer_err "   expected $MODEL_NINFER_SHA256"
      _ninfer_err "   got      $got"
      _ninfer_err "Delete it and run this again: rm '$dest'"
      return 1
    fi
    _ninfer_say "checksum OK"
  fi
  : > "$stamp"
  return 0
}

ninfer_installed() {
  local model="${1:?ninfer_installed needs a model id}"
  ninfer_have_build || return 1
  local path
  path=$(ninfer_artifact_path "$model") || return 1
  [[ -s "$path" ]]
}
