# Troubleshooting

Work top-to-bottom: most failures are the driver, WSL state, or VRAM.

## `install.ps1` says WSL needs a reboot
Normal on a machine that never had WSL. Reboot, then run `.\install.ps1`
again — it picks up where it left off.

## `wsl --install` fails / WSL won't start
- Virtualization must be enabled in BIOS/UEFI ("SVM" on AMD, "VT-x" on Intel).
  Check Task Manager → Performance → CPU → "Virtualization: Enabled".
- Update WSL itself: `wsl --update`, then `wsl --shutdown`.

## `nvidia-smi` works in Windows but fails inside WSL
- Update the **Windows** driver to ≥ 570 (Game Ready or Studio), then run
  `wsl --shutdown` and retry. The Windows driver provides the GPU to WSL.
- Never `apt install` an NVIDIA driver inside WSL — it shadows the Windows one.
  If you did: `sudo apt purge 'nvidia-*'` inside WSL, then `wsl --shutdown`.

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
`wsl -- dos2unix scripts/*.sh` (or re-clone).

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
