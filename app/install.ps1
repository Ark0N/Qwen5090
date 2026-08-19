#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-shot installer for running Qwen3.8-27B (NVFP4) on Windows 11 + RTX 5090.

.DESCRIPTION
  Checks Windows 11, the NVIDIA driver, and WSL2; installs Ubuntu-24.04 if
  missing; then runs the Linux-side setup (uv + Python 3.13 + vLLM + ~22 GB
  model download). Re-running after a reboot or a fixed prerequisite is safe.

  In -Unattended mode (used by gui.ps1) the Ubuntu distro is provisioned
  silently — a 'qwen' Linux user is created automatically, no prompts — and a
  RunOnce entry re-opens the GUI after a required reboot.

  Exit codes: 0 = success, 1 = failure, 3010 = reboot required (re-run after).

.EXAMPLE
  .\install.ps1
  .\install.ps1 -SkipDownload   # set everything up but let vLLM fetch weights on first run
  .\install.ps1 -Uncensored     # the abliterated build (public download, no account)
  .\install.ps1 -Unattended     # no prompts; what gui.ps1 runs under the hood
  .\install.ps1 -WslMemoryOnly  # only re-size the WSL VM from this PC's RAM, then exit
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    # Which checkpoint to download. -Uncensored is the abliterated NVFP4
    # re-quant, a public download. -HfToken is only needed for a gated repo
    # passed via -Model (the GUI hands it over in QWEN5090_HF_TOKEN).
    [string]$Model = "",
    [switch]$Uncensored,
    [string]$HfToken = $env:QWEN5090_HF_TOKEN,
    [switch]$SkipDownload,
    [switch]$Unattended,
    [switch]$NoShortcut,
    [switch]$WslMemoryOnly
)
$ErrorActionPreference = "Stop"

$script:ModelStandard = "unsloth/Qwen3.8-27B-NVFP4"
$script:ModelUncensored = "sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4"
$script:ModelUncensoredGated = "orcarouter/Qwen3.8-27B-Uncensored-NVFP4"
if (-not $Model) { $Model = if ($Uncensored) { $script:ModelUncensored } else { $script:ModelStandard } }
# Both values end up inside a single-quoted bash string; keep them to the shapes
# Hugging Face actually uses so nothing can break out of the quoting.
if ($Model -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    Write-Host "ERROR: '$Model' is not a Hugging Face repo id (owner/name)." -ForegroundColor Red; exit 1
}
if ($HfToken -and $HfToken -notmatch '^[A-Za-z0-9_-]{8,200}$') {
    Write-Host "ERROR: that does not look like a Hugging Face token (expected hf_...)." -ForegroundColor Red; exit 1
}

# Every run is transcribed to %LOCALAPPDATA%\Qwen5090\logs so failures leave
# a trace even outside the GUI (which also captures stdout separately).
$script:LogDir = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogFile = Join-Path $script:LogDir ("install-{0}.transcript.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try { Start-Transcript -Path $script:LogFile -Force | Out-Null } catch { }
function Stop-Log { try { Stop-Transcript | Out-Null } catch { } }

function Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; Stop-Log; exit 1 }

function Format-Elapsed([TimeSpan]$Span) {
    if ($Span.TotalMinutes -ge 1) { return ("{0}m {1:d2}s" -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds) }
    return ("{0}s" -f $Span.Seconds)
}

