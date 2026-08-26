#!/bin/bash
# Head-to-head: all four harnesses on ONE fixed simple task subset, same model,
# same effort (xhigh), same caps. Sequential (GPU is shared). Each harness gets
# its own run-id under runs/. Reuses no partial data — every harness runs the
# identical list from scratch for a clean comparison.
set -u
cd <repo>/tbench || exit 1
export PYTHONPATH=<repo>/tbench
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
TB=~/.local/bin/tb
OUT=<repo>/tbench/runs

# 12 simple tasks: all 360s budget, category spread, mix of dsh-tractable and
# dsh-hard so the comparison has discriminating signal.
TASKS=(hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow \
       pytorch-model-cli.hard sanitize-git-repo fix-git openssl-selfsigned-cert \
       sqlite-db-truncate fibonacci-server write-compressor nginx-request-logging)
TARGS=(); for t in "${TASKS[@]}"; do TARGS+=(-t "$t"); done

COMMON=(--dataset terminal-bench-core==0.1.1 "${TARGS[@]}" --n-concurrent 2 \
        --global-agent-timeout-sec 500 --no-cleanup --output-path "$OUT")

run() { echo "=== [$(date +%T)] START $1"; "${@:2}"; echo "=== [$(date +%T)] END $1 (rc $?)"; }

# 1) dsh
run dsh "$TB" run "${COMMON[@]}" --agent-import-path dsh_agent:DshAgent --run-id cmp-dsh

# 2) terminus (needs OPENAI_* in env)
OPENAI_API_KEY=sk-qwen5090-local OPENAI_API_BASE=http://<5090-ip>:8000/v1 \
OPENAI_BASE_URL=http://<5090-ip>:8000/v1 \
run terminus "$TB" run "${COMMON[@]}" --agent-import-path terminus_fix:TerminusQwen \
    --model openai/qwen3.8-27b --run-id cmp-terminus

# 3) pi
run pi "$TB" run "${COMMON[@]}" --agent-import-path pi_agent:PiAgent --run-id cmp-pi

# 4) claude-code via bridge (ensure bridge up first)
curl -s --max-time 5 http://127.0.0.1:4001/health/liveliness >/dev/null 2>&1 || \
  { nohup litellm --config litellm-bridge.yaml --host 0.0.0.0 --port 4001 \
      > litellm-bridge.log 2>&1 & echo $! > litellm-bridge.pid; sleep 12; }
run cc "$TB" run "${COMMON[@]}" --agent-import-path cc_agent:CCBridgeAgent --run-id cmp-cc

echo "=== ALL DONE $(date +%T)"
