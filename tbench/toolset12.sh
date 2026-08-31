#!/bin/bash
# Tool-set A/B for the DeepSeek Harness TUI on the 12-task comparison subset:
# the shipped `standard` preset (the 16-row composition a real TUI user gets,
# ~25 tools) against `minimal` (bash + str_replace_editor, the published
# benchmark composition). Both at medium effort with the `tuned` persona
# (structured rules + budget awareness, dsh_agent.py PERSONAS), driven through
# dsh_tui_agent.py so the casts show the model working. Sequential, conc 2,
# 900 s agent timeout - the GPU is shared with the user's live sessions.
# Run-ids: toolset12-tui-<preset>.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
export PYTHONPATH="$PWD"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
TB=~/.local/bin/tb
OUT="$PWD/runs"

QWEN_URL="${QWEN_URL:-http://localhost:8000}"
export QWEN_URL QWEN_API_BASE="$QWEN_URL/v1"
export TB_EFFORT=medium TB_DSH_PERSONA="${TB_DSH_PERSONA:-tuned}"

TASKS=(hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow \
       pytorch-model-cli.hard sanitize-git-repo fix-git openssl-selfsigned-cert \
       sqlite-db-truncate fibonacci-server write-compressor nginx-request-logging)
TARGS=(); for t in "${TASKS[@]}"; do TARGS+=(-t "$t"); done
COMMON=(--dataset terminal-bench-core==0.1.1 "${TARGS[@]}" --n-concurrent 2 \
        --global-agent-timeout-sec 900 --no-cleanup --output-path "$OUT")

run() { echo "=== [$(date +%T)] START $1"; "${@:2}"; echo "=== [$(date +%T)] END $1 (rc $?)"; }

echo "############ TOOLSET12 medium persona=$TB_DSH_PERSONA 12 tasks  $(date +%F' '%T)  serve=$QWEN_URL ############"
for PRESET in ${PRESETS:-standard minimal}; do
  export TB_DSH_TUI_PRESET="$PRESET"
  run "tui/$PRESET" "$TB" run "${COMMON[@]}" --agent-import-path dsh_tui_agent:DshTuiAgent \
      --run-id "toolset12-tui-$PRESET"
done
echo "############ TOOLSET12 DONE $(date +%F' '%T) ############"
