<#
.SYNOPSIS
  Terminal chat against the local server started by run.ps1.

.EXAMPLE
  .\chat.ps1                    # thinking mode on (dim text = reasoning)
  .\chat.ps1 -NoThink           # direct answers
  .\chat.ps1 -Effort high       # crank the reasoning dial
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [int]$Port = 8000,
    [switch]$NoThink,
    [ValidateSet("low", "medium", "high", "xhigh")]
    [string]$Effort
)
$ErrorActionPreference = "Stop"

$repoWin = $PSScriptRoot -replace '\\', '/'
$repoWsl = ((& wsl -d $Distro -- wslpath -a "$repoWin") -replace "`0", "").Trim()
if (-not $repoWsl) { Write-Host "ERROR: WSL distro '$Distro' not ready - run .\install.ps1 first." -ForegroundColor Red; exit 1 }

$chatArgs = "--port $Port"
if ($NoThink) { $chatArgs += " --no-think" }
if ($Effort) { $chatArgs += " --effort $Effort" }
& wsl -d $Distro -- bash -c "`$HOME/.qwen5090/venv/bin/python '$repoWsl/scripts/chat.py' $chatArgs"
