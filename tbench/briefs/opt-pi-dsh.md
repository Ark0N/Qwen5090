# Optimization: pi (harden) + dsh (recover fibonacci-server)

You own BOTH pi and dsh here (they need the least work). Read tbench/REPORT.md and
CONTEXT.md first.

Baseline: pi 7/12 (already at the 7-task frontier — the union of everything any harness
solved), dsh 6/12. The 12-task subset is fixed (do not change it):
hello-world csv-to-parquet simple-sheets-put tmux-advanced-workflow pytorch-model-cli.hard
sanitize-git-repo fix-git openssl-selfsigned-cert sqlite-db-truncate fibonacci-server
write-compressor nginx-request-logging

## dsh (main job): recover fibonacci-server
dsh is the ONLY solvable-task miss: fibonacci-server PASSES on pi but dsh failed it
(failure_mode `unset` = wrong answer, not a timeout). Read `runs/cmp-dsh/fibonacci-server/*/`
(agent.log + the test log) to see why dsh's answer failed the tests. Try a targeted fix
(the dsh minimal preset may need a tool the task wants, or the model needed the workspace
instruction hint). Iterate on `-t fibonacci-server` with run-ids `opt-dsh-N`. Do NOT
regress the 6 dsh already passes.

## pi (secondary): robustness only
pi is already at the frontier; do not chase the 4 model-ceiling tasks. Just investigate
its 1 `agent_installation_failed` in `runs/cmp-pi/` — if it's a flaky npm/nvm step,
harden pi-setup.sh.j2 (retry/pin) so a real full run doesn't lose a task to install noise.

## Final runs (same flags as baseline: 12 `-t`, conc 2, 500s cap, --no-cleanup, output .../runs)
- dsh: run-id `cmp-dsh-opt`  (`--agent-import-path dsh_agent:DshAgent`)
- pi:  run-id `cmp-pi-opt`   (`--agent-import-path pi_agent:PiAgent`)

Report: dsh 6/12 → X/12 (did fibonacci recover?), pi 7/12 → Y/12, what changed for each,
both final invocations. Files you own: dsh_agent.py, dsh-setup.sh.j2, pi_agent.py,
pi-setup.sh.j2, ~/.pi/agent/models.json, briefs/opt-pi-dsh-notes.md. Do NOT touch
terminus/cc files.
