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
dsh :3080 ──OpenAI /v1──> vLLM *or* NInfer :8000   (Qwen NVFP4, on the GPU)
          └─OpenAI /v1──> llama.cpp :8001          (DeepSeek V4-Flash GGUF)
```

Nothing sits in between, and the harness never touches the serving path — it
is a client, so it works just as well from another machine.

Port 8000 is whichever Qwen backend you have running: vLLM and NInfer replace
each other rather than run side by side, since both want the whole GPU.
`config` reads `owned_by` off `/v1/models` and adapts the route to the one that
answered — you do not tell it which.

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

## Running it on the Windows 11 machine itself

The harness is Linux software, so on the Windows PC it runs **inside WSL** —
the same Ubuntu distro the Qwen half already provisioned. The DeepSeek server
does not: `serve.sh` refuses the llama.cpp path in WSL, because the distro gets
a fixed slice of RAM (`.wslconfig`, 20 GB on a 32 GB PC) and a 62 GB model
cannot be served out of it. So it runs natively on Windows and the two halves
sit on opposite sides of the WSL boundary:

```
WSL (Ubuntu)                     Windows
  dsh :3080  ──── /v1 ────>  llama-server :8001   (DeepSeek GGUF, on the GPU)
  vLLM :8000  <── /v1 ────   (same distro, no boundary to cross)
```

That makes `localhost` mean two different things, which is the one thing to get
right here. For vLLM it is correct — that server is in the distro with you. For
llama.cpp it is the distro's own loopback and nothing is listening on it.

`start` and `config` resolve this themselves: on WSL they probe loopback, then
the default gateway, then the `resolv.conf` nameserver, and take the first that
answers on 8001. Mirrored networking makes loopback work; the default NAT mode
puts the host on the gateway. So the usual case needs no address at all:

```bash
bash app/scripts/deepseek-harness.sh start
```

If it finds nothing it says so, and the cause is almost always the Windows
firewall rather than the address: a rule opened for the tailnet is scoped to
that profile, and traffic arriving from the WSL adapter is a different one.
Either widen the rule or name the address yourself:

```bash
DEEPSEEK_URL=http://<5090-ip>:8001 bash app/scripts/deepseek-harness.sh start
```

Using the machine's own Tailscale address from inside its own WSL looks like a
detour and is a perfectly good answer — it is a single stable address that does
not move when WSL's NAT subnet changes on reboot.

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

agent-default-model:
  provider: qwen5090
  model: sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
```

Five things there are load-bearing:

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
- **`agent-default-model`** — configuring a route does not select it. The
  plugin ships pointing at `deepseek-official`, DeepSeek's *hosted* API, so a
  first run against a perfectly good local server fails with
  `MISSING_CREDENTIAL: … no API key for provider route "deepseek-official"`.
  That reads as a broken install and is really an unselected model. `config`
  therefore points it at a local route — but **only when you have not chosen
  one yourself**; a selection already in the file is left alone, like the rest
  of the document.

The base URL is configuration and the model id is discovery: a server that is
switched off keeps its configured models and just moves address, rather than
pinning the route to wherever it used to live.

### On NInfer, two of those change

`config` adapts when `owned_by` says `ninfer`. Both differences are measured
against a running server (2026-08-24, `qwen3.8-27b`):

- **The context window has to be probed.** Only vLLM publishes `max_model_len`
  on `/v1/models`; NInfer's model object carries `id`, `object`, `created` and
  `owned_by` and nothing else. Left alone, pi-ai falls back to its own 262,144
  — against a server actually started at 252,928, and the truncation that
  follows is silent. So `config` asks the server to refuse an oversized prompt
  and reads the real ceiling out of the refusal (`exceeding Engine max_context
  252928`). It costs one 1.5 MB request that is rejected at tokenization before
  any prefill: 0.18–0.21 s measured. `QWEN_CTX=<tokens>` pins it if the probe
  cannot run — behind a proxy that rewrites error bodies, say.
