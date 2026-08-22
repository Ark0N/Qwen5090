"""Harbor agent adapter for the DeepSeek Harness (`dsh`).

Harbor ships about fifty agent adapters and none of them is dsh, so this is
what lets Terminal-Bench drive the harness against a model served on the 5090.

Point Harbor at it with the import path plus the endpoint::

    harbor run -d terminal-bench/terminal-bench-2-1 \\
      -a app.scripts.tb_dsh_agent:DeepSeekHarness \\
      -m sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4 \\
      --ak base_url=http://<5090-ip>:8000/v1 \\
      --allow-agent-host <5090-ip>

``--allow-agent-host`` is not optional: Harbor firewalls the agent phase, and
without it every request to the server is refused inside the container.

On reproducing the published 82.7
---------------------------------
That number is DeepSeek's own, measured with the harness's **minimal** agent
preset at the max thinking tier. `minimal` is mounted by the Web surface -
`dsh --profile web --dump-default-config` shows the `agent-presets` row with
`default: standard` - and the headless profile does not mount the preset
roster at all. So `minimal=True` here does not *select* that preset; it
reproduces what the preset is documented to do, by patching the composition:
the system prompt is fixed to the one sentence minimal uses, and tool mode is
left native so the agent has persistent bash plus the editor and nothing else.
Anything measured this way is an approximation of the published setup, and
should be reported as one.
"""

import json
import shlex
from typing import Any, override

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.agents.installed.node_install import nvm_node_install_snippet
from harbor.agents.model_connection import ModelConnectionSpec
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# The one sentence the minimal preset fixes the whole system prompt to.
MINIMAL_PERSONA = "You are a helpful software engineer assistant."


class DeepSeekHarness(BaseInstalledAgent):
    """Runs one Terminal-Bench task through `dsh --profile headless`."""

    SUPPORTS_ATIF = False
    SUPPORTS_RESUME = False
    # The endpoint arrives as a kwarg rather than through provider inference:
    # a self-hosted vLLM or llama.cpp server is not a provider Harbor knows,
    # and guessing one only produces a base URL that has to be overridden.
    MODEL_CONNECTION = ModelConnectionSpec(passthrough=True)

    _LOG = "/logs/agent/dsh.txt"

    def __init__(
        self,
        *args,
        base_url: str = "http://127.0.0.1:8000/v1",
        api_key: str = "sk-qwen5090-local",
        effort: str | None = "max",
        minimal: bool = True,
        context_window: int = 131072,
        max_tokens: int = 32768,
        dsh_version: str = "latest",
        tools_mode: str | None = None,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._effort = effort
        self._minimal = minimal
        self._context_window = int(context_window)
        self._max_tokens = int(max_tokens)
        self._dsh_version = dsh_version
        self._tools_mode = tools_mode

    @staticmethod
    @override
    def name() -> str:
        return "dsh"

    @override
    def get_version_command(self) -> str | None:
        return ". ~/.nvm/nvm.sh; $HOME/.dsh-runtime/node_modules/.bin/dsh --version"

    # ------------------------------------------------------------ install --
    @override
    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(environment, ("curl", "bash", "ca-certificates"))
        # pnpm rather than npm, and not as a preference: `npm install
        # @deepseek-ai/dsh` does not finish - twelve minutes at full CPU and
        # 3.3 GB resident with nothing written, measured on a 29 GB host. pnpm
        # resolves the same 503 packages in about a minute. Every published
        # version is also a prerelease, and a bare `pnpm add` picks 0.1.0-rc.8
        # over the newer 0.1.1-rc.2, so the tag is named explicitly.
        await self.exec_as_agent(
            environment,
            command=(
                "set -euo pipefail; "
                f"{nvm_node_install_snippet()} && "
                "curl -fsSL https://get.pnpm.io/install.sh | SHELL=/bin/bash sh - >/dev/null 2>&1 && "
                'export PNPM_HOME="$HOME/.local/share/pnpm" && '
                'export PATH="$PNPM_HOME:$PNPM_HOME/bin:$PATH" && '
                'mkdir -p "$HOME/.dsh-runtime" && cd "$HOME/.dsh-runtime" && '
                """printf '{"name":"dsh-runtime","private":true}\\n' > package.json && """
                f'pnpm add "@deepseek-ai/dsh@{self._dsh_version}" >/dev/null && '
                '"$HOME/.dsh-runtime/node_modules/.bin/dsh" --version'
            ),
            timeout_sec=900,
        )

    # -------------------------------------------------------------- config --
    def _settings_yaml(self) -> str:
        """The provider route, as the harness's settings document wants it."""
        model = {
            "id": self.model_name,
            "contextWindow": self._context_window,
            "maxTokens": self._max_tokens,
        }
        if self._effort:
            # key = the level a selector offers, value = the wire spelling.
            model["reasoningEfforts"] = {self._effort: self._effort}
        doc = {
            "llm-pi-ai": {
                "providers": {
                    "qwen5090": {
                        "displayName": "Qwen 5090",
                        "apiKeyEnv": "QWEN5090_API_KEY",
                        "api": "openai-completions",
                        "baseURL": self._base_url,
                        # pi-ai shapes a request from the base URL, and an
                        # address it does not recognise is addressed as though
                        # it were OpenAI itself - system prompt as `developer`,
                        # cap as `max_completion_tokens`. Both are refused by
                        # vLLM and by llama.cpp.
                        "compat": {
                            "supportsDeveloperRole": False,
                            "maxTokensField": "max_tokens",
                            "supportsReasoningEffort": bool(self._effort),
                        },
                        "models": [model],
                    }
                }
            }
        }
        # JSON is valid YAML, which avoids shipping a YAML writer into a
        # container that has no Python of its own.
        return json.dumps(doc, indent=2)

    def _patch_yaml(self) -> str | None:
        """Home-level composition patch: the minimal preset, approximated."""
        if not self._minimal:
            return None
        return json.dumps([{"id": "system-prompt", "config": {"persona": MINIMAL_PERSONA}}], indent=2)

    # ------------------------------------------------------------------ run --
    @override
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        env = dict(self.model_connection.env)
        env["QWEN5090_API_KEY"] = self._api_key
        env["DSH_HOME"] = "/home/agent/.dsh"
        if self._tools_mode:
            env["DSH_TOOLS_MODE"] = self._tools_mode

        writes = [
            'mkdir -p "$DSH_HOME" /logs/agent',
            f"cat > \"$DSH_HOME/settings.yaml\" <<'DSHCFG'\n{self._settings_yaml()}\nDSHCFG",
            # A route naming no credential is refused outright, even for a
            # keyless local server, so the placeholder has to exist.
            'printf "QWEN5090_API_KEY=%s\\n" "$QWEN5090_API_KEY" > "$DSH_HOME/.env"',
            'chmod 600 "$DSH_HOME/.env"',
        ]
        patch = self._patch_yaml()
        if patch:
            writes.append(f"cat > \"$DSH_HOME/cordis.patch.yml\" <<'DSHPATCH'\n{patch}\nDSHPATCH")

        await self.exec_as_agent(
            environment,
            command="set -euo pipefail; " + "; ".join(writes),
            env=env,
        )

        await self.exec_as_agent(
            environment,
            command=(
                ". ~/.nvm/nvm.sh; "
                '"$HOME/.dsh-runtime/node_modules/.bin/dsh" --profile headless '
                f"{shlex.quote(instruction)} "
                f"2>&1 </dev/null | stdbuf -oL tee {self._LOG}"
            ),
            env=env,
        )
