"""Terminal-Bench installed-agent adapter for Claude Code against qwen5090.

Claude Code speaks the Anthropic Messages API and nothing else, so the model
is reached through a LiteLLM proxy on this host that translates /v1/messages
into the OpenAI calls the NInfer serve understands (see litellm-bridge.yaml).

The stock ClaudeCodeAgent is unusable as-is for this: its `_env` reads
ANTHROPIC_API_KEY out of the launching environment (KeyError without one) and
never forwards ANTHROPIC_BASE_URL, so it can only talk to api.anthropic.com.
"""

import os
import shlex
from pathlib import Path

from terminal_bench.agents.installed_agents.claude_code.claude_code_agent import (
    ClaudeCodeAgent,
)
from terminal_bench.terminal.models import TerminalCommand

# Appended to Claude Code's own system prompt. Two measured failure shapes, both
# of the model rather than the harness, and neither one more wall-clock will fix:
#
#  - Premature end_turn. On fix-git the model wrote "Let me resolve it by taking
#    your Stanford version" as plain text with no tool call, Claude Code saw
#    stop_reason=end_turn and ended the session 36 s in, mid-merge-conflict.
#  - Runaway prose. Long narrated summaries are what pushed single responses past
#    the output cap on sqlite-db-truncate and write-compressor.
#
# Kept behavioural and task-agnostic on purpose — it says how to drive the loop,
# never anything about the tasks themselves.
CONTINUATION_PROMPT = (
    "You are running fully autonomously inside a benchmark container. There is "
    "no human to read you or answer you, and you get exactly one turn. "
    "Never end your turn to announce what you are about to do: if you have just "
    "described a next step, carry it out in the same turn with a tool call. "
    "Keep going until the task is actually finished and you have verified the "
    "result yourself, and only then stop. "
    "Be brief in prose: reason concisely, do not echo file contents back, and do "
    "not write up a summary report at the end. Prefer running a command over "
    "explaining one."
)

# The bridge listens on this host's tailnet address, not a docker bridge
# gateway: every task gets its own compose network and the gateway address
# differs per network, while the tailnet IP is reachable from all of them.
BRIDGE_URL = "http://<bridge-host>:4001"
MODEL_ID = "qwen3.8-27b"
API_KEY = "sk-qwen5090-local"

# Effort sweep knob. The serve accepts low/medium/xhigh and 400s on anything
# else, so an unrecognised TB_EFFORT falls back to the default rather than
# failing every request of a run.
EFFORTS = ("low", "medium", "xhigh")
DEFAULT_EFFORT = "xhigh"


def _effort() -> str:
    value = (os.environ.get("TB_EFFORT") or DEFAULT_EFFORT).strip().lower()
    return value if value in EFFORTS else DEFAULT_EFFORT


def _model_for_effort() -> str:
    """The bridge alias that carries this effort.

    The effort cannot ride on the request: Claude Code has no flag for it, and
    the `thinking` budget it does send is what cc_hooks.py has to strip (it
    becomes reasoning_effort=high, a 400 here). And it cannot ride on the proxy's
    environment either — the bridge is a long-lived process started well before
    any `tb run`, so TB_EFFORT set in the launching shell never reaches it.

    So it rides on the model name. litellm-bridge.yaml declares one deployment
    per effort, each pinning its own `reasoning_effort` and all pointing at the
    same served checkpoint; picking the alias picks the effort. That keeps the
    knob per-request rather than per-proxy, so two runs at different efforts
    cannot contaminate each other, and it makes the effort visible in the
    trial transcript (Claude Code echoes the model id it was given).
    """
    return f"{MODEL_ID}-{_effort()}"


class CCBridgeAgent(ClaudeCodeAgent):
    @staticmethod
    def name() -> str:
        return "claude-code-qwen5090"

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("version", "latest")
        super().__init__(*args, **kwargs)

    @property
    def _env(self) -> dict[str, str]:
        return {
            # Placeholder credential: the serve is keyless, but Claude Code
            # refuses to start without an API key and LiteLLM's master_key
            # gates the proxy.
            "ANTHROPIC_API_KEY": API_KEY,
            "ANTHROPIC_BASE_URL": BRIDGE_URL,
            # All three model slots point at the one served checkpoint. The
            # small/fast slot is used for background chores and the haiku slot
            # for auto-mode style classification; an unset slot sends a real
            # Anthropic model id that the bridge would have to guess at.
            # Every slot gets the effort-carrying alias: an unset slot would
            # send a real Anthropic model id, which the bridge's wildcard would
            # then serve at the default effort instead of the swept one.
            "ANTHROPIC_MODEL": _model_for_effort(),
            "ANTHROPIC_SMALL_FAST_MODEL": _model_for_effort(),
            "ANTHROPIC_DEFAULT_SONNET_MODEL": _model_for_effort(),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": _model_for_effort(),
            "ANTHROPIC_DEFAULT_OPUS_MODEL": _model_for_effort(),
            # 16384 was too low and cost two tasks outright. Reasoning tokens
            # are billed against max_tokens on this serve, and at xhigh a single
            # turn routinely spends >16K on thinking alone — Claude Code then
            # aborts the whole session with "response exceeded the ... output
            # token maximum" (write-compressor burned 65,664 output tokens in
            # three turns). 32000 is Claude Code's own default ceiling for this
            # slot and sits under the deployment's 32768.
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000",
            # No egress to Anthropic from a benchmark container.
            "DISABLE_TELEMETRY": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_BUG_COMMAND": "1",
            # Parity with the stock claude-code agent.
            "FORCE_AUTO_BACKGROUND_TASKS": "1",
            "ENABLE_BACKGROUND_TASKS": "1",
        }

    @property
    def _install_agent_script_path(self) -> Path:
        return self._get_templated_script_path("cc-setup.sh.j2")

    def _run_agent_commands(self, instruction: str) -> list[TerminalCommand]:
        escaped_instruction = shlex.quote(instruction)
        return [
            TerminalCommand(
                command=(
                    f"claude --verbose --output-format stream-json "
                    f"-p {escaped_instruction} "
                    f"--append-system-prompt {shlex.quote(CONTINUATION_PROMPT)} "
                    f"--allowedTools {' '.join(self.ALLOWED_TOOLS)}"
                ),
                min_timeout_sec=0.0,
                max_timeout_sec=float("inf"),
                block=True,
                append_enter=True,
            ),
        ]
