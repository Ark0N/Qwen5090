# Handoff: the harness benchmark project

What this directory is, what was found, and how to pick it back up. The full
analysis is in [`REPORT.md`](REPORT.md); the reproduction guide is
[`README.md`](README.md); the product-facing writeup is
[`../app/docs/HARNESS-BENCHMARKS.md`](../app/docs/HARNESS-BENCHMARKS.md).

## Follow-up: single-harness tuning + a live eval (2026-08-30 → 31)

The three-phase study above settled on **dsh at `medium`**. Since then the work
narrowed to making that one harness as good as it gets, all measured on the same
12-task subset unless noted. New drivers: `persona12.sh`, `toolset12.sh`,
`low12.sh`. New adapter: `dsh_tui_agent.py` (drives the real TUI in the pane, so
the cast shows the model working; also copies dsh's session log into each
trial's `agent-logs/`, timed-out trials included).

- **Effort correction.** The "8/12 ceiling" was really the top of a **5–8
  range**: the identical dsh-medium config scored 8/12 one day and 5/12 five
  days later, so cross-date noise on this suite is ~±3 and `pytorch-model-cli`
  was never a ceiling task (a `null`/parse-error scored as a fail). Count `null`
  separately from `false`.
- **Persona.** The self-optimization loop's `structured` persona vs the
  published one: **7/12 vs 5/12** at medium, within noise — kept, not promoted
  above effort. A `tuned` persona adds budget awareness + `setsid -f`.
- **Tool set.** TUI `standard` (≈25 tools) vs `minimal` (2): **7/11 vs 6/11** —
  the "fewer tools for small models" idea does not show on this model; default
  stays `standard`.
- **`setsid` → `setsid -f`.** Under the persistent-bash tool a `cd dir && setsid
  … &` server is a descendant of the tool's shell and dies at session end;
  `-f` re-parents it to init. Fixed in both templates and the live preset.
- **`max-tokens`.** A step that spent pi-ai's 32768 output cap entirely on
  reasoning ended the turn with no action; the cap is now a route setting
  (65536, `TB_DSH_MAX_TOKENS`) and both runners continue on `max-tokens` (up to
  twice; headless drops to `low`).
- **Sampler.** Not a lever: dsh forwards only `temperature` and sets none, and
  NInfer's defaults already equal the model card's (`0.7/0.8/1.5`), proven with
  a fixed `seed`.
- **Live eval.** A fresh dsh worker passed a 6-test battery (server survival,
  exact transform, git fix, search, input validation, sanitize), a second
  Codeman session (Claude Code) reviewed it adversarially and found two edge
  defects (query-string routing, huge-int crash), the worker fixed both on
  feedback, and the two lessons were merged into the persona's API rule. See
  REPORT.md's last two sections.

New adapter knobs: `TB_DSH_PERSONA` (baseline|structured|tuned),
`TB_DSH_MAX_TOKENS`, `TB_DSH_TUI_PRESET` (standard|minimal).

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

- The original three-phase results were pushed to `Ark0N/Qwen5090` `main`.
  **The follow-up work above is committed but NOT pushed** (local `main` is ahead).
- The three build-phase worker sessions are deleted. The live-eval sessions
  (a dsh worker + a Claude reviewer) may still be idle on the box.
- The LiteLLM bridge (Claude Code's Anthropic→OpenAI translator) is **stopped**.
- The model serve (`http://<5090-ip>:8000`) was up at teardown; it can sleep.

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
