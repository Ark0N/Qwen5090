# Brief: terminus baseline — diagnose and fix

The terminus (built-in Terminal-Bench reference agent) smoke run failed; make it pass.
Read briefs/CONTEXT.md first.

State so far:
- Failed run: `tbench/runs/smoke-terminus/` — failure_mode `unknown_agent_error`, the
  agent executed ZERO commands (agent.log shows only asciinema start/clear/exit).
  Episode record: `runs/smoke-terminus/hello-world/*/agent-logs/episode-0/debug.json`.
- It was launched with env OPENAI_API_KEY=sk-qwen5090-local,
  `OPENAI_API_BASE=http://<5090-ip>:8000/v1`, OPENAI_BASE_URL=(same), and
  `--agent terminus --model openai/qwen3.8-27b`.

Your steps:
1. Read debug.json and the harness source for terminus
   (`terminal_bench/agents/terminus_1.py` + `terminal_bench/llms/lite_llm.py`) to find
   why the LLM call failed or its output was unusable. Check whether Terminus.__init__
   accepts kwargs like api_base (pass via `--agent-kwarg api_base=...`).
2. Re-smoke with run-ids `terminus-smoke-2`, `terminus-smoke-3`, ... until hello-world
   resolves. Consider: response-format/JSON parsing (terminus expects a structured JSON
   reply — the qwen serve emits reasoning_content plus content; maybe
   `--agent-kwarg` for prompt template, or terminus-2 (`--agent terminus-2`) handles it
   better — try variants and keep what works).
3. Report per CONTEXT.md — the exact working invocation matters most, including every
   env var. Files you own: briefs/terminus-notes.md (optional). You should not need to
   create any adapter files; if a tiny subclass IS needed, put it in
   tbench/terminus_fix.py.
