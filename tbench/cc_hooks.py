"""LiteLLM proxy pre-call hook for the Claude Code bridge.

Two things the config file cannot express, both measured against this serve:

1. Claude Code sends an Anthropic `thinking` budget on every request. LiteLLM's
   /v1/messages adapter buckets that budget into an OpenAI `reasoning_effort`,
   and a large budget becomes `high` — which this chat template rejects with a
   hard 400 (`reasoning effort 'high' is not supported by the loaded chat
   template`; it accepts low/medium/xhigh only). The derivation happens inside
   the adapter, *after* deployment litellm_params are merged, so neither
   `additional_drop_params` nor a `reasoning_effort` default in the config can
   displace it. Removing `thinking` from the inbound request is the only lever
   that lands: the adapter then derives nothing and the deployment's own
   `reasoning_effort` is what reaches the server.

   That is also what makes the TB_EFFORT sweep work. Because the effort is the
   deployment's rather than the request's, cc_agent.py selects it by naming an
   effort-suffixed model alias (`qwen3.8-27b-medium`, ...), and this hook must
   keep stripping `thinking` or the client's `high` would win over the swept
   value again.

2. `tool_choice` with no callable `tools` is a 400. Claude Code's WebSearch is a
   server-side Anthropic tool with no input_schema, so LiteLLM drops the tool
   and forwards the tool_choice anyway. Strip it only when nothing callable is
   left — dropping it unconditionally would defang a genuinely forced call.
"""

from litellm.integrations.custom_logger import CustomLogger

_ANTHROPIC_ROUTES = ("anthropic_messages", "acompletion", "completion")

# Effort sweep. cc_agent.py encodes TB_EFFORT in the model name it asks for
# (`qwen3.8-27b-medium`, ...), because neither the request nor this proxy's
# environment can carry it: Claude Code has no effort flag, and the proxy is
# started long before any `tb run`.
#
# The hook sets the effort rather than leaving it to the deployment's own
# `reasoning_effort`, because a value on the request BEATS the deployment's
# (measured). Setting it here makes the alias authoritative no matter what the
# client sent. It only survives to the serve because the deployments carry
# `allowed_openai_params: ["reasoning_effort"]` — without that, LiteLLM decides
# an unknown `openai/` model does not support reasoning and `drop_params: true`
# silently discards the field, which is exactly what it did before this sweep
# (every earlier run therefore used the template's own default effort).
_EFFORT_SUFFIXES = ("low", "medium", "xhigh")


def _effort_from_model(model):
    if not isinstance(model, str):
        return None
    for effort in _EFFORT_SUFFIXES:
        if model.endswith(f"-{effort}"):
            return effort
    return None


class CCBridgeHooks(CustomLogger):
    async def async_pre_call_hook(
        self, user_api_key_dict, cache, data: dict, call_type: str
    ):
        if not isinstance(data, dict):
            return data

        data.pop("thinking", None)

        effort = _effort_from_model(data.get("model"))
        if effort is not None:
            data["reasoning_effort"] = effort
        # `output_config.effort` is the newer spelling of the same knob and is
        # checked against the loaded template exactly the same way.
        output_config = data.get("output_config")
        if isinstance(output_config, dict):
            output_config.pop("effort", None)
            if not output_config:
                data.pop("output_config", None)

        tools = data.get("tools")
        callable_tools = [
            t
            for t in (tools or [])
            if isinstance(t, dict) and t.get("input_schema") is not None
        ] if isinstance(tools, list) else []
        if not callable_tools and "tool_choice" in data:
            data.pop("tool_choice", None)

        return data


proxy_handler_instance = CCBridgeHooks()
