# cc-worker scratch notes

## Bridge
- LiteLLM 1.98.0 (uv tool). Config: `tbench/litellm-bridge.yaml`, port 4001, bound 0.0.0.0.
- Verified on the host before any tb run:
  - `POST /v1/messages` -> text completion (non-stream) OK
  - `POST /v1/messages` `stream:true` -> full Anthropic SSE sequence OK
  - `POST /v1/messages/count_tokens` -> `{"input_tokens":53}` OK
  - tool-use translation: an Anthropic `tools` array came back as
    `{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}`, `stop_reason: tool_use` OK
- Container reachability: `docker run --rm alpine wget -qO- http://<bridge-host>:4001/health/liveliness`
  -> `"I'm alive!"`.
- litellm 1.98.0 already stubs `/api/event_logging/batch` specifically to keep Claude Code
  telemetry from 404ing — no extra work needed there.

## Observations
- The bridge emits an EMPTY `thinking` content block (start immediately followed by stop) ahead of
  the text block on streamed replies. Watch for Claude Code rejecting a signature-less thinking
  block when it replays assistant turns.
- `master_key: sk-qwen5090-local` in general_settings; the same string is the client credential.

## Traps hit (in order), and the fix for each
1. `user is not supported` (400). Claude Code sends `metadata.user_id`; LiteLLM maps it to
   OpenAI `user`, and NInfer 400s on params it does not implement instead of ignoring them.
   `drop_params: true` does NOT cover this — LiteLLM believes an `openai/` route supports
   `user`. Fix: per-deployment `additional_drop_params: ["user","metadata","store",
   "parallel_tool_calls"]`.
2. `reasoning effort 'high' is not supported by the loaded chat template` (400). This is the
   documented qwen5090 trap arriving by a new road: Claude Code sends an Anthropic
   `thinking.budget_tokens`, and LiteLLM's /v1/messages adapter buckets a large budget into
   `reasoning_effort=high`. Two config-level fixes were tried and BOTH failed:
   - `reasoning_effort: xhigh` in litellm_params — wins on `/v1/chat/completions` (verified:
     a request carrying `high` returns 200) but LOSES on `/v1/messages`, because the adapter
     derives reasoning_effort after the deployment params are merged.
   - `additional_drop_params: ["reasoning_effort"]` — no effect on the /v1/messages path for
     the same reason: the value is injected downstream of `_should_drop_param`.
   What works: a proxy `async_pre_call_hook` (`cc_hooks.py`, wired with
   `litellm_settings.callbacks`) that pops `thinking` (and `output_config.effort`) off the
   inbound Anthropic request. The adapter then derives nothing and the deployment's own
   `reasoning_effort` is what reaches the server.
3. Pre-empted, not observed: the `tool_choice` with no callable tool 400 (Claude Code's
   WebSearch is a server-side tool with no input_schema, so LiteLLM drops the tool and
   forwards the tool_choice). The same hook strips it only when nothing callable remains.

## Non-issues, checked
- `/v1/messages/count_tokens` — implemented by LiteLLM 1.98.0, returns a plain
  `{"input_tokens": N}`. Claude Code never 404'd on it.
- Onboarding — `~/.claude.json` is pre-seeded by cc-setup.sh.j2 with
  `hasCompletedOnboarding`/`hasTrustDialogAccepted`; `-p` never prompted.
- Claude Code logs `[claude-code:unrecognized_model] {"model":"qwen3.8-27b"}` and then works.
  It assumes a 200,000-token context for the unknown id (the serve offers 252,928), so the
  window is under-used, never over-run. `total_cost_usd` in its result JSON is a fiction
  computed from a Claude price sheet — ignore it.
- Streamed replies start with an EMPTY `thinking` content block (start immediately followed
  by stop). Harmless; Claude Code never rejected it.

## Resolved smokes
- `cc-smoke-3`, `cc-smoke-4`, `cc-smoke-5`: hello-world resolved, both tests passed,
  4 turns, `terminal_reason: completed`. cc-smoke-5 ran against the final config with the
  proxy freshly restarted, so the committed state is the state that passes.
- Proxy left RUNNING: pid in `litellm-bridge.pid` (2520056 at hand-off), port 4001,
  started from the tbench dir — the config path and `cc_hooks` import are both relative
  to it, so restart it from there or both break.
