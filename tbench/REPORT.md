# Agent-harness comparison on qwen3.8-27b (RTX 5090) — Terminal-Bench

**Setup.** One model (`qwen3.8-27b`, NInfer on an RTX 5090, OpenAI-compatible serve),
effort `xhigh` everywhere, so the only variable is the *harness*. Terminal-Bench
`terminal-bench-core==0.1.1`, a fixed 12-task simple subset, concurrency 2, 500s agent
cap, `--no-cleanup`. Four harnesses:

- **dsh** — DeepSeek Harness headless (minimal preset), installed in each task container.
- **terminus** — Terminal-Bench's built-in reference agent, drives the container from
  outside via LiteLLM; needs `terminus_fix.py` (NInfer rejects OpenAI structured output).
- **pi** — pi coding agent (`@earendil-works/pi-coding-agent`), installed in-container.
- **cc** — Claude Code CLI, installed in-container, routed to qwen through a LiteLLM
  Anthropic→OpenAI bridge on the host.

## Baseline results

| harness  | accuracy | resolved | wall (12 tasks, conc 2) | avg agent time/task |
|----------|----------|----------|-------------------------|---------------------|
| **pi**   | **0.58** | **7/12** | 25.7 min                | 168 s               |
| dsh      | 0.50     | 6/12     | 30.1 min                | 244 s               |
| cc       | 0.33     | 4/12     | 32.9 min                | 245 s               |
| terminus | 0.25     | 3/12     | 17.9 min                | 132 s               |

### Per-task matrix (PASS / fail / err=infra)

| task | dsh | term | pi | cc |
|------|-----|------|----|----|
| hello-world            | PASS | PASS | PASS | PASS |
| csv-to-parquet         | PASS | fail | PASS | PASS |
| simple-sheets-put      | PASS | fail | PASS | PASS |
| tmux-advanced-workflow | PASS | PASS | PASS | PASS |
| pytorch-model-cli.hard | err  | err  | fail | fail |
| sanitize-git-repo      | fail | fail | fail | fail |
| fix-git                | PASS | PASS | PASS | **fail** |
| openssl-selfsigned-cert| fail | fail | fail | fail |
| sqlite-db-truncate     | PASS | fail | PASS | fail |
| fibonacci-server       | fail | fail | **PASS** | fail |
| write-compressor       | fail | fail | fail | fail |
| nginx-request-logging  | fail | fail | fail | fail |

## Reading the results

- **The model, not the harness, sets the ceiling.** Four tasks fail on *every* harness
  (sanitize-git-repo, openssl-selfsigned-cert, write-compressor, nginx-request-logging),
  and pytorch-model-cli.hard fails/errs for all. These need multi-step correctness a 27B
  model at xhigh can't reach here. The **union of all harnesses' passes is 7 tasks** — so
  7/12 is the practical frontier on this subset, and **pi already hits all 7**.
- **pi is the best harness** — it reaches the frontier and is second-fastest. Its
  in-container install is light (~60s) and its losses are all the model ceiling.
- **dsh is a close, clean second** (6/12). Its only harness-attributable miss is
  fibonacci-server (pi solved it); no agent errors, cleanest failure profile.
- **cc's losses look like latency and are not.** Three trials are tagged `agent_timeout`,
  but the panes name a different cause: sqlite-db-truncate and write-compressor both abort
  on `API Error: Claude's response exceeded the 16384 output token maximum` — an output cap
  in cc's own adapter, not the clock. fix-git is not a timeout at all
  (`terminal_reason: completed`, 36 s). The bridge itself adds ~0.15 s per call and logged
  133/133 200s with zero retries. Diagnosis and fixes in the optimization section.
- **terminus is weakest here for a structural reason.** 7 of its 12 are
  `unknown_agent_error`: even with the response-format fix, driving the container blind
  and parsing the model's freeform command batches is brittle on a smaller model. The
  three it loses that pi/dsh solve (csv-to-parquet, simple-sheets-put, sqlite-db-truncate)
  are parse failures, not capability — recoverable.

### Failure-mode tally (non-pass)
- dsh: 4 genuine fail, 1 test_timeout (infra), 1 agent_timeout
- terminus: **7 unknown_agent_error**, 1 test_timeout, 1 genuine fail
- pi: 2 agent_timeout, 1 agent_installation_failed, (rest model ceiling)
- cc: 3 agent_timeout, 1 agent_installation_failed, (rest model ceiling)

