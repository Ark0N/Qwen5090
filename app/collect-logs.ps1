<#
.SYNOPSIS
  Bundle all logs + system state into one ZIP for bug reports.

.DESCRIPTION
  Collects Windows-side logs (%LOCALAPPDATA%\Qwen5090\logs), WSL-side logs
  (~/.qwen5090/logs), GPU/driver/WSL state, and tool versions into
  qwen5090-diagnostics-<timestamp>.zip on your Desktop. No admin rights needed.
  Also available as the "Collect diagnostics" button in the GUI.

.EXAMPLE
  .\collect-logs.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [string]$OutFile = ""
)
# Keep going no matter what breaks - a broken component is exactly what we're documenting.
$ErrorActionPreference = "Continue"

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutFile) { $OutFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "qwen5090-diagnostics-$ts.zip" }
$work = Join-Path $env:TEMP "qwen5090-diag-$ts"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Save-Section([string]$file, [string]$title, [scriptblock]$body) {
    $path = Join-Path $work $file
    Add-Content -Path $path -Value "`n===== $title ====="
    try {
        $out = & $body *>&1 | Out-String
        Add-Content -Path $path -Value $out
    } catch {
        Add-Content -Path $path -Value "unavailable: $($_.Exception.Message)"
    }
    Write-Host "collected: $title"
}

Save-Section "system.txt" "Collected at" { Get-Date -Format o }
Save-Section "system.txt" "Windows version" {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object ProductName, DisplayVersion, CurrentBuildNumber | Format-List
}
Save-Section "gpu.txt" "nvidia-smi" { & nvidia-smi }
Save-Section "gpu.txt" "GPU summary" { & nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,compute_cap --format=csv }
Save-Section "wsl.txt" "wsl --version" { (& wsl --version) -replace "`0", "" }
Save-Section "wsl.txt" "wsl --status" { (& wsl --status) -replace "`0", "" }
Save-Section "wsl.txt" "wsl -l -v" { (& wsl -l -v) -replace "`0", "" }
Save-Section "wsl-env.txt" "GPU inside WSL" { & wsl -d $Distro -- bash -c "nvidia-smi 2>&1 | head -25" }
Save-Section "wsl-env.txt" "venv versions" { & wsl -d $Distro -- bash -c "~/.qwen5090/venv/bin/python --version 2>&1; ~/.qwen5090/venv/bin/vllm --version 2>&1" }
Save-Section "wsl-env.txt" "disk space" { & wsl -d $Distro -- bash -c "df -h / 2>&1" }
Save-Section "wsl-env.txt" "memory" { & wsl -d $Distro -- bash -c "free -h 2>&1" }
# Version and liveness only. Deliberately NOT ~/.dsh/settings.yaml: the Web UI's
# own Models page writes credentials into that document, so it can hold a real
# cloud API key - and this bundle is made to be attached to a bug report.
Save-Section "wsl-env.txt" "DeepSeek Harness" { & wsl -d $Distro -- bash -c "node -v 2>&1; `$HOME/.dsh-runtime/node_modules/.bin/dsh --version 2>&1 || echo 'dsh not installed'; curl -sf -o /dev/null -m 3 http://127.0.0.1:3080/ && echo 'web UI: up' || echo 'web UI: not running'" }
Save-Section "wsl-logs.txt" "WSL-side logs (last 400 lines each)" {
    & wsl -d $Distro -- bash -c "for f in `$HOME/.qwen5090/logs/*.log; do [ -f `$f ] || continue; echo; echo '----- '`$f; tail -n 400 `$f; done"
}

$winLogs = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
if (Test-Path $winLogs) {
    Copy-Item $winLogs -Destination (Join-Path $work "windows-logs") -Recurse -Force
    Write-Host "collected: Windows-side logs"
}

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $OutFile -Force
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Diagnostics bundle: $OutFile"
Write-Host "Attach this file when reporting an issue."
