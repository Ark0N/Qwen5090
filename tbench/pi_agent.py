"""Terminal-Bench installed-agent adapter for the pi coding agent.

Installs pi (npm `@earendil-works/pi-coding-agent`) into the task container,
declares the qwen5090 NInfer serve as a custom provider in pi's `models.json`,
and answers each task with one non-interactive `pi -p` shot.

Reasoning effort comes from TB_EFFORT (default xhigh) and is passed to pi as
`--thinking`, so a sweep varies only the thinking level on the same weights.
"""

import os
import shlex

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

PI_CONFIG_DIR = "/opt/pi-agent"
PROVIDER = "qwen5090"
MODEL = "qwen3.8-27b"

# --- effort sweep knob -------------------------------------------------------
# TB_EFFORT selects the reasoning effort for a whole run (low | medium | xhigh),
# defaulting to xhigh, which is what the cmp-*-opt runs measured.
EFFORTS = ("low", "medium", "xhigh")
DEFAULT_EFFORT = "xhigh"

# The model serve, for the provider route rendered into the setup script. Not
# hardcoded: the address of the box this was measured on has no business in the
# repo. Same variable app/scripts/terminal-bench.sh reads.
QWEN_URL = (os.environ.get("QWEN_URL") or "http://localhost:8000").rstrip("/")


def _effort() -> str:
    """Reasoning effort for this run, read once from TB_EFFORT.

    The serve answers low/medium/xhigh only: `high`, `minimal` and `max` are a
    hard 400 from the loaded chat template and `none` turns thinking off, so an
    out-of-range value is refused here - at construction, before any container
    starts - rather than at the first request of every task.
    """
    effort = (os.environ.get("TB_EFFORT") or DEFAULT_EFFORT).strip()
    if effort not in EFFORTS:
        raise ValueError(
            f"TB_EFFORT={effort!r} is not one of {EFFORTS} "
            "(the serve rejects anything else)"
        )
    return effort


class PiAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "pi-qwen5090"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._version = kwargs.get("version", "0.84.3")
        self._effort = _effort()

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

    def _get_template_variables(self) -> dict[str, str]:
        # `qwen_url` lands in the rendered models.json as the provider baseUrl.
        return {"version": self.version, "qwen_url": QWEN_URL}

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
                    f"--thinking {self._effort} -- {shlex.quote(task_description)}"
                ),
                max_timeout_sec=float("inf"),
                block=True,
            )
        ]
