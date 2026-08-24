<#
.SYNOPSIS
  Point the DeepSeek Harness (dsh) at this PC's Qwen 5090 server.

.DESCRIPTION
  The DeepSeek Harness is DeepSeek's own agent runtime. Unlike Claude Code it
  speaks the OpenAI API natively, so there is no translation bridge here - this
  starts the harness inside WSL (scripts/deepseek-harness.sh), points a provider
  route at the model server, and serves a Web UI you open in your browser.

  The Qwen server should already be running - use the app's Run button, or
  .\app\run.ps1. Without one, the route is written from whatever the harness
  already knew, and the model selector will have nothing new to offer.

  dsh itself is installed on demand the first time it is started (or up front
  with -Install). It needs Node.js >= 22.19 inside WSL, which it will NOT
  install for you - see -Install below.

.EXAMPLE
  .\deepseek-harness.ps1                 # start it, print the URL to open
.EXAMPLE
  .\deepseek-harness.ps1 -Install        # install dsh inside WSL, nothing else
.EXAMPLE
  .\deepseek-harness.ps1 -Config         # rewrite the provider route only
.EXAMPLE
  .\deepseek-harness.ps1 -Status ; .\deepseek-harness.ps1 -Stop
.EXAMPLE
  .\deepseek-harness.ps1 -Service        # keep it running across reboots
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    # Where the model server is. The harness asks it what it is serving and
    # writes the answer into its own settings, so this has to be right.
    [int]$Port = 8000,
    # Where the Web UI listens. 3080 is the harness's own default.
    [int]$UiPort = 3080,
    # Pin the context window instead of letting the harness work it out. Only
    # needed when it cannot: it reads the window from /v1/models on vLLM, and
    # probes for it on NInfer, which publishes none.
    [int]$Ctx = 0,
    # Install dsh inside WSL and stop there. Not required before a start - the
    # start does it on demand - but the GUI offers it as its own step so the
    # download happens when the user asks for it rather than mid-launch.
    [switch]$Install,
    # Write the provider route and stop, without starting anything. Useful after
    # switching backends or models: the route follows whatever is on $Port.
    [switch]$Config,
    # Install a systemd --user unit inside WSL so it survives a reboot.
    [switch]$Service,
    # Install Node.js into the WSL user's home directory and stop there. The
    # harness needs >= 22.19 and refuses to install a language runtime by
    # itself; Ubuntu 24.04 - what install.ps1 provisions - ships Node 18, so on
    # a fresh box this is a required step rather than an edge case.
    [switch]$InstallNode,
    [switch]$Status,
    [switch]$Stop,
    [switch]$Doctor,
    # Remove dsh and its unit. Sessions and settings under ~/.dsh are kept.
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"

# The bash half lives next to this file. Translate C:\path\to -> /mnt/c/path/to;
# never hand wsl.exe a Windows path.
$scriptWin = Join-Path $PSScriptRoot "scripts\deepseek-harness.sh"
if (-not (Test-Path $scriptWin)) {
    Write-Host "ERROR: scripts\deepseek-harness.sh is missing next to this script." -ForegroundColor Red
    exit 1
}
$drive = $scriptWin.Substring(0,1).ToLower()
$scriptWsl = "/mnt/$drive" + ($scriptWin.Substring(2) -replace '\\','/')

$verb = "start"
if ($Stop)      { $verb = "stop" }
if ($Status)    { $verb = "status" }
if ($Doctor)    { $verb = "doctor" }
if ($Config)    { $verb = "config" }
if ($Install)   { $verb = "install" }
if ($InstallNode) { $verb = "install-node" }
if ($Service)   { $verb = "service" }
if ($Uninstall) { $verb = "uninstall" }

# Bind the Web UI where a Windows browser can actually reach it. WSL's localhost
# relay only forwards ports bound to all interfaces, so a 127.0.0.1 UI inside
# the distro is invisible from Windows - the browser would just refuse to
# connect. WSL sits behind its own NAT, so this is not a LAN exposure; it is the
# same reasoning the Claude Code bridge's -BindAll switch uses.
#
# On native Linux the script defaults to loopback instead, deliberately: there
# the harness IS on the LAN's machine, and it runs shell commands.
$envPrefix = "QWEN_URL=http://localhost:$Port DSH_HOST=0.0.0.0 DSH_PORT=$UiPort"
if ($Ctx -gt 0) { $envPrefix += " QWEN_CTX=$Ctx" }

# Everything after -- goes through as ONE bash -c string: wsl.exe re-joins a
# multi-argument tail through the default shell and quoting does not survive.
$bashCmd = "$envPrefix bash '$scriptWsl' $verb"

& wsl -d $Distro -- bash -c "$bashCmd"
$code = $LASTEXITCODE

# The URL is the whole point of a start, and the harness prints its own
# loopback form - which is right inside WSL and wrong from here.
if ($code -eq 0 -and $verb -eq "start") {
    Write-Host ""
    Write-Host "Open the harness at:  http://127.0.0.1:$UiPort" -ForegroundColor Green
    Write-Host ""
    Write-Host "Pick 'Qwen 5090' in the model selector. It is already pointed at the" -ForegroundColor Cyan
    Write-Host "server on port $Port, and follows whichever engine is running there." -ForegroundColor Cyan
    Write-Host ""
}

exit $code
