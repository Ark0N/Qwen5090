"""Terminal-Bench installed-agent adapter for the DeepSeek Harness (dsh).

Installs dsh 0.1.1-rc.2 into the task container with the same layout the
5090 setup uses locally (runtime dir + headless profile reproducing the
published `minimal` preset), routes it at the qwen5090 NInfer serve, and
answers each task with one `dsh --profile headless "<instruction>"` shot.
"""

import os
import shlex

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

# --- effort sweep knob -------------------------------------------------------
# TB_EFFORT selects the reasoning effort for a whole run (low | medium | xhigh),
# defaulting to xhigh, which is what the cmp-*-opt runs measured.
EFFORTS = ("low", "medium", "xhigh")
DEFAULT_EFFORT = "xhigh"


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


class DshAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "dsh-qwen5090"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._version = kwargs.get("version", "0.1.1-rc.2")
        self._effort = _effort()

    @property
    def _env(self) -> dict[str, str]:
        return {
            # Placeholder credential: the NInfer serve is keyless, but pi-ai
            # refuses a provider route that names no credential.
            "QWEN5090_API_KEY": "sk-qwen5090-local",
            "DSH_HOME": "/opt/dsh-home",
        }

    def _get_template_variables(self) -> dict[str, str]:
        # `effort` lands in the rendered settings.yaml as the
        # agent-default-model.reasoningEffort dsh sends on every request.
        return {"version": self.version, "effort": self._effort}

    @property
    def _install_agent_script_path(self):
        return self._get_templated_script_path("dsh-setup.sh.j2")

    def _run_agent_commands(self, task_description: str) -> list[TerminalCommand]:
        return [
            TerminalCommand(
                command=f"dsh --profile headless {shlex.quote(task_description)}",
                max_timeout_sec=float("inf"),
                block=True,
            )
        ]
