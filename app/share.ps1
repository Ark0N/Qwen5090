#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Make the local API reachable from other devices (LAN / Tailscale).

.DESCRIPTION
  WSL2 is NAT'd, so services inside it are localhost-only by default. This
  forwards the API port from all Windows interfaces into WSL (netsh portproxy)
  and opens Windows Firewall for it on Private/Domain networks only —
  Tailscale's interface counts as private; public Wi-Fi stays blocked.

  WSL's internal IP changes across reboots, so re-run after rebooting
  (run.ps1 -Share and the GUI checkbox do this automatically on every start).

.EXAMPLE
  .\share.ps1                # share port 8000
  .\share.ps1 -Remove        # undo
#>
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [string]$Distro = "Ubuntu-24.04",
    [switch]$Remove
)
$ErrorActionPreference = "Stop"
$ruleName = "Qwen5090 API $Port"

if ($Remove) {
    & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 *> $null
    & netsh advfirewall firewall delete rule name="$ruleName" *> $null
    Write-Host "Sharing removed for port $Port."
    exit 0
}

$wslIp = (((& wsl -d $Distro -- hostname -I) -replace "`0", "").Trim() -split '\s+')[0]
if (-not $wslIp) {
    Write-Host "ERROR: could not determine the WSL IP - is $Distro installed and running?" -ForegroundColor Red
    exit 1
}

# Refresh the proxy (idempotent) and the firewall rule.
& netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 *> $null
& netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port connectaddress=$wslIp connectport=$Port | Out-Null
& netsh advfirewall firewall delete rule name="$ruleName" *> $null
& netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$Port profile=private,domain | Out-Null

Write-Host "Port $Port is forwarded into WSL ($wslIp) and allowed on Private/Domain networks."
exit 0
