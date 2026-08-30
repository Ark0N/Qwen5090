#!/bin/bash
# Effort sweep: each harness at low + medium on the 8 SOLVABLE tasks (the 4
# model-ceiling tasks fail at any effort, so they add no signal and are skipped).
# xhigh is already measured in cmp-*-opt. Every adapter reads TB_EFFORT.
# Sequential (shared GPU). Run-ids: sweep-<harness>-<effort>.
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

TASKS=(hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow \
       fix-git sqlite-db-truncate fibonacci-server openssl-selfsigned-cert)
TARGS=(); for t in "${TASKS[@]}"; do TARGS+=(-t "$t"); done
COMMON=(--dataset terminal-bench-core==0.1.1 "${TARGS[@]}" --n-concurrent 2 \
        --global-agent-timeout-sec 900 --no-cleanup --output-path "$OUT")

bridge_up() { curl -s --max-time 5 http://127.0.0.1:4001/health/liveliness >/dev/null 2>&1; }

for EFFORT in medium low; do
  export TB_EFFORT="$EFFORT"
  echo "############ EFFORT=$EFFORT $(date +%T) ############"

  echo "=== dsh $EFFORT"; "$TB" run "${COMMON[@]}" --agent-import-path dsh_agent:DshAgent \
       --run-id "sweep-dsh-$EFFORT"

  echo "=== terminus $EFFORT"; OPENAI_API_KEY=sk-qwen5090-local \
    OPENAI_API_BASE="$QWEN_API_BASE" OPENAI_BASE_URL="$QWEN_API_BASE" \
    "$TB" run "${COMMON[@]}" --agent-import-path terminus_fix:TerminusQwen \
       --model openai/qwen3.8-27b --run-id "sweep-terminus-$EFFORT"

  echo "=== pi $EFFORT"; "$TB" run "${COMMON[@]}" --agent-import-path pi_agent:PiAgent \
       --run-id "sweep-pi-$EFFORT"

  echo "=== cc $EFFORT"; bridge_up || { nohup litellm --config litellm-bridge.yaml \
       --host 0.0.0.0 --port 4001 > litellm-bridge.log 2>&1 & echo $! > litellm-bridge.pid; sleep 12; }
  "$TB" run "${COMMON[@]}" --agent-import-path cc_agent:CCBridgeAgent --run-id "sweep-cc-$EFFORT"
done
echo "############ SWEEP DONE $(date +%T) ############"
