"""Terminus-1 against the qwen5090 NInfer serve.

Three faults are fixed here, all found by reading the baseline run's episode logs.

1. **`response_format` is rejected.** NInfer answers any structured-output request
   with `400 response_format_not_supported: only response_format {type:text} is
   supported`. LiteLLM only demotes the schema into the prompt when it thinks the
   provider cannot take it, and it thinks every `openai/*` model can, so
   `drop_params=True` does not help. Forcing `_supports_response_format` off makes
   `LiteLLM.call` use the harness's own `formatted-response.txt` fallback instead.

2. **Thinking eats the whole output budget.** Terminus sends no `max_tokens`, so the
   serve's 8192 default applies -- and on this model reasoning tokens are billed
   against it. Every one of the seven `unknown_agent_error`s in the baseline run is
   the same record: `finish_reason: "length"`, `completion_tokens: 8192`, 28-32K
   characters of `reasoning_content`, and `content: ""`. LiteLLM turns that into
   `OutputLengthExceededError`, which terminus-1 explicitly refuses to retry at both
   tenacity layers, so the agent dies mid-task. Fix: raise the cap, and recover from
   an overflow by re-asking briefly instead of dying.

3. **`is_blocking` breaks every heredoc that does not end in `EOF`.** Blocking
   appends `; tmux wait -S done` to the last line, so a batch ending `PY\n` is sent
   as `PY; tmux wait -S done` -- the terminator is never recognised, the shell sits
   at a `>` continuation prompt, and the command times out. Terminus guards against
   exactly this but hardcodes the delimiter `EOF`. That single collision is what
   lost csv-to-parquet. Fix: recognise any heredoc delimiter, send the batch
   unblocked, and wait on a separate no-op so blocking semantics survive.

Effort is left at the template default (xhigh), the same as every other harness in
the comparison. The one exception is the overflow-recovery call, which drops to
`reasoning_effort=low` for that single retry -- it only ever runs on a turn that
already produced nothing.
"""

import json
import os
import re

from pydantic import ValidationError

from terminal_bench.agents.terminus_1 import Command, CommandBatchResponse, Terminus
from terminal_bench.llms.base_llm import OutputLengthExceededError, ParseError
from terminal_bench.llms.chat import Chat
from terminal_bench.llms.lite_llm import LiteLLM
from terminal_bench.terminal.tmux_session import TmuxSession

# The serve defaults to 8192, which xhigh reasoning exhausts on its own.
MAX_TOKENS = int(os.environ.get("TERMINUS_MAX_TOKENS", "16384"))
# The recovery turn thinks at low effort, but it must NOT be given a smaller budget
# than the turn it is rescuing: measured on cmp-terminus-opt, a 4096-token recovery
# overflows exactly the same way (4096 completion tokens, 8.5K characters of
# reasoning, empty content) and loses the task anyway. Escalate instead.
RECOVERY_MAX_TOKENS = [
    int(t) for t in os.environ.get("TERMINUS_RECOVERY_MAX_TOKENS", "16384,32768").split(",")
]

_FENCE_RE = re.compile(r"```(?:json)?\s*\n(.*?)\n?\s*```", re.DOTALL)
_HEREDOC_RE = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

OVERFLOW_NUDGE = (
    "\n\nIMPORTANT: your previous reply used the entire output budget on internal "
    "deliberation and returned no JSON, so it was discarded and nothing ran. Do not "
    "deliberate. Reply immediately with the JSON object and nothing else. Keep "
    "state_analysis and explanation to one short sentence each. If you are unsure "
    "what to do, issue one small diagnostic command and read its output next turn."
)


def _extract_json(response: str) -> str:
    """Pull the JSON object out of a reply that may carry fences or prose."""
    if not response:
        return response

    stripped = response.strip()
    try:
        json.loads(stripped)
        return stripped
    except ValueError:
        pass

    match = _FENCE_RE.search(response)
    if match:
        candidate = match.group(1).strip()
        try:
            json.loads(candidate)
            return candidate
        except ValueError:
            pass

    start = response.find("{")
    if start != -1:
        try:
            obj, _ = json.JSONDecoder().raw_decode(response[start:])
            return json.dumps(obj)
        except ValueError:
            pass

    return response


