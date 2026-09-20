"""Terminal-Bench installed-agent adapter for the DeepSeek Harness (dsh).

Installs dsh 0.1.1-rc.2 into the task container with the same layout the
5090 setup uses locally (runtime dir + headless profile reproducing the
published `minimal` preset), routes it at the qwen5090 NInfer serve, and
answers each task with one `dsh --profile headless "<instruction>"` shot.
"""

import io
import logging
import os
import shlex
import tarfile
from pathlib import Path

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

# --- effort sweep knob -------------------------------------------------------
# TB_EFFORT selects the reasoning effort for a whole run (low | medium | xhigh),
# defaulting to xhigh, which is what the cmp-*-opt runs measured.
EFFORTS = ("low", "medium", "xhigh")
DEFAULT_EFFORT = "xhigh"

# Tracks the version installed on the 5090 box (2026-09-20). Bumping this
# is a measurement decision, not a maintenance one: 0.1.5-rc.2 moved the
# persona to the system-prompt row's personaPrefix and removed the
# agent-presets mechanism, so a run pinned to 0.1.1-rc.2 composes its
# profile by a different route than the box does.
DEFAULT_DSH_VERSION = "0.1.5-rc.2"

# The model serve, for the provider route rendered into the setup script. Not
# hardcoded: the address of the box this was measured on has no business in the
# repo. Same variable app/scripts/terminal-bench.sh reads.
QWEN_URL = (os.environ.get("QWEN_URL") or "http://localhost:8000").rstrip("/")


# --- persona knob ------------------------------------------------------------
# TB_DSH_PERSONA selects the persona rules rendered into the headless profile
# (baseline | structured), defaulting to baseline, which renders the container
# persona byte-identical to every run in REPORT.md. `structured` appends the
# six rules of the self-optimization loop's winning persona
# (app/optimization/tb_agent.py, `structured`), which is what the TUI's
# qwen5090 preset now carries - this knob is how that promotion gets measured
# in the benchmark rather than assumed from the loop's own suite.
STRUCTURED_RULES = (
    "\n\n"
    "      Rules:\n"
    "      - Inspect before you change: list files and read the relevant ones first.\n"
    "      - Run commands in small steps and read their output; a failing command is\n"
    "        information, not failure.\n"
    "      - Never assume file contents or exit codes; verify with cat/ls/python3.\n"
    "      - Prefer one focused command per tool call; avoid commands that read from\n"
    "        stdin (they block the shell).\n"
    "      - Keep a clear final verification step that proves the task is done.\n"
    "      - When everything is verified, end with a short final message that does\n"
    "        not call any tools."
)
# `tuned` = structured + budget awareness. write-compressor passed persona12
# only because a valid file was on disk when the timeout hit, and
# pytorch-model-cli.hard sat at 5/6 polishing: the agent has no idea it is on a
# clock, so it should bank a working answer first.
BUDGET_RULE = (
    "\n"
    "      - Get a working answer in place early - a first version that satisfies the\n"
    "        task as stated - and only then improve it. Time is limited: a finished\n"
    "        first version beats an unfinished better one."
)
PERSONAS = {
    "baseline": "",
    "structured": STRUCTURED_RULES,
    "tuned": STRUCTURED_RULES + BUDGET_RULE,
}

# Where the in-container runner leaves what the trial directory would otherwise
# lose: the dsh session log (session.jsonl.zstd) and the captured output of
# each shot. The container does not survive the run - the one persona12 trial
# whose reasoning mattered most (write-compressor) had no record of it.
CONTAINER_LOGS = "/installed-agent/logs"


def collect_container_logs(session, logging_dir) -> None:
    """Copy CONTAINER_LOGS out of the task container into the trial's agent-logs/.

    Best effort by design: a trial must never fail over its logs.
    """
    if logging_dir is None:
        return
    try:
        stream, _stat = session.container.get_archive(CONTAINER_LOGS)
        buf = io.BytesIO()
        for chunk in stream:
            buf.write(chunk)
        buf.seek(0)
        with tarfile.open(fileobj=buf) as tar:
            tar.extractall(Path(logging_dir), filter="data")
    except Exception as exc:  # noqa: BLE001 - logs are optional, the result is not
        logging.getLogger(__name__).warning(
            "could not collect %s from the container: %s", CONTAINER_LOGS, exc
        )


def _persona_rules() -> str:
    """Persona rules for this run, read once from TB_DSH_PERSONA."""
    persona = (os.environ.get("TB_DSH_PERSONA") or "baseline").strip()
    if persona not in PERSONAS:
        raise ValueError(f"TB_DSH_PERSONA={persona!r} is not one of {tuple(PERSONAS)}")
    return PERSONAS[persona]


# --- output-cap knob ----------------------------------------------------------
# TB_DSH_MAX_TOKENS is the per-step output cap rendered into the route's model
# entry (pi-ai's default is 32768). A step that spends the whole cap on reasoning
# ends the turn with reason `max-tokens` and no tool call; the runners answer
# that with a continuation (see the setup scripts). Small values force the
# condition for testing that path.
DEFAULT_MAX_TOKENS = 65536


def _max_tokens() -> int:
    raw = (os.environ.get("TB_DSH_MAX_TOKENS") or str(DEFAULT_MAX_TOKENS)).strip()
    try:
        value = int(raw)
    except ValueError:
        raise ValueError(f"TB_DSH_MAX_TOKENS={raw!r} is not an integer") from None
    if value < 1:
        raise ValueError(f"TB_DSH_MAX_TOKENS={raw!r} must be >= 1")
    return value


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
        self._version = kwargs.get("version", DEFAULT_DSH_VERSION)
        self._effort = _effort()
        self._persona_rules = _persona_rules()
        self._max_tokens = _max_tokens()

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
        return {
            "version": self.version,
            "effort": self._effort,
            "qwen_url": QWEN_URL,
            # Appended to the persona's first line; empty for `baseline`, so the
            # rendered profile stays byte-identical to the published runs.
            "persona_rules": self._persona_rules,
            "max_tokens": str(self._max_tokens),
        }

    @property
    def _install_agent_script_path(self):
        return self._get_templated_script_path("dsh-setup.sh.j2")

    def perform_task(self, instruction, session, logging_dir=None):
        result = super().perform_task(instruction, session, logging_dir)
        collect_container_logs(session, logging_dir)
        return result

    def _run_agent_commands(self, task_description: str) -> list[TerminalCommand]:
        # The task goes to a file and dsh-headless-run (written by the setup
        # script) makes the one `dsh --profile headless "<task>"` shot from it,
        # keeping its output and retrying once on an empty turn.
        return [
            TerminalCommand(
                command=(
                    f"printf '%s' {shlex.quote(task_description)} "
                    "> /installed-agent/task.txt && "
                    "dsh-headless-run /installed-agent/task.txt"
                ),
                max_timeout_sec=float("inf"),
                block=True,
            )
        ]
