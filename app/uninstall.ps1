#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Cleanup / uninstall for Qwen 5090 - removes everything install.ps1 set up.

.DESCRIPTION
  Deletes the Ubuntu distro (which contains the Python env AND the ~17 GB
  model download), removes the network-sharing port proxy and firewall rule,
  the desktop shortcut, and the resume-after-reboot entry. Frees ~20+ GB.

  Kept on purpose:
   - The WSL2 platform itself (other Linux distros may rely on it; it is small)
   - Log files under %LOCALAPPDATA%\Qwen5090\logs (auto-pruned after 14 days)
   - This folder (just delete it in Explorer when you are done)

  Exit codes: 0 = success, 1 = failure.

.EXAMPLE
  .\uninstall.ps1
  .\uninstall.ps1 -Port 9000   # if you shared the API on a non-default port
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [int]$Port = 8000
)
$ErrorActionPreference = "Stop"

$script:LogDir = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogFile = Join-Path $script:LogDir ("uninstall-{0}.transcript.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $script:LogFile -Force | Out-Null } catch { }
function Stop-Log { try { Stop-Transcript | Out-Null } catch { } }

function Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }

Write-Host "Logging this run to: $script:LogFile"
Write-Host "Removing everything Qwen 5090 installed (distro: $Distro)."

Step "Stopping the server (if running)"
$distros = @()
try { $distros = (& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" } } catch { }
if ($distros -contains $Distro) {
    & wsl -d $Distro -- bash -c "pkill -f 'vllm serve' 2>/dev/null; exit 0" *> $null
    Write-Host "Server processes stopped."
} else {
    Write-Host "$Distro is not installed - nothing to stop."
}

Step "Removing network sharing (port proxy + firewall rule)"
try {
    & "$PSScriptRoot\share.ps1" -Remove -Port $Port
} catch {
    Write-Host "WARNING: could not remove sharing rules ($($_.Exception.Message))" -ForegroundColor Yellow
}

Step "Removing the Linux distro, Python environment, and the model (~20+ GB)"
if ($distros -contains $Distro) {
    Write-Host "Unregistering $Distro - this deletes its entire disk, including the model download."
    Write-Host "This can take a minute for a large distro..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & wsl --terminate $Distro *> $null
    & wsl --unregister $Distro *>&1 | ForEach-Object { ($_ -replace "`0", "") } | Where-Object { $_ } | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: 'wsl --unregister $Distro' failed (exit code $LASTEXITCODE). Close any WSL windows and re-run." -ForegroundColor Red
        Stop-Log
        exit 1
    }
    Write-Host ("{0} removed in {1:0}s - disk space is freed." -f $Distro, $sw.Elapsed.TotalSeconds)
} else {
    Write-Host "$Distro is not installed - skipping."
}

Step "Removing shortcut and startup entries"
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Qwen 5090.lnk"
if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; Write-Host "Desktop shortcut removed." }
else { Write-Host "No desktop shortcut found." }
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
    -Name "Qwen5090Resume" -ErrorAction SilentlyContinue
Write-Host "Resume-after-reboot entry removed (if it existed)."

Step "Cleanup complete"
Write-Host "Removed        :  $Distro (Python env + model), sharing rules, shortcut, startup entry"
Write-Host "Kept           :  the WSL2 platform (small, other distros may use it)"
Write-Host "Kept           :  logs in $script:LogDir (auto-deleted after 14 days)"
Write-Host "Last step      :  delete this folder in Explorer if you want everything gone"
Write-Host "Reinstalling later? Just click 'Install / Repair' again - it sets everything back up."
Stop-Log
exit 0
