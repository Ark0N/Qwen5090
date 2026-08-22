# DeepSeek Harness on your own 5090

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) is
DeepSeek's open-source agent runtime — a coding agent in the same shape as
Claude Code, MIT-licensed, where the model adapter, the tool registry and the
agent loop are all plugins. It ships a Web UI, a headless one-shot mode, and an
ACP surface.

This points it at the server on your 5090.

## No bridge here

The Claude Code path needs [a translating bridge](CLAUDE-CODE.md) because
Claude Code speaks the Anthropic API and vLLM serves the OpenAI one. The
harness has no such gap: its `pi-ai` adapter speaks OpenAI natively, so a
provider route in its own settings document is the whole integration.

```
dsh :3080 ──OpenAI /v1──> vLLM :8000        (Qwen NVFP4, on the GPU)
          └─OpenAI /v1──> llama.cpp :8001   (DeepSeek V4-Flash GGUF)
```

Nothing sits in between, and the harness never touches the serving path — it
is a client, so it works just as well from another machine.

## Quick start

On the machine you want to work from — not necessarily the 5090:

```bash
bash app/scripts/deepseek-harness.sh install     # dsh itself, via pnpm
QWEN_URL=http://<5090-ip>:8000 bash app/scripts/deepseek-harness.sh start
```

Then open <http://127.0.0.1:3080>, pick a workspace, and pick the model.

Over Tailscale, `<5090-ip>` is the PC's Tailscale IP (`tailscale ip -4`) or its
MagicDNS name, and the server has to be shared off localhost first — on the
Windows host that is `.\app\share.ps1` or the app's share checkbox.

## Commands

| | |
|---|---|
| `install` | installs `dsh` into `~/.dsh-runtime` (and pnpm, if missing) |
| `config` | writes the provider routes and exits — no server started |
| `start` / `stop` / `restart` | the Web UI on `127.0.0.1:3080` |
| `status` / `doctor` | what is running, what is configured, what answers |
| `service` | a systemd **user** unit, so it survives a reboot |
| `share` / `unshare` | publish it on the tailnet over HTTPS |
| `uninstall` | removes the unit, the shim and the runtime |

Knobs: `QWEN_URL`, `DEEPSEEK_URL`, `DSH_HOME`, `DSH_PORT`, `DSH_HOST`,
`DSH_TRUSTED_HOSTS`, `DEEPSEEK_CTX`, `DSH_VERSION`.

## Reaching it from another machine

`dsh web --host` accepts **only** `127.0.0.1` or `0.0.0.0` — its config schema
refuses anything else at boot:

```
$.host expected "127.0.0.1" | "0.0.0.0" but got "100.x.y.z"
```

So "bind it to the tailnet address" is not expressible. `share` gets the same
reach a better way:

```bash
bash app/scripts/deepseek-harness.sh share
```

That runs `tailscale serve` in front of a UI that stays on loopback, giving an
HTTPS URL reachable by your tailnet and nothing else. Prefer it over
`DSH_HOST=0.0.0.0`: the harness runs shell commands on your behalf, and
`0.0.0.0` offers that to the whole LAN with no authentication in front of it.

The UI checks the `Host` header, so name the address it will be reached by:

```bash
DSH_TRUSTED_HOSTS="tnode.example.ts.net:3080" bash app/scripts/deepseek-harness.sh restart
```

## What `config` writes, and why

It merges two routes into `~/.dsh/settings.yaml` under `llm-pi-ai.providers`
and leaves the rest of that file alone — the harness's own Settings → Models
page writes there too, and a wholesale render would delete what you configured
in the UI.

```yaml
llm-pi-ai:
  providers:
    qwen5090:
      apiKeyEnv: QWEN5090_API_KEY
      api: openai-completions
      baseURL: http://<5090-ip>:8000/v1
      compat:
        supportsDeveloperRole: false
        maxTokensField: max_tokens
        supportsReasoningEffort: true
      models:
        - id: sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
          contextWindow: 131072
          reasoningEfforts: { low: low, medium: medium, xhigh: xhigh }
```

Four things there are load-bearing:

- **`compat.supportsDeveloperRole: false`** — pi-ai decides a request's shape
  from the base URL, and an address it does not recognise is addressed as
  though it were OpenAI itself: a reasoning model's system prompt goes out as
  `role: "developer"`, which this template rejects.
- **`compat.maxTokensField: max_tokens`** — same reason; the OpenAI default is
  `max_completion_tokens`.
- **`reasoningEfforts`** — the key is the level a selector offers, the value is
  what goes on the wire. The chat template accepts `low`, `medium` and `xhigh`
  **only**; it answers 400 to `high`, which is the level most clients send by
  default. Declaring the map is what keeps an unusable level off the menu.
- **`apiKeyEnv`** — pi-ai refuses a route that names no credential, even for a
  keyless local server, so `config` writes a placeholder into `~/.dsh/.env`
  (mode 0600, and deliberately not in the logs directory — `collect-logs.ps1`
  zips that up for bug reports).

The base URL is configuration and the model id is discovery: a server that is
switched off keeps its configured models and just moves address, rather than
pinning the route to wherever it used to live.

## pnpm, not npm

`npm install @deepseek-ai/dsh` does not finish. Measured 2026-08-22 on a 29 GB
box: twelve minutes at 97% CPU, 3.3 GB resident and still climbing, with not
one file written. pnpm resolved the same 503 packages in about a minute. dsh is
a pnpm project itself, and `dsh plugin` shells out to `pnpm` by name, so it has
to be on `PATH` regardless.

Two related traps:

- Every published version is a prerelease, and a bare `pnpm add @deepseek-ai/dsh`
  resolved **0.1.0-rc.8** while the `latest` tag pointed at 0.1.1-rc.2. The
  script names the tag.
- pnpm 11 declines to run dependencies' install scripts and reads its
  allowlist from `pnpm-workspace.yaml` — it *ignores* `pnpm.onlyBuiltDependencies`
  in `package.json`, with a warning. It does not matter here: `node-pty`,
  `koffi` and the rest ship prebuilt binaries for `linux-x64`.

## Requirements

Node `^22.19.0 || >=24.0.0`, `python3` with PyYAML (for the settings merge),
and `curl`.
