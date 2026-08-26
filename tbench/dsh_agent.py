"""Terminal-Bench installed-agent adapter for the DeepSeek Harness (dsh).

Installs dsh 0.1.1-rc.2 into the task container with the same layout the
5090 setup uses locally (runtime dir + headless profile reproducing the
published `minimal` preset), routes it at the qwen5090 NInfer serve, and
answers each task with one `dsh --profile headless "<instruction>"` shot.
"""

import shlex

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand


class DshAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "dsh-qwen5090"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._version = kwargs.get("version", "0.1.1-rc.2")

    @property
    def _env(self) -> dict[str, str]:
        return {
            # Placeholder credential: the NInfer serve is keyless, but pi-ai
            # refuses a provider route that names no credential.
            "QWEN5090_API_KEY": "sk-qwen5090-local",
            "DSH_HOME": "/opt/dsh-home",
        }

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
