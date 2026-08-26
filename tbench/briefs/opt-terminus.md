# Optimization: terminus (biggest recoverable gain)

Baseline: terminus scored 3/12 on the comparison subset; **7 of 12 were
`unknown_agent_error`**, not capability failures. Three tasks pi and dsh BOTH solved but
terminus lost to agent errors: csv-to-parquet, simple-sheets-put, sqlite-db-truncate.
Recover them. Read tbench/REPORT.md for the full matrix, and CONTEXT.md for rules.

The baseline results are in `runs/cmp-terminus/` — read the failing trials'
`agent-logs/episode-*/debug.json` to see the exact error (likely still command-batch
parse failures on the smaller model's freeform output, or response_format leaking).

Levers to try (pick what the logs justify, measure, keep what wins):
- `--agent terminus-2` (stock, no import path) — it prompts for plain JSON and parses
  with its own tolerant parser; may sidestep the errors terminus-1 hits. Cap episodes:
  `-k max_episodes=50`.
- Harden `terminus_fix.py`'s parsing (fenced ```json blocks, leading prose, trailing
  reasoning_content) if terminus-1 is the better base.
- Consider a lower effort if xhigh's long reasoning_content is what breaks parsing —
  but keep effort constant if you can, to stay comparable. Note any effort change.

The 12-task subset (identical list, do not change it):
hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow pytorch-model-cli.hard
sanitize-git-repo fix-git openssl-selfsigned-cert sqlite-db-truncate fibonacci-server
write-compressor nginx-request-logging

Steps:
1. Diagnose the 7 errors from the baseline logs.
2. Iterate on hello-world + csv-to-parquet + sqlite-db-truncate (`-t` each) with run-ids
   `opt-terminus-N` until those parse-failures resolve.
3. Final full-subset run, run-id `cmp-terminus-opt`, SAME flags as the baseline
   (`--dataset terminal-bench-core==0.1.1`, all 12 `-t`, `--n-concurrent 2`,
   `--global-agent-timeout-sec 500 --no-cleanup --output-path .../runs`,
   env `OPENAI_API_KEY=sk-qwen5090-local OPENAI_API_BASE=http://<5090-ip>:8000/v1 OPENAI_BASE_URL=(same)`).
4. Report: baseline 3/12 → your new X/12, what changed, exact final invocation, and which
   of the 3 target tasks you recovered. Files you own: terminus_fix.py, briefs/opt-terminus-notes.md.
   Do NOT touch other harnesses' files or run-ids.
