# Handoff: the harness benchmark project

What this directory is, what was found, and how to pick it back up. The full
analysis is in [`REPORT.md`](REPORT.md); the reproduction guide is
[`README.md`](README.md); the product-facing writeup is
[`../app/docs/HARNESS-BENCHMARKS.md`](../app/docs/HARNESS-BENCHMARKS.md).

## What was done

Benchmarked four coding-agent **harnesses** on [Terminal-Bench](https://www.tbench.ai/)
(`terminal-bench-core==0.1.1`), all driving the same local model (Qwen3.8-27B NVFP4 on
the NInfer serve), so the only variable is the harness. Three phases:

1. **Build** — wrote a Terminal-Bench adapter for each harness (dsh, pi, Claude Code via
   a LiteLLM bridge, terminus), each smoke-verified on `hello-world`.
2. **Compare + optimize** — ran all four on a fixed 12-task subset, then fixed each
   harness's own bottleneck and re-ran. Result: dsh / pi / Claude Code tie at 7/12,
   terminus 6/12 (up from a 7/6/4/3 baseline).
3. **Effort sweep** — swept `low` / `medium` / `xhigh` across all four on the 8 solvable
   tasks.

## The findings that matter

- **Best single configuration: DeepSeek Harness at `medium` effort = 8/8 solvable
  (8/12 overall)** — the full model ceiling, from one harness at one effort, cheaper
  than xhigh.
- **The best reasoning effort differs per harness**: dsh flat (medium best), terminus
  INVERTED (low best, 7/8), pi and Claude Code want high. `xhigh` is a bad universal
  default.
- **Almost every harness loss was fixable plumbing, not the model**: dsh killed its own
  background servers at turn end (process-group signal → use `setsid`); Claude Code hit
  its output-token cap and narrated without tool calls; terminus mis-parsed long
  reasoning output; and `reasoning_effort` was **silently dropped** for both
  LiteLLM-routed harnesses (fixed with `allowed_openai_params`).
- **The model, not the harness, sets the real ceiling**: 4 of the 12 tasks fail on every
  harness at every effort.

## Current state (as of teardown)

- All results committed and pushed to `Ark0N/Qwen5090` `main`. Git is clean.
- The 3 Codeman worker sessions used to build this (one per harness lane) are **deleted**.
- The LiteLLM bridge (Claude Code's Anthropic→OpenAI translator) is **stopped**.
- The model serve (`http://<5090-ip>:8000`, the gaming PC / `<hostname>`) was
  up at teardown; it can sleep. Wake it with `wakeonlan <mac-address>` from a machine
  on its LAN (`~/wol/info`).

## Files

| | |
|---|---|
| adapters | `dsh_agent.py`, `pi_agent.py`, `cc_agent.py`+`cc_hooks.py`+`litellm-bridge.yaml`, `terminus_fix.py` |
| container setup | `*-setup.sh.j2` |
| drivers | `compare.sh` (the 12-task comparison), `sweep.sh` (the effort sweep) |
| results | `runs/cmp-*` (comparison + optimization), `runs/sweep-*` (effort sweep). `results.json`/`run_metadata.json` are tracked; casts/logs/knob-smokes gitignored |
| notes | `briefs/` (per-lane worker notes and the task briefs) |

## To resume

- **Rerun a config**: see `README.md`. Each adapter reads `TB_EFFORT` (low/medium/xhigh,
  default xhigh); Claude Code needs the bridge started first (`sweep.sh` starts it).
- **Not-yet-run levers** (from `REPORT.md`): a cross-harness ensemble (already achievable
  by dsh-medium alone, so lower priority now); `n_attempts>1` on the 4 model-ceiling
  tasks; extending the subset toward the full 80-task set on faster hardware.
- **Prereqs**: Docker running, `tb` on PATH (`uv tool install terminal-bench`), the model
  serve reachable at the base URL baked into the adapters.
