# Which coding agent is best on your 5090?

The model is only half of a coding agent. The other half is the **harness**: the
program that turns the model into an agent, deciding how it sees the terminal,
how its tool calls are parsed, when a turn ends, and how its output is shaped.
The same model can score very differently depending on which harness drives it.

So we measured it. Four harnesses, one model (Qwen3.8-27B NVFP4 on a single
5090), the same tasks, the same reasoning effort. Only the harness changes.

**Short answer: pick [pi](DEEPSEEK-HARNESS.md) or the DeepSeek Harness for the
best out-of-the-box result, and Claude Code if you want the client you already
know.** After a round of tuning, three of the four tie for the lead. The details,
and the honest caveats, are below.

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
| pytorch-model-cli.hard | err | fail | err | fail |
| sanitize-git-repo | fail | fail | fail | fail |
| write-compressor | fail | fail | fail | fail |
| nginx-request-logging | fail | fail | fail | fail |
| **total** | **7** | **7** | **7** | **6** |

## What it means

**The three-way tie is real, but the harnesses are not interchangeable:**

- **pi is the efficient winner.** It reached 7/12 with no tuning at all and the
  lightest setup. If you want the best result for the least fuss, this is it.
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

**The model, not the harness, sets the real limit, and it is 8 out of 12.** Four
tasks fail on every harness (`sanitize-git-repo`, `write-compressor`,
`nginx-request-logging`, `pytorch-model-cli.hard`): these need multi-step
correctness that the 4-bit 27B model does not reach here. No amount of harness
tuning moves them.

The best single harness tops out at 7/12 because the 8th solvable task is split:
`openssl-selfsigned-cert` is solved only by terminus and Claude Code, while
`fibonacci-server` is solved only by the others. So **the best result available
on this model is 8/12, reachable by running more than one harness and taking the
best answer** (an ensemble), not by any single agent.

Two caveats, stated plainly:

- These are on the **4-bit NVFP4 quant** this project ships, not the
  full-precision model in the [official benchmark table](../../README.md#how-good-is-it).
  Treat the model card's Terminal-Bench 2.1 score (73.0) as the ceiling; the
  quant on a curated subset is a different, tougher measurement.
- Under sustained `xhigh` load the serve became a bottleneck of its own. `xhigh`
  generates a lot of reasoning tokens; testing a lower effort (`medium`) is the
  next optimization, and would most help Claude Code, which reasons the most.

## Reproduce it

Everything is in [`tbench/`](../../tbench/): the four harness adapters, the
container setup scripts, the comparison driver, the raw per-task results, and the
[full technical write-up](../../tbench/REPORT.md). Start with
[`tbench/README.md`](../../tbench/README.md).

---

[← Back to the README](../../README.md) ·
[Claude Code](CLAUDE-CODE.md) ·
[DeepSeek Harness](DEEPSEEK-HARNESS.md)