def _open_heredoc_delimiter(keystrokes: str) -> str | None:
    """Return the heredoc delimiter if this batch ends on one, else None.

    A blocking send appends `; tmux wait -S done` to the final line, which turns a
    heredoc terminator into an ordinary line and leaves the shell hanging.
    """
    delimiters = set(_HEREDOC_RE.findall(keystrokes))
    if not delimiters:
        return None

    lines = [line for line in keystrokes.split("\n") if line.strip()]
    if not lines:
        return None

    last = lines[-1].strip()
    return last if last in delimiters else None


class PromptSchemaLiteLLM(LiteLLM):
    """LiteLLM that never sends `response_format` and always sets `max_tokens`."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._supports_response_format = False

    def call(self, *args, **kwargs) -> str:
        kwargs.setdefault("max_tokens", MAX_TOKENS)
        return _extract_json(super().call(*args, **kwargs))


class TerminusQwen(Terminus):
    """Terminus-1 hardened for a local reasoning model on a minimal OpenAI serve."""

    @staticmethod
    def name() -> str:
        return "terminus-qwen5090"

    def __init__(
        self,
        model_name: str,
        api_base: str | None = None,
        temperature: float = 0.7,
        **kwargs,
    ):
        super().__init__(
            model_name=model_name,
            api_base=api_base,
            temperature=temperature,
            **kwargs,
        )
        self._llm = PromptSchemaLiteLLM(
            model_name=model_name, api_base=api_base, temperature=temperature
        )

    def _handle_llm_interaction(
        self,
        chat: Chat,
        prompt: str,
        logging_paths: tuple,
    ) -> CommandBatchResponse:
        try:
            return super()._handle_llm_interaction(chat, prompt, logging_paths)
        except OutputLengthExceededError:
            self._logger.warning(
                "Output budget exhausted by reasoning; retrying briefly at low effort."
            )
            return self._recover_from_overflow(chat, prompt, logging_paths)

    def _recover_from_overflow(
        self,
        chat: Chat,
        prompt: str,
        logging_paths: tuple,
    ) -> CommandBatchResponse:
        logging_path, prompt_path, response_path = logging_paths
        recovery_prompt = prompt + OVERFLOW_NUDGE

        if prompt_path is not None:
            prompt_path.write_text(recovery_prompt)

        last_error: Exception | None = None
        for budget in RECOVERY_MAX_TOKENS:
            try:
                response = chat.chat(
                    recovery_prompt,
                    response_format=CommandBatchResponse,
                    logging_path=logging_path,
                    reasoning_effort="low",
                    max_tokens=budget,
                )
            except OutputLengthExceededError as e:
                self._logger.warning(
                    f"Recovery at max_tokens={budget} overflowed too; escalating."
                )
                last_error = e
                continue

            if response_path is not None:
                response_path.write_text(response)

            try:
                return CommandBatchResponse.model_validate_json(response)
            except (json.JSONDecodeError, ValidationError) as e:
                last_error = ParseError(f"Failed to parse recovery response: {e}")

        raise last_error if last_error is not None else ParseError("recovery failed")

    def _execute_commands(
        self,
        commands: list[Command],
        session: TmuxSession,
    ) -> tuple[bool, str]:
        for command in commands:
            keystrokes = command.keystrokes
            heredoc = _open_heredoc_delimiter(keystrokes)
            block = (
                command.is_blocking
                and heredoc is None
                and not keystrokes.strip().endswith("&")
            )

            try:
                session.send_keys(
                    keystrokes,
                    block=block,
                    max_timeout_sec=command.timeout_sec,
                )

                if heredoc is not None and command.is_blocking:
                    # The terminator has to own its line, so wait on a no-op that
                    # the shell only reaches once the heredoc'd command has exited.
                    session.send_keys(
                        "true\n",
                        block=True,
                        max_timeout_sec=command.timeout_sec,
                    )
            except TimeoutError:
                return True, self._timeout_template.format(
                    timeout_sec=command.timeout_sec,
                    command=command,
                    terminal_state=session.capture_pane(),
                )

        return False, session.capture_pane()
