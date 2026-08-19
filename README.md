# Qwen3.8-27B-NVFP4 on Windows 11 + RTX 5090

Run **Qwen3.8-27B** — Alibaba's Apache-2.0, 27B dense multimodal model (released
2026-08-14) — locally on a Windows 11 gaming PC with an **RTX 5090**, using the
**NVFP4** 4-bit quantization built for Blackwell GPUs.

One double-click and you have a control panel that installs everything, runs an
OpenAI-compatible API, and chats with the model — entirely on your own hardware.

## Quickstart (GUI)

1. **[⬇ Download the ZIP](https://github.com/Ark0N/Qwen3.8-27B-NVFP4-RTX-5090/archive/refs/heads/main.zip)**
   and unzip it anywhere (or `git clone https://github.com/Ark0N/Qwen3.8-27B-NVFP4-RTX-5090.git`)
2. Double-click **`Qwen5090.cmd`**
3. Click **Install / Repair** (approve the admin prompt), wait for the ~17 GB
   download, then hit **Start server** and use the **Chat** tab

The installer is fully unattended: it enables WSL2, provisions Ubuntu 24.04
silently (no Linux username prompts — a `qwen` user is created for you),
installs vLLM, downloads the model, and drops a **Qwen 5090** shortcut on your
desktop. If Windows needs its one WSL reboot, the app re-opens by itself after
you log back in and you just click Install again to resume.

## Quickstart (command line)

```powershell
.\install.ps1        # run in an elevated (Administrator) PowerShell
.\run.ps1            # starts the server on http://localhost:8000/v1
.\chat.ps1           # chat with it from a second terminal
```

## Why NVFP4 on a 5090

- **It fits.** NVFP4 weights are ~17 GB; the 5090 has 32 GB. With an FP8 KV
  cache the default 128K context fits comfortably, and the full native 262K
  context is reachable (`.\run.ps1 -Ctx 262144`).
- **It's fast.** NVFP4 uses the 5090's Blackwell FP4 tensor cores: ~1.5× faster
  than the BF16 checkpoint, with community reports of ~80 tok/s single-stream.
  Multi-token prediction (speculative decoding) is enabled by default on top.
- **It's barely lossy.** Unsloth's dynamic NVFP4 quants keep accuracy close to
  the original checkpoint — unlike older 4-bit weight-only formats.

## Requirements

| Component | Requirement |
|---|---|
| OS | Windows 11 (build 22000+) |
| GPU | NVIDIA RTX 5090 (any Blackwell / RTX 50-series with ≥24 GB works) |
| Driver | NVIDIA ≥ 570 (580+ recommended) — Windows driver only, never install one inside WSL |
| Disk | ~25 GB free (weights + Python environment) |
| Software | WSL2 + Ubuntu 24.04 — `install.ps1` sets both up for you |

vLLM (the only engine with NVFP4 support today) doesn't run natively on
Windows, so everything Linux-side lives in WSL2. The PowerShell scripts hide
that completely: install, run, and chat from Windows; `localhost:8000` is
forwarded automatically.

## What the installer does

1. Verifies Windows 11, the NVIDIA driver version, and your GPU.
2. Enables WSL2 and provisions Ubuntu 24.04. In GUI/`-Unattended` mode this is
   silent: a `qwen` Linux user with passwordless sudo is created automatically.
   If the one-time WSL reboot is needed, a RunOnce entry re-opens the app after
   login (CLI users just re-run `install.ps1`; it resumes safely).
3. Inside WSL: installs [uv](https://docs.astral.sh/uv/), creates a Python 3.13
   venv at `~/.qwen5090/venv`, and installs `vllm`, `flashinfer`, and the
   CUTLASS DSL that NVFP4 kernels need.
4. Downloads [`unsloth/Qwen3.8-27B-NVFP4`](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)
   (~17 GB) into the Hugging Face cache. Skip with `-SkipDownload` (or the GUI
   checkbox).
5. Creates a desktop shortcut (disable with `-NoShortcut`).

## The GUI

`Qwen5090.cmd` opens a native WPF control panel (pure PowerShell — nothing to
install, no Electron):

- **Status bar** — GPU/driver, WSL + vLLM state, model download state, server
  health, all at a glance.
- **Setup tab** — one Install/Repair button with live installer logs and
  download progress; handles the admin elevation and reboot-resume for you.
- **Server tab** — start/stop, port, context-length picker (64K/128K/256K),
  MTP toggle, live vLLM logs. The server keeps running if you close the window.
- **Chat tab** — streaming chat with the model; thinking tokens render dim,
  with a thinking-mode toggle and Qwen3.8's `reasoning_effort` dial
  (low → xhigh). Sampling uses the recommended instruct settings.

## Using the API

The server speaks the OpenAI protocol — point any client at
`http://localhost:8000/v1` with any API key:

```powershell
curl.exe http://localhost:8000/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{\"model\": \"unsloth/Qwen3.8-27B-NVFP4\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'
```

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

Works out of the box with Open WebUI, Continue, Cline, and any other
OpenAI-compatible frontend. Tool calling and the `qwen3` reasoning parser are
enabled on the server.

## Tuning

| Knob | Default | Notes |
|---|---|---|
| `.\run.ps1 -Ctx` | `131072` | Context window. `262144` is the native max; lower to `65536` if you hit OOM while gaming. |
| `.\run.ps1 -Port` | `8000` | API port. |
| `.\run.ps1 -GpuUtil` | `0.90` | Fraction of VRAM vLLM may claim. The Windows desktop shares the GPU — don't go much higher. |
| `.\run.ps1 -NoMtp` | off | Disables speculative decoding if it misbehaves. |
| `.\chat.ps1 -NoThink` | off | Direct answers, no reasoning tokens. |
| `.\chat.ps1 -Effort low\|medium\|high\|xhigh` | model default | Qwen3.8's reasoning-effort dial. |

Recommended sampling (already set in `chat.ps1`): temperature 0.7, top-p 0.8,
top-k 20, presence penalty 1.5.

Quick throughput check while the server runs (from WSL):
`bash scripts/benchmark.sh`

## Repo layout

```
Qwen5090.cmd           double-click launcher for the GUI
gui.ps1                WPF control panel (install / server / chat)
install.ps1            one-shot installer (also used headless by the GUI)
run.ps1                start the vLLM server (CLI)
chat.ps1               terminal chat client (CLI)
scripts/setup-wsl.sh   Linux-side setup (called by install.ps1)
scripts/serve.sh       vllm serve with 5090-tuned flags
scripts/chat.py        streaming chat client (runs in the WSL venv)
scripts/benchmark.sh   single-stream tok/s check
docs/                  troubleshooting + performance notes
```

## Troubleshooting & performance

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) and
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Credits & license

- [Qwen team](https://huggingface.co/Qwen) — Qwen3.8-27B (Apache 2.0)
- [Unsloth](https://unsloth.ai) — dynamic NVFP4 quantization
- [vLLM](https://github.com/vllm-project/vllm) — inference engine

Tooling in this repo is MIT-licensed. Not affiliated with Alibaba, Unsloth,
NVIDIA, or the vLLM project.