Note: token counts are only observable for terminus (external LiteLLM driver: 101,744 in
/ 10,359 out over the run); the in-container harnesses run the model out of tb's sight.

## Optimization results (each harness's real bottleneck was fixable infra, not the model)

| harness  | baseline | optimized | what actually held it back, and the fix |
|----------|----------|-----------|------------------------------------------|
| **dsh**  | 6/12     | **7/12**  | fibonacci-server "failed" because dsh signals the whole **process group** at turn end, so the agent's background server was dead before the tests ran (`Connection refused` on all 6, though dsh's own answer was correct). Fix: a persona rule to launch servers with `setsid` (survives the group kill) + an input-validation rule. |
| **pi**   | 7/12     | **7/12**  | Already at the frontier; capability unchanged. Its one non-model loss was `agent_installation_failed` (a flaky TLS read from nodejs.org). Fix: bounded retry around apt/nvm/node/npm + `nvm install -b` so a transport error retries instead of triggering a 10-min source build. Verified on a resolved smoke; the full re-run was abandoned when the serve died (below). |
| **cc**   | 4/12     | **7/12**  | Not bridge latency: measured at ~0.15 s/call with 133/133 200s and zero retries, and `litellm-bridge.yaml` needed no change at all. Two of the three "timeouts" were an output cap in cc's own adapter (`CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384` — reasoning bills against it, so one xhigh turn overran it and Claude Code aborted the whole session); fix-git was never a timeout — the model narrated its next step with no tool call and the session ended on `end_turn` after 36 s. Fix: cap → 32000, a task-agnostic "don't stop to narrate, keep going until verified" `--append-system-prompt`, a self-heal for the flaky `claude` native-binary install, and `--global-agent-timeout-sec 900`. Recovered fix-git, sqlite-db-truncate, openssl-selfsigned-cert. |
| **terminus** | 3/12 | **6/12**  | 7 of 12 were `unknown_agent_error` — brittle parsing of a smaller model's freeform command batches. Fix: tolerant JSON/fenced-block parsing. Recovered simple-sheets-put, fix-git, fibonacci, openssl. |

### Optimized per-task matrix

| task | dsh | term | pi | cc |
|------|-----|------|----|----|
| hello-world            | PASS | PASS | PASS | PASS |
| csv-to-parquet         | PASS | fail | PASS | PASS |
| simple-sheets-put      | PASS | PASS | PASS | PASS |
| tmux-advanced-workflow | PASS | PASS | PASS | PASS |
| pytorch-model-cli.hard | err  | fail | fail | err  |
| sanitize-git-repo      | fail | fail | fail | fail |
| fix-git                | PASS | PASS | PASS | PASS |
| openssl-selfsigned-cert| fail | **PASS** | fail | **PASS** |
| sqlite-db-truncate     | PASS | err  | PASS | PASS |
| fibonacci-server       | PASS | PASS | PASS | fail |
| write-compressor       | fail | fail | fail | fail |
| nginx-request-logging  | fail | fail | fail | fail |
| **TOTAL**              | **7/12** | **6/12** | **7/12** | **7/12** |

Harness tuning disclosed: cc's optimized run (`runs/cmp-cc-opt`) raised the agent cap to
`--global-agent-timeout-sec 900` from the 500 s baseline, and needs it — the recovered
sqlite-db-truncate takes 629 s. Everything else about that run matches the baseline (same
12 tasks, concurrency 2, `--no-cleanup`), and it finished in the same wall clock, 32.8 min
against 32.9, because the two token-cap deaths no longer burn ten minutes each before
failing. Two of cc's remaining failures also changed class for the better:
nginx-request-logging no longer dies at install (it is now a plain model failure) and
write-compressor now runs out the clock instead of aborting on the output cap.

## Verdict

- **Best harness: a three-way tie at 7/12 (dsh, pi, cc)** after optimization, up from a
  pi-led 7/6/4/3 spread at baseline. **pi is the most efficient winner** — it hit 7/12
  out of the box with the lightest in-container install and no tuning; the other two had
  to be fixed up to match it. **dsh is the most robust** (cleanest failure profile, real
  end-of-turn signals). **cc matches on accuracy but needs the highest time budget** — not
  from the bridge (~0.15 s/call) but from the sheer volume of xhigh reasoning it generates:
  its optimized run is the one that needed a 900 s agent cap where 500 s sufficed
  elsewhere. **terminus is the lightest to run** (no in-container install)
  but the most parsing-fragile on a small model.
