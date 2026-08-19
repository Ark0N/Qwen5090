# Troubleshooting

Work top-to-bottom: most failures are the driver, WSL state, or VRAM.

## GUI won't open / closes instantly
- If you downloaded a ZIP (instead of `git clone`), Windows may block the
  scripts: right-click the downloaded ZIP → Properties → check **Unblock**
  *before* unzipping, or afterwards run
  `Get-ChildItem -Recurse | Unblock-File` in PowerShell from the unzipped folder.
- SmartScreen may warn on first launch of `Start Qwen 5090.cmd` — choose
  "More info → Run anyway".

## Where the logs live
Every run is logged automatically (kept 14 days):
- **Windows side**: `%LOCALAPPDATA%\Qwen5090\logs` — GUI events (`gui-*.log`),
  installer output + transcript (`install-*`), server output (`server-*`).
  The GUI's **Logs** button opens this folder.
- **WSL side**: `~/.qwen5090/logs` — Linux setup (`setup-*.log`) and the full
  vLLM server output (`serve-*.log`).

If the GUI itself crashes, the fatal error (with stack trace) is written to
the newest `gui-*.log` and shown in a message box.

## Other devices can't reach the API (LAN / Tailscale)
- Sharing must be re-applied after every reboot — WSL's internal IP changes.
  The GUI's **Share on network** checkbox does this on every server start;
  CLI: `.\app\run.ps1 -Share`. Undo with `.\app\share.ps1 -Remove`.
- Windows must classify your network as **Private** (Settings → Network &
  internet) — the firewall rule deliberately excludes Public networks.
  Tailscale's interface counts as private automatically.
- Tailscale: both devices must be on the same tailnet; connect to the PC's
  Tailscale IP (`tailscale ip -4` on the PC) or MagicDNS name, port 8000.
- Alternative without sharing: `tailscale serve --bg 8000` on the PC proxies
  `localhost:8000` to your tailnet over HTTPS.

## Reporting a problem
Click **Collect diagnostics** in the GUI (or run `.\app\collect-logs.ps1`). It
bundles all of the above plus GPU/driver/WSL state and tool versions into
`qwen5090-diagnostics-<timestamp>.zip` on your Desktop — attach that file.

## GUI chat says "server is not running"
Start it on the Server tab and wait for the status to turn green ("running") —
first start takes a minute or two while the model loads and CUDA graphs
compile. If it stays on "starting...", check the Server tab log.

## `install.ps1` says WSL needs a reboot
Normal on a machine that never had WSL. Reboot, then run `.\install.ps1`
again — it picks up where it left off.

## `wsl --install` fails / WSL won't start
- Virtualization must be enabled in BIOS/UEFI ("SVM" on AMD, "VT-x" on Intel).
  Check Task Manager → Performance → CPU → "Virtualization: Enabled".
- Update WSL itself: `wsl --update`, then `wsl --shutdown`.

## "virtualization is not enabled" / `HCS_E_HYPERV_NOT_INSTALLED`
The installer checks for this up front and prints the fix, but in short:
- **Task Manager says "Virtualization: Disabled"** → enable it in the BIOS/UEFI:
  restart into firmware (Settings → System → Recovery → Advanced startup →
  UEFI Firmware Settings, or Del/F2 at boot), then enable
  "Intel Virtualization Technology"/"VT-x" (Intel) or "SVM Mode" (AMD),
  save, boot, and run the installer again.
- **Task Manager says "Enabled" but the error persists** → the Windows
  hypervisor was switched off (old VirtualBox/anti-cheat guides do this).
  The installer now repairs this automatically; by hand it is
  `bcdedit /set hypervisorlaunchtype auto` in an admin prompt, then reboot.

## `nvidia-smi` works in Windows but fails inside WSL
- Update the **Windows** driver to ≥ 570 (Game Ready or Studio), then run
  `wsl --shutdown` and retry. The Windows driver provides the GPU to WSL.
- Never `apt install` an NVIDIA driver inside WSL — it shadows the Windows one.
  If you did: `sudo apt purge 'nvidia-*'` inside WSL, then `wsl --shutdown`.

## Server dies while loading: "unable to mmap ... Cannot allocate memory (12)"

That is *system* RAM, not VRAM. vLLM maps the whole ~22 GB weights file at
once, and Windows only lends WSL half the PC's RAM (plus a quarter of that as
swap), so on a 32 GB machine the mapping is refused before a single byte is
read. The log line just above it gives it away:

```
Checkpoint size: 21.81 GiB. Available RAM: 11.09 GiB.
```

Fix it on the **Windows** side:

1. Click **Install / Repair** in the app, or run `.\app\install.ps1 -WslMemoryOnly`
   in PowerShell for just this step. Either one reads how much RAM the PC has,
   writes matching limits to `%USERPROFILE%\.wslconfig`, and restarts WSL.
2. By hand instead: create `%USERPROFILE%\.wslconfig` with

   ```ini
   [wsl2]
   memory=24GB
   swap=8GB
   ```

   then `wsl --shutdown` in PowerShell and start the server again.

Keep ~8 GB for Windows itself. On a 16 GB PC leave `memory` alone and give
`swap=20GB` instead — loading is slower but it works. `wsl --shutdown` is
required for any `.wslconfig` change to take effect.

## Out of memory (CUDA OOM) at startup
The 5090's 32 GB is shared with the Windows desktop, so vLLM can't take it all.
In order of preference:
1. Lower the context: `.\run.ps1 -Ctx 65536`.
2. Lower VRAM share: `.\run.ps1 -GpuUtil 0.85`.
3. Close VRAM-hungry apps (games, browsers with many tabs, wallpaper engines).

## "no kernel image is available" / NVFP4 kernel errors
Your vLLM/flashinfer build predates Blackwell NVFP4 support. Re-run
`.\install.ps1` (it upgrades to `vllm>=0.25.0`, `flashinfer-python>=0.6.13`,
`nvidia-cutlass-dsl>=4.5.2`). SGLang and llama.cpp are **not** alternatives
for this checkpoint: SGLang can't load its FP8 lm_head, llama.cpp only reads
GGUF.

## Model download is slow or fails
- Re-run `.\install.ps1` — the Hugging Face cache resumes partial downloads.
- Behind a proxy/VPN, DNS inside WSL sometimes breaks. Test with
  `wsl -- curl -sI https://huggingface.co`. If it hangs, add
  `[network] generateResolvConf = false` guidance from the WSL docs or toggle
  the VPN.

## `bash\r: No such file or directory` or `$'\r': command not found`
The shell scripts were checked out with CRLF line endings. This repo's
`.gitattributes` prevents that; if you copied files by hand, fix them with
`wsl -- dos2unix app/scripts/*.sh` (or re-clone).

## Port 8000 already in use
`.\run.ps1 -Port 8080` (then `.\chat.ps1 -Port 8080`).

## Server starts but `chat.ps1` can't connect
- Give the server a minute: the model loads and CUDA graphs compile on first
  start. Wait for the `Uvicorn running on http://0.0.0.0:8000` line.
- WSL2 on Windows 11 forwards `localhost` automatically. If you disabled that,
  set `localhostForwarding=true` in `.wslconfig` and `wsl --shutdown`.

## Generation quality is off (rambling, repetitive)
Use the recommended instruct sampling (chat.ps1 already does): temperature 0.7,
top-p 0.8, top-k 20, presence penalty 1.5. For heavy reasoning tasks, raise the
dial with `.\chat.ps1 -Effort high`.
