<#
.SYNOPSIS
  Serve a GGUF model with llama.cpp on the 5090 - the second backend, for
  models that cannot fit in VRAM.

.DESCRIPTION
  vLLM holds every weight in VRAM, which is why the Qwen NVFP4 builds are fast
  and why DeepSeek V4-Flash cannot use it: 284B total parameters do not fit in
  32 GB at any quantization, and vLLM's own recipe starts at a 96 GB card. The
  weights live in system RAM instead, with only the attention layers and as
  many experts as fit on the GPU.

  This runs NATIVELY ON WINDOWS, deliberately - not in WSL like everything else
  here. WSL2 takes a fixed slice of RAM (.wslconfig, 20 GB on a 32 GB machine),
  and a model larger than that slice cannot be served from inside it at all.
  Windows maps the file instead and lets its own page cache shrink under
  pressure, which degrades to "slower" rather than "killed".

  Expect single-digit tokens per second on a 32 GB machine. That is the price
  of a 284B model on one consumer card, not a misconfiguration.

.EXAMPLE
  .\serve-gguf.ps1 -Download           # fetch the model, then serve it
  .\serve-gguf.ps1                     # serve what is already downloaded
  .\serve-gguf.ps1 -Model "unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-IQ3_XXS" -Download
  .\serve-gguf.ps1 -Share              # also reachable from LAN/Tailscale
#>
[CmdletBinding()]
param(
    # repo:quant, the spelling llama.cpp's own -hf flag uses.
    [string]$Model = "puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:Q2_K",
    [int]$Ctx = 131072,
    [int]$Port = 8001,
    # Where the weights live. Defaults to the fixed drive with the most room -
    # these are 60 to 105 GB and rarely belong on C:.
    [string]$ModelDir,
    [switch]$Download,
    # Fetch the weights and stop. What the app's Install button uses: the
    # download is the long part and wants its own progress, and nothing should
    # start occupying the GPU behind it.
    [switch]$DownloadOnly,
    # Serve even when the preflight says it will page off the disk.
    [switch]$Force,
    # How many layers keep their experts on the CPU. 0 = all of them, which is
    # the setting that always fits; lowering it moves experts onto the GPU and
    # is the first thing worth tuning once it runs at all.
    [int]$NCpuMoe = 0,
    # DSpark speculative decoding. The drafter is a separate ~11 GB download.
    [switch]$Draft,
    [switch]$Share,
    [string]$ApiKey
)
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ paths ---
$Root      = Split-Path -Parent $PSScriptRoot
$LlamaHome = Join-Path $env:LOCALAPPDATA "Qwen5090\llamacpp"
$LogDir    = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Say  ($m) { Write-Host ">> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- catalog ---
# The same facts as scripts/lib-model-catalog.sh, which is what serve.sh reads.
# Sizes are the weights on disk; Resident is the RAM+VRAM below which the model
# pages off the SSD on every token.
$Catalog = @{
    "puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:Q2_K" = @{
        Label = "DeepSeek V4-Flash 0731 REAP-150B - 2-bit"
        SizeGB = 63; ResidentGB = 69
        Note = "experts pruned 284B -> ~150B, then quantized to 2-bit. The only build in reach of a 32 GB machine - and not the model the published 82.7 Terminal-Bench figure was measured on."
    }
    "puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:IQ3_XXS" = @{
        Label = "DeepSeek V4-Flash 0731 REAP-150B - 3-bit"
        SizeGB = 67; ResidentGB = 73
        Note = "the pruned build at 3-bit."
    }
    "unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-IQ1_S" = @{
        Label = "DeepSeek V4-Flash 0731 - 1-bit"
        SizeGB = 83; ResidentGB = 89
        Note = "the intact 284B weights at their smallest. 1-bit costs tool-calling reliability, which is what an agent depends on."
    }
    "unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-Q2_K_XL" = @{
        Label = "DeepSeek V4-Flash 0731 - 2-bit"
        SizeGB = 97; ResidentGB = 103
        Note = "intact weights, for a 96 GB+ machine."
    }
    "unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-IQ3_XXS" = @{
        Label = "DeepSeek V4-Flash 0731 - 3-bit"
        SizeGB = 105; ResidentGB = 112
        Note = "unsloth's recommended tier and the closest of these to the published numbers. Needs a 128 GB machine."
    }
}

$entry = $Catalog[$Model]
$label = if ($entry) { $entry.Label } else { $Model }

# ------------------------------------------------------------- model dir ----
if (-not $ModelDir) {
    if ($env:QWEN5090_MODEL_DIR) {
        $ModelDir = $env:QWEN5090_MODEL_DIR
    } else {
        $best = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
                Sort-Object -Property FreeSpace -Descending | Select-Object -First 1
        if (-not $best) { Die "no fixed drive found to store the weights on" }
        $ModelDir = Join-Path $best.DeviceID "Qwen5090\models"
    }
}
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

# ------------------------------------------------------------- preflight ----
$repo  = $Model.Split(":")[0]
$quant = if ($Model.Contains(":")) { $Model.Split(":")[1] } else { "" }

$ramTotalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$ramFreeGB  = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB)
$vramFreeGB = 0
try {
    $q = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    if ($q) { $vramFreeGB = [math]::Round(([int]($q -split "`n")[0]) / 1024) }
} catch { }
$driveFreeGB = [math]::Round((Get-Item $ModelDir).PSDrive.Free / 1GB)
$offerGB = $ramFreeGB + $vramFreeGB