- **The optimization headline: none of the harness losses were the model's fault.** Every
  recoverable failure was infrastructure — a process-group kill (dsh), an output-token cap
  and a premature `end_turn` (cc), output parsing (terminus), a flaky download (pi).
  Fixing those lifted the field from a 3–7 spread to a 6–7 cluster.
- **The real ceiling is the model, and it's 8/12.** Four tasks fail on every harness
  (sanitize-git-repo, write-compressor, nginx-request-logging, pytorch-model-cli.hard) —
  genuine qwen3.8-27b capability limits. The **union of what any harness solves is 8
  tasks**; no single harness reaches 8 because openssl (terminus/cc only) and
  fibonacci (dsh/pi/terminus only) are solved by different harnesses. An **ensemble /
  best-of-N across harnesses would score 8/12** — the best overall result available on
  this model.

### Further optimization levers (not yet run)
- **Ensemble**: route each task to best-of-N across harnesses → 8/12 (proven by the union).
- **Effort**: xhigh generates very long reasoning_content; it drove serve load high enough
  that the remote 5090 serve became **unresponsive under sustained benchmark load** (the
  pi-opt re-run was abandoned when a bare "Say OK" completion began timing out at >120s).
  Testing `medium` would cut serve load and per-task latency (helping cc's timeouts most),
  at some accuracy cost — worth a sweep once the serve is back.
- **n_attempts > 1** (pass@k) on the 4 model-ceiling tasks to see if any are reachable
  with retries rather than truly out of reach.

### Reproduce
Adapters + configs in `tbench/`: `dsh_agent.py`, `pi_agent.py`, `cc_agent.py`+`cc_hooks.py`+`litellm-bridge.yaml`, `terminus_fix.py`, and the `*-setup.sh.j2` scripts. Baseline driver: `compare.sh`. Per-harness optimization notes: `briefs/opt-*-notes.md`. All runs under `runs/cmp-*`.

---

## Effort sweep (low / medium / xhigh)

Everything above ran at `xhigh`. This sweep runs each harness at `low` and `medium`
too, on the **8 solvable tasks** (the 4 model-ceiling tasks fail at every effort, so
they add no signal). It answers: does lower reasoning effort cost accuracy, and is
xhigh even the right default?

**First, a plumbing bug the sweep exposed.** `reasoning_effort` was being **silently
dropped for the two LiteLLM-routed harnesses** (Claude Code's proxy and terminus's SDK):
LiteLLM decides an unrecognised `openai/` model does not support the field and drops it
under `drop_params`. Proven by sending an invalid `high` and getting `200` where the
serve documents a hard `400`. So every earlier cc and terminus run used the serve chat
template's **default** effort (which is xhigh), not a value we set. Fixed with
`allowed_openai_params=["reasoning_effort"]` on both; an invalid effort now `400`s at the
serve, confirming delivery. dsh and pi send effort natively and were always correct.

### Result: resolved out of the 8 solvable tasks

| harness | low | medium | xhigh | curve |
|---|:---:|:---:|:---:|---|
| **dsh** | 7 | **8** | 7 | flat — effort barely matters, medium slightly best |
| **terminus** | **7** | 4 | 6 | **inverted — LOW is best** |
| **pi** | 4 | 6 | **7** | monotonic — wants HIGH |
| **cc** | 4 | 3 | **7** | wants HIGH; collapses below it |

Avg agent time per task: terminus ~40s (fastest), pi ~70-90s, dsh ~120-130s,
cc ~180-240s (slowest).

### What it means

- **The optimal effort is not the same for every harness.** This is the core finding.
  `xhigh` is a bad universal default: it is best only for pi and Claude Code, is a wash
  for dsh, and is actively *worse* than low for terminus.
- **terminus is the surprise: low effort is its best config, 7/8.** Its whole failure
  mode at xhigh was the model's long `reasoning_content` overrunning the output budget
  and breaking terminus's parser. At low effort the outputs are short and clean, and it
  jumps from 6 to 7. The earlier "terminus 6/12" was xhigh; **terminus is really a 7/8
  harness once you stop making it think so hard.**
- **Claude Code is the opposite: it needs the reasoning.** At medium it drops to 3/8,
  and every one of those failures is a wrong answer (`unset`), not a timeout or crash —
  genuine under-thinking. It is the most effort-hungry harness, which fits its being the
  most reasoning-heavy.
- **dsh is the most robust: 7-8 at every effort.** And its single best cell in the whole
  study is here.

### Best overall result: dsh at medium, 8/8

**`dsh` at `medium` effort solves all 8 solvable tasks (8/12 overall) — the full
frontier, from one harness at one effort.** This revises the pre-sweep conclusion: the
8-task frontier does **not** require a cross-harness ensemble after all. dsh at medium
even recovers `openssl-selfsigned-cert`, which dsh *failed* at xhigh — more reasoning was
making it worse. This is the best single configuration measured, and it is also cheaper
than xhigh.

**Recommended defaults per harness:** dsh → medium, terminus → low, pi → xhigh,
Claude Code → xhigh. Runs under `runs/sweep-<harness>-<effort>`.

## Low effort on the full 12-task subset (2026-08-30)

The effort sweep above ran `low` only on the 8 solvable tasks. This run puts `low`
across the **full 12-task comparison subset** for the three harnesses the maintainer
asked about (dsh, pi, cc; terminus not re-run), so the numbers sit on the same
denominator as the `/12` headline. Driver: `low12.sh`. Runs: `runs/low12-{dsh,pi,cc}`.

| harness | 12-task | same 8 as the sweep | sweep's earlier low/8 | wall time |
|---|:---:|:---:|:---:|---|
| **dsh** | **8/12** | 7/8 | 7/8 | 20m43s |
| **pi**  | 6/12 | 6/8 | 4/8 | 16m24s |
| **cc**  | 6/12 | 5/8 | 4/8 | 35m26s |

dsh reproduces its earlier low score exactly (7/8). pi and cc both came out **2 and 1
tasks better** than the same configuration in the sweep — same effort, same tasks, same
timeout — which puts the run-to-run noise on this suite at roughly ±1-2 tasks and is a
caution against reading single-task differences anywhere in this report as signal.

dsh's 8/12 is **corrected**: its raw result was 7/12 because `hello-world` failed with a
broken container install (`E: Package 'make' has no installation candidate`, no `curl`,
no npm/pnpm, so `/opt/dsh-runtime/node_modules/.bin/dsh` was never created). That is an
apt-index flake in one container, not a capability result — it hit no other task in the
run, and dsh passes `hello-world` at low everywhere else. Re-run in
`runs/low12-dsh-helloretry`: resolved. Note the setup script's readiness probe did **not**
catch it — Terminal-Bench recorded `failure_mode: unset` rather than
`agent_installation_failed`, so the probe is not as load-bearing as the README claims.

### Correction: the ceiling is not 8/12, and `pytorch-model-cli.hard` is not a ceiling task

The "real ceiling is the model, and it's 8/12" claim above names four tasks that
"fail on every harness". **One of them is wrong.** At low effort `pytorch-model-cli.hard`
is solved cleanly by **both dsh and cc** — all 6 subtests pass, and pi gets 5 of 6.

It was never actually measured at xhigh. In `cmp-dsh-opt` and `cmp-cc-opt` that task
recorded `is_resolved: null` with `failure_mode: parse_error` — the trial errored in
result *parsing*, not in solving — and the scoring recipe in `README.md`
(`jq -r .is_resolved | grep -c true`) counts `null` as a non-pass, so it was silently
folded in as a capability failure and became one of the four "ceiling" tasks.

The evidence was already on disk, too: `runs/dsh-curated-2`, from before the comparison,
also has it resolved. Nothing contradicted the ceiling claim loudly enough to be noticed
because the scoring recipe hid the difference between "failed" and "not measured".

So: the union of what some harness solves is **9/12**, not 8 (the 8 solved at low, plus
`openssl-selfsigned-cert`, which low never gets but dsh-medium and cc/terminus do). The
genuine model-ceiling set is **three** tasks — `sanitize-git-repo`, `write-compressor`,
`nginx-request-logging` — all still unsolved by every harness at every effort measured.

**When scoring a run, count `null` separately from `false`.** A `parse_error` trial is
missing data, and treating it as a failure understates the model.

## Persona A/B at medium on the full 12 (2026-08-31)

The [self-optimization loop](../app/docs/SELF-OPTIMIZATION.md) promoted a
`structured` persona — six rules appended to the container persona (inspect
before changing, small verified steps, never assume file contents or exit
codes, one focused command per call, a final verification step, end with a
tool-free message) — on its own 16-task suite (15/16 at medium), and the dsh
TUI's `qwen5090` preset now carries it. Its own roadmap notes that "persona
barely did once effort was fixed", so this run puts the question to the
Terminal-Bench subset instead: the headless adapter with `TB_DSH_PERSONA=
baseline|structured`, both arms at `medium`, all 12 tasks. Neither arm had been
measured at medium on the full 12 before (the effort sweep covered 8), so the
baseline arm is new data as well as the control. Driver `persona12.sh`; runs
`runs/persona12-dsh-{baseline,structured}` plus the two `-retry` re-runs below.

| task | baseline | | structured | |
|---|:---:|---:|:---:|---:|
| hello-world | PASS | 1m08s | PASS | 0m59s |
| csv-to-parquet | PASS | 1m24s | fail 1/2 | 1m44s |
| simple-sheets-put | PASS | 1m20s | PASS | 1m26s |
| tmux-advanced-workflow | PASS | 4m29s | PASS | 1m38s |
| fix-git | PASS | 1m34s | PASS | 1m19s |
| sqlite-db-truncate | fail 0/1 † | 4m12s | PASS | 5m24s |
| fibonacci-server | fail 5/6 | 1m05s | PASS | 1m16s |
| openssl-selfsigned-cert | fail 5/6 | 1m28s | fail 5/6 | 1m40s |
| pytorch-model-cli.hard | timeout | 18m12s | fail 5/6 | 6m20s |
| write-compressor | fail 0/3 | 7m33s | **PASS** (timeout) | 20m00s |
| sanitize-git-repo | fail 2/3 | 14m38s | fail 2/3 † | 3m39s |
| nginx-request-logging | fail 1/8 | 2m19s | fail 3/8 | 2m41s |
| **total** | **5 / 12** | | **7 / 12** | |

Times are agent time per trial (`agent_started_at` → `agent_ended_at`).
† from the `-retry` re-run; the original trial flaked at install (below).

**Accuracy: 7/12 against 5/12.** Two tasks, which is the edge of this
suite's ±1–2 run-to-run band — read it as *not worse, plausibly better*. On the ten tasks both arms completed, agent time is a
wash — 40.6 min baseline against 39.1 min structured, medians 1.6 and 1.7 min.
The long trials swap rather than shrink: the structured arm finishes
`pytorch-model-cli.hard` in 6m20s where baseline burned its 18-minute
timeout, and clears `tmux-advanced-workflow` in a third of the time, but then
spends 20 minutes on `write-compressor`.

Where the rules moved a result, the per-test detail says how:

- **`fibonacci-server`** — baseline passed 5/6 and missed only
  `test_negative_number` (a negative `n` returned 200). Structured passed all
  six. The "final verification step" is the rule that fits: the baseline
  agent's answer worked for the cases it tried and it stopped there.
- **`csv-to-parquet`** — the one regression, and it is the "inspect before you
  change" rule doing exactly what it says. The structured agent noticed the
  last row's `"Seattle "` carried a trailing space and *cleaned it*; the test
  wants the Parquet to match the CSV byte for byte. Baseline converted
  without looking and passed. A persona that makes the model read more
  carefully also makes it more willing to fix what it was not asked to fix.
- **`write-compressor`** — the first time any harness has solved this task
  with this model, and it has to be read with the timeout attached. The agent
  never returned: Terminal-Bench cut it at the agent timeout
  (`failure_mode: agent_timeout`) and the `data.comp` on disk at that moment
  decompressed to `data.txt` exactly, under 2,500 bytes, 3/3 tests. The
  headless profile prints nothing while it works and the container was gone
  before its dsh session log could be copied out, so *how* it got there is
  unrecorded. Baseline scored 0/3 in 7m33s. One solve at n=1 is not a
  capability claim, but it does mean the task is reachable, which the
  "ceiling" correction above said it was not.
- **`sqlite-db-truncate`** — the baseline re-run is a failure on merit and an
  odd one: dsh ran for 4m12s, printed nothing, and exited with no
  `recover.json` on disk — an empty turn behind a clean exit, the shape
  DEEPSEEK-HARNESS.md warns about when a tool call goes unparsed. Structured
  solved it in 5m24s.
- **`sanitize-git-repo`** — identical 2/3 in both arms: both find and replace
  the secrets, both trip `test_no_other_files_changed` (a tokenized dataset
  file under `exp_data/` gets modified). Still a ceiling task, but a narrow one.
- **`openssl-selfsigned-cert`** — identical 5/6 in both arms, on the same test:
  the agent writes "SHA-256" and `test_fingerprint` greps for the literal
  `sha256`. A wash, and a benchmark-literal miss rather than a model one.
- **`nginx-request-logging`** — 1/8 vs 3/8, both because `nginx` never gets
  installed in that container (the structured agent served the index and 404
  pages from something else, which is what its two extra passes are). Still a
  ceiling task.

**Two install flakes, two different modes, one per arm** — both re-run above
under the fixed templates and counted from the re-run, not as fails:

- baseline `sqlite-db-truncate`: the nodejs.org tarball download died
  (`bad record mac`), so nvm never installed node and `dsh` was never built.
  This is the flake the nvm retry loop (`0f7f8c5`) was written for; that
  commit landed mid-arm.
- structured `sanitize-git-repo`: an apt `Hash Sum mismatch` on
  `libstdc++-12-dev` killed the install before `curl` existed, so the nvm
  retry never got its chance. Terminal-Bench did record it as
  `agent_installation_failed` this time — the readiness-probe fix works — and
  the apt step now retries too (`5736fb7`). The scorer for this section keys
  flakes on that failure mode plus the pre-fix pane signature.

**The baseline arm is the sweep's configuration, and it scored three tasks
lower.** `sweep-dsh-medium` (2026-08-26) resolved all 8 of its tasks; the same
adapter, persona, effort and task list here resolved 5 of those 8, losing
`sqlite-db-truncate`, `fibonacci-server` and `openssl-selfsigned-cert` — every
one a near-miss (0/1, 5/6, 5/6). That is outside the ±1–2 band the low12 run
established *within* a day. One known confound: the serve is not held constant
across dates — the [self-optimization loop](../app/docs/SELF-OPTIMIZATION.md)
tunes the live NInfer flags (`--preserve-thinking` was promoted since the
sweep), and this run did not record them. So the honest noise figure for a
cross-date comparison on this suite is more like **±3**, and the "dsh at
medium, 8/12" headline should be read as the top of a 5–8 range, not a
point. A same-day re-run of the sweep configuration is the cheap way to
settle it.

**What it changes.** The structured persona is not worse on the benchmark, it
recovers one task the baseline misses through under-verification, and its one
loss is over-eagerness on a task that rewards doing less. That is enough to
keep it as the TUI's default preset, and not enough to promote it above the
noise band: with ±1–2 tasks of run-to-run variance on this suite, the
[HARNESS-BENCHMARKS](../app/docs/HARNESS-BENCHMARKS.md) headline stays
"medium effort", not "medium effort plus this persona". The loop's own
finding — effort moved the numbers, persona barely did — holds here too.

Two things this run leaves open: the `write-compressor` solve wants a repeat
before the ceiling set is rewritten as two tasks, and the headless adapter
should copy `$DSH_HOME/sessions/*/session.jsonl.zstd` into the trial's
`agent-logs/` before the turn ends — `--no-cleanup` keeps the casts, not the
agent containers, and the one trial whose reasoning mattered most is the one
with no record of it.

### Sampling defaults are the model card's (measured 2026-08-31)

A candidate lever after the persona A/B was pinning the sampler: pi-ai sends
no sampling parameters, so the serve's default governs every agent request,
and the model card recommends `temperature 0.7 / top_p 0.8 / top_k 20 /
presence_penalty 1.5`. Two facts closed it without a run. First, dsh cannot
pin anything but `temperature` — its pi-ai adapter forwards only that field
and no settings key feeds it. Second, it does not need to: NInfer honours
`seed`, and with a fixed seed the output with nothing set is byte-identical to
the output with `0.7`, `0.8` and `1.5` sent explicitly (and to the full set),
while `temperature 1.0`/`0.6`, `top_p 1.0`/`0.95` and `presence_penalty 0`
each produce different text. `top_k` 20/0/40 were indistinguishable under
`top_p 0.8`. NInfer's "model-aware sampling defaults" are the card's values;
`temperature: 0` is deterministic. Scripts: the `probe_*.py` files are not
kept — the recipe is three requests with the same `seed`.

## Tool set A/B in the TUI: `standard` vs `minimal` (2026-08-31)

The harness research ([HARNESS-DESIGN.md](../app/docs/HARNESS-DESIGN.md)) had
one finding that applied directly here and had never been measured on this
model: smaller models do better with fewer tools. The headless adapter runs
dsh's `minimal` composition (bash + `str_replace_editor`, 3 rows); a real TUI
user gets `standard` (16 rows: file tools, search, jobs, todo, subagents, web,
…). With the TUI adapter working, the comparison is one flag. Both arms at
`medium` with the `tuned` persona (structured rules + budget awareness,
`dsh_agent.py` PERSONAS), through `dsh_tui_agent.py`, so every trial also has
a cast of the TUI at work and, since this run, the dsh session log in
`agent-logs/`. Driver `toolset12.sh`; runs `runs/toolset12-tui-{standard,minimal}`
plus `runs/toolset12-tui-minimal-retry` (below).

| task | standard | | minimal | |
|---|:---:|---:|:---:|---:|
| hello-world | PASS | 1m47s | PASS | 1m36s |
| simple-sheets-put | PASS | 2m19s | PASS | 2m04s |
| tmux-advanced-workflow | PASS | 2m09s | PASS | 2m54s |
| sqlite-db-truncate | PASS | 7m53s | PASS | 3m35s |
| fibonacci-server | PASS | 2m16s | PASS † | 2m07s |
| csv-to-parquet | fail 1/2 | 3m38s | **PASS** | 5m18s |
| fix-git | PASS | 2m31s | fail 1/2 † | 2m14s |
| openssl-selfsigned-cert | PASS | 2m09s | fail 5/6 | 2m01s |
| write-compressor | fail 0/3 | 4m52s | timeout | 20m00s |
| sanitize-git-repo | fail 2/3 | 3m08s | fail 2/3 | 2m29s |
| nginx-request-logging | fail 7/8 | 2m05s | fail 7/8 | 2m12s |
| pytorch-model-cli.hard | err(test_timeout) | 4m37s | err(test_timeout) | 5m25s |
| **total** | **7 / 11** | | **6 / 11** | |

Times are agent time per trial. `err(test_timeout)` is **not measured**: the
task's own tests pip-install a 176 MB torch wheel inside a 120 s test budget;
the headless agents had installed torch themselves during the turn, the TUI
agents extracted the weights without it, and the tests then timed out in both
arms. † re-run after the fix below.

**Verdict: no evidence that fewer tools help this model — `standard` 7/11
against `minimal` 6/11, one task, inside the noise, and each arm took one the
other lost** (minimal passed `csv-to-parquet` where standard declared the age
column `int32`; standard passed `fix-git` and `openssl`, the latter the usual
`sha256`-literal miss on minimal). Agent time is comparable once minimal's
20-minute `write-compressor` timeout is set aside (34 min vs 32 min over the
other eleven). The research finding is real for some models; on this one, in
this harness, the 25-tool preamble costs nothing measurable, which is what
NINFER.md's "leave the full set on" already predicted from prefill cost. Keep
`standard`. The `tuned` persona (structured rules plus budget awareness) was
in both arms and is therefore not separately measured here: the TUI arms sit
at 7/11 where the headless `structured` run sat at 7/12, which is consistent
with "no harm" and nothing stronger.

Two trials were lost to infrastructure and re-run: the minimal arm's
`fix-git`, whose turn ended with `PI_AI_ERROR: inference request expired while
waiting for admission` after two tool calls — local reproduction turns for the
defect below were hitting the same serve (`MAX_SEQS=2`) while the arm ran at
two concurrent, which is a mistake of this run and not of the harness — and
its `fibonacci-server`, which is the defect. Every other turn in both arms
ended `completed`, except the standard arm's `write-compressor`, which ended
with reason **`max-tokens`**: the model's answer hit its output cap and dsh
ended the turn there, with no continuation. That is a harness failure mode
worth its own fix (a "continue" on `max-tokens`, the way Claude Code's cap
was raised in the first comparison) and is now visible only because the
session logs are collected.

### What the minimal arm's `fibonacci-server` found: a harness defect

The minimal arm scored 0/6 on `fibonacci-server` with the server *correctly*
started — `cd /repo && setsid nohup python3 server.py > server.log 2>&1
< /dev/null &` — and curl-verified at 200 on every endpoint in the same
turn. At test time port 3000 refused. The standard arm, same rule, same
persona, passed.

Reproduced locally against the live TUI with the agent's exact command
shape, then explained with `ps -o pid,ppid,pgid,sid`:

- Under `minimal`, the `bash` tool is `dsh-tool-bash-persistent`: one
  long-lived interactive shell. A backgrounded **list** — `cd dir && setsid …
  &` — forks a subshell that runs `cd`, then `setsid`, and *waits* on the
  server as its last command. The server gets its own session (`sid = pgid =
  self`, so `setsid` worked) but its parent is that still-alive subshell,
  whose parent is the persistent shell, whose parent is dsh. When the session
  ends, the persistent tool kills its **descendant tree**, not merely the
  process group — and the server is still in it.
- The bare `setsid nohup … &` form survives, by accident: the job is a group
  leader, so `setsid` forks, the intermediate exits, and the server is
  re-parented to init *before* the TUI exits. Out of the tree.
- Under `standard`, the `bash` tool is one-shot (`bash -c` per call), so
  every child is orphaned to init the moment the call returns. Immune, also
  by accident.

`setsid -f` (always fork) makes the server leave the tree regardless of
command shape; verified alive after TUI exit with the failing form (ppid 1
before exit), and present in Debian 12 and Ubuntu 22.04. The rule now says
so in both templates and the live preset (`27ad164`). The headless profile
runs the same persistent tool and is **not** affected — both forms were
measured alive after `dsh --profile headless` exits — so this is the TUI's
interactive shutdown path specifically, and the persona12 numbers stand.

## The `max-tokens` turn: cap raised, continuation added (2026-08-31)

The session logs collected since the tool-set run showed one turn ending with
reason `max-tokens` (standard arm, `write-compressor`): `stopReason: length`,
**`outputTokens: 32768`**, and the step's blocks were *reasoning only* — the
model spent pi-ai's entire default output cap (`DEFAULT_MAX_TOKENS = 32768`,
per step) thinking, emitted no text and no tool call, and dsh ended the turn
there. Nothing continued it. Two changes, both in the adapters and mirrored on
the 5090 box:

- **The cap is now a route setting**: `models[].maxTokens` in the rendered
  `settings.yaml`, from `TB_DSH_MAX_TOKENS` (default **65536**; the live
  `~/.dsh/settings.yaml` carries the same). Doubling it gives a long but
  finite chain room; it does not rescue a runaway one, which is what the
  second change is for.
- **A continuation on `max-tokens`, up to twice.** The headless runner reads
  the session's last `turn/end` reason (zstd is now installed for it) and,
  on `max-tokens`, re-runs dsh with a prompt that says the previous attempt
  ran out of budget while reasoning, must inspect the working directory and
  *act* — **at `low` effort** (the container's `settings.yaml` is flipped
  for the continuation and restored after), because a step that burned its
  whole budget thinking is better finished at low than not at all. The TUI
  watcher does the same in-session: it counts `turn/end` events, and on a
  `max-tokens` one pastes the continuation into the composer instead of
  exiting; the effort stays as configured there, since the TUI's `/effort`
  is a slider rather than a command that takes an argument.

Mechanics verified with the cap forced to 40 tokens (every step then ends on
`max-tokens`): locally against a DSH_HOME copy — headless made the initial
shot plus exactly two continuations, flipped to `low` and restored `medium`,
saved all three outputs; the TUI ran three turns in one session and exited
cleanly — and then in task containers through both adapters (`runs/mt-headless`,
`runs/mt-tui`). Whether a continuation *recovers* the real case is a model
question at n=1 — and the re-run answers it as far as one run can.

**`write-compressor` at the 65536 cap** (`runs/mt-write-compressor`, TUI,
standard preset, tuned persona): the turn never ended on `max-tokens`. The
agent took **32 steps** — 4 reads, 17 bash calls, 2 writes, 9 edits, ~170K
output tokens in all — wrote a compressor, produced `data.comp`, and was
still shrinking it when the 20-minute agent timeout hit. Tests: **2/3** —
the file exists and decompresses byte-exact, at **2,679 bytes against the
2,500 limit**. So the failure mode is fixed (a reasoning-only step that
ends the turn) and the task is still lost, on merit and narrowly. The
per-poll session-log copy earned its keep on this exact trial: it was
killed at the timeout, and the log is in `agent-logs/` anyway.
