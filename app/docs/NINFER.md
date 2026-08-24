# The NInfer backend — the fast one

[NInfer](https://github.com/Neroued/ninfer) is a from-scratch C++/CUDA
inference engine that supports one GPU — the RTX 5090 — and a closed set of
five Qwen checkpoints. It is not a general model runtime, and that is the whole
point: everything in it is compiled for `sm_120a` ahead of time, with no JIT, no
Triton and no FlashInfer anywhere in the serving path.

One of its five artifacts is a repack of `unsloth/Qwen3.8-27B-NVFP4` — the same
weights this toolkit already serves through vLLM. So this is not a different
model. It is the same model, roughly twice as fast.

## What it actually buys you

Measured on an RTX 5090, NInfer's published figures against this toolkit's own
vLLM measurements (see [PERFORMANCE.md](PERFORMANCE.md)):

| | vLLM here | NInfer |
|---|---|---|
| decode, one request | ~80 tok/s @ 128K | **151–195 tok/s** (MTP3) |
| decode, 8 requests | — | **766 tok/s** aggregate |
| prefill, 7,680-token prompt | — | **8,340 tok/s** |
| prefill, ~90K-token prompt | 371 tok/s | — |
| prefill, 260,096-token prompt | *aborted at ~139K after 7 min* | **2,203 tok/s** |

The last row is the one that matters most. On the vLLM path the 262K window is
real but barely usable — pasting a large document can take minutes before the
reply starts, and past ~139K it stops being practical at all. That cliff is a
property of the `turboquant_4bit_nc` KV store and the GDN attention core on
that path, and it simply is not present here.

Two other differences worth knowing:

- **MTP works at every context.** On the vLLM path, speculative decoding has to
  be switched off above 128K because vLLM garbles output with a 4-bit KV cache
  (there is an upstream fix, `patch-mtp.sh`, but it is opt-in and single
  session). NInfer runs MTP3 over an int8 cache at every concurrency from 1 to 8.
- **It speaks Anthropic natively.** `POST /v1/messages` is implemented by the
  server itself, alongside OpenAI Chat Completions and Responses.

## What it costs

- **A closed set of five artifacts, and none of them is abliterated.** If you
  use the uncensored build, keep using vLLM — that is what it is there for.
- **A compile.** NInfer ships no binaries and has no install target; installing
  it means building C++/CUDA for your card. It happens once and is reused.
- **A separate ~21 GB download.** The `.ninfer` container is not a Transformers
  checkpoint, a safetensors distribution or a GGUF, so the weights you may
  already have downloaded cannot be reused.
- **Concurrency caps at 8**, fixed at startup, against vLLM's 16 here.

## Install it

**Windows** — either tick **Qwen3.8-27B via NInfer (fastest)** in the GUI's
Model dropdown and click Install, or:

```powershell
.\app\install.ps1 -Ninfer
```

**Linux:**

```bash
bash app/scripts/setup-ninfer.sh
```

Either way, the model is recorded as this machine's default, so **every later
start uses it with no flag** — a plain `Start Qwen 5090.cmd`, a bare
`.\app\run.ps1`, `bash app/scripts/serve.sh`, or the systemd service.

**One exception, and it is silent: an explicit `MODEL=` wins.** The recorded
default is only what `serve.sh` falls back to, so a `MODEL=` line left
uncommented in `~/.qwen5090/server.env` keeps the systemd service on whatever
it names — the service comes up healthy, on the right port, serving the old
backend, and nothing anywhere says why. `install-service.sh` writes that line
commented out for exactly this reason, but a machine whose owner pinned a
checkpoint by hand earlier will still have it set. Check it before concluding
the recorded default did not take:

```bash
grep -n '^MODEL=' ~/.qwen5090/server.env    # no output is what you want
```

Same rule for `CTX`, `MAX_SEQS` and `GPU_UTIL` — they are forwarded to
whichever backend runs, and NInfer reads some of them differently (see
Settings below). A `GPU_POWER_LIMIT` set there applies here too, and a cap
low enough to bite will hold decode below the figures above; the telemetry
file's `power.limit` column is the way to tell.

Check what is installed:

```bash
bash app/scripts/setup-ninfer.sh status
```

## Go back to vLLM

The build and the artifact are left on disk; only the recorded default changes:

```bash
bash app/scripts/setup-ninfer.sh --default-vllm
```

Or just ask for a model explicitly — `.\app\run.ps1 -Uncensored`,
`MODEL=unsloth/Qwen3.8-27B-NVFP4 bash app/scripts/serve.sh` — which always wins
over the recorded default.

## The five artifacts

| Model id | Size | Notes |
|---|---:|---|
| `neroued/Qwen3.8-27B-nvfp4-NInfer` | 21 GB | **the default.** Same weights as the Standard vLLM build |
| `neroued/Qwen3.8-27B-NInfer` | 18 GB | smaller; same reasoning scores, no published throughput campaign |
| `neroued/Qwen3.6-27B-nvfp4-NInfer` | 18 GB | previous Qwen release. Faster, and much better MTP acceptance (69% vs 46%) |
| `neroued/Qwen3.6-27B-NInfer` | 17 GB | smallest, slowest at prefill |
| `neroued/Qwen3.6-35B-A3B-NInfer` | 22 GB | MoE: 35B total, 3B active. **~593 tok/s** at one request. Text only |

Pick one by passing it as a model id anywhere the others go:

```bash
bash app/scripts/setup-ninfer.sh neroued/Qwen3.6-35B-A3B-NInfer
```

```powershell
.\app\run.ps1 -Model neroued/Qwen3.6-35B-A3B-NInfer
```

## Settings

`serve-ninfer.sh` takes the same environment variables as `serve.sh` wherever
they mean the same thing, and translates them:

| Variable | Default | Notes |
|---|---|---|
| `CTX` | `131072` | clamped to what the artifact fits — 252,928 for the Qwen3.8 NVFP4 one |
| `PORT` | `8000` | the same port vLLM uses; NInfer replaces that server rather than joining it |
| `MTP` | `1` | `--spec mtp --draft-tokens 3 --lm-head-draft` |
| `SPEC_TOKENS` | `3` | draft window, 1–5 |
| `KV_CACHE_DTYPE` | `int8` | `int8` or `bf16`. vLLM spellings (`fp8`, `turboquant_4bit_nc`) map to `int8` |
| `MAX_SEQS` | `2` | concurrent requests. The flag takes 1–8, but VRAM decides — see below |
| `KV_CAPACITY` | `auto` | `auto` takes everything left after the weights |
| `PREFIX_CACHE` | `1` | prefix reuse; worth keeping on for agent clients |
| `VISION` | `0` | images and video. Off by default because it costs allocations even when unused |
| `API_KEY` | unset | required as a bearer token / `x-api-key` when set |
| `GPU_UTIL` | — | **ignored.** NInfer sizes its KV pool from what is left rather than claiming a fraction up front |

`GPU_POWER_LIMIT` and `GPU_TELEMETRY` behave exactly as they do on the vLLM
path — the telemetry sampler is shared, so a crash on this backend leaves the
same record.

### `MAX_SEQS` accepts 1–8, but the card decides

The Engine's runtime reservation grows with concurrency, so the usable maximum
depends on how big a window you asked for. At `CTX=252928` on a 32 GB card,
measured 2026-08-24 by trying each value:

| `MAX_SEQS` | runtime reservation | KV pool | result |
|---|---|---|---|
| 1 | 9.01 GiB | 252,928 tokens (3952/3952 pages) | starts, 1.73 GiB slack |
| 2 | 9.75 GiB | 263,616 tokens (4119/7904 pages) | starts, 1.00 GiB slack |
| 4 | 10.14 GiB + 1 GiB headroom | — | **refuses to start**, ~424 MiB short |

The refusal is explicit and happens a second into startup, before the weights
matter:

```
minimum Engine runtime reservation requires 10892272384 bytes in addition to
1073741824 bytes of automatic headroom, but only 11541931008 bytes are
available after weights
```

3 is untested and lands within ~10 MiB of the limit on that trend, so treat
**2 as the ceiling at the full window**. Wanting more means asking for a
smaller `CTX`, not just a bigger number.

Note the KV pool is shared rather than carved per slot — at `MAX_SEQS=2` it
holds 263,616 tokens, so a single session can still use the whole 252,928-token
window. Raising this does not cost you context; it costs you headroom.

It matters most for agent clients that fan out: the [DeepSeek
Harness](DEEPSEEK-HARNESS.md) runs subagents, and at `MAX_SEQS=1` every one of
them serialises behind the others.

## Using it with Claude Code

The bridge works unchanged: NInfer serves the same OpenAI API on the same port.
One thing to set by hand — the bridge discovers the context window from
`/v1/models`, and only vLLM publishes `max_model_len` there, so tell it:

```bash
QWEN_CTX=252928 bash app/scripts/claude-code.sh run
```

Without that it assumes 131072 and stops less than half way into the window.

NInfer also implements `/v1/messages` itself, which in principle means Claude
Code could talk to it with no bridge at all. That is untested here, and the
bridge does four things the direct path would lose — it rewrites the
`reasoning_effort` this template rejects, disables thinking for the
small-budget background alias, strips `tool_choice` when WebSearch leaves no
callable tool behind, and routes auto mode's classifier to a non-thinking
alias. Try it if you like, but the bridge is the supported route.

## Requirements, and the one that bites

NInfer needs a **CUDA toolkit at 13.1 or newer** at build time. This is not the
driver: `nvcc` ships in the toolkit, and Ubuntu 24.04's own packaged toolkit is
CUDA 12.0, which cannot target Blackwell at all.

The setup script looks in three places, in this order:

1. a system toolkit (`nvcc` on `PATH`, or `/usr/local/cuda`) — what NInfer's own
   Dockerfile uses, and the best-understood option;
2. `/usr/local/cuda-13.x`;
3. the toolkit torch's CUDA wheels vendor inside the vLLM venv — the only one
   present in a stock WSL rootfs. It works, but the wheel puts its libraries in
   `lib/` where CMake looks in `lib64/` and ships no driver library, so the
   script builds a shim directory that mirrors both.

On Windows, `install.ps1 -Ninfer` runs the normal WSL setup first precisely to
get (3), skipping the 22 GB weights download since the artifact replaces it.

If the build fails in a way that looks like a toolkit problem, installing the
real toolkit from [NVIDIA](https://developer.nvidia.com/cuda-downloads) is the
first thing to try.

The rest is ordinary: `cmake >= 3.28`, `ninja`, `pkg-config`, a C++20 compiler,
and the ffmpeg and libcurl development headers. `setup-ninfer.sh` installs all
of them with apt. The ffmpeg headers are not optional even for text-only use —
NInfer's CMakeLists checks for them unconditionally.

## Rebuilding

The checkout tracks NInfer's default branch. After an upstream change:

```bash
bash app/scripts/setup-ninfer.sh --rebuild
```

Pin a specific commit or tag with `QWEN5090_NINFER_REF` if a rebuild ever
behaves differently from the one you measured. The commit a build came from is
recorded in `~/.qwen5090/ninfer/built-from.txt`.

## Where things live

```
~/.qwen5090/ninfer/src/            the checkout
~/.qwen5090/ninfer/build/          the CMake build tree
~/.qwen5090/ninfer/bin/            ninfer-serve, ninfer
~/.qwen5090/ninfer/models/         the .ninfer artifacts
~/.qwen5090/default-model          which model this machine starts by default
```

On Windows those are inside the WSL distro, so `.\app\move-to-drive.ps1` (which
relocates the whole distro) is how you move them to another drive. **Cleanup /
Uninstall** in the GUI unregisters the distro and takes all of it with it.
