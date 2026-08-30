# Harness benchmark project — shared context

Goal: compare agent harnesses (deepseek-harness/dsh, pi, claude-code, terminus) on
Terminal-Bench `terminal-bench-core==0.1.1`, all backed by the SAME local model.

- Project dir (your working area): `<repo>/tbench`
- Model serve: `http://<5090-ip>:8000/v1` (OpenAI-compatible, NInfer on an RTX 5090)
  - model id: `qwen3.8-27b` (must match exactly)
  - keyless; placeholder credential `sk-qwen5090-local` satisfies clients that demand one
- Terminal-Bench harness: `tb` CLI (installed via uv; on PATH at `~/.local/bin/tb`)
  - package source (read the agent APIs here):
    `~/.local/share/uv/tools/terminal-bench/lib/python3.12/site-packages/terminal_bench`
- Reference adapter that WORKS end to end: `tbench/dsh_agent.py` + `tbench/dsh-setup.sh.j2`
  (installed-agent pattern: setup script is SOURCED into the task's tmux session —
  restore $PWD at the end, it leaks; probe readiness at the end so failures surface
  as INSTALL_FAIL_STATUS).

## Hard rules
- A full 64-task dsh run is LIVE in `tbench/runs/dsh-curated-2/` — do not touch that
  directory, do not kill docker containers you did not start, do not launch full runs.
- Smoke-test ONLY: `--task-id hello-world --n-concurrent 1` with a UNIQUE `--run-id`
  (prefix it with your worker name), `--output-path <repo>/tbench/runs`.
- Run tb from the tbench dir with `PYTHONPATH=<repo>/tbench`.
- Touch ONLY the files your brief assigns you. Other files in tbench belong to other agents.
- Never write outside this tbench directory.
- hello-world resolved (`is_resolved: true` in the run's results.json) is your definition of done.

## Report format (your final message)
1. VERDICT: WORKING or BLOCKED (+ why)
2. The exact `tb run` invocation (and env) that produced the resolved smoke
3. Files you created/changed
4. Traps you hit (short bullets, for the report we will write later)
