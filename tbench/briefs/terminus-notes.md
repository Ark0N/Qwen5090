# terminus baseline — what was wrong and what works

## Root cause of the `smoke-terminus` failure

`runs/smoke-terminus/hello-world/*/agent-logs/episode-0/debug.json`, key
`original_response`:

```
Error code: 400 - {'error': {'code': 'response_format_not_supported',
 'message': 'only response_format {type:text} is supported',
 'param': 'response_format', 'type': 'invalid_request_error'}}
```

Terminus-1 asks for structured output twice over: the schema is in the prompt
*and* `CommandBatchResponse` is handed to `chat.chat(response_format=...)`.
`LiteLLM.call` only demotes that to a prompt-only schema when
`self._supports_response_format` is false, and that flag comes from
`get_supported_openai_params("openai/qwen3.8-27b")` — which reports the
**provider's** capabilities, so every `openai/*` model is assumed to take a
json_schema. NInfer does not. `drop_params=True` does not help for the same
reason: LiteLLM has no idea the param is unsupported here.

Result: 400 on every attempt, three tenacity retries in `LiteLLM.call` × three
in `Terminus._handle_llm_interaction` = 9 failed calls, agent executes zero
commands, `unknown_agent_error`.

Nothing else was wrong — not the env, not the api_base (debug.json shows it
resolved to `http://<5090-ip>:8000/v1/` from `OPENAI_API_BASE`), not the
model id, not `reasoning_content`. LiteLLM reads `choices[0].message.content`,
which this serve populates correctly alongside `reasoning_content`.

## The fix

`tbench/terminus_fix.py` — `TerminusQwen`, a Terminus-1 subclass that swaps in a
`LiteLLM` with `_supports_response_format = False`. The harness then falls back
to its own `llms/prompt-templates/formatted-response.txt`, i.e. the schema
travels in the prompt and the request body carries no `response_format`. The
model answers bare JSON that `CommandBatchResponse.model_validate_json` parses
unmodified (a fence-stripper is in there as belt and braces; it has not been
needed in any observed episode).

Verified twice, hello-world resolved both times, one episode each:
`runs/terminus-smoke-2/`, `runs/terminus-smoke-4/`.

## The zero-code alternative: `--agent terminus-2`

Terminus-2 never passes `response_format` to `chat.chat` — it prompts for plain
JSON (or XML, `-k parser_name=xml`) and parses with its own
`TerminusJSONPlainParser`. So it works against this serve **unmodified**:
`runs/terminus-smoke-3/`, resolved, no custom file.

Which to run for the harness comparison is a judgement call: terminus-1 is the
canonical Terminal-Bench baseline the published numbers use, terminus-2 is the
newer agent and needs no patch. Both are now smoke-clean.

## Traps for a full run (not hit by hello-world)

- `get_max_tokens("openai/qwen3.8-27b")` raises inside litellm (model unmapped).
  Terminus-1 never calls it; terminus-2 does, catches, and falls back to a
  **1,000,000-token** context limit — i.e. its context-unwinding/summarising
  path will never fire before the serve's real 252,928-token window is blown.
  Consider `litellm.register_model` or an explicit cap for long tasks.
- Terminus-2's default `max_episodes` is effectively unlimited (1,000,000).
  Terminus-1 defaults to 50. Cap terminus-2 with `-k max_episodes=...` if you
  want the two comparable, and to bound cost.
- Both agents accept `-k api_base=...`, `-k temperature=...`. `api_base` was not
  needed: `OPENAI_API_BASE` already reaches LiteLLM.
- Smokes were run with `--no-cleanup` on purpose — the default `--cleanup` does
  `docker compose down --rmi all`, which would delete the shared
  `tb__<task>__client` image out from under a concurrent run.
