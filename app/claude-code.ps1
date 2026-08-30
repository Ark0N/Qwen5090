<#
.SYNOPSIS
  Point Claude Code at this PC's Qwen 5090 server.

.DESCRIPTION
  Claude Code speaks the Anthropic API; vLLM serves the OpenAI API. This starts
  a small translation bridge inside WSL (scripts/claude-code.sh) and then either
  launches Claude Code inside WSL, or prints the environment variables a
  Windows-native Claude Code needs.

  The Qwen server must already be running - use the app's Run button, or
  .\app\run.ps1. Claude Code itself is installed on demand the first time a
  session is opened (or up front with -InstallClaude).

.EXAMPLE
  .\claude-code.ps1                  # start the bridge, open Claude Code in WSL
.EXAMPLE
  .\claude-code.ps1 -Windows         # print env vars for Claude Code on Windows
.EXAMPLE
  .\claude-code.ps1 -Effort medium   # think less, answer sooner
.EXAMPLE
  .\claude-code.ps1 -Start          # bridge only, no session (what the GUI uses)
.EXAMPLE
  .\claude-code.ps1 -InstallClaude  # install Claude Code inside WSL, nothing else
.EXAMPLE
  .\claude-code.ps1 -Status ; .\claude-code.ps1 -Stop
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [int]$Port = 8000,
    [int]$BridgePort = 4000,
    # Which levels are legal depends on the checkpoint being served: the Qwen
    # templates take low|medium|xhigh, DeepSeek V4's takes low|high|max, and
    # each rejects the other's spellings with a hard 400. So this is forwarded
    # only when actually bound - the same only-when-bound idiom -GpuUtil uses -
    # and claude-code.sh picks the served template's own default otherwise.
    [ValidateSet('low','medium','xhigh','high','max')]
    [string]$Effort,
    [switch]$Windows,
    # Start the bridge and return, instead of launching a session on top of it.
    [switch]$Start,
    # Bind the bridge where Windows can reach it without also asking for the
    # -Windows env dump. The GUI needs this: it polls the bridge's health from
    # the Windows side, and WSL's localhost relay only forwards ports bound to
    # all interfaces. A 127.0.0.1 bridge is invisible to it, so a session opened
    # from the GUI would run fine behind a pill that still read "stopped".
    [switch]$BindAll,
    # Install Claude Code itself inside WSL and stop there. Not needed before a
    # session - `run` installs it on demand - but the GUI offers it as its own
    # step so the download happens when the user asks for it, not mid-launch.
    [switch]$InstallClaude,
    # Debugging: record every request and reply to ~/.qwen5090/debug as JSONL.
    # Applies from the next bridge start, and stays on until one without it.
    [switch]$LogPayloads,
    [switch]$Status,
    [switch]$Stop,
    [switch]$Doctor
)
$ErrorActionPreference = "Stop"

# The bash half lives next to this file. Translate C:\path\to -> /mnt/c/path/to;
# never hand wsl.exe a Windows path.
$scriptWin = Join-Path $PSScriptRoot "scripts\claude-code.sh"
if (-not (Test-Path $scriptWin)) {
    Write-Host "ERROR: scripts\claude-code.sh is missing next to this script." -ForegroundColor Red
    exit 1
}
$drive = $scriptWin.Substring(0,1).ToLower()
$scriptWsl = "/mnt/$drive" + ($scriptWin.Substring(2) -replace '\\','/')

# Bind the bridge where the client can actually reach it. Claude Code running
# inside WSL wants loopback; a Windows-native one reaches WSL services through
# the localhost relay, which only forwards ports bound to all interfaces.
# WSL sits behind its own NAT, so this is not a LAN exposure.
$bridgeHost = if ($Windows -or $BindAll) { "0.0.0.0" } else { "127.0.0.1" }

$verb = "run"
if ($Start)  { $verb = "start" }
if ($Stop)   { $verb = "stop" }
if ($Status) { $verb = "status" }
if ($Doctor) { $verb = "doctor" }
if ($InstallClaude) { $verb = "install-claude" }
if ($Windows -and -not ($Start -or $Stop -or $Status -or $Doctor -or $InstallClaude)) { $verb = "env" }

# Everything after -- goes through as ONE bash -c string: wsl.exe re-joins a
# multi-argument tail through the default shell and quoting does not survive.
# $ is escaped so bash expands it, not PowerShell.
$envPrefix = "QWEN_URL=http://localhost:$Port BRIDGE_PORT=$BridgePort BRIDGE_HOST=$bridgeHost"
if ($PSBoundParameters.ContainsKey('Effort')) { $envPrefix += " QWEN_EFFORT=$Effort" }
if ($LogPayloads) { $envPrefix += " QWEN_LOG_PAYLOADS=1" }
$bashCmd = "$envPrefix bash '$scriptWsl' $verb"

if ($verb -eq "env") {
    # Ask the bridge for its settings, then translate the exports into
    # PowerShell assignments for this window.
    $lines = & wsl -d $Distro -- bash -c "$bashCmd"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host ""
    Write-Host "Bridge is up. Paste this into the PowerShell window you run Claude Code from:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in $lines) {
        if ($line -match '^\s*export\s+([A-Z0-9_]+)="?([^"]*)"?\s*$') {
            $name = $Matches[1]
            $value = $Matches[2]
            # The bridge listens inside WSL; Windows reaches it over localhost.
            $value = $value -replace '^http://0\.0\.0\.0:', 'http://127.0.0.1:'
            Write-Host ('  $env:{0} = "{1}"' -f $name, $value)
        }
    }
    Write-Host ""
    Write-Host "  claude" -ForegroundColor Green
    Write-Host ""
    # Those exports apply to every 'claude' started from that window, cloud sessions
    # included, so say so here rather than letting someone paste them into a profile.
    Write-Host "Keep that window for Qwen only: the variables apply to every 'claude' you" -ForegroundColor Yellow
    Write-Host "start from it. In a PowerShell profile they would hijack your normal cloud" -ForegroundColor Yellow
    Write-Host "Claude Code permanently. Inside WSL, .\claude-code.ps1 without -Windows keeps" -ForegroundColor Yellow
    Write-Host "the two apart by itself." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

& wsl -d $Distro -- bash -c "$bashCmd"
exit $LASTEXITCODE
