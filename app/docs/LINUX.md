# Running on native Linux

This toolkit was built as a Windows 11 product: unzip, double-click, click
Install. That path provisions WSL2 and Ubuntu, because **vLLM is Linux-only** —
the Windows half exists purely to build a Linux box to run the model in.

If you *already* have Linux with an RTX 5090 in it, none of that is needed. The
scripts under `app/scripts/` are plain bash and run directly. You skip the
launcher, the WPF app, and WSL entirely.

Verified end to end on Ubuntu 26.04, RTX 5090 (32 GB), driver 595.84 / CUDA 13.2.

## What you need

| | |
|---|---|
| OS | Any modern Linux with glibc (verified on Ubuntu 26.04) |
| GPU | NVIDIA RTX 5090, or another Blackwell (`sm_120`) card with ≥ 24 GB |
| Driver | 570 or newer — `nvidia-smi` must list the GPU |
| RAM | 32 GB comfortable; **must exceed the largest weights shard** (see below) |
| Disk | ~20 GB weights + ~8 GB venv |
| Packages | `build-essential` (Triton shells out to a C compiler), `curl`, `python3` |

Install the compiler first — the setup script will tell you if it is missing,
but it cannot install it without root:

```bash
sudo apt-get install -y build-essential
```

## Setup

```bash
git clone https://github.com/Ark0N/Qwen5090.git
cd Qwen5090
bash app/scripts/setup-linux.sh
```

That is the same script the Windows installer runs inside WSL; it detects which
platform it is on and adjusts its advice. Six steps: GPU check, model access
check, build tools, `uv`, a Python 3.13 venv with vLLM at `~/.qwen5090/venv`,
and the ~20 GB model download. Re-running is safe and idempotent.

