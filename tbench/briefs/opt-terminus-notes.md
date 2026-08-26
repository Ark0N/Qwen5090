# terminus optimization — diagnosis and fixes

Baseline: `runs/cmp-terminus/`, 3/12, **7 `unknown_agent_error`**.

## The 7 errors were all one fault, and it was not parsing

Every errored trial's last episode reads the same in `agent-logs/episode-N/debug.json`:

| task | episode | finish_reason | completion_tokens | reasoning chars | content chars |
|---|---|---|---|---|---|
| simple-sheets-put | 9 | length | 8192 | 32,371 | **0** |
| sanitize-git-repo | 4 | length | 8192 | 28,028 | **0** |
| openssl-selfsigned-cert | 0 | length | 8192 | 27,999 | **0** |
| write-compressor | 7 | length | 8192 | 27,572 | **0** |
| fibonacci-server | 0 | length | 8192 | 29,459 | **0** |
| csv-to-parquet | 1 | length | 8192 | ~29,000 | **0** |
| sqlite-db-truncate | 1 | length | 8192 | ~30,000 | **0** |

`completion_tokens: 8192` exactly, every time — the serve's default output cap,
spent entirely on `reasoning_content`, with `content` empty. This is the trap
CLAUDE.md already records: **reasoning tokens are billed against `max_tokens`.**
Terminus sends no `max_tokens` at all, so xhigh thinking on a hard task eats the
whole default budget before the model writes a single character of JSON.

LiteLLM turns `finish_reason: "length"` into `OutputLengthExceededError`, and
terminus-1 lists that exception in `retry_if_not_exception_type` at *both*
tenacity layers — so it is never retried, propagates out of `perform_task`, and
the trial is recorded as `unknown_agent_error`. The model was not producing
unparseable output; it was producing *no* output.

## The second fault: `is_blocking` breaks every heredoc not ending in `EOF`

csv-to-parquet's episode-0 sent a `python3 - <<'PY' … PY` batch with
`is_blocking: true`. Blocking appends `; tmux wait -S done` to the final line, so
the terminator went out as `PY; tmux wait -S done`, the heredoc never closed, and
the pane sat at a `>` continuation prompt until the 30 s timeout. Terminus-1
guards for exactly this — but only for the literal delimiter `EOF`
(`keystrokes.strip().endswith("EOF")`). The model chose `PY`.

The model actually *diagnosed it correctly* in the reasoning of the next episode
("the heredoc delimiter was not recognized because it had extra text
`; tmux wait -S done` appended") — and then ran out of output budget before it
could say so in JSON. Both faults in one trial.

## Fixes, all in `terminus_fix.py`

1. `max_tokens` is now set on every call (`TERMINUS_MAX_TOKENS`, default
   **16384** — double the serve default). The serve accepts 32768 too; 16384 was
   chosen to leave room inside the 500 s per-task agent cap.
2. **Overflow recovery.** `_handle_llm_interaction` catches
   `OutputLengthExceededError` and re-asks with an explicit "do not deliberate,
   emit the JSON now" nudge, at `reasoning_effort=low` and a small 4096 cap, up
   to twice. Verified live against the serve: a forced overflow recovers into a
   valid `CommandBatchResponse`. This only ever runs on a turn that already
   produced nothing, so the main path stays at the template default (xhigh) —
   **effort is unchanged and still comparable to the other harnesses.**
3. **Generalized heredoc guard.** `_open_heredoc_delimiter` recognises any
   `<<DELIM` / `<<'DELIM'` / `<<-DELIM` whose terminator is the batch's last
   line, sends that batch unblocked, and then waits on a separate blocking
   `true` — which the shell only reaches once the heredoc'd command has exited,
   so blocking semantics survive intact.
4. Tolerant JSON extraction (fenced ```json blocks, leading/trailing prose) kept
   from the first pass, now with `raw_decode` fallback. Unit-tested; in practice
   the model emits bare JSON and it has not been needed.

## What was tried and rejected

- `chat_template_kwargs: {enable_thinking: false}` — the serve refuses it
  (`chat_template_option_not_supported`). `reasoning_effort` *is* accepted, which
  is what the recovery path uses.
- Lowering effort globally — would have broken comparability with dsh/pi/cc, and
  turned out to be unnecessary once the budget was raised.

## Result: 3/12 → 6/12 (`runs/cmp-terminus-opt/`)

| task | baseline | optimized | |
|---|---|---|---|
| hello-world | PASS | PASS | |
| csv-to-parquet | err:unknown_agent_error | fail | error → genuine failure |
| simple-sheets-put | err:unknown_agent_error | **PASS** | recovered |
| tmux-advanced-workflow | PASS | PASS | |
| pytorch-model-cli.hard | err:test_timeout | fail | error → genuine failure |
| sanitize-git-repo | err:unknown_agent_error | err:unknown_agent_error | |
| fix-git | PASS | PASS | |
| openssl-selfsigned-cert | err:unknown_agent_error | **PASS** | recovered |
| sqlite-db-truncate | err:unknown_agent_error | err:parse_error | |
| fibonacci-server | err:unknown_agent_error | **PASS** | recovered |
| write-compressor | err:unknown_agent_error | err:unknown_agent_error | |
| nginx-request-logging | fail | fail | |

Agent errors fell from **7 to 3**; two of the four that stopped erroring became
genuine attempts that simply failed on merit. 18.9 min wall (baseline 17.9),
171,562 in / 19,401 out tokens. Three overflow recoveries fired during the run.

Of the brief's three named targets, **simple-sheets-put** was recovered;
csv-to-parquet and sqlite-db-truncate were not — though both passed in the
iteration run `runs/opt-terminus-1/` (3/3), so they sit right at the model's
reliability edge rather than being structurally broken. The two extra recoveries
(openssl-selfsigned-cert, fibonacci-server) are tasks neither dsh nor pi solved.

## A further fix, made after `cmp-terminus-opt` and NOT included in it

All three remaining non-passes (sqlite-db-truncate `parse_error`,
sanitize-git-repo and write-compressor `unknown_agent_error`) turned out to be
the *same bug in the recovery path itself*: at `max_tokens=4096` the recovery
call overflows exactly like the call it is rescuing — 4096 completion tokens,
8.5K characters of low-effort reasoning, empty content. Giving the rescue a
smaller budget than the thing it rescues was simply wrong.

`RECOVERY_MAX_TOKENS` is now an escalating list, default `16384,32768`, and the
recovery logs each escalation. Verified live against the serve (a forced
overflow on a hard sqlite prompt now recovers into a valid `CommandBatchResponse`)
and on csv-to-parquet, which resolved under it.

**The full verification run for this change did not complete** — `opt-terminus-2`
was killed externally twice, both times while the two longest tasks
(sanitize-git-repo, write-compressor) were mid-flight. Orphaned containers from
both attempts were torn down.

Because of this, `terminus_fix.py` on disk no longer matches what produced
`cmp-terminus-opt`. To reproduce that run byte-for-byte, add
`TERMINUS_RECOVERY_MAX_TOKENS=4096` to the environment. To run the newer,
better-justified configuration, use the defaults.
