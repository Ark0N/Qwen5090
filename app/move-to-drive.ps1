<#
.SYNOPSIS
  Move the WSL distro - and with it the model weights and the Python
  environment - onto another drive.

.DESCRIPTION
  Everything the WSL half of this toolkit downloads lives inside the distro's
  virtual disk: the venv (about 10 GB) and the Qwen weights (19-23 GB). WSL
  puts that disk under %LOCALAPPDATA% on C:, and there is no setting to move
  it, so the only way to free C: is to export the distro and import it back
  somewhere else.

  Pointing HF_HOME at /mnt/e instead would look simpler and is a trap: vLLM
  maps each weight shard with a private, WRITABLE mmap, which is exactly the
  operation that Windows-drive filesystems do not support properly from inside
  WSL. The weights have to sit on the distro's own ext4.

  This is not a small operation - it exports the whole distro, unregisters it,
  and imports it at the new location - so it asks before doing anything and
  keeps the exported tarball until the new copy has answered for itself.

.EXAMPLE
  .\move-to-drive.ps1 -Drive E:            # show what it would do
  .\move-to-drive.ps1 -Drive E: -Apply   # actually do it
#>
[CmdletBinding()]
param(
    [string]$Drive = "E:",
    [string]$Distro = "Ubuntu-24.04",
    # Nothing happens without this. The export/unregister/import sequence is
    # not something to start by accident. Named -Apply rather than -Confirm,
    # which PowerShell reserves for ShouldProcess.
    [switch]$Apply,
    # Keep the export tarball after a successful import.
    [switch]$KeepBackup
)
$ErrorActionPreference = "Stop"

function Say  ($m) { Write-Host ">> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path "$Drive\")) { Die "$Drive is not available." }

$registered = (& wsl --list --quiet) -replace "`0", "" -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($registered -notcontains $Distro) { Die "WSL distro '$Distro' is not registered - nothing to move." }

$target  = Join-Path $Drive "Qwen5090\wsl\$Distro"
$backup  = Join-Path $Drive "Qwen5090\wsl\$Distro-export-$(Get-Date -Format 'yyyyMMdd-HHmmss').tar"

# Where it lives now, and how big, so the report is about this machine rather
# than about WSL in general.
$current = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Packages"), (Join-Path $env:LOCALAPPDATA "wsl") `
             -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
$sizeGB = if ($current) { [math]::Round($current.Length / 1GB, 1) } else { 0 }
$freeGB = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'").FreeSpace / 1GB)

Say "distro   : $Distro"
if ($current) { Say "disk now : $($current.FullName) ($sizeGB GB)" }
Say "moving to: $target"
Say "$Drive has $freeGB GB free"

# The export is written before the original is removed, so the peak requirement
# is both copies at once.
$needGB = [math]::Ceiling($sizeGB * 2)
if ($freeGB -lt $needGB) {
    Die "$Drive needs about $needGB GB free (the export and the imported copy exist at the same time) and has $freeGB GB."
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "This would:" -ForegroundColor Yellow
    Write-Host "  1. shut WSL down"
    Write-Host "  2. export $Distro to $backup"
    Write-Host "  3. unregister $Distro  (the copy on C: is deleted at this point)"
    Write-Host "  4. import it at $target"
    Write-Host "  5. check it starts, then $(if ($KeepBackup) { 'keep' } else { 'delete' }) the export"
    Write-Host ""
    Write-Host "Re-run with -Apply to go ahead. Stop the server first." -ForegroundColor Yellow
    exit 0
}

# A running server holds the distro open, and exporting underneath it produces
# a tarball of a half-written filesystem.
$busy = & wsl -d $Distro -- bash -c "pgrep -f 'vllm serve' >/dev/null 2>&1 && echo busy || true" 2>$null
if ($busy -match "busy") { Die "the vLLM server is running in $Distro - stop it first." }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null

Say "shutting WSL down"
& wsl --shutdown | Out-Null

Say "exporting to $backup - this writes $sizeGB GB and takes a while"
& wsl --export $Distro "$backup"
if ($LASTEXITCODE -ne 0) { Die "export failed - nothing has been changed yet." }
if (-not (Test-Path $backup)) { Die "export reported success but $backup is missing - stopping." }

Say "unregistering $Distro"
& wsl --unregister $Distro
if ($LASTEXITCODE -ne 0) { Die "unregister failed. The export is intact at $backup - import it manually with:`n    wsl --import $Distro `"$target`" `"$backup`"" }

Say "importing at $target"
New-Item -ItemType Directory -Force -Path $target | Out-Null
& wsl --import $Distro "$target" "$backup"
if ($LASTEXITCODE -ne 0) { Die "import failed. Your data is still in $backup - retry with:`n    wsl --import $Distro `"$target`" `"$backup`"" }

# An imported distro forgets its default user and comes back as root, which
# breaks every script here that expects the qwen user's home.
Say "restoring the default user"
& wsl -d $Distro -- bash -c "id -u qwen >/dev/null 2>&1 && printf '[user]\ndefault=qwen\n' >> /etc/wsl.conf || true" 2>$null
& wsl --terminate $Distro | Out-Null

$who = (& wsl -d $Distro -- whoami) -replace "`0", ""
Say "distro starts, running as '$($who.Trim())'"
if ($who -notmatch "qwen") {
    Warn "the default user did not come back as 'qwen'. Fix it inside the distro with:
         printf '[user]\ndefault=qwen\n' | sudo tee -a /etc/wsl.conf   then  wsl --terminate $Distro"
}

if ($KeepBackup) {
    Say "keeping the export at $backup ($sizeGB GB) - delete it when you are satisfied"
} else {
    Remove-Item $backup -Force -ErrorAction SilentlyContinue
    Say "export removed"
}
Say "done - $Distro now lives on $Drive"
