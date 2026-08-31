"""Terminal-Bench installed-agent adapter for the DeepSeek Harness **TUI**.

Same runtime install and model route as dsh_agent.py, plus the
@deepseek-harness-tui/dsh-tui profile. Where the headless adapter answers a
task with one silent `dsh --profile headless "<task>"` shot (its README:
"successful runs keep stderr empty"), this one runs the real TUI inside the
task's tmux pane, so the trial's pane capture and asciinema cast show the
model thinking, calling tools and reading results - the same view a person
gets in a terminal.

Driving an interactive TUI from a blocking Terminal-Bench command works like
this: `dsh-tui-run` (written by the setup script) starts `dsh --profile
dsh-tui` in the FOREGROUND of the pane and a background watcher that waits
for the composer glyph, pastes the task through tmux's bracketed paste (a
multi-line task must not submit at its first newline), presses Enter, polls
the session's append-only log for the `turn/end` event, and sends Ctrl-C
twice so the TUI exits and the pane command completes. All four mechanics
were verified against dsh-tui 0.9.2 in a scratch tmux session on 2026-08-31.

Knobs: TB_EFFORT and TB_DSH_PERSONA (baseline|structured|tuned) as in dsh_agent.py; TB_DSH_TUI_PRESET
selects which shipped preset the session composes from - `standard` (the 25
tools a real TUI user gets) or `minimal` (bash + str_replace_editor, the
published benchmark composition) - with the persona swapped for the
benchmark's in either case.
"""

import os
import shlex

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

from dsh_agent import QWEN_URL, _effort, _persona_rules, collect_container_logs

TUI_VERSION = "0.9.2"  # the profile installed on the 5090 box, 2026-08-31
PRESETS = ("standard", "minimal")
DEFAULT_PRESET = "standard"
# The watcher's own ceiling on one turn; Terminal-Bench's
# --global-agent-timeout-sec is the real cap and is normally shorter.
MAX_TURN_SEC = 1500


def _preset() -> str:
    preset = (os.environ.get("TB_DSH_TUI_PRESET") or DEFAULT_PRESET).strip()
    if preset not in PRESETS:
        raise ValueError(f"TB_DSH_TUI_PRESET={preset!r} is not one of {PRESETS}")
    return preset


class DshTuiAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "dsh-tui-qwen5090"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._version = kwargs.get("version", "0.1.1-rc.2")
        self._effort = _effort()
        self._persona_rules = _persona_rules()
        self._preset = _preset()

    @property
    def _env(self) -> dict[str, str]:
        return {
            "QWEN5090_API_KEY": "sk-qwen5090-local",
            "DSH_HOME": "/opt/dsh-home",
            # The TUI's own default (`workspace-write`) still ASKS; a benchmark
            # turn that stops on an approval row never finishes. Same posture
            # Codeman's Run button and the headless minimal preset use.
            "DSH_PERMISSION_MODE": "danger-full-access",
        }

    def _get_template_variables(self) -> dict[str, str]:
        return {
            "version": self.version,
            "tui_version": TUI_VERSION,
            "effort": self._effort,
            "qwen_url": QWEN_URL,
            "persona_rules": self._persona_rules,
            "preset": self._preset,
            "max_turn_sec": str(MAX_TURN_SEC),
        }

    @property
    def _install_agent_script_path(self):
        return self._get_templated_script_path("dsh-tui-setup.sh.j2")

    def perform_task(self, instruction, session, logging_dir=None):
        result = super().perform_task(instruction, session, logging_dir)
        collect_container_logs(session, logging_dir)
        return result

    def _run_agent_commands(self, task_description: str) -> list[TerminalCommand]:
        # The task goes to a file (typed the same way the headless adapter types
        # its argument: a single-quoted literal with continuation prompts) and
        # the wrapper pastes it into the composer from there.
        return [
            TerminalCommand(
                command=(
                    f"printf '%s' {shlex.quote(task_description)} "
                    "> /installed-agent/task.txt && "
                    "dsh-tui-run /installed-agent/task.txt"
                ),
                max_timeout_sec=float("inf"),
                block=True,
            )
        ]