Say $label
if ($entry) { Write-Host "   $($entry.Note)" }
Write-Host ("   weights {0} GB | this machine offers {1} GB ({2} VRAM + {3} RAM free of {4} total)" -f `
    $(if ($entry) { $entry.SizeGB } else { "?" }), $offerGB, $vramFreeGB, $ramFreeGB, $ramTotalGB)
Write-Host "   models  : $ModelDir ($driveFreeGB GB free)"

if ($entry) {
    if ($Download -and $driveFreeGB -lt ($entry.SizeGB + 5)) {
        Die "$ModelDir has $driveFreeGB GB free and this needs about $($entry.SizeGB + 5) GB. Pick another drive with -ModelDir."
    }
    if ($offerGB -ge $entry.ResidentGB) {
        Write-Host "   fits in memory - no disk paging" -ForegroundColor Green
    } elseif ($offerGB * 100 -lt $entry.SizeGB * 70) {
        $msg = "$($entry.ResidentGB - $offerGB) GB short of the $($entry.ResidentGB) GB this build needs resident. " +
               "Below about 70% of the weights in memory every token waits on the SSD, and the server reads as hung rather than slow."
        if (-not $Force) { Die "$msg`n       Pick a smaller build, add RAM, or pass -Force to try anyway." }
        Warn "$msg -Force given, going ahead."
    } else {
        Warn "$($entry.ResidentGB - $offerGB) GB short of resident - that much pages off the SSD on every token. It works; it will not be fast."
    }
}