For the uncensored (abliterated) build, set `MODEL` — see
[Uncensored build](../../README.md#uncensored-build):

```bash
MODEL=sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4 bash app/scripts/setup-linux.sh
```

## Serving

```bash
bash app/scripts/serve.sh
```

Defaults to `CTX=131072` on port 8000, which is the fastest sensible
configuration (fp8 KV cache + MTP, ~80 tok/s). Every knob is an environment
variable — see the table in [the main README](../../README.md#for-power-users) and the
comments in `serve.sh` itself.

```bash
CTX=262144 bash app/scripts/serve.sh          # full native window (see below)
PORT=8080 MODEL=... bash app/scripts/serve.sh
```

Then point any OpenAI-compatible client at `http://localhost:8000/v1`. The API
key can be anything.

## Claude Code against your own GPU

```bash
bash app/scripts/claude-code.sh install   # adds a `qwen-claude` command
qwen-claude
```

`qwen-claude` starts the LiteLLM bridge (translating Anthropic `/v1/messages`
to vLLM's OpenAI API) and execs Claude Code against it, **inside its own
process** — your normal `claude` is untouched.

> Never `eval` the output of `claude-code.sh env` into your shell. Those
> variables redirect *every* `claude` started from that shell, including real
> Anthropic sessions, silently.

Full detail in [CLAUDE-CODE.md](CLAUDE-CODE.md).

## DeepSeek Harness against your own GPU

The other agent client, and on Linux it is the easier of the two: `dsh` speaks
the OpenAI API natively, so there is no bridge process at all — just a provider
route in its own settings file.

```bash
sudo apt-get install -y nodejs                    # 26.04 ships 22.22.1, new enough
bash app/scripts/deepseek-harness.sh install      # pnpm, then dsh itself
bash app/scripts/deepseek-harness.sh start        # writes the route, boots the Web UI
```

Then open <http://127.0.0.1:3080>. `install` deliberately does **not** install
Node — it will not put a language runtime on your box behind your back — so
that first line is yours to run. On releases older than 26.04, use `fnm` or
`nvm` into your home directory instead of the distro package.

`start` discovers everything else: which backend is on port 8000, what model it
is serving, and how big its context window is. Nothing is typed twice.

It works against a server on another machine, which is the whole point of it
being client-side:

```bash
QWEN_URL=http://<5090-ip>:8000 bash app/scripts/deepseek-harness.sh start
```

`service` installs a `--user` unit so it survives a reboot, and `share` puts it
on your tailnet over HTTPS (the UI itself stays on loopback — it runs shell
commands, and 0.0.0.0 would offer that to the whole LAN).

**On the NInfer backend, raise `MAX_SEQS` to 2.** The harness runs subagents
and NInfer fixes concurrency at startup, so the shipped `MAX_SEQS=1` serialises
them. 2 is the ceiling at the full 252,928-token window on a 32 GB card — see
[NINFER.md](NINFER.md) for why 4 refuses to start.

Full detail, and the five settings that decide whether requests are accepted at
all, in [DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md).

## Starting automatically at boot

`serve.sh` in a terminal dies with the terminal. To have the server come back
by itself after a reboot:

```bash
bash app/scripts/install-service.sh install
```

That writes a systemd **user** unit (no root: it runs as you and inherits the
`~/.qwen5090` venv, model cache and logs), enables lingering so it starts at
boot rather than at login, and starts it.

```bash
bash app/scripts/install-service.sh status     # unit state + does the API answer
bash app/scripts/install-service.sh logs       # follow the journal
bash app/scripts/install-service.sh uninstall  # remove it
systemctl --user restart qwen5090              # after changing settings
```

Settings live in **`~/.qwen5090/server.env`**, not in the unit, so changing the
model or the context is an edit plus a restart:

```bash
MODEL=sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
CTX=262144
MTP=1
QWEN5090_MTP_TQ_PATCHED=1
MAX_SEQS=1
GPU_UTIL=0.93
```

The generated file ships with the safe defaults and carries the 262K block
commented out, with a note that `patch-mtp.sh apply` has to come first.

Two details the unit handles that are easy to miss by hand:

- **`PATH`.** A systemd unit does not inherit a login shell's environment, and
  FlashInfer's JIT links with `c++` by that exact name. The unit sets an
  explicit `PATH` including `/usr/bin`, or the engine dies at exit code 127
  *after* the weights load.
- **`TimeoutStartSec=900`.** A cold start is weights, `torch.compile` and
  cudagraph capture — minutes. The default 90-second timeout would kill it
  mid-compile and systemd would call it a failed start.

If lingering could not be enabled (it needs authentication), the service starts
when you log in instead of at boot; `sudo loginctl enable-linger $USER` fixes
that.

## The full 262,144-token window

The model's native context is 262,144, but that is **not** the default, and the
reason is a chain of interlocking constraints:

1. An fp8 KV cache holds ~171,000 tokens on a 32 GB card. The full window needs
   ~9.1 GiB against the ~6.2 GiB free after the weights load.
2. So above `CTX=131072`, `serve.sh` switches the cache to
   `turboquant_4bit_nc`, which halves the per-token cost and fits comfortably.
3. But stock vLLM 0.27.1 **garbles output** when MTP speculative decoding runs
   over that 4-bit cache — repetition loops, behind an HTTP 200. So `serve.sh`
   turns MTP off, and the speed drops to ~49 tok/s.

You can have the window *and* the speed by fixing (3) at the source.

### The MTP × TurboQuant fix (upstream PR #40914)

The bug is that vLLM captures the MTP verify step as a context-free first-chunk
`flash_attn` FULL cudagraph — the capture dummy batch has `seq_len ==
query_len`, so the replayed graph never reads the KV cache
([vllm#40880](https://github.com/vllm-project/vllm/issues/40880)).
[PR #40914](https://github.com/vllm-project/vllm/pull/40914) routes uniform K+1
spec-verify batches through the decode kernel instead.

```bash
bash app/scripts/patch-mtp.sh status
bash app/scripts/patch-mtp.sh apply     # keeps a .pre40914.bak
bash app/scripts/patch-mtp.sh revert    # undo
```

Then serve with MTP kept on:

```bash
CTX=262144 MTP=1 QWEN5090_MTP_TQ_PATCHED=1 MAX_SEQS=1 GPU_UTIL=0.93 \
  bash app/scripts/serve.sh
```

`QWEN5090_MTP_TQ_PATCHED=1` alone is not enough — `serve.sh` also greps the
installed vLLM for the patch marker. Reinstall vLLM and the safe MTP-off
behaviour returns by itself, rather than silently serving corrupt output.

**`MAX_SEQS=1` and `GPU_UTIL=0.93` are not optional here.** MTP-3 adds draft
token slots and an MTP head; at the default `MAX_SEQS=16` the KV cache comes up
0.43 GiB short of a 262,144 window and vLLM refuses to start
(`estimated maximum model length is 237120`).

Measured on an RTX 5090 (32 GB), abliterated build, driving a display:

| | MTP off (stock) | MTP-3 (patched) |
|---|---|---|
| Generation | 52.6 tok/s | **139.3 tok/s** (2.65×) |
| KV cache | 339,077 tokens (1.29× window) | 377,487 tokens (1.44×) |
| Garble battery | clean | 15/15 clean |
| Concurrent sessions | up to `MAX_SEQS` | **1** |

Two caveats before you turn this on:

- **It patches a file inside the venv.** Any vLLM reinstall wipes it; re-run
  `patch-mtp.sh apply`. The script refuses to patch a layout it does not
  recognise rather than corrupting the file.
- **One session at a time.** MTP plus concurrency is unstable on this KV path,
  and at the full window the KV pool only holds ~1.1 sessions anyway. Fine for
  a single Claude Code session; not a multi-user server.

If you want concurrency instead of context, stay at `CTX=131072`: fp8 + MTP,
~80 tok/s, and `MAX_SEQS=16`.

## Or skip vLLM: the NInfer backend

The prefill ceiling described below is a property of the vLLM path, not of the
card. [NInfer](https://github.com/Neroued/ninfer) is a C++/CUDA engine compiled
for `sm_120a` that serves a repack of the same Qwen3.8-27B NVFP4 weights, and
on its published RTX 5090 numbers it clears a 260,096-token prompt at
2,203 tok/s where vLLM here manages 371 tok/s at 90K and gives up past ~139K.
Decode roughly doubles too, and MTP needs no patch at any context.

A native Linux box is the easy case for it: you already have a real CUDA
toolkit, which is the one requirement likely to cause trouble elsewhere.

```bash
bash app/scripts/setup-ninfer.sh     # compiles the engine, fetches a 21 GB artifact
bash app/scripts/serve.sh            # from here on this serves NInfer
```

The model is recorded in `~/.qwen5090/default-model`, so `serve.sh` and the
systemd unit pick it up with no flag. Back to vLLM:

```bash
bash app/scripts/setup-ninfer.sh --default-vllm
```

There is no abliterated artifact for this backend — that build stays on vLLM.
Full detail in [NINFER.md](NINFER.md).

## Prefill is the real limit, not the window

Retrieval accuracy holds across the whole 262K window, but prefill collapses
super-linearly above ~30K tokens on the 4-bit path:

```
prompt_tokens=  5,585    0.5 s   ~11,117 tok/s
prompt_tokens= 22,210    2.0 s   ~11,315 tok/s
prompt_tokens= 90,800  245.0 s   ~   371 tok/s
```

The symptom is GPU at 100% utilisation but only ~128 W and no scheduler stats
line for minutes. It reads as a hang and is not one. Prefix caching (on by
default with the 4-bit cache) makes this survivable for agent use, since Claude
Code resends the same large prefix every turn.

## The dashboard: what is loaded, and what the box is doing

The Windows GUI has status pills — model, GPU, server. Linux had nothing but the
server log and `nvidia-smi` in another terminal. This is the equivalent:

```bash
bash app/scripts/dashboard.sh          # http://127.0.0.1:8600
```

It shows the model and backend the server reports, whether the systemd unit is
up, GPU utilisation, power against the limit, temperature, clocks, PCIe link,
throttle state, VRAM with the processes holding it, CPU per core, load average,
and RAM and swap — refreshing every 2 seconds with four minutes of history
behind the sparklines.

**It is read-only on purpose.** There is no start, stop or reconfigure button;
those paths belong to `serve.sh`, `install-service.sh` and `systemctl`, which is
where the safeguards are. Nothing you can click here can take the server down.

It also imports nothing outside Python's standard library, so it still runs when
the venv is missing or half-rebuilt — which is one of the times you most want to
look at it. A fallen-off GPU is reported as its own state rather than a hang:
every `nvidia-smi` call is bounded, because a card that has dropped off the bus
makes `nvidia-smi` block rather than fail.

| Variable | Default | |
|---|---|---|
| `DASH_PORT` | `8600` | |
| `DASH_HOST` | `127.0.0.1` | `0.0.0.0` to reach it from the LAN — it warns when you do |
| `QWEN_URL` | `http://127.0.0.1:8000` | which server to ask; a remote one works |
| `DASH_ACCESS_LOG` | unset | `1` restores per-request logging |

To leave one running:

```bash
nohup bash app/scripts/dashboard.sh >/dev/null 2>&1 &
```

Two things it is worth watching for on this hardware: the **throttle** row
turning red (`at power cap` means the card is bumping `power.limit` — check the
telemetry file's `power.limit` column before reading anything into a throughput
number), and **VRAM** still held after the server is gone, which is a stuck
process rather than a busy one.

## Chassis fans: making them follow the GPU

The board's fan controller (a Nuvoton NCT6799D on the ROG Strix X670E-F) is
invisible to Linux until `nct6775` is loaded, so out of the box the only thing
managing airflow is the BIOS SmartFan curve — which is tuned for gaming bursts,
not for a 5090 pulling 350–600 W for an hour at a stretch.

```bash
sudo bash app/scripts/fan-curve.sh status      # what is bound, what is spinning
sudo bash app/scripts/fan-curve.sh test        # 8s ramp to full, then restore
sudo bash app/scripts/fan-curve.sh install     # module + unit + config, at boot
sudo bash app/scripts/fan-curve.sh uninstall   # hand the fans back to the BIOS
```

`install` loads the module, writes `/etc/modules-load.d/qwen5090-fans.conf` so
it survives a reboot, records the **current BIOS PWM value as a floor**, and
enables a systemd **system** unit. A system unit, unlike the rootless user unit
in "Starting automatically at boot" above: writing `/sys/class/hwmon/*/pwm*`
needs root and there is no way around that.

Settings are in `/etc/qwen5090/fan-curve.env` — edit and
`systemctl restart qwen5090-fans`. Two of them are safety properties rather
than preferences:

- **`FAN_FLOOR`** is a hard lower clamp recorded from the BIOS at install time.
  The daemon can raise fans above it and can never drive them below it, so the
  worst a bad curve can do is make the machine loud rather than hot. Lower it
  deliberately if you want a quieter idle — that is safe once you know which
  header drives what, and it is what buys back range if your BIOS baseline is
  already high.
- **`FAN_EXCLUDE`** lists channels the daemon must never write. **Channel 7 is
  the AIO pump on this machine** — `pwm=255` with the only live tach. A pump is
  not a fan and must not be modulated by a temperature curve.

Note that on this board only `fan7` reports RPM; `fan1`–`fan6` read 0 whether
or not something is connected, because ASUS routes those tach lines through its
own EC. So there is no software way to confirm a chassis PWM write did
anything — use `fan-curve.sh test` and your ears. It also means per-fan curves
are not practical here (`pwmconfig` identifies fans by stopping them and
watching RPM, and there is no RPM to watch), which is why all the chassis
channels are driven together as one group.

## Differences from the Windows path

| | Windows 11 | Native Linux |
|---|---|---|
| Entry point | `Start Qwen 5090.cmd` → WPF app | `bash app/scripts/setup-linux.sh` |
| Install | `install.ps1` (WSL2, Ubuntu, UAC, reboot) | not needed |
| Memory sizing | `.wslconfig` written by `install.ps1` | host RAM is already the real RAM |
| Status at a glance | GUI status pills | `dashboard.sh` — a local web page |
| Chat tab, Cleanup, install buttons | yes | no — use `chat.py` or any OpenAI client |
| Sharing on the LAN | `share.ps1` (netsh portproxy + firewall) | `serve.sh` already binds `0.0.0.0` |
| Logs | `%LOCALAPPDATA%\Qwen5090\logs` | `~/.qwen5090/logs` |

The `.ps1` files are inert on Linux; nothing needs deleting.

## Troubleshooting

**`nvidia-smi` fails** — install the driver (`sudo ubuntu-drivers install`) and
reboot. vLLM cannot see a GPU the driver cannot.

**`RuntimeError: Failed to find C compiler`, ~60 s into startup** — install
`build-essential`. Triton JIT-compiles kernels on the first CUDA call, well
after the weights load, so it reads like a model problem and is not.

**`/bin/sh: 1: c++: not found` during FlashInfer's JIT** — same cause. Note it
needs `c++` specifically, not just `gcc`; `build-essential` provides both.

**`Cannot allocate memory (12)` while loading weights** — the largest shard is
one private writable mmap, and Linux overcommit refuses a mapping bigger than
`MemAvailable + swap`. The abliterated build's single shard is 18.4 GiB. Free
RAM or add swap; `serve.sh` preflights this and tells you the numbers.

**Server 200s on `/v1/models` but 500s on the first chat** — the FlashInfer
prefill kernel JIT is failing. Not reachable on the TurboQuant path (it pins
`flash_attn_version=2`, so no JIT runs), but it can happen at `CTX=131072`.

**Empty replies behind an HTTP 200** — reasoning tokens count against
`max_tokens`. A small cap with thinking on returns `content=None` and
`finish_reason=length`. Pass `chat_template_kwargs: {"enable_thinking": false}`
for short answers.

**`Unexpected reasoning effort high`** — the chat template accepts `low`,
`medium` and `xhigh` only. `high` is a hard 400. The Claude Code bridge already
substitutes `QWEN_EFFORT` for exactly this reason. On NInfer the message reads
`reasoning effort 'high' is not supported by the loaded chat template`, and
`none` is additionally accepted there as a genuine thinking-off switch.

**`MISSING_CREDENTIAL: ... no API key for provider route "deepseek-official"`**
— the harness is configured but the model was never *selected*. Its
`agent-default-model` plugin ships pointing at DeepSeek's hosted API. Re-run
`deepseek-harness.sh config`, which sets it to your local route when you have
not chosen one yourself.

**`ERR_PNPM_IGNORED_BUILDS` during `deepseek-harness.sh install`** — pnpm 11.23
refuses to finish while a dependency's install script is undecided, *after*
having installed everything correctly. Current versions of the script write
that policy up front and judge success by whether the `dsh` binary exists. If
you hit it on an older copy, the install is fine — check
`~/.dsh-runtime/node_modules/.bin/dsh --version`.

**`context_length_exceeded ... 300052 tokens` in the server log** — that is the
harness's own context probe, not a failed request. NInfer publishes no context
window, so `config` overruns it on purpose and reads the real ceiling out of
the refusal. It is a `msgs=1 tools=0` request and appears once per `config`.
