# Brief: claude-code-via-bridge adapter

Make the Claude Code CLI run Terminal-Bench tasks against the qwen5090 serve through an
Anthropic-to-OpenAI bridge. Read briefs/CONTEXT.md first.

State so far:
- LiteLLM proxy is installed (uv tool: `litellm` on PATH). It can expose an
  Anthropic-format `/v1/messages` endpoint and route to any OpenAI-compatible backend.
- Terminal-Bench ships a claude_code installed agent
  (`terminal_bench/agents/installed_agents/claude_code/`) — read it. Its `_env` requires
  ANTHROPIC_API_KEY in the LAUNCHING environment and does not pass ANTHROPIC_BASE_URL,
  so you will subclass it.
- Task containers reach host services on this host's LAN or tailnet address
  (`TB_BRIDGE_URL`) — docker bridge gateways vary per compose network, so use
  that, not 172.17.0.1.

Your steps:
1. Write `tbench/litellm-bridge.yaml`: model_list mapping a model name (suggest alias
   `qwen3.8-27b`, plus a wildcard so any anthropic model name claude sends also routes)
   to `openai/qwen3.8-27b` with `api_base: http://<5090-ip>:8000/v1`,
   `api_key: sk-qwen5090-local`.
2. Start the proxy detached so it outlives your shell:
   `nohup litellm --config tbench/litellm-bridge.yaml --host 0.0.0.0 --port 4001 > tbench/litellm-bridge.log 2>&1 & echo $! > tbench/litellm-bridge.pid`
   Verify with curl: an Anthropic-style POST to `http://127.0.0.1:4001/v1/messages`
   (headers `x-api-key: sk-qwen5090-local`, `anthropic-version: 2023-06-01`) returns a
   completion; then verify reachability from a container:
   `docker run --rm alpine wget -qO- http://<bridge-host>:4001/health` (or similar).
3. Write `tbench/cc_agent.py` (class CCBridgeAgent) subclassing ClaudeCodeAgent,
   overriding `_env` to set: ANTHROPIC_API_KEY=sk-qwen5090-local,
   `ANTHROPIC_BASE_URL=http://<bridge-host>:4001`, ANTHROPIC_MODEL=qwen3.8-27b,
   ANTHROPIC_SMALL_FAST_MODEL=qwen3.8-27b, DISABLE_TELEMETRY=1,
   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 — and NOT reading os.environ (the stock
   class throws without ANTHROPIC_API_KEY in the host env).
4. Smoke until hello-world resolves: run-ids `cc-smoke-1`, `cc-smoke-2`, ...
   Known risks to check in the trial logs: /v1/messages/count_tokens support, streaming,
   tool-use translation, claude CLI wanting onboarding. Fix via litellm config or env.
5. Report per CONTEXT.md. Files you own: tbench/litellm-bridge.yaml, tbench/cc_agent.py,
   tbench/litellm-bridge.log/.pid, briefs/cc-notes.md (optional scratch).
   Leave the proxy RUNNING and record its pid.