function Read-ProcessOutput([string]$Path) {
    # wsl.exe emits UTF-16 (interleaved NULs when decoded as ANSI/UTF-8) and
    # rewrites progress lines with bare CRs; normalize both into plain lines.
    if (-not (Test-Path $Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $raw = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return @() }
    $raw = $raw -replace "`0", ""
    return @(($raw -split "[`r`n]+") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Invoke-Streamed {
    <#
      Runs an external command with stdout/stderr redirected to files, echoing
      new output lines as they arrive and printing an elapsed-time heartbeat
      after every ~10 s of silence, so long steps never look hung (the GUI
      tails this script's stdout). Returns the process exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = "",
        [int]$HeartbeatSec = 10
    )
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $outFile = Join-Path $script:LogDir "step-$stamp.out.log"
    $errFile = Join-Path $script:LogDir "step-$stamp.err.log"
    $startArgs = @{
        FilePath = $FilePath; PassThru = $true; NoNewWindow = $true
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
    }
    if ($Arguments) { $startArgs.ArgumentList = $Arguments }
    $proc = Start-Process @startArgs

    $total = [System.Diagnostics.Stopwatch]::StartNew()
    $quiet = [System.Diagnostics.Stopwatch]::StartNew()
    $shown = 0
    $lastPrinted = ""
    $prevTail = $null; $tailPolls = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        $lines = @(Read-ProcessOutput $outFile)
        # Lines before the newest one are complete - print them as they arrive.
        $ready = @(); if ($lines.Count -gt 1) { $ready = @($lines[0..($lines.Count - 2)]) }
        while ($shown -lt $ready.Count) {
            if ($ready[$shown] -ne $lastPrinted) {
                $lastPrinted = $ready[$shown]
                Write-Host "   $lastPrinted"
                $quiet.Restart()
            }
            $shown++
        }
        # The newest line may still be partial; print it once it stops changing.
        $tail = $null; if ($lines.Count -gt 0) { $tail = $lines[$lines.Count - 1] }
        if ($tail) {
            if ($tail -eq $prevTail) { $tailPolls++ } else { $prevTail = $tail; $tailPolls = 0 }
            if ($tailPolls -eq 2 -and $tail -ne $lastPrinted) {
                $lastPrinted = $tail
                Write-Host "   $tail"
                $quiet.Restart()
            }
        }
        if ($quiet.Elapsed.TotalSeconds -ge $HeartbeatSec) {
            Write-Host ("   ... {0} is still running ({1} elapsed) - please wait" -f $Activity, (Format-Elapsed $total.Elapsed))
            $quiet.Restart()
        }
    }
    $proc.WaitForExit()
    foreach ($line in @(Read-ProcessOutput $outFile) | Select-Object -Skip $shown) {
        if ($line -ne $lastPrinted) { $lastPrinted = $line; Write-Host "   $line" }
    }
    foreach ($line in @(Read-ProcessOutput $errFile)) { Write-Host "   $line" }
    if ($proc.ExitCode -eq 0) {
        Write-Host ("   {0} finished in {1}." -f $Activity, (Format-Elapsed $total.Elapsed))
    } else {
        Write-Host ("   {0} exited with code {1} after {2}." -f $Activity, $proc.ExitCode, (Format-Elapsed $total.Elapsed)) -ForegroundColor Yellow
    }
    return $proc.ExitCode
}

Write-Host "Logging this run to: $script:LogFile"
Write-Host ("Run context: time={0} | unattended={1} | skipDownload={2} | distro={3} | model={4} | hfToken={5}" -f (Get-Date -Format o), [bool]$Unattended, [bool]$SkipDownload, $Distro, $Model, [bool]$HfToken)
try { Write-Host ("WSL: " + (((& wsl --version 2>$null) -replace "`0", "" | Where-Object { $_ }) -join " | ")) } catch { Write-Host "WSL: not queryable yet" }

function ConvertFrom-WslSize {
    <#
      .wslconfig sizes look like 16GB / 16G / 12000MB / 8000000000 (bare = bytes).
      Returns the value in GB, or $null when it cannot be parsed.
    #>
    param([string]$Value)
    if (-not $Value) { return $null }
    if ($Value.Trim() -notmatch '^(?<num>\d+(\.\d+)?)\s*(?<unit>[KMGT]?B?)$') { return $null }
    $num = [double]$matches['num']
    switch ($matches['unit'].ToUpper().TrimEnd('B')) {
        'T'     { return $num * 1024 }
        'G'     { return $num }
        'M'     { return $num / 1024 }
        'K'     { return $num / 1048576 }
        default { return $num / 1GB }
    }
}

function Set-WslMemoryLimit {
    <#
      vLLM maps the whole ~22 GB weights file in one go, and Linux refuses a
      mapping bigger than the VM's RAM + swap ("unable to mmap ...: Cannot
      allocate memory (12)"). WSL2 defaults to half the PC's RAM plus a quarter
      of that as swap - not enough on a 32 GB machine - so raise the limits in
      %USERPROFILE%\.wslconfig. Existing values are only ever raised, and other
      keys/sections are left untouched. Returns $true if the file changed.
    #>
    $needGB = 28   # ~22 GB of weights + the loader's own working set
    $hostGB = 0
    try { $hostGB = [int][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { }
    if ($hostGB -le 0) {
        Write-Host "   Could not read the installed RAM - leaving the WSL memory settings alone." -ForegroundColor Yellow
        return $false
    }

    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $lines = @()
    if (Test-Path -LiteralPath $path) { $lines = @(Get-Content -LiteralPath $path) }

    # Find the [wsl2] section and any memory=/swap= keys inside it.
    $hdrIdx = -1; $memIdx = -1; $swapIdx = -1; $inWsl2 = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -match '^\[(.+)\]$') {
            $inWsl2 = ($matches[1].Trim().ToLower() -eq 'wsl2')
            if ($inWsl2 -and $hdrIdx -lt 0) { $hdrIdx = $i }
            continue
        }
        if (-not $inWsl2) { continue }
        if ($line -match '^memory\s*=') { $memIdx = $i }
        elseif ($line -match '^swap\s*=') { $swapIdx = $i }
    }

    $curMem = $null;  if ($memIdx  -ge 0) { $curMem  = ConvertFrom-WslSize (($lines[$memIdx]  -split '=', 2)[1]) }
    $curSwap = $null; if ($swapIdx -ge 0) { $curSwap = ConvertFrom-WslSize (($lines[$swapIdx] -split '=', 2)[1]) }
    if ($null -eq $curMem)  { $curMem  = [math]::Floor($hostGB / 2) }   # WSL2 default
    if ($null -eq $curSwap) { $curSwap = [math]::Floor($curMem / 4) }   # WSL2 default
    Write-Host ("   This PC has {0} GB RAM; WSL2 may use {1} GB + {2} GB swap." -f $hostGB, [int]$curMem, [int]$curSwap)
    if (($curMem + $curSwap) -ge $needGB) {
        Write-Host "   Enough to load the model - no change needed."
        return $false
    }

    # Leave Windows at least 8 GB; make up any shortfall with swap, which is a
    # sparse file and costs nothing until the loader actually needs it.
    $newMem = [int][math]::Min([double]$needGB, [math]::Max([double]($hostGB - 8), [double]$curMem))
    $newSwap = [int][math]::Max([double]$curSwap, [math]::Max([double]($needGB - $newMem), 8.0))
    $memLine = "memory=${newMem}GB"
    $swapLine = "swap=${newSwap}GB"

    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $memIdx)       { $null = $out.Add($memLine) }
        elseif ($i -eq $swapIdx)  { $null = $out.Add($swapLine) }
        else                      { $null = $out.Add($lines[$i]) }
    }
    if ($hdrIdx -lt 0) {
        if ($out.Count -gt 0) { $null = $out.Add("") }
        $null = $out.Add("[wsl2]")
        $null = $out.Add($memLine)
        $null = $out.Add($swapLine)
    } else {
        $insert = @()
        if ($memIdx  -lt 0) { $insert += $memLine }
        if ($swapIdx -lt 0) { $insert += $swapLine }
        # Add a missing key below the one that is already there, not above it.
        $anchor = [math]::Max($hdrIdx, [math]::Max($memIdx, $swapIdx))
        if ($insert.Count -gt 0) { $out.InsertRange($anchor + 1, [string[]]$insert) }
    }

    try {
        if (Test-Path -LiteralPath $path) {
            $backup = "$path.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
            Copy-Item -LiteralPath $path -Destination $backup -Force
            Write-Host "   Existing settings backed up to $backup"
        }
        # No BOM: WSL ignores a .wslconfig that starts with one.
        [System.IO.File]::WriteAllLines($path, [string[]]$out, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Host "   WARNING: could not write $path ($($_.Exception.Message)) - the server may fail to load the model." -ForegroundColor Yellow
        return $false
    }
    Write-Host "   Raised WSL2 limits in ${path}: $memLine, $swapLine"
    return $true
}

function Register-ResumeAfterReboot {
    # Re-open the GUI at next logon so the user can continue with one click.
    # The launcher lives one level up from app\ (the repo root).
    $launcher = Join-Path (Split-Path $PSScriptRoot -Parent) "Start Qwen 5090.cmd"
    if (Test-Path $launcher) {
        $cmd = "cmd /c start `"`" `"$launcher`""
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
            -Name "Qwen5090Resume" -Value $cmd -PropertyType String -Force | Out-Null
        Write-Host "The Qwen 5090 app will re-open automatically after you log back in."
    }
}

function Test-DistroReady {
    param([int]$Retries = 10)
    # A freshly registered rootfs can take a few seconds to accept commands.
    for ($i = 0; $i -lt $Retries; $i++) {
        & wsl -d $Distro -u root -- bash -c "exit 0" *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Install-DistroUnattended {
    # Silent provisioning: register the distro without OOBE, create a 'qwen'
    # user with passwordless sudo, and make it the default. Returns $true on success.
    Write-Host "Step 1/3: Downloading and registering $Distro (several hundred MB - progress below)..."
    $code = Invoke-Streamed -Activity "the $Distro download" -FilePath "wsl" -Arguments "--install -d $Distro --no-launch"
    if ($code -ne 0) { return $false }

    Write-Host "Step 2/3: Unpacking the Linux filesystem (usually 1-2 minutes, produces little output)..."
    # Older WSL builds only unpack the rootfs when the store launcher
    # ("ubuntu2404.exe") runs. WSL 2.4+ unpacks during '--install --no-launch'
    # and often does not put that launcher on PATH at all, so treat it as an
    # optimization: what decides success is whether root commands work after.
    $launcherName = (($Distro -replace '[-.]', '').ToLower()) + ".exe"
    $launcher = Get-Command $launcherName -ErrorAction SilentlyContinue
    if ($launcher) {
        $code = Invoke-Streamed -Activity "the $Distro first-time setup" -FilePath $launcher.Source -Arguments "install --root"
        if ($code -ne 0) { Write-Host "   $launcherName exited with $code - checking whether the distro works anyway..." -ForegroundColor Yellow }
    } else {
        Write-Host "   ($launcherName is not on PATH - this WSL version does not need it.)"
    }
    if (-not (Test-DistroReady)) {
        Write-Host "$Distro is registered but not accepting commands yet." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Step 3/3: Creating the 'qwen' Linux user account..."
    & wsl -d $Distro -u root -- bash -c "id qwen >/dev/null 2>&1 || useradd -m -s /bin/bash qwen; usermod -aG sudo qwen; echo 'qwen ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/qwen; chmod 440 /etc/sudoers.d/qwen; printf '[user]\ndefault=qwen\n' > /etc/wsl.conf" *>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        # A distro that runs as root still works end to end; don't fail the
        # whole install (and re-trigger a pointless OOBE) over the user account.
        Write-Host "WARNING: could not create the 'qwen' user - continuing with root as the default user." -ForegroundColor Yellow
        return $true
    }
    & wsl --terminate $Distro *> $null
    Write-Host "User account ready."
    return $true
}

function New-DesktopShortcut {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $launcher = Join-Path $repoRoot "Start Qwen 5090.cmd"
    if (-not (Test-Path $launcher)) { return }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "Qwen 5090.lnk"))
        $lnk.TargetPath = $launcher
        $lnk.WorkingDirectory = $repoRoot
        $lnk.Description = "Qwen3.8-27B local AI on your RTX 5090"
        $lnk.Save()
        Write-Host "Desktop shortcut created: Qwen 5090"
    } catch {
        Write-Host "WARNING: could not create a desktop shortcut ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

if ($WslMemoryOnly) {
    # Escape hatch for a machine that is installed but cannot load the weights:
    # size the VM from this PC's RAM and get out, no prerequisite checks.
    Step "Sizing the WSL virtual machine"
    if (Set-WslMemoryLimit) {
        Write-Host "   Restarting WSL so the new limits take effect (this stops any running server)..."
        & wsl --shutdown *> $null
        Write-Host "Done - start the server again."
    } else {
        Write-Host "Nothing to change."
    }
    Stop-Log
    exit 0
}

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

Step "Checking CPU virtualization (required for WSL2)"
# Three states matter here:
#  - hypervisor already running            -> fine
#  - firmware on, hypervisor launch off    -> bcdedit fix + one reboot (3010)
#  - firmware off                          -> only the BIOS can fix it; fail with instructions
$hvPresent = $false
try { $hvPresent = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
if ($hvPresent) {
    Write-Host "Hypervisor is running - OK"
} else {
    $fwEnabled = $null
    try { $fwEnabled = [bool](Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
    if ($null -eq $fwEnabled) {
        Write-Host "WARNING: could not query the virtualization state - continuing; WSL will complain if it is off." -ForegroundColor Yellow
    } elseif ($fwEnabled) {
        $bcd = ""
        try { $bcd = (& bcdedit /enum "{current}") -join "`n" } catch { }
        if ($bcd -match 'hypervisorlaunchtype\s+Off') {
            # Commonly left behind by VirtualBox/anti-cheat guides; WSL2 fails with
            # HCS_E_HYPERV_NOT_INSTALLED until the hypervisor is allowed to start.
            Write-Host "Virtualization is enabled in firmware, but the Windows hypervisor is switched off"
            Write-Host "(hypervisorlaunchtype = Off) - turning it back on..."
            & bcdedit /set "{current}" hypervisorlaunchtype auto | Out-Null
            if ($Unattended) { Register-ResumeAfterReboot }
            Write-Host "`nDone. Windows needs ONE reboot for the hypervisor to start, then setup continues." -ForegroundColor Yellow
            if (-not $Unattended) { Write-Host "After rebooting, run .\install.ps1 again." -ForegroundColor Yellow }
            Stop-Log
            exit 3010
        }
        Write-Host "Virtualization is enabled in firmware - OK (Windows starts the hypervisor during WSL setup)"
    } else {
        Write-Host "CPU virtualization is DISABLED in your BIOS/UEFI firmware." -ForegroundColor Red
        Write-Host "WSL2 cannot run without it (WSL reports error HCS_E_HYPERV_NOT_INSTALLED)."
        Write-Host ""
        Write-Host "How to fix (about 5 minutes):"
        Write-Host "  1. Restart into firmware settings: Settings > System > Recovery > Advanced startup >"
        Write-Host "     Restart now, then Troubleshoot > Advanced options > UEFI Firmware Settings"
        Write-Host "     (or press Del/F2 while the PC boots)."
        Write-Host "  2. Enable the setting for your CPU (usually under Advanced or CPU Configuration):"
        Write-Host "       Intel:  'Intel Virtualization Technology' / 'VT-x'"
        Write-Host "       AMD:    'SVM Mode'"
        Write-Host "  3. Save and exit (usually F10), boot Windows, and run the installer again."
        Fail "Enable virtualization in the BIOS/UEFI, then re-run this installer."
    }
}

Step "Checking WSL2"
& wsl --status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "WSL is not installed yet - downloading and installing it now."
    Write-Host "This can take several minutes depending on your connection; progress appears below."
    $null = Invoke-Streamed -Activity "the WSL installation" -FilePath "wsl" -Arguments "--install --no-distribution"
    if ($Unattended) { Register-ResumeAfterReboot }
    Write-Host "`nWSL installed. Windows needs ONE reboot, then setup continues." -ForegroundColor Yellow
    if (-not $Unattended) { Write-Host "After rebooting, run .\install.ps1 again." -ForegroundColor Yellow }
    Stop-Log
    exit 3010
}
Write-Host "WSL is installed. Checking for WSL kernel updates (your Blackwell GPU needs a recent kernel)."
Write-Host "This is quick if WSL is already current, but can take a few minutes the first time."
$null = Invoke-Streamed -Activity "the WSL kernel update" -FilePath "wsl" -Arguments "--update"   # best-effort
Write-Host "WSL2 - OK"

Step "Sizing the WSL virtual machine"
# The model is loaded through a single ~22 GB memory mapping; a default-sized
# WSL VM (half the PC's RAM) cannot back it and the server dies at load time.
if (Set-WslMemoryLimit) {
    Write-Host "   Restarting WSL so the new limits take effect (this stops any running server)..."
    & wsl --shutdown *> $null
}

Step "Checking Linux distro ($Distro)"
# wsl.exe prints UTF-16; strip the interleaved nulls before comparing.
$distros = (& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
if ($distros -notcontains $Distro) {
    $installed = $false
    Write-Host "$Distro is not installed yet - setting it up now (three sub-steps, a few minutes total)."
    $installed = Install-DistroUnattended
    if (-not $installed) {
        Write-Host "Silent install unavailable - falling back to the interactive Ubuntu setup." -ForegroundColor Yellow
        Write-Host "A window will open asking you to create a Linux username and password;" -ForegroundColor Yellow
        Write-Host "type 'exit' in the Linux shell when done." -ForegroundColor Yellow
        # If it is already registered, '--install' is a no-op - opening a shell
        # is what actually runs the first-time setup.
        $distros = (& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
        if ($distros -contains $Distro) { Start-Process wsl -ArgumentList "-d $Distro" -Wait }
        else { Start-Process wsl -ArgumentList "--install -d $Distro" -Wait }
        $distros = (& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }
        if ($distros -notcontains $Distro) { Fail "Failed to install $Distro. Run 'wsl --install -d $Distro' manually, then re-run this script." }
    }
} else {
    Write-Host "$Distro is already installed."
}
Write-Host "$Distro - OK"

Step "Running Linux-side setup (vLLM install + model download)"
Write-Host "Model: $Model"
if ($Model -eq $script:ModelUncensored) {
    Write-Host "This build has its safety alignment removed (abliterated)."
}
if ($Model -eq $script:ModelUncensoredGated) {
    Write-Host "This build has its safety alignment removed and is gated on Hugging Face;"
    Write-Host "accept its terms once at https://huggingface.co/$Model if you have not."
}
Write-Host "This is the longest step: Python + vLLM install, then the model download (~22 GB)."
Write-Host "Detailed progress streams below the whole time."
$repoWin = $PSScriptRoot -replace '\\', '/'
$repoWsl = ((& wsl -d $Distro -- wslpath -a "$repoWin") -replace "`0", "").Trim()
if (-not $repoWsl) { Fail "Could not translate the repo path into WSL. Is $Distro initialized? Try 'wsl -d $Distro' once, then re-run." }
$envPrefix = "MODEL='$Model' "
if ($HfToken) { $envPrefix += "HF_TOKEN='$HfToken' " }
if ($SkipDownload) { $envPrefix += "SKIP_DOWNLOAD=1 " }
if ($Unattended) { $envPrefix += "NONINTERACTIVE=1 " }
& wsl -d $Distro -- bash -c "${envPrefix}bash '$repoWsl/scripts/setup-wsl.sh'"
if ($LASTEXITCODE -ne 0) { Fail "Linux-side setup failed - see the output above, then re-run .\install.ps1 (it resumes safely)." }

if (-not $NoShortcut) {
    Step "Creating desktop shortcut"
    New-DesktopShortcut
}

Step "All done"
Write-Host "Open the app     :  double-click 'Start Qwen 5090.cmd' (or the 'Qwen 5090' desktop shortcut)"
Write-Host "Command line     :  .\app\run.ps1 to serve, .\app\chat.ps1 to chat"
if ($Model -ne $script:ModelStandard) { Write-Host "Serve this model :  .\app\run.ps1 -Model $Model" }
Write-Host "API endpoint     :  http://localhost:8000/v1   (OpenAI-compatible, api_key can be anything)"
Stop-Log
exit 0
