# Claude Code on your own 5090

Run [Claude Code](https://claude.com/claude-code) as an agent against this
server — no Anthropic account, no per-token billing, nothing leaving the
machine. It reads and writes your files, runs commands, and edits code exactly
as it normally does; only the model behind it changes.

Set expectations first: a 27B local model is not Claude. It handles
well-scoped edits, refactors, file spelunking and scripted chores. It is
weaker at long multi-step planning, and slower — see
[PERFORMANCE.md](PERFORMANCE.md).

## Why a bridge is needed

Claude Code speaks the **Anthropic** API (`/v1/messages`). vLLM serves the
**OpenAI** API (`/v1/chat/completions`) and has no `/v1/messages` endpoint at
all. Neither side bends, so a small [LiteLLM](https://github.com/BerriAI/litellm)
process sits between them and translates in both directions — streaming, tool
calls and token counting included.

```
claude ──Anthropic /v1/messages──> bridge :4000 ──OpenAI /v1──> vLLM :8000
                                  (LiteLLM)                     (your 5090)
```

The bridge is ~40 MB of Python, installs itself on first run into
`~/.qwen5090/bridge/venv`, and idles at essentially zero CPU.

## Quick start

**On the 5090 PC** — start the Qwen server first (the app's Run button, or
`.\app\run.ps1`), then:

```powershell
.\app\claude-code.ps1
```

That starts the bridge inside WSL and opens Claude Code there. If Claude Code
is installed on the Windows side instead, use `-Windows` and it prints the
three environment variables to paste into your PowerShell window.

**From another machine** (Linux, macOS, or WSL elsewhere) — share the server
first (`.\app\share.ps1` on the 5090 PC, or tick *Share on network*), then:

```bash
QWEN_URL=http://<5090-ip>:8000 bash app/scripts/claude-code.sh run
```

Over Tailscale, `<5090-ip>` is the PC's Tailscale IP (`tailscale ip -4`) or its
MagicDNS name.

Claude Code itself is installed with `npm install -g @anthropic-ai/claude-code`.

## Put it on your PATH

```bash
bash app/scripts/claude-code.sh install
```

Copies the script to `~/.qwen5090/claude-code.sh` and drops a `qwen-claude`
command in `~/.local/bin`, so a session can be opened from any directory
without remembering where the repo is:

```bash
qwen-claude                 # interactive session, current directory
qwen-claude -p "..."        # one-shot
qwen-claude status|doctor|stop|restart
```

Whatever `QWEN_URL` was set when you ran `install` is baked into the command —
install from a laptop with `QWEN_URL=http://<5090-ip>:8000` and `qwen-claude`
keeps pointing there. `QWEN_URL=` still overrides per invocation, and
`uninstall` removes the command again.

## Commands

```bash
bash app/scripts/claude-code.sh run       # start the bridge, then launch Claude Code
bash app/scripts/claude-code.sh start     # bridge only
bash app/scripts/claude-code.sh stop
bash app/scripts/claude-code.sh restart
bash app/scripts/claude-code.sh status
bash app/scripts/claude-code.sh doctor    # config + a live end-to-end request
bash app/scripts/claude-code.sh env       # print exports for your own shell
```

`env` is the escape hatch — `eval "$(bash app/scripts/claude-code.sh env)"` sets
up any Anthropic-API client, not just Claude Code.

## Settings

All are environment variables for the `.sh`, and flags on the `.ps1`.

| Variable | Default | What it does |
|---|---|---|
| `QWEN_URL` | `http://localhost:8000` | Where vLLM is listening. |
| `BRIDGE_PORT` | `4000` | Port the bridge listens on. |
| `BRIDGE_HOST` | `127.0.0.1` | Bind address. `0.0.0.0` when a Windows-native Claude Code has to reach into WSL. |
| `QWEN_EFFORT` | `xhigh` | `low`, `medium` or `xhigh`. **No other value is valid** — see below. |
| `FAST_THINKING` | `0` | Set `1` to let background chores think too (slower, no benefit). |
| `BRIDGE_KEY` | `sk-qwen5090-local` | Shared secret between Claude Code and the bridge. |
| `BRIDGE_HOME` | `~/.qwen5090/bridge` | Where the venv and generated config live. |

The model id and context length are **not** settings: the bridge asks
`/v1/models` at startup and configures itself, so it follows whichever
checkpoint you are serving.

## Three quirks this model has, and how the bridge handles them

These are not LiteLLM bugs; they are real properties of Qwen3.8's chat template
that any Anthropic-API client would hit.

**1. `reasoning_effort: "high"` is rejected.** The chat template accepts
`low`, `medium` and `xhigh` only, and returns a hard `400` for anything else:

```
Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.
```

Claude Code sends exactly `"high"` whenever extended thinking is on, so an
unconfigured bridge dies mid-session. The bridge drops the client's value
(`additional_drop_params`) and substitutes `QWEN_EFFORT`.

**2. Reasoning tokens are billed against `max_tokens`.** A request with a small
cap spends its whole budget thinking and returns `content: null` behind an
HTTP 200 — an empty reply, not an error. Claude Code fires a second, cheaper
model for background chores (conversation titles and so on) with a small cap,
so the bridge exposes a separate `qwen5090-fast` alias with thinking switched
off via `chat_template_kwargs`. Measured, at `max_tokens: 24`:

| | reply |
|---|---|
| thinking on | `''` (`stop_reason: max_tokens`) |
| thinking off | `'Tokyo'` (`stop_reason: end_turn`) |

**3. Claude Code does not recognise the model name**, so it assumes a 200K
context window and starts compacting early. The bridge reads the real
`max_model_len` from `/v1/models` and exports it as
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`. The cosmetic
`[claude-code:unrecognized_model]` line at startup is expected.

## Troubleshooting

**`no Qwen server answering at ...`** — the model server is not running, or is
not shared. Start it on the 5090 PC; for remote use run `.\app\share.ps1`.

**Claude Code says `Connection refused`** — the bridge is not up. Run
`bash app/scripts/claude-code.sh status`, and check `~/.qwen5090/logs/bridge.log`.

**Empty replies** — the model spent its token budget thinking. Lower
`QWEN_EFFORT`, or check you are not capping `max_tokens` yourself.

**Long silences on a big codebase** — expected, and it is prefill, not a hang.
Above ~30K tokens of context, prompt processing on the 262K path collapses from
~11,000 tok/s to a few hundred. The GPU sits at 100% utilisation but low
wattage. Serving at `-Ctx 131072` is dramatically faster per prompt; see
[PERFORMANCE.md](PERFORMANCE.md).

**`No module named 'proxy_server'`** — a broken LiteLLM/FastAPI pair. FastAPI
0.140.7 removed `get_flat_dependant`, which LiteLLM's proxy imports at startup,
but LiteLLM's own metadata still claims compatibility. The installer pins
`fastapi>=0.136.3,<0.140.7`. If you built the venv by hand, delete
`~/.qwen5090/bridge` and let the script rebuild it.

**Tools never fire.** The server must have been started by `serve.sh` — it
passes `--enable-auto-tool-choice --tool-call-parser qwen3_coder`, without
which the model emits tool calls as plain text and Claude Code cannot act.

## Security

The bridge binds loopback by default and holds a fixed local key; it is a
translation layer, not an authentication boundary. The Qwen server itself has
no authentication at all, so `share.ps1` scopes it to Private/Domain networks
only. Share on trusted networks (or a tailnet) and nowhere else.
