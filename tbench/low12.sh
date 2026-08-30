#!/bin/bash
# Low-effort run of the 12-task comparison subset, on the three harnesses the
# maintainer asked for (dsh, pi, cc; terminus excluded).
#
# Why the 12-task set and not sweep.sh's 8: the 8 are a strict SUBSET of these
# 12, and low was already swept over those 8 (dsh 7/8, pi 4/8, cc 4/8). Running
# the full 12 re-measures those and adds the 4 model-ceiling tasks, so the score
# is directly comparable to the published /12 headline (dsh 7, pi 7, cc 7 at
# their optimized efforts) instead of living on a different denominator.
#
# Sequential: the GPU is shared with the user's live sessions. 900s agent
# timeout is the optimized value from REPORT.md (cc needs it; 500 truncated it).
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
export PYTHONPATH="$PWD"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
TB=~/.local/bin/tb
OUT="$PWD/runs"

# The model serve. Every number in REPORT.md was measured against one
# particular box, whose address has no business in a public repo - point
# QWEN_URL at your own. Same variable app/scripts/terminal-bench.sh reads.
QWEN_URL="${QWEN_URL:-http://localhost:8000}"
# litellm-bridge.yaml reads this one (LiteLLM's os.environ/ indirection).
export QWEN_API_BASE="$QWEN_URL/v1"

export TB_EFFORT=low

TASKS=(hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow \
       pytorch-model-cli.hard sanitize-git-repo fix-git openssl-selfsigned-cert \
       sqlite-db-truncate fibonacci-server write-compressor nginx-request-logging)
TARGS=(); for t in "${TASKS[@]}"; do TARGS+=(-t "$t"); done
COMMON=(--dataset terminal-bench-core==0.1.1 "${TARGS[@]}" --n-concurrent 2 \
        --global-agent-timeout-sec 900 --no-cleanup --output-path "$OUT")

bridge_up() { curl -s --max-time 5 http://127.0.0.1:4001/health/liveliness >/dev/null 2>&1; }

run() { echo "=== [$(date +%T)] START $1"; "${@:2}"; echo "=== [$(date +%T)] END $1 (rc $?)"; }

echo "############ TB_EFFORT=low  12 tasks  $(date +%F' '%T) ############"

run dsh "$TB" run "${COMMON[@]}" --agent-import-path dsh_agent:DshAgent --run-id low12-dsh

run pi "$TB" run "${COMMON[@]}" --agent-import-path pi_agent:PiAgent --run-id low12-pi

# Claude Code needs the Anthropic->OpenAI bridge; cc_agent picks the `-low` alias.
bridge_up || { nohup litellm --config litellm-bridge.yaml --host 0.0.0.0 --port 4001 \
     > litellm-bridge.log 2>&1 & echo $! > litellm-bridge.pid; sleep 12; }
bridge_up || { echo "!!! bridge failed to come up; cc will fail"; }
run cc "$TB" run "${COMMON[@]}" --agent-import-path cc_agent:CCBridgeAgent --run-id low12-cc

echo "############ LOW12 DONE $(date +%F' '%T) ############"
