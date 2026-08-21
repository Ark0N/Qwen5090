# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows 11 end-user toolkit that runs Qwen3.8-27B (NVFP4 4-bit, Blackwell-only) locally on an
RTX 5090. Remote: https://github.com/Ark0N/Qwen5090 (private, renamed from
Qwen3.8-27B-NVFP4-RTX-5090 on 2026-08-20; GitHub redirects the old URL). Users get it as a
ZIP; the entire UX is: unzip → double-click `Start Qwen 5090.cmd` → click Install.

**This file is tracked** (it was gitignored until 2026-08-20, when the owner asked for it to be
committed and synced). `.claude/` stays ignored — it is only harness runtime state.

## The core constraint: cross-platform development

*(Applies when developing from Linux **without a GPU**. If you are on the RTX 5090 PC itself, this
constraint is lifted — skip to "Continuing on the Windows 11 machine" below. If you are on a native
Linux box that has the 5090 in it, skip to "Running on native Linux" — you can run the real thing.)*

The original dev machine is **Linux**, but everything ships for **Windows 11 + WSL2**. PowerShell
cannot execute there, so nothing GUI/installer-side is ever runtime-tested locally — validate hard,
then tell the user what still needs a smoke test on the real machine.

| Task | Command |
|------|---------|
| Lint bash | `bash -n app/scripts/*.sh` (covers `claude-code.sh`) |
| Lint python | `python3 -m py_compile app/scripts/chat.py` |
| Parse PowerShell | portable pwsh (download tarball to scratchpad if missing): `[System.Management.Automation.Language.Parser]::ParseFile(...)` over `app/*.ps1` |
| Lint PowerShell | `Invoke-ScriptAnalyzer -Path app/ -Severity Error` in that pwsh (`Install-Module PSScriptAnalyzer -Force -Scope CurrentUser`) |

Runtime-test bash patterns locally when possible (e.g. the tee/trap logging and backgrounded-heredoc
constructs were verified by executing replicas in the scratchpad).

When a user reports a failure, first pin down **which build they ran**: the ZIP on their
machine is often several commits stale, and install.ps1's progress wording changes between
commits — `git log -S'<exact phrase from their transcript>' -- app/install.ps1` dates it
precisely. Then reproduce the failing shell construct as a replica in the scratchpad before
theorizing; a bash `ERR` trap reports the *line*, which is usually not the line that looks
guilty (a progress-reporting line can kill a download step).

## Continuing on the Windows 11 machine

This tree was handed over as a ZIP to the RTX 5090 PC itself, so on **that** machine the core
constraint above is lifted: `powershell.exe` runs, WSL2 is right there, and the GUI can actually be
clicked. Prefer real runs over static validation — parse-checking a `.ps1` proves nothing that
launching it doesn't prove better. `.claude/` was left behind on purpose (it was Codeman harness
config, Linux-only); `.git` came along, so history and `origin` are intact.

### Validating here (there is no test suite)

Validation is lint plus a smoke test against a live server — there are no unit tests, and
nothing to run a single test *of*. The toolchain on this PC is narrower than the Linux table
above assumes: `powershell.exe` is Windows PowerShell **5.1**, there is no `pwsh` and no
PSScriptAnalyzer installed, and the Windows `python3` is the Microsoft Store stub that only
prints an ad — Python lives inside WSL. What actually works:

| Task | How |
|------|-----|
| Parse every `.ps1` | PS 5.1 has the parser built in: `[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)`. No pwsh download needed. |
| Check BOM + line endings | first three bytes must be `EF BB BF`, and a regex for a newline not preceded by a carriage return must match zero times |
| Validate the GUI's XAML | `Add-Type -AssemblyName PresentationFramework`, extract the `$xaml = @'…'@` heredoc, `[System.Windows.Markup.XamlReader]::Parse($x)`. `$w.FindName('CmbEffort')` then reads dropdown contents and `SelectedIndex` **without launching the GUI** — this is how the effort/context lists were checked. |
| Lint bash / python | inside WSL: `bash -n app/scripts/*.sh`, `python3 -m py_compile app/scripts/chat.py` |
| Smoke-test the API | run `serve.sh`, then curl `/v1/chat/completions` — see "Measured on the 5090" for the probes that matter |

**The wsl.exe quoting trap is worse than the rule above suggests.** A `bash -c "…"` string
handed to `wsl.exe` from the Bash tool loses `$var` expansions *silently*: a
`for e in low medium; do … "$e" …; done` one-liner runs with `$e` empty and prints blanks
rather than failing, and `tail -n2` comes out the far side as
`tail: option used in invalid context`. Heredocs carrying regexes or `$1` arrive mangled.
The pattern that always works: **write the script to a file in the scratchpad, strip CRLF
with `sed -i 's/\r$//'`, then run `wsl -d $Distro -- bash -c "bash '/mnt/c/…/script.sh'"`.**
Same for editing repo files — write a Python patch script to a file and run it with WSL's
`python3`; never inline it. This cost four separate debugging detours in one session.

When editing `.ps1` from here, remember the Write tool emits no BOM and LF line endings, so
patch through a script that preserves both (read bytes, detect the BOM, join with CRLF,
write the BOM back) rather than with a plain text write.

