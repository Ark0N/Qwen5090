#!/usr/bin/env bash
# Shared helper, meant to be *sourced*. Tells WSL2 apart from a native Linux
# box so the scripts can print instructions that actually apply.
#
# Everything under app/scripts/ is plain Linux and runs identically in both
# places - vLLM is Linux-only, which is exactly why the Windows half of this
# product provisions WSL2 and then gets out of the way. The only real
# difference is the advice: on WSL a missing GPU means the *Windows* driver is
# wrong and the fix is `wsl --shutdown`, while on a native box it means the
# Linux driver is missing and installing one is correct (on WSL it is actively
# harmful - it shadows the Windows driver).

qwen5090_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && return 0
  grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null
}

# "wsl" or "linux" - handy for a case statement.
qwen5090_platform() {
  if qwen5090_is_wsl; then echo wsl; else echo linux; fi
}

# How this machine's user starts the server, for closing instructions.
qwen5090_start_hint() {
  if qwen5090_is_wsl; then
    echo "  Start the server from Windows:  double-click 'Start Qwen 5090.cmd' (or .\\app\\run.ps1)"
    echo "  ...or from this WSL shell:      bash app/scripts/serve.sh"
  else
    echo "  Start the server:               bash app/scripts/serve.sh"
    echo "  Point Claude Code at it:        bash app/scripts/claude-code.sh run"
  fi
}
