<#
.SYNOPSIS
  Start the Qwen3.8-27B-NVFP4 vLLM server (runs inside WSL2, Ctrl+C stops it).

.EXAMPLE
  .\run.ps1                     # 128K context, port 8000, MTP on
  .\run.ps1 -Ctx 262144         # full native context
  .\run.ps1 -Port 8080 -NoMtp
  .\run.ps1 -Share              # also reachable from LAN/Tailscale (one admin prompt)
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [int]$Ctx = 131072,
    [int]$Port = 8000,
    [string]$Model = "unsloth/Qwen3.8-27B-NVFP4",
    [double]$GpuUtil = 0.90,
    [switch]$NoMtp,
    [switch]$Share
)
$ErrorActionPreference = "Stop"

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
$gpuUtilStr = $GpuUtil.ToString([System.Globalization.CultureInfo]::InvariantCulture)
Write-Host "Starting Qwen3.8-27B-NVFP4 on http://localhost:$Port/v1  (first load takes a minute; Ctrl+C stops)" -ForegroundColor Cyan
& wsl -d $Distro -- bash -c "CTX=$Ctx PORT=$Port MODEL='$Model' GPU_UTIL=$gpuUtilStr MTP=$mtp bash '$repoWsl/scripts/serve.sh'"