Smoke tests, as of 2026-08-20 03:30 (all run on the 5090 itself):

1. **PASSED** — WSL setup (`scripts/setup-wsl.sh`, the GUI's `NONINTERACTIVE=1` branch): step 3/6
   apt-installed `build-essential`, and the Triton check printed "Triton kernel compiler OK."
   The *Windows* half of install.ps1 was not re-run (it needs UAC and its work was already done:
   distro registered, `.wslconfig` already memory=24GB/swap=8GB on this 32 GB PC).
2. **PASSED** — `.\app\run.ps1 -Uncensored`, after three fixes. Cold request 18 s (the FlashInfer
   JIT happens on the first message, not at startup), warm ~80 tok/s, FlashInfer + MTP both active.
   The vision-tower open question is **answered**: the encoder profile run completes normally
   ("Initial profiling/warmup run took ~36 s") and was never the problem.
3. **PARTIAL** — the GUI launches, the window title renders its em dash correctly, and the status
   pills populate (GPU/driver, "Ubuntu-24.04 + vLLM ready", model, server). The health ping was
   verified end to end: with a server started *outside* the GUI, the SERVER pill flipped
   "stopped" → "running on port 8000" on its own. Not click-tested: Setup-tab install, the Run
   button, streamed chat, Cleanup — WPF does not realize TabItem content in the UI Automation tree
   for a window driven headlessly, so the buttons cannot be reached programmatically. That part
   still needs a human at the keyboard.

### What the three fixes were (19927f9, 94326c6)

`build-essential` was only the first layer. vLLM's FlashInfer path JIT-compiles **CUDA** kernels,
and nvcc lives in the CUDA toolkit, not the driver:

- It fails **twice**, and the second is easy to misread: the sampler kernel dies during KV-cache
  sizing at startup, and the batch *prefill* kernel is not built until the first real request — so
  the server logs "Application startup complete", serves `/v1/models` with 200, then kills its own
  engine with a 500 on the first chat message.
- Ubuntu's toolkit is useless (24.04 ships CUDA 12.0, no sm120). Nothing needs downloading:
  **torch's CUDA wheels already vendor a full toolkit** at
  `$VENV/lib/python3.13/site-packages/nvidia/cu13`, nvcc included. Three snags: `ninja` lives in
  the venv's `bin/` which was never on `PATH` (FlashInfer shells out to it by bare name); the wheel
  uses `lib/` where FlashInfer links `-L$CUDA_HOME/lib64` and ships no bare `libcudart.so` symlink;
  and its nvcc is a patch ahead of torch's headers (13.3 vs 13.2), which CCCL rejects outright
  unless `-DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK` is passed.
- `--attention-backend` is a **vllm flag**; the `VLLM_ATTENTION_BACKEND` env var was removed in
  v0.27 and is now silently ignored — it looks exactly like a fix that does not work. Note it only
  reaches the main model: MTP's draft model re-selects FlashInfer regardless, so the no-toolkit
  fallback has to drop MTP too.
- **262144 needs a 4-bit KV cache to start on a 32 GB card**: weights ~19.5 GiB leave ~6.3 GiB,
  and an fp8 cache for that window wants 9.13 GiB. 0d49281 made serve.sh switch precision to fit
  rather than refuse, so 262144 starts everywhere it is asked for — but it is **no longer the
  default**: 131072 is (2026-08-21), because the fp8 path keeps MTP and runs ~80 tok/s against ~49
  and avoids the prefill cliff. See the KV-precision contract below, and "Measured on the 5090".
  The switch was **not** a bluescreen fix — see "The 0x116 bluescreens" below.

Both of the loose ends recorded here have since been fixed. The stale `.incomplete` blob (the reason
setup printed "downloaded 21G of ~19 GB") is now cleared by setup-wsl.sh before each download - by
mtime, `-mmin +60`, because huggingface_hub *resumes* from those files and the live download carries
the same suffix, so a blanket delete or a `du --exclude` would break the transfer or zero the
progress line. And the MODEL pill now reports the served model whenever a server is up, falling back
to the dropdown only when nothing is answering.

## Running on native Linux (2026-08-21)

**The product now targets two platforms**, and everything under `app/scripts/`
is the shared half. A third machine entered the picture: a native **Ubuntu 26.04**
box with a real RTX 5090 (driver 595.84, CUDA 13.2), no Windows and no WSL. The
scripts ran there unmodified — `setup-wsl.sh` completed all six steps, `serve.sh`
served, `claude-code.sh` bridged Claude Code. Only the *wording* was WSL-specific.

- `scripts/lib-platform.sh` — `qwen5090_is_wsl` / `qwen5090_platform` /
  `qwen5090_start_hint`. Sourced by setup-wsl.sh and serve.sh so their advice
  matches the platform: on WSL a dead GPU means the *Windows* driver and
  `wsl --shutdown`, and installing a Linux driver is actively harmful; on native
  Linux installing the driver is the fix. Same for the memory error — `.wslconfig`
  vs `swapon`.
- `scripts/setup-linux.sh` — three-line wrapper that execs setup-wsl.sh. It
  exists so a Linux user is not told to run "setup-wsl" on a box with no WSL.
  **Do not rename setup-wsl.sh**: install.ps1 references it by name.
- `scripts/install-service.sh` — `install`/`uninstall`/`status`/`logs` for a
  systemd **user** unit (no root; it runs as the user and inherits `~/.qwen5090`).
  Settings live in `~/.qwen5090/server.env` via `EnvironmentFile`, not baked into
  the unit, so changing model/context is an edit plus a restart. Two non-obvious
  bits: the unit must set `PATH` explicitly (a unit inherits no login shell, and
  FlashInfer links with `c++` by name), and `TimeoutStartSec=900` because a cold
  start is weights + torch.compile + cudagraph capture — the default 90 s would
  kill it mid-compile. `install` also enables lingering, or a user unit would
  only start at login rather than at boot.
- `app/docs/LINUX.md` — the full walkthrough; README gained an "Already running
  Linux?" section and a Linux block under power users.

**The `.ps1` layer is simply unused there.** No GUI, no install.ps1, no
share.ps1 (serve.sh already binds 0.0.0.0). Logs land in `~/.qwen5090/logs`.

### The build-tools trap is `c++`, not just `gcc`

FlashInfer's JIT compiles with nvcc but **links with `c++`**, by that exact name.
A toolchain with `gcc` but no `c++` gets three successful nvcc steps and then
`/bin/sh: 1: c++: not found`, exit 127, and the engine dies *after* the weights
have loaded — it reads like a model failure. `build-essential` provides both;
this only bites when someone assembles a compiler by hand.

Worth knowing for a no-root box: `binutils`, `libc6-dev` and `cc1` are already
present on a stock Ubuntu desktop, so only the gcc *driver*, `libgcc-*-dev` and
`cc1plus` are missing — extracting those debs into `~/.local` and grafting the
system `cc1` alongside produces a working compiler without sudo. It works, but
prefer `apt-get install build-essential` — the hand-built one gets no updates.

## MTP at the full 262,144 window: upstream PR #40914

The KV-precision contract below says the 4-bit switch *forces MTP off*, because
stock vLLM 0.27.1 garbles output with MTP over `turboquant_4bit_nc`. That is
still the correct default — but it is now **fixable**, and `scripts/patch-mtp.sh`
does it (`status` / `apply` / `revert`, idempotent, keeps a `.pre40914.bak`).

The bug: vLLM captures the MTP verify step as a context-free first-chunk
`flash_attn` FULL cudagraph (capture dummy batch has `seq_len == query_len`), so
the replayed graph never reads the KV cache — repetition collapse behind HTTP 200
(vllm#40880). PR #40914 routes uniform K+1 spec-verify batches through the decode
kernel with all-GPU synthetic args. Credit: the backport was lifted from
[MiaAI-Lab/Qwen3.8-27B-NVFP4-RTX-5090](https://github.com/MiaAI-Lab/Qwen3.8-27B-NVFP4-RTX-5090),
which solves the same collision the opposite way — it keeps MTP and patches,
where serve.sh refused the combination.

`serve.sh`'s interlock gained an escape hatch requiring **both**
`QWEN5090_MTP_TQ_PATCHED=1` **and** the patch marker physically present in the
installed `turboquant_attn.py`. An env var alone must never re-enable this: a
rebuilt venv silently restores the safe path, which is the whole point.

**`MAX_SEQS=1` and `GPU_UTIL=0.93` are load-bearing on this path.** MTP-3 adds
draft slots plus the MTP head; at the default `MAX_SEQS=16` the KV cache lands
0.43 GiB short of a 262,144 window and vLLM refuses to start with
`estimated maximum model length is 237120`. Measured 2026-08-21 on the Linux
5090, abliterated build, display attached:

| | MTP off (stock) | MTP-3 (patched) |
|---|---|---|
| generation | 52.6 tok/s | **139.3 tok/s** (2.65x) |
| KV cache | 339,077 tokens (1.29x) | 377,487 tokens (1.44x) |
| garble battery | clean | 15/15 clean, and clean at 900-token outputs |
| concurrency | up to MAX_SEQS | **1** (MTP + batching is unstable here) |

So 131072 remains the default — it keeps concurrency and needs no patched venv.
262144 + patch is opt-in, single-session, and must be re-applied after any vLLM
reinstall. The prefill cliff above ~30K tokens is unchanged by any of this.

## Hard rules that will break the product if violated

- **PowerShell targets Windows PowerShell 5.1** (`powershell.exe`, what the launcher invokes). No
  PS7-only syntax. Every `.ps1` must keep its **UTF-8 BOM** (5.1 reads BOM-less files as ANSI and
  mangles non-ASCII, e.g. the em dash in the GUI window title). The Write tool emits no BOM — re-add
  it (`printf '\xef\xbb\xbf'`) after creating a new `.ps1`.
- **Line endings are load-bearing**: `.gitattributes` forces LF for `*.sh`/`*.py` (CRLF breaks bash
  inside WSL) and CRLF for `*.ps1`. The "LF will be replaced by CRLF" warnings on commit are
  expected, not errors.
- **WSL invocation pattern**: always `wsl -d $Distro -- bash -c "<one string>"`. Never pass
  multi-arg commands directly after `--` (wsl.exe re-joins the raw command-line tail through the
  default shell; quoting only survives reliably via a single `bash -c` string). Escape `$` as
  `` `$ `` in PS double-quoted strings so bash expands it, and prefer single quotes inside the bash
  string over nested double quotes.
  **Never write an unquoted assignment prefix** like `PATH=$HOME/bin:$PATH cmd`. `$HOME`/`$PATH`
  are expanded before the inner bash parses the line, and WSL inherits the Windows PATH, which holds
  `C:\Program Files (x86)\...` on virtually every machine — the bare `(` then dies with
  `syntax error near unexpected token`, exit 2. Quote it, or avoid PATH in the command text
  entirely. This is what made the GUI report an installed Claude Code as missing (gui.ps1:1244,
  fixed 2026-08-21); `scripts/claude-code.sh:72` had it right all along with
  `export PATH="$HOME/.local/bin:$PATH"`.
- **Root layout is a product decision**: only `Start Qwen 5090.cmd`, `README.md`, `LICENSE` (plus
  dotfiles) at the root; all code under `app/`. Don't add root files — ZIP users must see one thing
  to click. The launcher name, the desktop shortcut, and install.ps1's RunOnce entry all reference
  each other by path; change one, change all.
- **`set -euo pipefail` + assignment is a landmine** in the `.sh` scripts: a bare
  `X=$(cmd | cmd)` inherits the pipeline's status, so a single failing `du`/`grep`
  aborts the whole install. Wrap fallible substitutions in `|| true`. This exact
  pattern killed the 17 GB download seconds after it started (setup-wsl.sh:64),
  and only in the GUI path — `NONINTERACTIVE=1` takes a *different branch* of
  setup-wsl.sh than a manual `bash setup-wsl.sh`, so hand-testing never hit it.
  When touching either branch, exercise both.
- **The weights need RAM, not just VRAM**: vLLM maps each shard with one private,
  *writable* mmap, and Linux heuristic overcommit refuses a mapping larger than
  `MemAvailable + swap`. WSL2 defaults to half the host's RAM (quarter of that as
  swap), so unsloth's single 21 GiB shard fails with `Cannot allocate memory (12)`
  on a 32 GB PC. `install.ps1` sizes `%USERPROFILE%\.wslconfig` from
  `Win32_ComputerSystem.TotalPhysicalMemory` (raise-only, backs the file up,
  `wsl --shutdown` after); `-WslMemoryOnly` runs just that step; `serve.sh`
  preflights the same arithmetic. Reproduce the failure locally with a sparse
  file + `mmap(PROT_READ|PROT_WRITE, MAP_PRIVATE)` — read-only/shared succeed.
- **Ubuntu's WSL rootfs ships no C compiler**, and Triton (the JIT vLLM compiles kernels with)
  shells out to one on the first CUDA call: `RuntimeError: Failed to find C compiler`, ~60 s into
  startup, *after* the weights have loaded, so it reads like a model problem and isn't.
  `scripts/lib-build-tools.sh` defines `ensure_build_tools` (apt-get build-essential; root or
  passwordless-sudo, `-n` so nothing hangs on a password) and is sourced by **both** setup-wsl.sh
  (step 3/6) and serve.sh, so pre-fix installs self-heal on the next Run. Setup then smoke-tests
  `triton.runtime.driver.active.get_current_device()` — warn-only — to surface a broken toolchain
  at install time instead of at first chat.
- `$args` is a reserved automatic variable in PowerShell — use `$psArgs` etc.
- `Start-Process -ArgumentList` gets a single pre-quoted string (array form doesn't quote paths
  with spaces on PS 5.1).

## Architecture (three layers, one direction)

1. **Launcher/GUI** — `Start Qwen 5090.cmd` → `app/gui.ps1`: a single-file WPF app (XAML string +
   `XamlReader`). It never does work itself; it shells out to the layer below.
2. **Windows scripts** — `app/install.ps1` (also run headless by the GUI with `-Unattended`),
   `run.ps1`, `chat.ps1`, `share.ps1`, `uninstall.ps1` (GUI Cleanup button; unregisters the distro
   incl. model, removes share rules/shortcut/RunOnce), `collect-logs.ps1`, `claude-code.ps1` (thin
   wrapper over the WSL-side bridge script, behind the GUI's Claude Code tab). All GUI-spawned children
   run hidden with stdout/stderr redirected to log files.
3. **WSL side (where everything real happens)** — vLLM is Linux-only, so `install.ps1` provisions
   Ubuntu-24.04 and `app/scripts/*.sh` run inside it: `setup-wsl.sh` (uv + Python 3.13 venv at
   `~/.qwen5090/venv` + model download), `serve.sh` (`vllm serve` with 5090-tuned flags),
   `chat.py`/`benchmark.sh` (clients against the OpenAI-compatible endpoint), and
   `claude-code.sh` (the Claude Code bridge — see its contract below).

### GUI concurrency model (gui.ps1) — don't fight it

The WPF dispatcher thread is never blocked. All patterns funnel through one 300 ms DispatcherTimer:
- **Child processes** (install/server/diagnostics): spawned via `Start-Process -PassThru` with
  output redirected to timestamped files under `%LOCALAPPDATA%\Qwen5090\logs`; the timer tails those
  files into the UI text boxes and polls `HasExited`.
- **Chat streaming**: a background runspace does the SSE read and pushes chunks into a
  `ConcurrentQueue`; the timer drains it into the RichTextBox (reasoning tokens = dim italic runs).
- **Server health**: an async `HttpClient.GetAsync` task is started on one tick and its result
  consumed on a later tick — pinged unconditionally so servers started outside the GUI are detected.
- Fatal script errors are caught by a top-level `trap`; event-handler exceptions by a
  `Dispatcher.UnhandledException` hook. Both log to `gui-*.log` and show a MessageBox.

### Contracts between layers

- **install.ps1 exit codes**: 0 = done, 1 = failed, **3010 = reboot required** (GUI offers reboot;
  a RunOnce entry re-opens the launcher after logon).
- **Unattended Ubuntu provisioning**: `wsl --install -d <distro> --no-launch` +
  `ubuntu2404.exe install --root`, then create a `qwen` user (passwordless sudo) and set it as
  default via `/etc/wsl.conf` + `wsl --terminate`. Falls back to the interactive OOBE window if the
  store launcher is missing. Re-running install is always safe (idempotent by design).
- **serve.sh env knobs** (set by run.ps1): `MODEL`, `CTX` (default **131072**; 262144 is the
  model's native max), `PORT`,
  `GPU_UTIL` (0.90, dropped to **0.85 on the 4-bit KV path** — see below; run.ps1 forwards it only
  when `-GpuUtil` is actually bound, because any value suppresses that default), `MTP`,
  `KV_CACHE_DTYPE`, `ATTN_BACKEND` (empty = let vLLM pick), `MAX_SEQS` (16),
  `PREFIX_CACHE` (0/1, **defaults on with the 4-bit cache** — same only-when-bound forwarding
  from run.ps1's `-PrefixCache` as `-GpuUtil` gets).
  `NONINTERACTIVE=1`/`SKIP_DOWNLOAD=1` for setup-wsl.sh.
- **KV precision follows the context, and MTP follows the KV precision.** fp8 holds ~171,000 tokens
  on a 32 GB card, so `CTX > 131072` switches to `turboquant_4bit_nc` (441,815 tokens of capacity at
  262144) **and drops GPU_UTIL to 0.85**. The profiler claims every byte inside the utilisation
  budget for the KV cache, so at 0.90 it sized 7.21 GiB / 441,815 tokens — 1.7× more than a 262,144
  window can use — and left Windows ~3.2 GiB. Too thin: the desktop's own footprint moves between
  vLLM's profiling pass and its allocation pass, and when it grows in between the allocation dies
  part-way (`Available KV cache memory: 7.21 GiB`, then `OutOfMemoryError: Tried to allocate
  462.00 MiB`) — measured on 2026-08-20, with a run an hour earlier succeeding on byte-identical
  profiling numbers, so it is a race, not a misconfiguration. 0.85 still sizes far more than the
  window needs — 379,961 tokens on a freshly rebooted PC (see "the 0.85 path, revalidated" below).
  serve.sh also sets `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` (both overridable).
  That switch then *forces MTP off*: TurboQuant + speculative decoding makes this model
  emit empty content or `: : : :` to the token limit while still answering HTTP 200 — measured 0/3
  sane trivial answers with MTP on, 3/3 with it off. Cost of the full window: ~49 tok/s vs ~80 at
  the default 131072 with fp8 + MTP — which is exactly why 131072 is the default and 262144 is
  opt-in. `MAX_SEQS=16` because the GDN/Mamba layers need one cache block per decode
  sequence and vLLM's default 256 aborts the start at a long context.
- **Claude Code bridge** (`scripts/claude-code.sh`, `app/claude-code.ps1`, docs in
  `app/docs/CLAUDE-CODE.md`): runs LiteLLM in its own venv at `~/.qwen5090/bridge/venv`,
  translating Anthropic `/v1/messages` to this server's OpenAI API. It is a *client-side* tool —
  it works against a remote server too (`QWEN_URL=`), and never touches the serving path.
  The GUI's **Claude Code tab** drives the same wrapper: `-Start` brings up the bridge without a
  session, and `-BindAll` binds it to 0.0.0.0 because WSL's localhost relay only forwards ports
  bound to all interfaces — a 127.0.0.1 bridge works fine for a session inside WSL but is invisible
  to the GUI's Windows-side health ping, which would leave a live bridge sitting behind a pill
  reading "stopped". The session itself is the one GUI child that is **not** hidden: Claude Code is
  an interactive terminal app, so it gets a real console (`-NoExit`, so a failure stays readable).
  **Traffic recording is opt-in and lives outside the logs directory.**
  `QWEN_LOG_PAYLOADS=1` (`-LogPayloads`, or the tab's "Record traffic" box) makes the same hooks
  module append every request and reply to `~/.qwen5090/debug/payloads-<date>.jsonl`. The switch is
  baked into the rendered `qwen_hooks.py` rather than read from the environment, so flipping it
  changes the file and `start` restarts on it — an env var alone would be ignored by a bridge that
  is already up. `~/.qwen5090/debug/`, never `~/.qwen5090/logs/`: collect-logs.ps1 bundles
  `logs/*.log` into the bug-report ZIP, and these files are the user's actual conversations.
  Secrets are stripped at **any depth** — LiteLLM hides the raw request headers, `x-api-key` and
  all, inside `secret_fields`, which a top-level filter walks straight past (caught by the test on
  2026-08-21, not by review).
  **Claude Code installs itself on demand** (`install-claude`, `-InstallClaude`, or the tab's
  Install button; `run` also does it, the way `ensure_bridge_installed` handles LiteLLM):
  Anthropic's native installer at `https://claude.ai/install.sh` puts one checksum-verified binary
  in `~/.local/bin` — no Node, no npm, no root, which matters because Ubuntu's WSL rootfs ships
  neither node nor npm and the npm package would drag in a whole toolchain first. That directory
  is on `PATH` from the top of claude-code.sh: a non-login `bash -c` reads no profile, so without
  it a `claude` installed seconds earlier still reads as missing — which is exactly what made a
  perfectly good install look absent when probed from the outside on 2026-08-21.
  Self-configuring: model id and `max_model_len` come from `/v1/models`, so it follows whatever
  checkpoint is being served. Four properties of this server drive its whole design, and
  the first three are already documented above under "Measured on the 5090":
  **(a)** Claude Code sends `reasoning_effort: "high"`, which this template 400s on, so the bridge
  drops the client's value and injects `QWEN_EFFORT` (default `xhigh`) instead;
  **(b)** reasoning tokens count against `max_tokens`, so the `qwen5090-fast` alias that Claude
  Code uses for background chores disables thinking — otherwise those small-cap calls return
  empty behind a 200; **(c)** the model name is unknown to Claude Code, which would assume a 200K
  window, so `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is exported from the real value;
  **(d)** `tool_choice` with an empty `tools` is a hard 400 from vLLM, and Claude Code's WebSearch
  is a *server-side* Anthropic tool (`{"type": "web_search_20250305"}`, no `input_schema`) that
  LiteLLM has no OpenAI function to translate it into, so it drops the tool and forwards
  `tool_choice` anyway. Only WebSearch trips it; ordinary function tools survive translation, so
  the session works until the model reaches for the web. The bridge generates `qwen_hooks.py`
  beside `config.yaml` (a LiteLLM `async_pre_call_hook`, wired in with `callbacks:`) that strips
  `tool_choice` only when no callable tool is left - dropping it unconditionally would be one
  config line but would also silently defang a genuinely forced tool call. Verified 2026-08-21 on
  a throwaway bridge on :4100: the WebSearch shape went 400 -> 200, and a real function tool still
  came back as `tool_use`.
  **A fourth alias exists for auto mode, and it is not optional.** Auto mode classifies every
  tool call that is not plainly read-only in a *separate* request: non-streaming, ~115 KB of
  rules in the system prompt (~30K tokens, i.e. the prefill cliff), and a hard **60-second**
  client-side timeout. It asks for `claude-sonnet-5`, so `ANTHROPIC_DEFAULT_SONNET_MODEL` is the
  only lever that reaches it — `CLAUDE_CODE_AUTO_MODE_MODEL` exists in the bundle but is ignored,
  from the environment and from `settings.json` alike (measured against 2.1.238 with a mock
  Anthropic server). Left on the main alias, every classification is an xhigh thinking pass
  against that 60 s budget and *every* tool fails with `qwen5090 is temporarily unavailable
  (timed out), so auto mode cannot determine the safety of …` — which reads as broken tool
  calling and is not: the model's own turns take ~2 s and its `tool_use` blocks are well-formed.
  Hence `qwen5090-classifier`: same weights, thinking off, cap 16384 for the classifier's
  two-stage retry. `FAST_THINKING=1` must not reach it. Side effect: `/model sonnet` picks it too.
  `start` re-renders the config *and the hooks module* and restarts if either differs from what is
  running — settings changes
  must not be silently ignored — and `stop` waits for the port to close, or the next `start` sees a
  dying process as healthy and the session dies with "connection refused".
  **Dependency pin that must not be dropped**: `fastapi>=0.136.3,<0.140.7`. 0.140.7 removed
  `get_flat_dependant`, which LiteLLM's proxy imports at startup, while LiteLLM's metadata still
  claims `fastapi<1.0` — so an unpinned install resolves to a pair that fails at *launch* with a
  misleading `No module named 'proxy_server'`. Pinning fastapi below 0.116 instead silently
  downgrades LiteLLM itself to 1.79.
- **Sharing (LAN/Tailscale)**: `share.ps1` = netsh portproxy into WSL + firewall rule scoped to
  Private/Domain profiles only. WSL's IP changes every reboot, so `-Share`/the GUI checkbox
  re-applies it on each server start.
- **Logging**: Windows side `%LOCALAPPDATA%\Qwen5090\logs` (pruned after 14 days), WSL side
  `~/.qwen5090/logs` (scripts tee everything + ERR trap). `collect-logs.ps1` bundles both plus
  system state into a Desktop ZIP — that's the designated bug-report artifact.

## Measured on the 5090 (2026-08-20, uncensored build at CTX=262144)

A full-window run — server started by `serve.sh`, a real code-generation task at
`xhigh`, then needle-in-a-haystack and a per-effort sweep. What it settled:

- **The API field is `reasoning`, not `reasoning_content`** on vLLM 0.27.1 with this
  model — in streaming deltas *and* in the non-streaming message. `gui.ps1` and
  `chat.py` read only `reasoning_content` and therefore threw the entire thinking
  stream away (14,000+ tokens in one measured run: 4,645 chunks received in 437 s
  while the server logged 40–49 tok/s). Both now accept either name; keep the
  fallback, other servers do use `reasoning_content`.
- **The chat template accepts `low`, `medium`, `xhigh` only.** `high` is rejected:
  `{"message":"Unexpected reasoning effort high. Supported types are xhigh
  (default), medium, and low.","code":400}`. It has been removed from the GUI
  dropdown, `chat.ps1`'s ValidateSet and `chat.py`'s choices. `xhigh` is the
  template's own default. Effort really does scale: 146 → 242 → 711 chars of
  thinking for low → medium → xhigh on the same question.
- **Reasoning tokens are billed against `max_tokens`.** `max_tokens=16` with
  thinking on returns `content=None` and `finish_reason=length`; the same request
  with `enable_thinking:false` answers correctly. Any client asking for a short
  answer under a small cap gets an empty string behind an HTTP 200.
- **Prefill collapses super-linearly above ~30K tokens**, and this is the real
  limit of the 262K window:

      prompt_tokens=  5,585    0.5 s   ~11,117 tok/s   needle found
      prompt_tokens= 22,210    2.0 s   ~11,315 tok/s   needle found
      prompt_tokens= 90,800  245.0 s   ~   371 tok/s   needle found
      prompt_tokens=~139,000  aborted after 7 min

  Retrieval accuracy never degrades — it is purely speed. `py-spy` on the engine
  during the stall puts the time in `triton_turboquant_store`
  (`v1/attention/ops/triton_turboquant_store.py:414`, via `_store_kv` →
  `do_kv_cache_update`) and `qwen_gdn_attention_core`, i.e. the 4-bit KV store and
  the GDN linear-attention core during chunked prefill — both only on the path
  serve.sh picks when `CTX > 131072`. Symptom to recognise: GPU at 100% util but
  only ~128 W, and no scheduler stats line for minutes. It reads as a hang and is
  not one. Not yet measured: whether fp8 at 131072 clears the same prompt faster.
- **The 0.85 path, revalidated after a reboot** (2026-08-20 16:02, `run.ps1 -Uncensored`,
  nothing else on the GPU — 770 MiB used at launch). The profiler sized
  `Available KV cache memory: 6.2 GiB` → **379,961 tokens**, startup completed with no
  allocation OOM, and VRAM settled at 28,084 of 32,607 MiB, i.e. **4.4 GiB still free for
  Windows** where the 0.90 run left ~3.2 GiB. Then: "Paris" in 0.9 s at `low` (no cold-start
  penalty — TurboQuant's flash_attn v2 pin means there is no JIT to pay for), a code task at
  `xhigh` at 291 tokens in 5.6 s (**~52 tok/s**, `finish_reason: stop`), and a streamed reply
  of 160 SSE chunks whose deltas carry `reasoning`. Content was sane every time, which is the
  MTP interlock working. Startup logs two `[ERROR]` lines about undocumented `min_frames` /
  `max_frames` kwargs in transformers' Qwen3-VL video processor — noise, not a fault.
- **Startup, for reference**: weights 18.74 GiB in 8.6 s warm / ~60 s cold, engine
  init 10.8 s, MM warmup 12.2 s, "Application startup complete" ~78 s in, first
  request 1.03 s. TurboQuant pins `flash_attn_version=2`, so the FlashInfer prefill
  JIT never runs and the old first-message 500 cannot happen on this path.
- **8 GB of headroom for Windows was not enough.** With `memory=24GB` on a 31.7 GB
  PC the host fell to **1.89 GB free** while the weights mapped in, and vLLM warned
  `checkpoint size (19.15 GiB) exceeds 90% of available RAM (19.44 GiB)`. VRAM peaked
  at 32,148 of 32,607 MiB at the same time. `install.ps1` now reserves 12 GB
  (`$hostGB - 12`), giving 20 GB + 8 GB swap on a 32 GB machine — still ≥ `$needGB`.
  The sizing stays raise-only, so an existing `.wslconfig` at 24 GB must be lowered
  by hand, then `wsl --shutdown`.

## The 0x116 bluescreens (open; six dumps as of 2026-08-21)

This PC bluescreens with `0x116` VIDEO_TDR_ERROR, arg3 `0xc000009a`
STATUS_INSUFFICIENT_RESOURCES, arg4 4, at the end of a serving run. Dumps:
2026-08-16 20:20, 08-20 21:42, 08-20 23:32, 08-21 00:44, 08-21 02:36,
**08-21 10:22**. `nvlddmkm` event-153 reset storms accompanied the early ones and
stopped after the driver update; the later crashes produce no such events.

**Five theories have been falsified in turn. Do not re-argue any of them from
scratch, and do not ship any of them as a fix.**

1. 612ef34 — too-short GPU watchdog. `TdrDelay`/`TdrDdiDelay` were confirmed live
   at 10 during a crash.
2. 250b4ff — thin VRAM headroom at `GPU_UTIL=0.90`. The 21:42 crash ran at 0.85.
3. 8d3ff91 — the display driver (NVIDIA Bug 6546168, fixed in 610.74). 610.88 was
   installed 08-20 23:51 and the PC crashed again 52 minutes later.
4. `HwSchMode=1` (hardware-accelerated GPU scheduling off). Armed by the 01:35
   reboot; the run that started 01:38 still crashed at 02:36.
5. **The `turboquant_4bit_nc`/GDN path at `CTX=262144`.** This was the last
   correlation standing after five crashes — and the sixth killed it. The 10:22
   crash ran the shipped fp8 configuration
   (`soak131k-20260821-101831.log`: `ctx=131072 gpu_util=0.90 mtp=1 kv=fp8
   prefix_cache=0`), served ~2 minutes at 54–98 tok/s, and died mid-decode: last
   stat line 10:21:49 `0.0 tokens/s, Running: 1 reqs`, bugcheck at 10:22:30.

So the crash is **not** specific to a KV precision, a context length, a
`GPU_UTIL`, the driver, or GPU scheduling. What every crash does share is a vLLM
decode/prefill workload on this card; a June `nvlddmkm` storm at an idle desktop
(see TROUBLESHOOTING.md) says the fault predates the toolkit. Treat it as
hardware/platform until something new says otherwise.

131072 became the default on 2026-08-21 for speed (~80 tok/s vs ~49) and to
avoid the prefill cliff — **not** as a crash fix. Do not describe it as one.

Recording new incidents: check for a minidump *and* a Kernel-Power 41 first —
the 08-21 01:01 freeze was commit exhaustion (`dwm.exe` `STATUS_COMMITMENT_LIMIT`)
with vLLM not running, and does not belong in the count above. When reading old
logs, `gpu_util=0.9` (one decimal) means a caller passed `-GpuUtil` explicitly,
which suppresses serve.sh's own choice; `0.90`/`0.85` means serve.sh chose it.

## Model/stack facts (post-cutoff; verified via web 2026-08)

Two checkpoints ship as a user choice (GUI Setup tab dropdown; `-Uncensored` on
install.ps1/run.ps1; `MODEL=` for the .sh scripts):

| | standard | uncensored (default) | uncensored (gated) |
|---|---|---|---|
| repo | `unsloth/Qwen3.8-27B-NVFP4` | `sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4` | `orcarouter/Qwen3.8-27B-Uncensored-NVFP4` |
| size | 21.81 GiB, one 21 GiB shard | 19.1 GiB (18.4 GiB shard + bf16 MTP head) | ~23 GB, 5+1 shards ≤5 GB |
| access | public | **public** | **gated** — accepted licence + `HF_TOKEN` |
| quant | compressed-tensors nvfp4 | compressed-tensors nvfp4-pack (llm-compressor, W4A4 g16, from huihui-ai's abliteration) | mixed nvfp4+fp8 |
| serve flags | `--kv-cache-dtype fp8`, 3 MTP tokens | same + `--trust-remote-code` | dtype from `config.json` (passing it is an error), 2 MTP tokens, `--trust-remote-code` |

`-Uncensored` on install.ps1/run.ps1 means the middle column — no account. The
gated one is reachable only via `-Model`/the third GUI dropdown entry. Other
ungated NVFP4 abliterations exist (`Blackfrost-AI/…-ABLITERATED-NVFP4` 28 GB no
MTP, `sakamakismile/…AEON-ULTIMATE…-NVFP4`, `joshebbs/…-modelopt`); GGUF ones
(huihui-ai, 0bserverx, …) are useless here — llama.cpp only.

`serve.sh` derives those flags from the model id (exact match for the gated one,
then a generic `*[Aa]bliterated*|*[Uu]ncensored*` case, else standard);
`setup-wsl.sh` checks gated access in step 2/6 (before the 10-minute vLLM install)
and `huggingface_hub.login()`s the token into `~/.cache/huggingface/token` so vLLM
reuses it. The GUI stages the token through a file across the UAC relaunch —
never the logs folder, `collect-logs.ps1` zips that up.

Qwen3.8-27B released 2026-08-14 (Apache 2.0, 262K ctx). NVFP4 quant `unsloth/Qwen3.8-27B-NVFP4`
(21.81 GiB) runs **only on vLLM** (`vllm>=0.25.0` + `flashinfer-python>=0.6.13` +
`nvidia-cutlass-dsl>=4.5.2`, Python 3.13) — SGLang can't load the FP8 lm_head, llama.cpp is
GGUF-only. Driver ≥ 570 required for Blackwell. Recommended instruct sampling: temp 0.7, top-p 0.8,
top-k 20, presence 1.5. Re-verify pins on the web before bumping them.

## Workflow

- Full permissions are granted: read, write, edit, and execute without asking.
- Commit after every meaningful change; never batch unrelated work.
- Use conventional commits (`feat:` `fix:` `docs:` `refactor:` `test:` `chore:`); the message says what changed and why.
- Run the linters above before declaring any task done.
- Keep README and docs in sync — README is written for non-technical ZIP users first (the download
  button is the hero); technical content goes in the power-users section or `app/docs/`.
