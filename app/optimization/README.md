# Self-optimization loop — Qwen5090 (dsh harness + NInfer server)

Autonomous search over **harness** and **serving** configurations, scored by a
local terminal-bench-style task suite. Runs continuously; the "winner" is
promoted to the live server and to the dsh harness settings.

## What is being optimized

| Layer | Knob | Where it lands |
|---|---|---|
| Harness | persona / system prompt (`minimal`, `tb`, `structured`) | benchmark agent (mirrors the dsh minimal-preset surface) |
| Harness | `reasoning_effort` (`none`/`low`/`medium`/`xhigh`) | dsh `settings.yaml` → `agent-default-model.reasoningEffort` (promoted) |
| Harness | max_tokens / max_iterations per turn | benchmark agent defaults |
| Harness | provider `retryPolicy` (10 retries, ≤30 s backoff) | dsh `settings.yaml` → `qwen5090` route (one-shot, done) |
| Server | MTP `--draft-tokens` 3/4/5 | live `ninfer-serve` flags |
| Server | `--prefill-chunk` 1024/4096 | live `ninfer-serve` flags |
| Server | `--max-concurrency` 2/4 | live `ninfer-serve` flags |
| Server | `--preserve-thinking`, sampler (`--temperature/--top-p`), KV precision probe | live `ninfer-serve` flags |

The model weights themselves are fixed (NVFP4 artifact); "optimizing the model"
here means its serving runtime (speculative decoding window, KV, batching,
sampling, thinking retention).

## Benchmark

16 offline, deterministic tasks in `tasks.py` (file transforms, bug fixing,
refactoring, git, sqlite, permissions, spec-driven scripting, multi-bug
debugging, URL normalization, Makefile writing, corrupted-JSONL recovery).
4 fast tasks form the screening subset; all 16 form the full run. Scoring:
passes first, then total tokens, then wall time. Each task runs in a fresh
sandbox (`results/<runid>/work/<task>/`) and is verified by a script
(`exit 0 == pass`).

**Every verifier is audited** by `validate_tasks.py` (16/16 sound): it builds
each sandbox, `bash -n` the verify script, compiles embedded Python, runs the
verify against a known-correct reference answer (must PASS), and — for the
tasks that start broken — checks the pristine state FAILS. Re-run it after any
edit to `tasks.py`.

**Suite changes invalidate scores.** `loop.py` fingerprints the task list
(`state.json: suite_fp`); when the suite changes, full-run scores from the old
suite are dropped so a 12-task and a 16-task run are never compared.

The agent (`tb_agent.py`) mirrors the repo's `tb_dsh_agent.py` minimal preset:
short persona + persistent `bash` + `str_replace_editor`, OpenAI function
calling, `reasoning_effort` passthrough, retry-with-backoff on server errors.

## The single-machine switch protocol

The dsh harness (the agent driving this whole thing), the benchmark agent and
the verifier all run on the ONE RTX 5090 and share the one model server on
:8000. The system therefore **time-slices**, coordinated by three layers, of
which none below the data plane needs the model:

| Layer | Keeps | Alive by |
|---|---|---|
| `watchdog.sh` (pure bash) | `loop.py` | PID file `.loop.pid`; restarts within ~35 s |
| `loop.py` (python) | the model server on :8000 | `serve_ctl.sh` + probe; auto-rollback |
| dsh `retryPolicy` on the `qwen5090` route | the harness (LLM turns, subagents) | 10 retries, ≤30 s backoff (~180 s budget) rides out a 30–60 s swap |

**`mode.json` is the contract.** The loop owns it; the harness (and anything
driven by the harness) reads it before heavy work:

- `harness` — server on best-known flags, probe passed → full-speed work OK
- `candidate-testing` — server on candidate flags → keep harness footprint
  minimal (short turns, no new long subagents; the candidate may run at a
  smaller context window and may be unstable)
- `recovering` — server down/unhealthy; the loop is repairing it

**Every server start is probed** (`probe_server`): a short deterministic
generation whose answer must come back almost exactly right. This catches a
dead server AND degenerate output (the MTP-garble mode: `391391...` or empty
content). `finish_reason=length` alone is not a failure — reasoning tokens
bill against `max_tokens`, so a correct short answer can arrive with
finish=length.

**Swaps are guarded both ways:** before the loop swaps it waits for a quiet
window (no recent harness session writes AND GPU < 10% over 24 s, deferring
up to 15 min); the harness side defers heavy work while the mode says
`candidate-testing`. A candidate that fails to start, or starts but fails the
probe, rolls back automatically to the best-known flags (retried until
healthy, mode `recovering` meanwhile). At the end of every round the loop
lands the server on the best-known flags and flips the mode back to
`harness`.

**Do not** use command-line pattern matching (`pgrep -f 'loop.py'`) to find
the loop — a shell whose own command text merely mentions `loop.py` fooled
the first watchdog version. Use the PID files.

## How a round works (`loop.py`)

1. **Phase A (harness):** screen up to 4 untried `(persona, effort)` combos on
   the 4-task subset; full-run (16 tasks) the top new combo and the incumbent
   harness. Promote the winning effort into dsh settings.
