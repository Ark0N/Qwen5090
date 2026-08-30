# Which coding agent is best on your 5090?

The model is only half of a coding agent. The other half is the **harness**: the
program that turns the model into an agent, deciding how it sees the terminal,
how its tool calls are parsed, when a turn ends, and how its output is shaped.
The same model can score very differently depending on which harness drives it.

So we measured it. Four harnesses, one model (Qwen3.8-27B NVFP4 on a single
5090), the same tasks, the same reasoning effort. Only the harness changes.

**Short answer: run the [DeepSeek Harness](DEEPSEEK-HARNESS.md) at `medium`
reasoning effort.** It is the only configuration in the study that solves
everything this model can solve — 8/12, where every other agent tops out at
7/12 — and it is cheaper than running it at maximum effort. Take
[Claude Code](CLAUDE-CODE.md) instead if you would rather use the client you
already know: it ties at 7/12, but it wants `xhigh` and the bridge in the
middle. The details, and the honest caveats, are below.

## The test

- **Model**: Qwen3.8-27B NVFP4 (the 4-bit quant this project ships), served by
  the NInfer backend, effort `xhigh`, identical for every harness.
- **Benchmark**: [Terminal-Bench](https://www.tbench.ai/) `terminal-bench-core==0.1.1`.
  Each task is a real job in a fresh Docker container (write a script, fix a git
  repo, stand up a server, convert data) graded by a hidden test suite.
- **Task set**: a fixed 12-task subset sized for this hardware. The full 80-task
  set includes multi-hour kernel builds, VM boots and interactive games that a
  one-shot local agent cannot clear on any harness; those measure patience, not
  capability, so they are excluded. The 12 span file operations, data processing,
  web, security, git and coding.
- **The four harnesses**:
  | harness | what it is | how it reaches the model |
  |---|---|---|
  | **[DeepSeek Harness (dsh)](DEEPSEEK-HARNESS.md)** | DeepSeek's open agent runtime, headless minimal preset | native OpenAI, no bridge |
  | **[pi](https://github.com/earendil-works/pi-coding-agent)** | the pi coding agent | native OpenAI, no bridge |
  | **[Claude Code](CLAUDE-CODE.md)** | Anthropic's CLI | through the LiteLLM Anthropic to OpenAI bridge |
  | **terminus** | Terminal-Bench's own reference agent | drives the container from outside via LiteLLM |

## Results

Two numbers per harness: **out of the box**, and **after one round of tuning**
each harness's own bottleneck.

| harness | out of the box | after tuning |
|---|:---:|:---:|
| **pi** | **7 / 12** | **7 / 12** |
| **DeepSeek Harness** | 6 / 12 | **7 / 12** |
| **Claude Code** | 4 / 12 | **7 / 12** |
| **terminus** | 3 / 12 | 6 / 12 |

### Per-task, after tuning

| task | dsh | pi | Claude Code | terminus |
|---|:---:|:---:|:---:|:---:|
| hello-world | PASS | PASS | PASS | PASS |
| csv-to-parquet | PASS | PASS | PASS | fail |
| simple-sheets-put | PASS | PASS | PASS | PASS |
| tmux-advanced-workflow | PASS | PASS | PASS | PASS |
| fix-git | PASS | PASS | PASS | PASS |
| sqlite-db-truncate | PASS | PASS | PASS | err |
| fibonacci-server | PASS | PASS | fail | PASS |
| openssl-selfsigned-cert | fail | fail | PASS | PASS |
| pytorch-model-cli.hard † | err | fail | err | fail |
| sanitize-git-repo | fail | fail | fail | fail |
| write-compressor | fail | fail | fail | fail |
| nginx-request-logging | fail | fail | fail | fail |
| **total** | **7** | **7** | **7** | **6** |

† `err` here is **not measured**, not failed: the trial errored while its result
was being parsed. At `low` effort this task is solved cleanly — all 6 subtests —
by both the DeepSeek Harness and Claude Code. See the correction below.

## What it means

**The three-way tie is real, but the harnesses are not interchangeable.** All of
this is at `xhigh`; the effort sweep further down changes the ranking.

- **pi is the efficient winner at this effort.** It reached 7/12 with no tuning
  at all and the lightest setup. At lower efforts it falls behind — see the
  sweep.
- **The DeepSeek Harness is the most robust.** Cleanest failures, real
  end-of-turn signals, native OpenAI so no bridge to babysit. Our recommended
  default for serious use.
- **Claude Code matches on accuracy** and is the client many people already know,
  but it does the most reasoning per task, so it wants the most time and the
  bridge in the middle.
- **terminus is the lightest to run** (nothing installed in the container) but the
  most fragile at parsing a smaller model's output.

**The most important finding: almost every failure was fixable plumbing, not the
model.** Out of the box the field ranged from 3 to 7; after tuning, from 6 to 7.
What we changed, per harness:

- **DeepSeek Harness** killed its own background server at the end of a turn (it
  signals the whole process group), so a task that starts a web server saw
  "connection refused" at test time even though the agent's answer was correct.
  Fix: launch background servers with `setsid`.
- **Claude Code** was not slowed by the bridge (measured at ~0.15 s per call,
  zero retries). Two "timeouts" were really its own 16k output-token cap tripping
  on long reasoning, and one was the model narrating its next step without
  actually making a tool call. Fix: raise the cap, and a short "keep going until
  it is verified" instruction.
- **terminus** mis-parsed the model's freeform command batches. Fix: tolerant
  JSON parsing.
- **pi** hit one flaky download during install. Fix: a retry.

## The honest ceiling

**The model, not the harness, sets the real limit, and it is at least 9 out of
12.** Three tasks fail on every harness at every effort measured —
`sanitize-git-repo`, `write-compressor` and `nginx-request-logging`. These need
multi-step correctness the 4-bit 27B model does not reach here, and no amount of
harness tuning moves them.

> **Corrected 2026-08-30.** This section used to say the ceiling was 8/12 and
> name a fourth task, `pytorch-model-cli.hard`, as unreachable. It is not: at
> `low` effort both the DeepSeek Harness and Claude Code solve it, 6 subtests
> out of 6. It was never actually *measured* at `xhigh` — the trial recorded
> `is_resolved: null` with a parse error, and the scoring recipe counted `null`
> the same as `false`, so missing data became a capability limit. **When scoring
> a run of your own, count `null` separately from `false`.**

At `xhigh` effort the best single harness tops out at 7/12. But that is not the
end of the story: see the effort sweep below.

## The effort sweep: xhigh is the wrong default

Everything above ran at maximum reasoning effort (`xhigh`). When we swept `low`
and `medium` too, the biggest surprise of the whole study appeared: **the best
reasoning effort is different for each agent.**

| agent | low | medium | xhigh | wants |
|---|:---:|:---:|:---:|---|
| **DeepSeek Harness** | 7/8 | **8/8** | 7/8 | anything (medium best) |
| **terminus** | **7/8** | 4/8 | 6/8 | **low** |
| **pi** | 4/8 | 6/8 | **7/8** | high |
| **Claude Code** | 4/8 | 3/8 | **7/8** | high |

(Scored on the 8 tasks believed solvable when the sweep was run. One of the
four excluded, `pytorch-model-cli.hard`, turned out to be solvable after all —
see the correction above.)

- **The DeepSeek Harness at `medium` scores 8/8 on these, i.e. 8/12 overall.**
  That is the best single result in the entire study, from one agent at one
  effort, and it is cheaper than xhigh. It even recovers a task it *failed* at
  xhigh, because too much reasoning was making its answer worse. **This is the
  configuration to use.** (It also reaches 8/12 at `low`, by a different route —
  see the low-effort run below.)
- **terminus is a low-effort agent.** Its trouble at xhigh was the model's long
  reasoning overrunning its output budget and breaking its parser; at low effort it
  jumps to 7/8. Turning the effort *down* is what fixes it.
- **Claude Code and pi want the reasoning.** Claude Code drops to 3/8 at medium,
  and every one of those is a plain wrong answer, not a crash: genuine under-thinking.

So a single agent reaches **8/12** by itself — you do not need to run several,
which is what the xhigh-only numbers had suggested. The union of what *some*
harness solves is 9/12.

Three caveats, stated plainly:

- These are on the **4-bit NVFP4 quant** this project ships, not the
  full-precision model in the [official benchmark table](../../README.md#how-good-is-it).
  Treat the model card's Terminal-Bench 2.1 score (73.0) as the ceiling; the
  quant on a curated subset is a different, tougher measurement.
- Under sustained `xhigh` load the serve became a bottleneck of its own. `xhigh`
  generates a lot of reasoning tokens; testing a lower effort (`medium`) is the
  next optimization, and would most help Claude Code, which reasons the most.
- **Run-to-run noise on this suite is roughly ±1–2 tasks.** Re-running the
  identical configuration later, pi scored 2 tasks better and Claude Code 1
  better than the sweep recorded. Read a one-task gap between two harnesses as
  noise, not as a result.

## The same effort on all 12 tasks (2026-08-30)

The sweep above scored `low` on those 8 tasks only. Re-run across the
full 12 — same denominator as the headline table — for the three harnesses
still in use:

| harness | 12-task at `low` | wall time |
|---|:---:|---|
| **DeepSeek Harness** | **8/12** | 20m43s |
| **pi** | 6/12 | 16m24s |
| **Claude Code** | 6/12 | 35m26s |

The DeepSeek Harness matches its medium-effort 8/12 here, over a slightly
different set of tasks, in a third of Claude Code's wall time. That result
includes one re-run: `hello-world` failed on a broken apt index inside a single
container, which is a flake rather than a capability result.

## Reproduce it

Everything is in [`tbench/`](../../tbench/): the four harness adapters, the
container setup scripts, the comparison driver, the raw per-task results, and the
[full technical write-up](../../tbench/REPORT.md). Start with
[`tbench/README.md`](../../tbench/README.md).

---

[← Back to the README](../../README.md) ·
[Claude Code](CLAUDE-CODE.md) ·
[DeepSeek Harness](DEEPSEEK-HARNESS.md)
