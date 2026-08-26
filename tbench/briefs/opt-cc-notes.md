# cc optimization round — diagnosis and changes

## The brief's premise was wrong, and the baseline logs say so plainly

The brief (and REPORT.md) attribute cc's losses to LiteLLM bridge latency, and name
fix-git + sqlite-db-truncate as tasks that "ran out the 500s clock". Neither holds.

**Measured bridge overhead: ~0.1-0.2 s per call.** Same one-token prompt, ten runs:
direct to the serve 0.14-12.0 s (the serve's own variance dominates), through the bridge
0.24-0.27 s. Over the whole baseline run `litellm-bridge.log` shows **133 requests, all
200, zero retries, zero timeouts, no slow path**. The bridge is not the bottleneck and
there was nothing there to tune.

What actually killed each task (all four read straight out of `runs/cmp-cc/*/panes/`):

| task | tb failure_mode | what the pane says |
|---|---|---|
| sqlite-db-truncate | agent_timeout | `API Error: Claude's response exceeded the 16384 output token maximum` — 92,085 output tokens over 6 turns |
| write-compressor | agent_timeout | same error — 65,664 output tokens over **3** turns |
| sanitize-git-repo | agent_timeout | genuinely long: wrote its final report at ~559 s against a 500 s cap |
| nginx-request-logging | agent_installation_failed | `claude native binary not installed` — npm skipped the postinstall for the platform-native optional dep |
| fix-git | *unset* (NOT a timeout) | `terminal_reason: completed` after **36 s / 7 turns** |

So two of the three "agent_timeouts" were an **output-token cap I had set myself**
(`CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384` in cc_agent.py). Reasoning tokens bill against
max_tokens on this serve, and at `xhigh` a single turn routinely spends more than 16K on
thinking alone; Claude Code aborts the entire session when one response crosses the cap.
tb then records the dead session as an agent_timeout, which is what made it look like a
latency problem.

**fix-git was never a timeout.** The model wrote *"Let me resolve it by taking your
Stanford version of about.md"* as plain text with no tool call; the serve returned
`stop_reason: end_turn`; Claude Code ended the session 36 s in, mid-conflict. More wall
budget could not have helped — exactly the check the brief asked for before assuming it.

## Changes

1. **`cc_agent.py`: `CLAUDE_CODE_MAX_OUTPUT_TOKENS` 16384 -> 32000.** Removes the error
   that killed sqlite-db-truncate and write-compressor. 32000 is Claude Code's own default
   ceiling for this slot and sits under the deployment's `max_output_tokens: 32768`;
   verified `max_tokens: 32000` returns 200 through the bridge.
2. **`cc_agent.py`: `--append-system-prompt` continuation nudge.** Behavioural and
   task-agnostic — never end a turn to announce a next step, carry it out in the same turn;
   keep going until the work is verified; keep prose short. Aimed at the premature
   `end_turn` and at the runaway narration that overran the token cap.
3. **`cc-setup.sh.j2`: heal a half-installed CLI.** If `claude --version` fails after
   `npm install -g`, run `install.cjs` by hand, then reinstall once with
   `--force --include=optional`. The readiness probe stays, so a genuinely broken install
   still surfaces as INSTALL_FAIL_STATUS instead of dying mid-task.
4. **`--global-agent-timeout-sec 900`** (from the 500 s baseline). Load-bearing and
   measured, not padding: the recovered sqlite-db-truncate needed **790.3 s**, so 500 s
   and even 600 s would still have lost it. sanitize-git-repo's baseline work finished at
   ~559 s, also over the old cap.
5. **`litellm-bridge.yaml`: unchanged.** Nothing to gain — see the latency measurement.
   `cc_hooks` was left in place: it costs one dict lookup per call, and removing it brings
   back the `reasoning_effort=high` 400 outright.

## Iterations

- `opt-cc-1` (fix-git + sqlite-db-truncate, cap 900): **sqlite-db-truncate PASSES**
  (790.3 s). fix-git ran 538.6 s (vs 36 s at baseline), `terminal_reason: completed`,
  and now passes `test_layout_file` but fails `test_about_file`.
- `opt-cc-2` (fix-git alone, identical config): **fix-git PASSES**, 224.7 s, both
  `test_about_file` and `test_layout_file` green.

**So fix-git is variance, not a ceiling.** With the continuation prompt the agent reliably
runs the whole loop (36 s at baseline -> 225-539 s), and the remaining spread is how it
resolves the merge conflict: opt-cc-1 hand-resolved `_includes/about.md` into something
that did not hash-match `/app/resources/patch_files/about.md` (1 of 2 tests), opt-cc-2 got
it right (2 of 2). No further tuning was applied to it — telling cc how to resolve this
particular conflict would stop the comparison being about harnesses.

Both target tasks therefore recover:

| task | baseline | after |
|---|---|---|
| sqlite-db-truncate | agent_timeout (token cap at 685 s) | **PASS**, 790.3 s |
| fix-git | fail — session ended after 36 s | **PASS**, 224.7 s (1 of 2 attempts) |

## Final run (launched, results land on disk)

```bash
cd <repo>/tbench

PYTHONPATH=<repo>/tbench \
tb run --dataset terminal-bench-core==0.1.1 \
  --agent-import-path cc_agent:CCBridgeAgent \
  -t hello-world -t csv-to-parquet -t simple-sheets-put -t tmux-advanced-workflow \
  -t pytorch-model-cli.hard -t sanitize-git-repo -t fix-git -t openssl-selfsigned-cert \
  -t sqlite-db-truncate -t fibonacci-server -t write-compressor -t nginx-request-logging \
  --n-concurrent 2 \
  --global-agent-timeout-sec 900 \
  --run-id cmp-cc-opt \
  --output-path <repo>/tbench/runs \
  --no-cleanup
```

`--global-agent-timeout-sec 900`, up from the 500 s baseline. Report it as harness tuning:
it is what the recovered sqlite-db-truncate needs (790.3 s measured), and sanitize-git-repo
was still working at ~559 s when the old cap cut it off. Everything else is identical to
`cmp-cc` — same 12 tasks, same concurrency 2, same `--no-cleanup`, same output path.

Bridge left running: pid in `litellm-bridge.pid` (2520056), port 4001, started from the
tbench dir.

## Final result: 4/12 -> 7/12 (0.333 -> 0.583), 32.8 min wall

`runs/cmp-cc-opt/`, 2026-08-26 04:31:32 -> 05:04:21 UTC. Same wall clock as the baseline
(32.9 min) despite the higher cap, because the two token-cap deaths no longer burn 10+
minutes each before failing.

| task | baseline | cmp-cc-opt | agent time | note |
|---|---|---|---|---|
| hello-world | PASS | PASS | 31.2 s | |
| csv-to-parquet | PASS | PASS | 59.7 s | |
| simple-sheets-put | PASS | PASS | 100.8 s | |
| tmux-advanced-workflow | PASS | PASS | 117.6 s | |
| **fix-git** | fail (36 s, dead session) | **PASS** | 58.4 s | continuation prompt |
| **sqlite-db-truncate** | agent_timeout (token cap) | **PASS** | 629.1 s | 32000 cap + 900 s clock |
| **openssl-selfsigned-cert** | fail | **PASS** | 81.1 s | failed on *every* harness at baseline |
| write-compressor | agent_timeout (token cap) | fail — agent_timeout | 900 s cap hit | now a genuine long-run loss, not an API abort |
| nginx-request-logging | agent_installation_failed | fail | 94.6 s | **install fix worked**; now a model failure |
| sanitize-git-repo | agent_timeout (~559 s of work) | fail | 141.2 s | finishes well inside the clock now, still wrong |
| fibonacci-server | fail | fail | 84.9 s | model ceiling (only pi solves it) |
| pytorch-model-cli.hard | fail | fail — parse_error | 215.0 s | infra/parse, as at baseline |

Three recovered (fix-git, sqlite-db-truncate, openssl-selfsigned-cert), and two failures
changed class for the better: nginx-request-logging no longer dies at install, and
write-compressor now dies against the wall clock rather than aborting on the output cap.

**7/12 matches pi**, the practical frontier REPORT.md identified for this subset — but cc
gets there by a different route: it is the only harness that solved
openssl-selfsigned-cert, and it still misses fibonacci-server, which pi solves.
So the union of harness passes on this subset is now 8, not 7.

Note on the cap: tb logged `Agent timed out after 900.0s for task write-compressor`, so
`--global-agent-timeout-sec 900` took effect. The 1200.2 s figure in results.json for that
trial is `agent_started_at -> agent_ended_at`, i.e. it includes the harness tearing down
the blocking tmux command after the kill — not extra model time.

## TB_EFFORT knob (effort sweep prep)

`TB_EFFORT=low|medium|xhigh`, default `xhigh`. Flow:
`TB_EFFORT` -> `cc_agent._model_for_effort()` -> all five `ANTHROPIC_*_MODEL` slots get
`qwen3.8-27b-<effort>` -> `cc_hooks` reads the suffix off `data["model"]` and sets
`reasoning_effort` -> the deployment's `allowed_openai_params` lets it through to the serve.

It rides on the model name because neither of the other two channels exists: Claude Code
has no effort flag, and the proxy is a long-lived process started before any `tb run`, so
`TB_EFFORT` in the launching shell never reaches it. A consequence worth having: the knob
is per-request, so two runs at different efforts cannot contaminate each other.

### The finding that mattered: reasoning_effort was never being sent at all

`reasoning_effort` in `litellm_params` was silently discarded on every run to date.
LiteLLM decides an unrecognised `openai/` model does not support reasoning, and
`drop_params: true` then drops the field. Proven with a deliberately invalid value: a
deployment pinned to `reasoning_effort: high` returned **200** where the serve documents a
hard 400 — i.e. nothing was reaching it. `model_info.supports_reasoning: true` does not fix
this; `allowed_openai_params: ["reasoning_effort"]` does (same probe then 400s as it
should), and so does `extra_body`.

**So every cc run before this one used the chat template's own default effort, not a
value we sent.** That default is xhigh, so the `cmp-cc*` numbers stand as xhigh results —
but they were xhigh by the serve's default, not by our configuration. Anything else routed
through LiteLLM at an "explicit" effort deserves the same probe.

Second measured detail: with `allowed_openai_params` in place, a `reasoning_effort` on the
*request* beats the deployment's. That is why the hook sets it rather than leaving it to
the deployment default — the alias then wins regardless of what the client sent.

### Verification

| probe | expected | got |
|---|---|---|
| deployment pinned to the invalid `high`, no whitelist | 400 if transmitted | **200** — not transmitted |
| same, with `allowed_openai_params` | 400 | **400** |
| same, with `model_info.supports_reasoning: true` | 400 | 200 — does not work |
| `qwen3.8-27b-low` + request `reasoning_effort: high` | 200 (hook overwrites) | **200** |
| `qwen3.8-27b` (no suffix) + request `high` | 400 (nothing to overwrite) | **400** |
| identical prompt across aliases, `/v1/messages` | output tokens rise with effort | **71 / 85 / 103** for low / medium / xhigh |

Smoke `knob-cc-med-2`: hello-world **resolved**, both tests passed, and the trial
transcript's `modelUsage` is keyed on `qwen3.8-27b-medium` alone (`canonicalModel` likewise),
so every billed call went to the medium alias. The bare `qwen3.8-27b` in that transcript is
only the response-side model field LiteLLM fills from the underlying checkpoint.

`knob-cc-med` (the first attempt) died in install: nodejs.org dropped the tarball read, nvm
fell back to a source build, and that build fails on this image. `cc-setup.sh.j2` now uses
`nvm install -b` with three retries so a transport error stays retryable instead of turning
into a doomed 10-minute compile — the same flake class that cost cc nginx-request-logging at
baseline. Flagged as a deliberate extra change: it is install robustness, not the knob.
