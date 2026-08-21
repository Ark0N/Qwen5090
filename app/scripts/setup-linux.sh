#!/usr/bin/env bash
# Native-Linux entry point for the one-time setup.
#
# There is nothing Linux-specific in here: setup-wsl.sh has always been a plain
# Linux script (vLLM is Linux-only, which is why the Windows half of this
# product provisions WSL2 and then hands over to it), and it detects which of
# the two it is running on. This wrapper exists so a Linux user is not asked to
# run something called "setup-wsl" on a machine that has no WSL.
#
#   bash app/scripts/setup-linux.sh
#   MODEL=sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4 bash app/scripts/setup-linux.sh
#
# See app/docs/LINUX.md for the full walkthrough.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-wsl.sh" "$@"
