#!/usr/bin/env bash
# Shared helper, meant to be *sourced* by setup-wsl.sh and serve.sh.
#
# Why this exists: Triton — the kernel compiler vLLM JITs through — shells out
# to a real C compiler at runtime. The very first CUDA call builds its driver
# module from driver.c, and on this model several hot paths are Triton kernels
# too (the GDN attention prefill, the vision tower's position-embedding
# interpolation). Ubuntu's WSL rootfs ships no compiler at all, so vLLM dies
# about a minute into startup with:
#
#     RuntimeError: Failed to find C compiler. Please specify via CC
#     environment variable or set triton.knobs.build.impl.
#
# One apt-get fixes it for good.

qwen5090_have_cc() {
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1
}

qwen5090_apt() {
  # The distro normally runs as root; a 'qwen' default user has passwordless
  # sudo. '-n' so a password prompt fails fast instead of hanging an install
  # that the GUI started with no console attached.
  if [[ "$(id -u)" == "0" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || return 1

  # Which sudo form works is a property of this machine's sudoers, so settle it
  # once and remember it.
  #
  # `sudo -n env DEBIAN_FRONTEND=noninteractive apt-get ...` is the form that
  # gets DEBIAN_FRONTEND past sudo's env_reset - but the command sudo matches
  # against sudoers is then /usr/bin/env, not /usr/bin/apt-get. Under a blanket
  # rule that is invisible; under a rule scoped to the package manager, which
  # is the *safe* way to grant this and what this project recommends -
  #     testuser ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt
  # - it is denied outright, and unattended installs fail on a machine whose
  # owner did exactly what they were told to do.
  #
  # So fall back to invoking apt-get directly, which such a rule does match.
  # The cost is only that DEBIAN_FRONTEND may be stripped; every call site here
  # already passes -y and -qq, which is what keeps our packages from prompting.
  if [[ -z "${QWEN5090_APT_SUDO_FORM:-}" ]]; then
    if sudo -n env DEBIAN_FRONTEND=noninteractive apt-get --version >/dev/null 2>&1; then
      QWEN5090_APT_SUDO_FORM=env
    else
      QWEN5090_APT_SUDO_FORM=direct
    fi
  fi

  if [[ "$QWEN5090_APT_SUDO_FORM" == "env" ]]; then
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get "$@"
  else
    sudo -n apt-get "$@"
  fi
}

# Make sure a C compiler exists, installing build-essential if not.
# Returns 1 (after printing what to do by hand) if it cannot get one.
ensure_build_tools() {
  if qwen5090_have_cc; then
    return 0
  fi
  echo "No C compiler in this Ubuntu image - installing build-essential (about a minute)."
  # A fresh WSL rootfs has empty package lists, so 'update' is not optional.
  # DPkg::Lock::Timeout waits out Ubuntu's background apt jobs instead of
  # failing on a lock a few seconds after first boot.
  if ! qwen5090_apt update -qq -o Acquire::Retries=3; then
    echo "   (apt-get update failed - trying the install anyway)" >&2
  fi
  qwen5090_apt install -y -qq -o DPkg::Lock::Timeout=180 build-essential || true
  if qwen5090_have_cc; then
    echo "Build tools ready: $( { cc --version || gcc --version; } 2>/dev/null | head -1 )"
    return 0
  fi
  cat >&2 <<'MSG'

ERROR: could not install a C compiler inside WSL.

vLLM compiles GPU kernels on the fly with Triton, which needs one; without it
the server fails with "Failed to find C compiler" a minute after it starts.

Install it by hand - from Windows PowerShell:

     wsl -d Ubuntu-24.04 -u root -- bash -c "apt-get update && apt-get install -y build-essential"

If that fails too, WSL has no working network or DNS: check that Windows is
online, then run  wsl --shutdown  and try again.
MSG
  return 1
}