# -------------------------------------------------------------- llama.cpp ---
# The CUDA 13.3 Windows build is the one that carries Blackwell (sm120); the
# 12.4 build does not. Two archives: the binaries, and the CUDA runtime DLLs
# they load by name.
function Install-LlamaCpp {
    $server = Join-Path $LlamaHome "llama-server.exe"
    if (Test-Path $server) { return $server }

    Say "downloading llama.cpp (CUDA 13.3, Blackwell) into $LlamaHome"
    New-Item -ItemType Directory -Force -Path $LlamaHome | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Two traps here, both measured against the live API:
    #   - Invoke-RestMethod hands back a JSON array as ONE object, so piping it
    #     into Where-Object filters a single aggregate whose .assets.Count is
    #     the sum of every release's. foreach enumerates it properly.
    #   - -like anchors at both ends, so a pattern has to start with a wildcard
    #     to match "llama-b10569-bin-win-cuda-13.3-x64.zip".
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases" `
                                  -Headers @{ "User-Agent" = "Qwen5090" } -TimeoutSec 60
    if (-not $releases) { Die "could not reach the llama.cpp releases API" }

    # The binaries and the CUDA runtime DLLs they load are separate archives,
    # and only the CUDA 13 build carries Blackwell (sm120) - the 12.4 one does
    # not. Take both from the same release.
    $binPattern    = "llama-b*-bin-win-cuda-13*-x64.zip"
    $cudartPattern = "cudart-llama-bin-win-cuda-13*-x64.zip"
    $rel = $null
    foreach ($r in $releases) {
        if (($r.assets | Where-Object { $_.name -like $binPattern }) -and
            ($r.assets | Where-Object { $_.name -like $cudartPattern })) { $rel = $r; break }
    }
    if (-not $rel) { Die "no llama.cpp release carries both a CUDA 13 Windows build and its runtime" }
    Say "  release $($rel.tag_name)"

    foreach ($pattern in @($binPattern, $cudartPattern)) {
        $asset = $rel.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
        if (-not $asset) { Die "release $($rel.tag_name) has no asset matching $pattern" }
        $zip = Join-Path $env:TEMP $asset.name
        Say "  $($asset.name) ($([math]::Round($asset.size/1MB)) MB)"
        & curl.exe -sSL --fail -o "$zip" $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) { Die "download failed: $($asset.name)" }
        Expand-Archive -Path $zip -DestinationPath $LlamaHome -Force
        Remove-Item $zip -Force
    }
    # Some builds unpack into a nested folder; flatten so the DLLs sit next to
    # the exe that loads them.
    $nested = Get-ChildItem $LlamaHome -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    if ($nested -and $nested.DirectoryName -ne $LlamaHome) {
        Get-ChildItem $nested.DirectoryName | Move-Item -Destination $LlamaHome -Force
    }
    if (-not (Test-Path $server)) { Die "llama-server.exe is missing after unpacking" }
    Say "llama.cpp installed: $((& $server --version 2>&1 | Select-Object -First 1))"
    return $server
}

# ----------------------------------------------------------- model files ----
# Enumerate through the Hub API rather than guessing names: one build is a
# single 62 GB file, the next is four shards under a quant subfolder.
function Get-ModelFiles {
    param([string]$Repo, [string]$Quant)
    $info = Invoke-RestMethod -Uri "https://huggingface.co/api/models/$Repo" -TimeoutSec 60
    $files = $info.siblings | ForEach-Object { $_.rfilename } |
             Where-Object { $_ -like "*.gguf" -and $_ -notlike "*dspark*" }
    if ($Quant) { $files = $files | Where-Object { $_ -like "*$Quant*" } }
    return @($files | Sort-Object)
}

function Get-HubFile {
    param([string]$Repo, [string]$RelPath, [string]$Dest)
    $url = "https://huggingface.co/$Repo/resolve/main/$RelPath"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    # -C - resumes, which matters when a 62 GB transfer is interrupted; curl
    # ships with Windows 10 1803 and later.
    $curlArgs = @("-L", "--fail", "--retry", "5", "--retry-delay", "5", "-C", "-", "-o", $Dest, $url)
    if ($env:HF_TOKEN) { $curlArgs = @("-H", "Authorization: Bearer $env:HF_TOKEN") + $curlArgs }
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 33) { Die "download failed: $RelPath (curl $LASTEXITCODE)" }
}

$localRepoDir = Join-Path $ModelDir ($repo -replace "/", "--")
$wanted = @()
if ($DownloadOnly) { $Download = $true }
if ($Download) {
    Say "listing $repo ($quant)"
    $wanted = Get-ModelFiles -Repo $repo -Quant $quant
    if (-not $wanted) { Die "no GGUF matching '$quant' in $repo" }
    Say "$($wanted.Count) file(s) to fetch - this is tens of gigabytes and resumes if interrupted"
    foreach ($f in $wanted) {
        $dest = Join-Path $localRepoDir $f
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) {
            Say "  have $f"
        } else {
            Say "  get  $f"
            Get-HubFile -Repo $repo -RelPath $f -Dest $dest
        }
    }
}

