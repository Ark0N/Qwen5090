#!/usr/bin/env bash
# One command, the production configuration: start the server exactly the way
# the Windows box serves it — same model, same window, same flags. Written for
# the dual-boot case (boot Ubuntu, pull, serve, and every client on the
# tailnet keeps working against the same URL), but it runs on any 5090 box
# with the NInfer backend installed (scripts/setup-ninfer.sh).
#
#   git pull && bash app/scripts/serve-full.sh
#
# What it pins, and why (everything not listed is already serve-ninfer.sh's
# default and matches production):
#
#   MODEL   neroued/Qwen3.8-27B-nvfp4-NInfer — the NInfer repack of the same
#           Qwen3.8-27B NVFP4 weights the vLLM path serves.
#   CTX     262144 — the model's native window. The artifact clamps it to
#           252,928, the most that fits beside the weights on a 32 GB card;
#           usable here because NInfer has no prefill cliff.
#
# The resulting command line (via serve.sh's dispatch to serve-ninfer.sh):
# 0.0.0.0:8000, --max-context 252928, --kv-dtype int8, --max-concurrency 2,
# --prefill-chunk 1024, --spec mtp --draft-tokens 3 --lm-head-draft,
# --preserve-thinking, prefix reuse on.
#
# Sharing needs no extra step on Linux: 0.0.0.0 puts it on the LAN directly,
# and Tailscale reaches it at http://<tailnet-ip>:8000/v1 — serve-ninfer.sh
# prints that URL when a tailnet is up. (share.ps1 exists only because WSL on
# Windows needs a portproxy; native Linux does not.)
#
# Every value stays an ordinary environment override:
#   CTX=131072 bash app/scripts/serve-full.sh    # same stack, default window
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export MODEL="${MODEL:-neroued/Qwen3.8-27B-nvfp4-NInfer}"
export CTX="${CTX:-262144}"
export PORT="${PORT:-8000}"
# Explicit even where they equal the defaults, so this file *is* the record of
# the production configuration rather than a pointer into another script's.
export MAX_SEQS="${MAX_SEQS:-2}"
export SPEC_TOKENS="${SPEC_TOKENS:-3}"
export MTP="${MTP:-1}"
export KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-int8}"
export KV_CAPACITY="${KV_CAPACITY:-auto}"
export PREFILL_CHUNK="${PREFILL_CHUNK:-1024}"
export PREFIX_CACHE="${PREFIX_CACHE:-1}"
export PRESERVE_THINKING="${PRESERVE_THINKING:-1}"

# Through serve.sh rather than serve-ninfer.sh directly, so the catalog
# dispatch, the preflights and any future routing stay in one place.
exec bash "$SCRIPT_DIR/serve.sh"