2. **Phase B (server):** screen up to 2 untried flag candidates on the subset,
   swapping the live server between them; full-run the best candidate and the
   incumbent server. Leave the server on the round's best flags.

**Server-swap safety.** The loop's own inference and this harness talk to the
same server on :8000. Before every swap the loop waits for a quiet window
(harness session file not written in the last 60 s AND six GPU utilization
samples under 10% over ~24 s), deferring up to 15 min and skipping the swap if
the machine stays busy. The dsh route also carries a 10-retry backoff policy
(~180 s budget) so an in-flight request typically rides a ~30–60 s restart.
A failed candidate start (e.g. KV OOM) restores the previous flags
automatically.

## Files

- `loop.py` — the loop brain; `python3 loop.py status` prints state + heartbeat
- `bench.py` — suite runner (`--tasks subset|all|ids`, `--cfg '<json>'`)
- `tb_agent.py` — the agent (also runnable standalone: `--task <id>`)
- `tasks.py` — the 16-task suite
- `validate_tasks.py` — verifier audit (run after editing `tasks.py`)
- `serve_ctl.sh` — `status|stop|start` for the :8000 server (reads `server.flags`)
- `server.flags` — flags the live server runs on (loop-managed)
- `server.flags.incumbent` — the pre-optimization flags (restore with
  `cp server.flags.incumbent server.flags && bash serve_ctl.sh stop && bash serve_ctl.sh start`)
- `state.json` — best configs, tried space, history
- `heartbeat.json` — liveness (mtime = last beat); `logs/loop.log` — trace
- `logs/rounds/NNNN.json` — per-round detail; `results/<runid>/` — per-run data
- `logs/server-requests.jsonl` — server request log (loop-managed runs add
  `--request-log-jsonl`; contains conversation payloads — delete if unwanted)

## Operations

```bash
cd /root/testapp/optimization
python3 loop.py status          # where is it?
tail -f logs/loop.log           # what is it doing?
cat mode.json                   # harness / candidate-testing / recovering
touch STOP                      # graceful stop (checked between steps)
rm STOP                         # (the watchdog restarts it within ~35 s)
```

**Supervision.** `watchdog.sh` (pure bash, pure-PID-file based) keeps
`loop.py` alive: it reads `.loop.pid`, verifies the pid is really
`loop.py`, and restarts it within ~35 s if it dies. `loop.py` in turn keeps
the model server alive. Both guard with PID files, never command-line
pattern matching. To start the whole stack after a reboot:

```bash
cd /root/testapp/optimization
setsid nohup bash watchdog.sh  >> logs/watchdog.out 2>&1 &   # supervisor
setsid nohup python3 loop.py  >> logs/loop.out      2>&1 &   # the loop
```

`loop.py` enforces single-instance with a `flock` on `.loop.lock` and refuses
to start a second full instance (status/mode subcommands are exempt and never
touch the pid file).

If the model server itself is down, the next loop round restores the
best-known flags and restarts it; `bash serve_ctl.sh start` works standalone.

## Measured server-side constraints (2026-08-25)

The 32 GB card at the 252,928-token int8-KV window is **VRAM-bound at
startup**. `ninfer-serve` refuses to start when the minimum Engine runtime
reservation + 1 GB headroom exceeds what is free after weights
(~10.49 GB available). Measured:

| config | reservation | result |
|---|---|---|
| base: conc 2, dt 3, pc 1024 | fits | starts |
| `--prefill-chunk 4096` (conc 2, dt 3) | 10.66 GB | **refused to start** |
| `--max-concurrency 4` (dt 3, pc 1024) | 10.89 GB | **refused to start** |

Configs that add draft slots on top of either only grow the reservation, so
the pc4096 composites and conc4-dt5 were pruned from the candidate grid
(measured, not predicted — the loop's rollback path handles a failed start
either way: stop → restore best-known flags → probe until healthy, mode
`recovering` meanwhile).

`dt4` / `dt5` (draft-tokens 4 / 5 at conc 2) **do** start and probe clean —
draft slots alone fit under the ceiling.

Failure diagnosis: the specific engine error line is logged by `serve_ctl.sh`
on start failure (it greps the per-start server log for the first
`[error]` line — the usage block otherwise buries it) and echoed by `loop.py`
(head of stderr). Per-start server logs: `logs/server-<ts>.log`.

## Honest caveats

- This suite is **not** official Terminal-Bench 2.1 (that path needs Docker +
  Harbor, which this VM does not have). It is a local proxy with the same
  shape (single-task agent + deterministic verifier), so *relative* improvements
  are meaningful; absolute scores are not comparable to the published 82.7.
- 4-task subset scores are noisy (0–4 passes); the loop therefore full-runs
  finalists before promoting.
- The harness knobs measured here live in this benchmark agent, which mirrors
  the dsh minimal preset. Only `reasoningEffort` is promotable into the real
  dsh settings (the persona is fixed by dsh presets).
- The request log contains payloads; see the privacy note above.