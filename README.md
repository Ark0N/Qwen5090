# Qwen3.8-27B on your RTX 5090 — Windows 11

Your own private ChatGPT-class AI, running 100% on your gaming PC. No cloud, no
subscription, no data leaving your machine.

<div align="center">

### [⬇️ &nbsp;DOWNLOAD ZIP&nbsp; ⬇️](https://github.com/Ark0N/Qwen3.8-27B-NVFP4-RTX-5090/archive/refs/heads/main.zip)

[![Download ZIP](https://img.shields.io/badge/⬇_Download_for_Windows_11-Qwen3.8--27B_NVFP4-76b900?style=for-the-badge&logo=nvidia&logoColor=white)](https://github.com/Ark0N/Qwen3.8-27B-NVFP4-RTX-5090/archive/refs/heads/main.zip)

**Unzip → double-click `Start Qwen 5090.cmd` → click Install. That's it.**

</div>

<!-- Maintainer note: while this repo is private, the ZIP link only works for
     logged-in GitHub accounts with access. It works for everyone once public. -->

## Get started (3 steps)

1. **[Download the ZIP](https://github.com/Ark0N/Qwen3.8-27B-NVFP4-RTX-5090/archive/refs/heads/main.zip)**
   and unzip it anywhere (Desktop is fine).
   *Windows may flag the download: right-click the ZIP → Properties → tick
   **Unblock** before unzipping, and choose "More info → Run anyway" if
   SmartScreen asks.*
2. **Double-click `Start Qwen 5090.cmd`**, then click **Install / Repair** and approve
   the admin prompt. Everything is automatic: WSL2, Ubuntu, the AI engine, and
   the ~22 GB model download (15–40 min total). If Windows asks to reboot once,
   the app re-opens by itself afterwards — just click Install again to resume.
3. **Click Start server** on the Server tab, wait for the green light
   (a minute or two), and talk to your AI on the **Chat** tab.

You also get a **Qwen 5090** desktop shortcut, and an OpenAI-compatible API at
`http://localhost:8000/v1` that works with any AI app (Open WebUI, Continue,
Cline, ...) — API key can be anything.

## What you need

| | |
|---|---|
| 💻 OS | Windows 11 |
| 🎮 GPU | NVIDIA RTX 5090 (other RTX 50-series with ≥24 GB also work) |
| 🔧 Driver | NVIDIA 570 or newer ([get the latest](https://www.nvidia.com/drivers)) |
| 🧠 RAM | 16 GB minimum, 32 GB recommended (the installer sizes WSL's share for you) |
| 💾 Disk | ~45 GB free (model ~22 GB, Python + CUDA libraries the rest) |

## What you get

- **A choice of builds**, picked from the **Model** dropdown on the Setup tab:
  the standard Qwen3.8-27B, or an **uncensored** (abliterated) build whose
  refusal behaviour has been removed — a plain public download, no account. See
  [Uncensored build](#uncensored-build); you answer for what you generate with
  it.
- **The model**: Qwen3.8-27B — Alibaba's Apache-2.0, 27B multimodal model
  (released 2026-08-14) with 262K context and a reasoning dial, in NVIDIA's
  NVFP4 4-bit format built for your 5090's Blackwell tensor cores. Expect
  ~80–100 tokens/s.
- **A control panel** (pure Windows, no Electron): one-button install with live
  progress, server start/stop with health light, and streaming chat where the
  model's "thinking" renders dim. Thinking mode and effort (low → xhigh) are
  toggles, and **Share on network** makes the API usable from your other
  devices over Wi-Fi or [Tailscale](https://tailscale.com).
- **Logs & diagnostics**: every run is logged (`%LOCALAPPDATA%\Qwen5090\logs`
  on Windows, `~/.qwen5090/logs` in WSL). If anything breaks, click
  **Collect diagnostics** — it zips all logs + system info to your Desktop for
  a one-file bug report.
- **A clean exit**: **Cleanup / Uninstall** on the Setup tab removes everything
  the app installed — Ubuntu, the Python environment, and the ~22 GB model —
  freeing 20+ GB. Reinstalling later is one click.

## How it works

vLLM (currently the only engine that runs NVFP4) is Linux-only, so the
installer sets up **WSL2 + Ubuntu 24.04** — Microsoft's built-in Linux layer —
completely silently: no Linux prompts, a `qwen` user is created for you, and
your Windows NVIDIA driver powers the GPU inside WSL automatically. The
PowerShell scripts hide all of it; `localhost:8000` just works.

What `install.ps1` actually does: checks Windows 11 + driver ≥ 570 → enables
WSL2 (one reboot max, auto-resumes) → provisions Ubuntu unattended → installs
`build-essential` (vLLM's kernel compiler needs a C compiler at runtime) →
creates a Python 3.13 venv with `vllm`, `flashinfer`, and the CUTLASS DSL → downloads
[`unsloth/Qwen3.8-27B-NVFP4`](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)
(~22 GB, skippable) → desktop shortcut. Re-running is always safe.

## For power users

**Command line** (elevated PowerShell for install; scripts live in `app\`):

```powershell
.\app\install.ps1    # everything the GUI does; add -SkipDownload / -Unattended
.\app\install.ps1 -WslMemoryOnly   # only re-size the WSL VM from this PC's RAM
.\app\run.ps1        # serve on http://localhost:8000/v1
.\app\chat.ps1       # terminal chat (second terminal)
.\app\uninstall.ps1  # remove the distro, env, and model (what the Cleanup button runs)
```

<a id="uncensored-build"></a>
**Uncensored build.** Pick *Uncensored (abliterated)* in the Setup tab's
**Model** dropdown, or from PowerShell:

```powershell
.\app\install.ps1 -Uncensored   # one-time download (~19 GB), no account needed
.\app\run.ps1 -Uncensored       # serve it
.\app\run.ps1                   # back to the standard build
```

That is [`sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4`](https://huggingface.co/sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4) —
[huihui-ai's abliterated Qwen3.8-27B](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated)
re-quantized to NVFP4 with llm-compressor, Apache-2.0, MTP head preserved. It
is a **public download**: no Hugging Face account, no token. At ~19 GB it is
smaller than the standard build, so there is more room for KV cache.

It has **no safety guardrails**. It answers what the standard model declines,
including things that are illegal or dangerous to act on, and it is no more
accurate while doing so — abliteration removes refusals, not mistakes. What you
do with the output is on you. Both builds run entirely on your PC. The author
also notes it occasionally drops a closing parenthesis when generating code.

A third entry, *Uncensored - OrcaRouter (sign-in)*
([`orcarouter/Qwen3.8-27B-Uncensored-NVFP4`](https://huggingface.co/orcarouter/Qwen3.8-27B-Uncensored-NVFP4),
~23 GB), is a different abliteration of the same model. It is **gated**: sign in
at Hugging Face, accept the terms on the model page, create a **read** token at
[huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), and
paste it into the **HF token** box that lights up next to the dropdown. Stored
inside WSL, so you do it once.

Any other checkpoint works too: `run.ps1 -Model owner/name` (add
`install.ps1 -Model owner/name` to download it). Serving flags follow the model
id automatically — `serve.sh` knows which builds take `--kv-cache-dtype` from
the command line versus their own `config.json`, how many MTP tokens to draft,
and which need `--trust-remote-code`.

**Tuning:**

| Knob | Default | Notes |
|---|---|---|
| `run.ps1 -Ctx` | `131072` | Context window. The model can do 262,144 tokens, but that window's KV cache needs ~9 GB and only ~6 GB is free once the weights are loaded, so 128K is the most a 32 GB card will start with. Drop to `65536` if you are gaming at the same time. |
| `run.ps1 -Port` | `8000` | API port. |
| `run.ps1 -GpuUtil` | `0.90` | Fraction of VRAM vLLM may claim — the Windows desktop shares the GPU. |
| `run.ps1 -NoMtp` | off | Disables speculative decoding if it misbehaves. |
| `run.ps1 -Uncensored` | off | Serves the abliterated build instead (install it first). |
| `run.ps1 -Model` | `unsloth/Qwen3.8-27B-NVFP4` | Any Hugging Face repo id or a path inside WSL. |
| `chat.ps1 -NoThink` | off | Direct answers, no reasoning tokens. |
| `chat.ps1 -Effort low\|medium\|high\|xhigh` | model default | Qwen3.8's reasoning-effort dial. |

**API example** (sampling: temperature 0.7, top-p 0.8, top-k 20, presence 1.5):

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="local")
resp = client.chat.completions.create(
    model="unsloth/Qwen3.8-27B-NVFP4",
    messages=[{"role": "user", "content": "Explain NVFP4 in one paragraph."}],
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
print(resp.choices[0].message.content)
```

Tool calling and the `qwen3` reasoning parser are enabled on the server.
Quick benchmark while it runs (from WSL): `bash app/scripts/benchmark.sh`

**Use it from your phone/laptop (LAN / Tailscale):** tick **Share on network**
on the Server tab (one admin prompt per start), or run `.\app\run.ps1 -Share`.
Any device on your Wi-Fi or tailnet can then use `http://<this-PC's-IP>:8000/v1`
— for Tailscale, use the PC's Tailscale IP (`tailscale ip -4`) or MagicDNS
name. Sharing forwards the port out of WSL and opens Windows Firewall on
Private/Domain networks only (Tailscale counts as private; public Wi-Fi stays
blocked). The API has no authentication, so only share on networks you trust.
Undo anytime: `.\app\share.ps1 -Remove`. HTTPS alternative with zero setup:
`tailscale serve --bg 8000`.

**Why NVFP4 on a 5090:** the ~22 GB weights fit the 32 GB card with room for
a 128K context (FP8 KV cache + Qwen3.8's hybrid attention), it runs ~1.5×
faster than BF16 on Blackwell's FP4 tensor cores, and Unsloth's dynamic quants
keep accuracy close to the original checkpoint.

## Repo layout

```
Start Qwen 5090.cmd        ← double-click this — it's all most people need
README.md                  this file
app/                       everything under the hood:
  gui.ps1                    WPF control panel (install / server / chat)
  install.ps1                one-shot installer (also used headless by the GUI)
  run.ps1                    start the vLLM server (CLI)
  chat.ps1                   terminal chat client (CLI)
  share.ps1                  expose the API to LAN/Tailscale (used by -Share)
  uninstall.ps1              remove everything (distro + model); GUI 'Cleanup' button
  collect-logs.ps1           zip all logs + system state for bug reports
  scripts/                   Linux-side setup, serve, chat, benchmark
  docs/                      troubleshooting + performance notes
```

## Something not working?

See [app/docs/TROUBLESHOOTING.md](app/docs/TROUBLESHOOTING.md) and
[app/docs/PERFORMANCE.md](app/docs/PERFORMANCE.md), or click
**Collect diagnostics** in the app and share the ZIP it puts on your Desktop.

## Credits & license

- [Qwen team](https://huggingface.co/Qwen) — Qwen3.8-27B (Apache 2.0)
- [Unsloth](https://unsloth.ai) — dynamic NVFP4 quantization
- [vLLM](https://github.com/vllm-project/vllm) — inference engine

Tooling in this repo is MIT-licensed. Not affiliated with Alibaba, Unsloth,
NVIDIA, or the vLLM project.
