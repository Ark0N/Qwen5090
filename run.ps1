<#
.SYNOPSIS
  Start the Qwen3.8-27B-NVFP4 vLLM server (runs inside WSL2, Ctrl+C stops it).

.EXAMPLE
  .\run.ps1                     # 128K context, port 8000, MTP on
  .\run.ps1 -Ctx 262144         # full native context
  .\run.ps1 -Port 8080 -NoMtp
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [int]$Ctx = 131072,
    [int]$Port = 8000,
    [string]$Model = "unsloth/Qwen3.8-27B-NVFP4",
    [double]$GpuUtil = 0.90,
    [switch]$NoMtp
)
$ErrorActionPreference = "Stop"

$repoWin = $PSScriptRoot -replace '\\', '/'
$repoWsl = ((& wsl -d $Distro -- wslpath -a "$repoWin") -replace "`0", "").Trim()
if (-not $repoWsl) { Write-Host "ERROR: WSL distro '$Distro' not ready - run .\install.ps1 first." -ForegroundColor Red; exit 1 }

$mtp = if ($NoMtp) { 0 } else { 1 }
$gpuUtilStr = $GpuUtil.ToString([System.Globalization.CultureInfo]::InvariantCulture)
Write-Host "Starting Qwen3.8-27B-NVFP4 on http://localhost:$Port/v1  (first load takes a minute; Ctrl+C stops)" -ForegroundColor Cyan
& wsl -d $Distro -- bash -c "CTX=$Ctx PORT=$Port MODEL='$Model' GPU_UTIL=$gpuUtilStr MTP=$mtp bash '$repoWsl/scripts/serve.sh'"
