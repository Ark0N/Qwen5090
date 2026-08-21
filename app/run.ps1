<#
.SYNOPSIS
  Start the Qwen3.8-27B-NVFP4 vLLM server (runs inside WSL2, Ctrl+C stops it).

.EXAMPLE
  .\run.ps1                     # 128K context, port 8000, MTP on
  .\run.ps1 -Ctx 262144         # the model's full window (slower: 4-bit KV cache, no MTP)
  .\run.ps1 -Ctx 65536          # smaller window, if you are gaming at the same time
  .\run.ps1 -Port 8080 -NoMtp
  .\run.ps1 -Uncensored         # serve the abliterated build instead
  .\run.ps1 -Share              # also reachable from LAN/Tailscale (one admin prompt)
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    # 131,072 - the largest window that still holds an fp8 KV cache on a 32 GB
    # card, so MTP stays on and decoding runs ~80 tok/s instead of ~49. The
    # model goes to 262144; serve.sh drops the KV cache to 4-bit above 128K so
    # that window fits too - see the note there.
    [int]$Ctx = 131072,
    [int]$Port = 8000,
    [string]$Model = "unsloth/Qwen3.8-27B-NVFP4",
    # Download it first with:  .\install.ps1 -Uncensored
    # serve.sh keys its flags off the model id, so nothing else changes here.
    [switch]$Uncensored,
    # Only forwarded when you actually pass it - see the note further down.
    [double]$GpuUtil = 0.90,
    [switch]$NoMtp,
    # Reuse the KV of a shared prompt prefix across requests. On by default
    # with the 4-bit cache; -PrefixCache:$false forces it off. Same
    # only-when-bound handling as -GpuUtil.
    [switch]$PrefixCache,
    [switch]$Share
)
$ErrorActionPreference = "Stop"

if ($Uncensored -and $Model -eq "unsloth/Qwen3.8-27B-NVFP4") {
    # The ungated abliterated NVFP4 re-quant; -Model takes any other repo id.
    $Model = "sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4"
}

$repoWin = $PSScriptRoot -replace '\\', '/'
$repoWsl = ((& wsl -d $Distro -- wslpath -a "$repoWin") -replace "`0", "").Trim()
if (-not $repoWsl) { Write-Host "ERROR: WSL distro '$Distro' not ready - run .\install.ps1 first." -ForegroundColor Red; exit 1 }

if ($Share) {
    $shareArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\share.ps1`" -Port $Port -Distro $Distro"
    try {
        $p = Start-Process powershell -Verb RunAs -ArgumentList $shareArgs -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            Write-Host "Shared - other devices on your LAN/tailnet can reach the API at:" -ForegroundColor Cyan
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "172.*" } |
                ForEach-Object { Write-Host "   http://$($_.IPAddress):$Port/v1" }
            Write-Host "   (undo anytime with .\app\share.ps1 -Remove)"
        } else {
            Write-Host "WARNING: sharing setup failed (exit $($p.ExitCode)) - server will be localhost-only." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARNING: sharing was declined at the admin prompt - server will be localhost-only." -ForegroundColor Yellow
    }
}

$mtp = if ($NoMtp) { 0 } else { 1 }
# Only forward GPU_UTIL when the caller actually asked for one. serve.sh
# treats any value it receives as a deliberate override and then skips its
# own per-KV-precision default - 0.85 on the 4-bit path, which is what keeps
# the Windows desktop's VRAM out of the KV cache's way. Passing this
# parameter's default unconditionally would silence that and hand back the
# mid-allocation CUDA OOM it exists to prevent.
$gpuUtilEnv = ""
if ($PSBoundParameters.ContainsKey('GpuUtil')) {
    $gpuUtilStr = $GpuUtil.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $gpuUtilEnv = "GPU_UTIL=$gpuUtilStr "
}
# Same rule for the prefix cache: silence unless asked, so serve.sh keeps its
# own per-KV-precision default.
$prefixCacheEnv = ""
if ($PSBoundParameters.ContainsKey('PrefixCache')) {
    $prefixCacheEnv = "PREFIX_CACHE=$(if ($PrefixCache) { 1 } else { 0 }) "
}
Write-Host "Starting $Model on http://localhost:$Port/v1  (first load takes a minute; Ctrl+C stops)" -ForegroundColor Cyan
& wsl -d $Distro -- bash -c "CTX=$Ctx PORT=$Port MODEL='$Model' ${gpuUtilEnv}${prefixCacheEnv}MTP=$mtp bash '$repoWsl/scripts/serve.sh'"