# The first shard is what llama.cpp is pointed at; it finds its siblings.
$local = Get-ChildItem -Path $localRepoDir -Recurse -Filter "*.gguf" -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -notlike "*dspark*" -and ($quant -eq "" -or $_.FullName -like "*$quant*") } |
         Sort-Object FullName
if (-not $local) {
    Die "no weights found under $localRepoDir. Run once with -Download (about $(if ($entry) { $entry.SizeGB } else { 60 }) GB)."
}
$first = ($local | Where-Object { $_.Name -like "*-00001-of-*" } | Select-Object -First 1)
if (-not $first) { $first = $local | Select-Object -First 1 }

if ($DownloadOnly) {
    Say "downloaded - start it from the app, or with:  .\app\serve-gguf.ps1 -Model `"$Model`""
    exit 0
}

# ---------------------------------------------------------------- drafter ---
$draftPath = $null
if ($Draft) {
    $draftRepo = "unsloth/DeepSeek-V4-Flash-0731-GGUF"
    $draftFile = "dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf"
    $draftPath = Join-Path (Join-Path $ModelDir ($draftRepo -replace "/", "--")) $draftFile
    if (-not (Test-Path $draftPath)) {
        if (-not $Download) { Die "-Draft needs $draftFile - re-run with -Download too (about 11 GB)." }
        Say "fetching the DSpark drafter (~11 GB)"
        Get-HubFile -Repo $draftRepo -RelPath $draftFile -Dest $draftPath
    }
}

# ------------------------------------------------------------------ share ---
# llama-server binds every interface itself, so unlike the WSL path there is no
# portproxy to set up - only the firewall, scoped the same way share.ps1 scopes
# it: Private and Domain, never Public. Tailscale's interface counts as private.
if ($Share) {
    $ruleName = "Qwen5090 GGUF API $Port"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & netsh advfirewall firewall delete rule name="$ruleName" *> $null
        & netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow `
              protocol=TCP localport=$Port profile=private,domain | Out-Null
        Say "port $Port allowed on Private/Domain networks"
    } else {
        Warn "-Share needs an elevated window to add the firewall rule; serving anyway (localhost only until it exists)."
    }
}

# ----------------------------------------------------------------- launch ---
$server = Install-LlamaCpp

$llamaArgs = @(
    "-m", $first.FullName
    "--host", "0.0.0.0"
    "--port", "$Port"
    "-c", "$Ctx"
    "-ngl", "999"          # every layer on the GPU...
    "--jinja"              # ...tool calling needs the real chat template
    "-fa", "on"
    "-ub", "128"           # small micro-batches: prefill against RAM-resident
                           # experts is bandwidth-bound, and a big batch just
                           # thrashes the page cache
)
# mmap stays ON, which is the default and the whole reason this runs natively:
# the weights are mapped, not read, so the pages that do not fit are simply not
# resident. --no-mmap here would try to read 62 GB into 25 GB of free RAM.
# ...except the experts, which do not fit. 0 means all of them stay on the CPU,
# which is the setting that always starts.
if ($NCpuMoe -gt 0) { $llamaArgs += @("--n-cpu-moe", "$NCpuMoe") } else { $llamaArgs += "--cpu-moe" }
if ($draftPath)     { $llamaArgs += @("-md", $draftPath) }
if ($ApiKey)        { $llamaArgs += @("--api-key", $ApiKey) }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $LogDir "serve-gguf-$stamp.log"
Say "serving $($first.Name) on http://localhost:$Port/v1  (log: $log)"
Say "first load reads $(if ($entry) { $entry.SizeGB } else { '?' }) GB off the disk - give it a few minutes"

& $server @llamaArgs 2>&1 | Tee-Object -FilePath $log
exit $LASTEXITCODE