- **There is an `off` tier.** NInfer validates `reasoning_effort` itself, ahead
  of the template, and takes `none` — which genuinely disables thinking, with
  no `reasoning_content` in the reply. That is worth having: reasoning tokens
  are billed against `max_tokens`, so a small-cap chore with thinking on comes
  back as an empty string behind an HTTP 200. `minimal`, `high` and `max` are
  all still refused by the loaded template. The vLLM route keeps
  `low/medium/xhigh` — `none` is unverified there, and offering a tier that
  400s is exactly what this map exists to prevent.

One thing that does **not** need changing: dsh declares 25 tools by default,
and the `minimal` preset exists because that preamble costs llama.cpp 828
seconds. NInfer prefilled a 7,757-token turn of it at 6,019 tok/s, then reused
7,834 tokens of prefix on the next turn in 41 ms. Leave the full tool set on.

Concurrency is worth a thought, though. NInfer fixes it at startup and dsh runs
subagents, so `MAX_SEQS=1` serialises them. The flag accepts 1..8 but VRAM
decides: at the full 252,928 window on a 32 GB card the Engine's runtime
reservation leaves room for **2**, and 4 refuses to start outright
(`minimum Engine runtime reservation requires …`). See NINFER.md.

## Set the effort to medium, not xhigh

When we [benchmarked the harnesses](HARNESS-BENCHMARKS.md), the DeepSeek Harness
was the standout, and its best setting was a surprise: **`medium` reasoning
effort, not `xhigh`.** On the Terminal-Bench subset it scored:

| effort | solved (of 8 solvable) |
|---|:---:|
| low | 7 / 8 |
| **medium** | **8 / 8** |
| xhigh | 7 / 8 |

`medium` solved everything the model can do on that set, the best single result
of the whole four-harness study, and it did so *cheaper* than xhigh. It even
solved a task that xhigh got wrong: past a point, more reasoning was making the
answer worse, not better. The harness is unusually effort-robust either way (7 to
8 out of 8 at every level), so this is a free win rather than a knife-edge.

To set it, change the `reasoningEffort` under `agent-default-model` in
`~/.dsh/settings.yaml` (the [self-optimization loop](SELF-OPTIMIZATION.md) can
also land here on its own):

```yaml
agent-default-model:
  provider: qwen5090
  model: qwen3.8-27b
  reasoningEffort: medium      # was xhigh
```

This is measured on the 4-bit NVFP4 quant and a curated task set, so treat it as
a strong default rather than a law. The [full comparison](HARNESS-BENCHMARKS.md)
has the per-task detail and the other agents' very different effort curves
(terminus, for one, wants the opposite: `low`).

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
- pnpm 11 declines to run dependencies' install scripts and reads its policy
  from `pnpm-workspace.yaml` — it *ignores* `pnpm.onlyBuiltDependencies` in
  `package.json`, with a warning. Not running them is harmless here:
  `node-pty`, `koffi` and the rest ship prebuilt binaries for `linux-x64`
  (verified by loading node-pty's own prebuild and spawning a pty with it).
  What is **not** harmless is that pnpm 11.23 makes it fatal: it writes an
  `allowBuilds` map full of `set this to true or false` placeholders, prints
  `ERR_PNPM_IGNORED_BUILDS` and exits non-zero — *after* linking all 447
  packages and producing a working binary. `install` therefore writes that
  policy up front, and judges success by whether the `dsh` binary is there
  rather than by pnpm's exit status.

## Requirements

Node `^22.19.0 || >=24.0.0`, `python3` with PyYAML (for the settings merge),
and `curl`.

`install` brings its own pnpm but **not** Node — it will not install a language
runtime behind your back, so it stops with instructions if none is new enough.
On Ubuntu 26.04 the distro package clears the floor on its own
(`sudo apt-get install -y nodejs` → 22.22.1); on older releases use `fnm` or
`nvm` into your home directory rather than a system-wide install.
