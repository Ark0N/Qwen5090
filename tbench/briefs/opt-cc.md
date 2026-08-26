# Optimization: claude-code-via-bridge (recover timeouts)

Baseline: cc scored 4/12. Its harness-attributable losses are `agent_timeout` (3 total):
fix-git and sqlite-db-truncate both PASS on pi/dsh but cc ran out the 500s clock —
every LLM call crosses your LiteLLM Anthropic→OpenAI bridge, adding latency. Recover
those two. Read tbench/REPORT.md for the matrix and CONTEXT.md for rules.

First confirm the bridge is alive: `curl -s http://127.0.0.1:4001/health/liveliness`.
If not, restart FROM the tbench dir (config + cc_hooks import are relative):
`nohup litellm --config litellm-bridge.yaml --host 0.0.0.0 --port 4001 > litellm-bridge.log 2>&1 & echo $! > litellm-bridge.pid`.

Levers (measure, keep what wins):
- Raise the per-task agent cap: `--global-agent-timeout-sec 900` (the tasks are 360s
  natively; the timeouts are bridge overhead, so more wall budget should let them finish).
- Cut bridge round-trip cost: check `litellm-bridge.log` for slow/retried calls; try
  `litellm_params: {stream: true}` off/on, disable extra callbacks if `cc_hooks` adds
  latency it doesn't need for these tasks, confirm no per-call cold path.
- Investigate the fix-git failure in `runs/cmp-cc/fix-git/*/` — confirm it's a timeout,
  not a wrong answer, before assuming more time fixes it.

12-task subset (identical, unchanged):
hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow pytorch-model-cli.hard
sanitize-git-repo fix-git openssl-selfsigned-cert sqlite-db-truncate fibonacci-server
write-compressor nginx-request-logging

Steps:
1. Diagnose the 3 agent_timeouts from baseline logs (confirm timeout vs wrong answer).
2. Iterate on fix-git + sqlite-db-truncate (`-t` each), run-ids `opt-cc-N`, with a raised
   timeout and any bridge tuning, until they pass.
3. Final full-subset run, run-id `cmp-cc-opt`, same 12 `-t`, `--n-concurrent 2`,
   `--no-cleanup`, `--output-path .../runs`, and RECORD the `--global-agent-timeout-sec`
   you used (note it changed from the 500s baseline — that's a legitimate harness tuning,
   just report it).
4. Report: baseline 4/12 → new X/12, what you changed, final invocation, which tasks
   recovered. Files you own: cc_agent.py, cc_hooks.py, litellm-bridge.yaml, the bridge
   log/pid, briefs/opt-cc-notes.md. Leave the bridge running.
