"""Terminal-Bench installed-agent adapter for the pi coding agent.

Installs pi (npm `@earendil-works/pi-coding-agent`) into the task container,
declares the qwen5090 NInfer serve as a custom provider in pi's `models.json`,
and answers each task with one non-interactive `pi -p` shot.

Reasoning effort is pinned to `xhigh` to match the dsh adapter, so the two
harnesses are compared at the same thinking level on the same weights.
"""

import shlex

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

PI_CONFIG_DIR = "/opt/pi-agent"
PROVIDER = "qwen5090"
MODEL = "qwen3.8-27b"
THINKING = "xhigh"


class PiAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "pi-qwen5090"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._version = kwargs.get("version", "0.84.3")

    @property
    def _env(self) -> dict[str, str]:
        return {
            # Placeholder credential: the NInfer serve is keyless, but pi keeps
            # a model unavailable until *some* credential is configured for its
            # provider. models.json reads this name via "$QWEN5090_API_KEY".
            "QWEN5090_API_KEY": "sk-qwen5090-local",
            # Config dir override, so the provider definition does not depend on
            # which user's $HOME the task container happens to run as.
            "PI_CODING_AGENT_DIR": PI_CONFIG_DIR,
            # No update checks / telemetry at startup: they add latency to every
            # task and can hang on a container with restricted egress.
            "PI_OFFLINE": "1",
            "PI_SKIP_VERSION_CHECK": "1",
        }

    @property
    def _install_agent_script_path(self):
        return self._get_templated_script_path("pi-setup.sh.j2")

    def _run_agent_commands(self, task_description: str) -> list[TerminalCommand]:
        # `--` ends option parsing, so an instruction that opens with a dash is
        # still a message rather than a flag.
        return [
            TerminalCommand(
                command=(
                    f"pi -p --provider {PROVIDER} --model {MODEL} "
                    f"--thinking {THINKING} -- {shlex.quote(task_description)}"
                ),
                max_timeout_sec=float("inf"),
                block=True,
            )
        ]
