#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-shot installer for running Qwen3.8-27B (NVFP4) on Windows 11 + RTX 5090.

.DESCRIPTION
  Checks Windows 11, the NVIDIA driver, and WSL2; installs Ubuntu-24.04 if
  missing; then runs the Linux-side setup (uv + Python 3.13 + vLLM + ~17 GB
  model download). Re-running after a reboot or a fixed prerequisite is safe.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -SkipDownload   # set everything up but let vLLM fetch weights on first run
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [switch]$SkipDownload
)
$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

Step "Checking Windows version"
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -lt 22000) { Fail "Windows 11 is required (build >= 22000); this machine reports build $build." }
Write-Host "Windows 11 (build $build) - OK"

Step "Checking NVIDIA GPU and driver"
if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    Fail "nvidia-smi not found. Install the latest NVIDIA driver from https://www.nvidia.com/drivers first."
}
$gpuInfo = (& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader) -split ',\s*'
$gpuName = $gpuInfo[0].Trim(); $driver = $gpuInfo[1].Trim(); $vram = $gpuInfo[2].Trim()
Write-Host "GPU: $gpuName | driver $driver | $vram"
if ([version]$driver -lt [version]"570.0") {
    Fail "Driver $driver is too old for Blackwell/NVFP4. Update to >= 570 (580+ recommended) and re-run."
}
if ($gpuName -notmatch '50\d0|RTX PRO \d+ Blackwell|B\d{3}') {
    Write-Host "WARNING: '$gpuName' does not look like a Blackwell GPU. NVFP4 needs an RTX 50-series card; continuing anyway." -ForegroundColor Yellow
}

Step "Checking WSL2"
& wsl --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "WSL is not installed yet - installing (this can take a few minutes)..."
    & wsl --install --no-distribution
    Write-Host "`nWSL installed. REBOOT Windows now, then run .\install.ps1 again to continue." -ForegroundColor Yellow
    exit 0
}
Write-Host "WSL2 - OK"

Step "Checking Linux distro ($Distro)"
# wsl.exe prints UTF-16; strip the interleaved nulls before comparing.
$distros = (& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
if ($distros -notcontains $Distro) {
    Write-Host "Installing $Distro - you will be asked to create a Linux username and password."
    Write-Host "When you land in the Linux shell, type 'exit' to come back here." -ForegroundColor Yellow
    & wsl --install -d $Distro
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install $Distro. Run 'wsl --install -d $Distro' manually, then re-run this script." }
}
Write-Host "$Distro - OK"

Step "Running Linux-side setup (vLLM install + model download)"
$repoWin = $PSScriptRoot -replace '\\', '/'
$repoWsl = (& wsl -d $Distro -- wslpath -a "$repoWin") -replace "`0", ""
$repoWsl = $repoWsl.Trim()
if (-not $repoWsl) { Fail "Could not translate the repo path into WSL. Is $Distro initialized? Try 'wsl -d $Distro' once, then re-run." }
$envPrefix = if ($SkipDownload) { "SKIP_DOWNLOAD=1 " } else { "" }
& wsl -d $Distro -- bash -c "${envPrefix}bash '$repoWsl/scripts/setup-wsl.sh'"
if ($LASTEXITCODE -ne 0) { Fail "Linux-side setup failed - see the output above, then re-run .\install.ps1 (it resumes safely)." }

Step "All done"
Write-Host "Start the server :  .\run.ps1"
Write-Host "Terminal chat    :  .\chat.ps1        (in a second terminal)"
Write-Host "API endpoint     :  http://localhost:8000/v1   (OpenAI-compatible, api_key can be anything)"
