# The self-optimization loop

On 2026-08-25 the DeepSeek Harness ([dsh](DEEPSEEK-HARNESS.md), driven by
Qwen3.8-27B on this repo's own stack) was pointed at a copy of this repo and
asked to improve it. What it built is in **`app/optimization/`**: an autonomous
loop that tunes the *harness configuration* and the *NInfer serving flags* of
the very server that is answering it, scored by a benchmark suite it also
wrote. The model optimizes its own serving stack, on one GPU, while staying
available as an assistant.

`app/optimization/README.md` is the loop's own documentation (accurate to the
code); this file is the operator's view: results, findings, caveats, and where
it should go next.

## What it does

One round at a time, forever:

- **Phase A (harness):** screen untried (persona × reasoning-effort) combos on
  a 4-task subset, then full-run the finalists on the whole suite. The winning
  effort is promoted into the live dsh `settings.yaml`.
- **Phase B (server):** screen untried NInfer flag candidates (speculative
  draft length, prefill chunk, concurrency, sampler, KV precision,
  `--preserve-thinking`), swapping the **live** server between them, then
  full-run the best. The winner stays on the server.

Scoring is lexicographic: passes first, then total tokens, then wall time.

Because everything shares one RTX 5090, the loop is mostly a coordination
protocol wearing a benchmark: `mode.json` tells the harness when to tread
lightly (`candidate-testing`, `recovering`), every server start is probed with
a deterministic generation that catches the degenerate-output failure mode,
swaps wait for a quiet window (no recent session writes, GPU idle), a failed
candidate rolls back to best-known flags automatically, and a pure-bash
watchdog (PID files, deliberately not `pgrep -f`) restarts the loop itself.
The dsh route carries a 10-retry backoff (the loop's own first promotion) so
an in-flight harness request rides out a 30–60 s server swap.

## Running it

```bash
cd app/optimization              # on the machine with the GPU, next to the server
python3 loop.py status           # state + heartbeat
setsid nohup python3 loop.py >> logs/loop.out 2>&1 &   # start (Linux)
tail -f logs/loop.log            # watch
touch STOP                       # graceful stop; rm STOP before restarting
bash serve_ctl.sh start          # standalone server control if ever needed
cp server.flags.incumbent server.flags   # restore pre-optimization flags
```

On WSL, remember the client-exit rule from CLAUDE.md: start it under something
that stays alive (the dsh harness itself, a kept-open terminal, or a hidden
`wsl.exe` holder) — a bare backgrounded process dies with the `wsl.exe` that
spawned it. State, results and logs stay in the working copy
(`state.json`, `results/`, `logs/`), not in git.

## Results — 2026-08-25 03:20, round 10, 16-task suite

The suite began at 10 tasks and was grown by the loop to 16 (fingerprinted in
`state.json`, so pre-growth full runs are not directly comparable). All
percentages below are on the 16-task suite unless noted.

### Harness (persona × effort)

Screening (4-task subset) always passes 4/4, so subset wall time is a triage
signal only. Full runs are what count:

| combo | full | tokens | wall | note |
|---|---|---|---|---|
| **structured\|medium** | **15/16** | **168,033** | 195.8 s | promoted best |
| tb\|low | 15/16 | 317,403 | 275.7 s | same passes, ~1.9× tokens |
| minimal\|none | 7/8* | — | — | *10-task era, interrupted; failed `log-stats` on a regex-quoting bug |

The zero-thinking run's one failure is the interesting one: nine iterations
never spotted a quoting error that `low`-effort thinking caught immediately.
A little reasoning buys correctness on exactly the task class that breaks
no-reasoning; more reasoning than `medium` has not paid for itself here
(`minimal|xhigh` screened 18× slower than `minimal|none` with nothing to show
for it on this suite).

### Server (NInfer flags; incumbent = draft-tokens 3, prefill 1024, conc 2, int8 KV)

| candidate | full | tokens | wall | verdict |
|---|---|---|---|---|
| **`--preserve-thinking`** | **16/16** | 131,197 / 213,296 | 59.8 s / 138.4 s | **promoted** (two runs — note the noise) |
| dt4 (draft-tokens 4) | 16/16 | 206,856 | 77.8 s | held best for rounds 6–7 |
| incumbent (dt3) | 16/16 | 188,972 | 211.7 s | baseline |
| ctx98k + bf16 KV | 15/16 | 162,106 | 53.5 s | fast, but dropped a task — disqualified |
| dt5 | — | — | — | slow subset (63.7 s); full run was in flight at writing |
| temp 0.6 / top-p 0.95 | — | — | — | screened only |
| prefill-chunk 4096 | failed to start or probe — auto-rollback | | | |
| concurrency 4 | failed to start (KV reservation, as NINFER.md predicts) — auto-rollback | | | |

### Incidents it handled without help

- Degenerate output at a round start (`391391…`, then empty) — probe caught
  it, mode `recovering`, server restarted on known-good flags, round resumed.
- One hung screening run — watchdog restart, partial run discarded.
- Both impossible candidates (above) — clean rollback, noted in state, never
  retried.

## Honest caveats

- **This is not Terminal-Bench 2.1.** Same shape (single-task agent +
  deterministic verifier), locally invented tasks. Relative deltas are
  meaningful; absolute numbers are not comparable to published scores.
- **Wall time on a time-sliced GPU is very noisy.** The promoted winner's two
  full runs differ by 2.3× in wall and 1.6× in tokens on identical flags.
  Pass count is trustworthy; tokens mostly; wall the least.
- **The suite is self-expanded**, so a config chosen on it can overfit to what
  the model finds easy to verify. `validate_tasks.py` checks the verifiers,
  not the difficulty distribution.
- Results live in the WSL distro; snapshots are exported to
  `E:\Qwen5090\optimization-snapshots\` on the Windows host.

## Making it better

What the current design gets right: promotion only on full runs, probes on
every start, rollback as the default failure path, and state that records
*failed* candidates so they are never retried. The highest-value improvements,
roughly in order:

1. **Fix the measurement before adding knobs.** Score on pass count and
   completion tokens; demote wall time to a tie-breaker measured from server
   telemetry (decode tok/s) rather than end-to-end. Repeat finalists 3× and
   compare medians — `full_history` already exists, it just is not consulted.
   The preserve-thinking promotion is probably right, but on this evidence it
   could be noise.
2. **Promote on paired per-task deltas, not totals.** Same task, two configs,
   a sign test across tasks — noise-robust and cheap, and it flags per-task
   regressions a total hides.
3. **Gate full runs on screening.** dt5 screened 3–5× slower than everything
   and was still given a full run. Successive halving (screen many, full-run
   few, repeat only the leader) spends the same GPU-hours on ~3× more
   candidates.
4. **Make the subset discriminate.** 4/4 on every combo means the subset only
   measures speed. Put one task in it that `none`-effort reliably fails (the
   regex-quoting class) so screening carries a correctness signal too.
5. **Search the space that showed sensitivity.** Effort and draft-tokens moved
   the numbers; persona barely did once effort was fixed. Next knobs with
   likely payoff: adaptive effort (classify task difficulty, spend `medium`
   only when a first `none` pass fails — the round-1 failure is exactly this
   shape), the sampler pair the model card recommends (temp 0.7 / top-p 0.8),
   and dsh preamble size (the 25-tool roster costs prefill on every turn).
6. **Replay real work.** The request log (`--request-log-jsonl`) captures the
   harness's actual sessions. Replaying real turns against two flag sets is a
   better fitness signal than any invented suite, and it costs no new ideas —
   the data is already on disk.
7. **Hold out tasks.** Grow the suite in two halves: tune on one, confirm on
   the other, and rotate. Catches suite-overfitting for the price of a split.
8. **Watch promotions in production.** After promoting, compare the next N
   real sessions' iteration counts against the trailing baseline and
   auto-revert on regression — the last safety net, currently missing.
9. **Export state off the VM on a schedule.** A `wsl --unregister` (or the
   Cleanup button) erases every result. One rsync to `/mnt/e` per round is
   cheap insurance.
