#!/bin/bash
# Persona A/B for the DeepSeek Harness at medium effort on the 12-task
# comparison subset: the published container persona (`baseline`) against the
# same persona plus the self-optimization loop's six "structured" rules
# (`structured`, see dsh_agent.py PERSONAS). Both arms run at medium because
# that is dsh's measured optimum (REPORT.md effort sweep), and neither arm
# has been measured on the full 12 at medium before - so the baseline arm is
# new data too, not just a control.
#
# Sequential, same flags as low12.sh (conc 2, 900s agent timeout): the GPU is
# shared with the user's live sessions. Run-ids: persona12-dsh-<persona>.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
export PYTHONPATH="$PWD"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
TB=~/.local/bin/tb
OUT="$PWD/runs"

QWEN_URL="${QWEN_URL:-http://localhost:8000}"
export QWEN_API_BASE="$QWEN_URL/v1"
export TB_EFFORT=medium

TASKS=(hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow \
       pytorch-model-cli.hard sanitize-git-repo fix-git openssl-selfsigned-cert \
       sqlite-db-truncate fibonacci-server write-compressor nginx-request-logging)
TARGS=(); for t in "${TASKS[@]}"; do TARGS+=(-t "$t"); done
COMMON=(--dataset terminal-bench-core==0.1.1 "${TARGS[@]}" --n-concurrent 2 \
        --global-agent-timeout-sec 900 --no-cleanup --output-path "$OUT")

run() { echo "=== [$(date +%T)] START $1"; "${@:2}"; echo "=== [$(date +%T)] END $1 (rc $?)"; }

echo "############ PERSONA12 medium 12 tasks  $(date +%F' '%T)  serve=$QWEN_URL ############"
for PERSONA in ${PERSONAS:-baseline structured}; do
  export TB_DSH_PERSONA="$PERSONA"
  run "dsh/$PERSONA" "$TB" run "${COMMON[@]}" --agent-import-path dsh_agent:DshAgent \
      --run-id "persona12-dsh-$PERSONA"
done
echo "############ PERSONA12 DONE $(date +%F' '%T) ############"
