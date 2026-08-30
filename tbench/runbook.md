# Full-run runbook — harness comparison on the curated 64 tasks

All runs: same 64-task list (16 exclusions), same model (qwen3.8-27b @ `<5090-ip>:8000`),
effort xhigh everywhere, `--n-concurrent 2 --global-agent-timeout-sec 800 --no-cleanup`,
output `<repo>/tbench/runs`. Run SEQUENTIALLY (GPU is shared).
`cd <repo>/tbench` and `PYTHONPATH=$PWD` for every run.

EXCLUDES (identical for every run):
-e build-linux-kernel-qemu -e eval-mteb -e 'eval-mteb.hard' -e play-zork -e super-benchmark-upet \
-e conda-env-conflict-resolution -e run-pdp11-code -e swe-bench-astropy-1 -e swe-bench-astropy-2 -e swe-bench-fsspec \
-e blind-maze-explorer-5x5 -e blind-maze-explorer-algorithm -e 'blind-maze-explorer-algorithm.easy' -e 'blind-maze-explorer-algorithm.hard' \
-e qemu-startup -e qemu-alpine-ssh

1. dsh      — RUNNING as run-id `dsh-curated-2`:
   `--agent-import-path dsh_agent:DshAgent`
2. terminus — run-id `terminus-curated`:
   env `OPENAI_API_KEY=sk-qwen5090-local OPENAI_API_BASE=http://<5090-ip>:8000/v1 OPENAI_BASE_URL=http://<5090-ip>:8000/v1`
   `--agent-import-path terminus_fix:TerminusQwen --model openai/qwen3.8-27b`
3. pi       — run-id `pi-curated`:
   `--agent-import-path pi_agent:PiAgent`
4. cc       — run-id `cc-curated`:
   `--agent-import-path cc_agent:CCBridgeAgent`
   PRE-CHECK: bridge alive (`curl -s http://127.0.0.1:4001/health/liveliness`), else restart
   FROM the tbench dir: `nohup litellm --config litellm-bridge.yaml --host 0.0.0.0 --port 4001 > litellm-bridge.log 2>&1 & echo $! > litellm-bridge.pid`

Post-run scoring: accuracy from `<run>/results.json`; also collect per-task resolved
matrix + wall-clock + token counts for the report. `docker image prune` only after ALL
runs are done. Claude Code's `total_cost_usd` is fictional (Claude price sheet); ignore.
