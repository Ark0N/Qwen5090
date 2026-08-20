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

If that errors with *"is not digitally signed"*, run
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` first — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

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

> **Do not eval it just to run Claude Code, and never put it in a profile.**
> Those exports apply to *every* `claude` started from that shell, so your
> normal cloud session silently starts answering from Qwen instead — and in
> `~/.bashrc` or `~/.zshrc` it hijacks the cloud one permanently.
>
> `run` and the installed `qwen-claude` command exist precisely to avoid this:
> they set the variables inside their own process and `exec` Claude Code there,
> so the shell you launched them from — and plain `claude` — never sees them.
> Keeping a local model and a cloud subscription side by side is the normal
> case, not an edge case:
>
> ```bash
> claude          # your cloud Claude Code, untouched
> qwen-claude     # the same Claude Code, driven by the 5090
> ```
>
> If plain `claude` ever connects to Qwen unexpectedly, an old `eval` is still
> live in that shell — check with `echo $ANTHROPIC_BASE_URL` (it should be
> empty) and `grep ANTHROPIC ~/.bashrc ~/.zshrc ~/.profile`.

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

## Auto mode needs the classifier alias

Claude Code's **auto mode** (`⏵⏵ auto mode on`) does not decide on its own
whether a tool call is safe — it asks a model. Every tool call that is not
plainly read-only costs one extra request, and that request is unlike any
other the session makes:

| | |
|---|---|
| system prompt | ~115 KB of security rules (`claude auto-mode config` prints them) |
| streaming | no |
| model asked for | `claude-sonnet-5` |
| client-side timeout | 60 seconds, hard |

On a local 27B that combination is brutal. The prompt alone is ~30K tokens,
which on the 262K path is right at the prefill cliff, and if the alias it lands
on has thinking enabled the reply cannot arrive inside 60 s. The whole session
then behaves as if tools were broken, once per tool call:

```
Error: qwen5090 is temporarily unavailable (timed out), so auto mode cannot
determine the safety of WebFetch right now.
```

The model itself is fine — its own turns take a couple of seconds and its tool
calls are well-formed. Only the classification times out.

The lever is the **sonnet slot**: `claude-sonnet-5` is what auto mode asks for,
so `ANTHROPIC_DEFAULT_SONNET_MODEL` is what decides where the classifier lands.
The bridge points it at a third alias, `qwen5090-classifier` — same weights,
thinking off, output cap raised to 16384 for the classifier's second stage.
`CLAUDE_CODE_AUTO_MODE_MODEL` looks like the right knob and is not: it is
ignored, from the environment and from `settings.json` alike (measured against
Claude Code 2.1.238). One side effect worth knowing: `/model sonnet` inside a
session selects that alias too.

Measured after the fix, on the 5090 at `-Ctx 131072`: a one-shot auto-mode
session that runs a single mutating `Bash` call completes in **11 s**, tool
included, and Claude Code reports the routing itself at startup —
`[claude-code:unrecognized_model] {"model":"qwen5090-classifier",
"query_source":"auto_mode"}`. Before the fix the same shape of call failed at
60.05 s.

If classification is still too slow — a long conversation pushes the prompt
further up the prefill curve — turn auto mode off with `shift+tab` and approve
tools yourself, or serve at `-Ctx 131072`, where prefill is far cheaper.

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

**`... is temporarily unavailable (timed out), so auto mode cannot determine
the safety of ...`** — the tool call is fine; auto mode's classifier request
timed out. See [Auto mode needs the classifier
alias](#auto-mode-needs-the-classifier-alias). A bridge older than that fix
routes the classifier through the main thinking alias and every tool fails this
way; `bash app/scripts/claude-code.sh restart` re-renders the config.

## Security

The bridge binds loopback by default and holds a fixed local key; it is a
translation layer, not an authentication boundary. The Qwen server itself has
no authentication at all, so `share.ps1` scopes it to Private/Domain networks
only. Share on trusted networks (or a tailnet) and nowhere else.
