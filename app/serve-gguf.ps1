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
    # Where the weights live. E: by default - these are 60 to 105 GB and that is
    # the drive with room for them. -ModelDir or QWEN5090_MODEL_DIR override it,
    # and if E: is not there the roomiest fixed drive is used instead.
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
    # Quantize the KV cache. The weights are the obvious memory problem here,
    # but the cache is the one that decides whether a long context starts at
    # all: it lives in VRAM next to the attention layers, and there are only
    # 32 GB. q8_0 halves it against the f16 default at no quality cost worth
    # measuring; q4_0 halves it again if even that will not fit.
    [ValidateSet("", "q8_0", "q4_0")]
    [string]$KvQuant = "",
    # Where the model's thinking ends up. The default is `auto`, and auto does
    # not engage for this template - measured 2026-08-22 against the running
    # server: a bare `</think>` arrived inside message.content with
    # reasoning_content empty, because the template opens thinking implicitly
    # and the parser has no opening tag to match. Naming `deepseek` puts the
    # thoughts in reasoning_content where a client can ignore them.
    [ValidateSet("deepseek", "deepseek-legacy", "none", "auto")]
    [string]$ReasoningFormat = "deepseek",
    # The tier handed to the chat template, and the set is not llama.cpp's.
    # This template validates the value itself and raises on anything else:
    #   deepseek-v4 chat template: reasoning_effort must be low, high or max
    # so `medium` or `xhigh` - both of which llama.cpp accepts - would break
    # every request. Empty keeps the template's own default, which is `low`.
    # The level is a block of instruction text prepended to the prompt, and it
    # only applies in thinking mode.
    [ValidateSet("", "low", "high", "max")]
    [string]$ReasoningEffort = "",
    # Replace the template baked into the GGUF. Needed because the one this
    # build ships renders no tools at all - measured with /apply-template, the
    # prompt is byte-identical with and without a tools array, so an agent
    # client's tool definitions never reach the model. A built-in name
    # (deepseek3 and the rest of llama.cpp's list) or a path to a .jinja file.
    # Left empty, a DeepSeek model picks up the tools-capable template shipped
    # in app/templates - which is the whole point, since an agent client sends
    # tools on every request.
    [string]$ChatTemplate = "",
    # Serve the model's own template even when a bundled one exists. Its
    # answers are the reference; it just cannot call tools.
    [switch]$StockTemplate,
    # What /v1/models calls this. Without it llama.cpp reports the full path -
    # "E:\Qwen5090\models\...\DeepSeek-V4-Flash-0731-reap-150b-Q2_K.gguf" - which
    # pins every client config to a drive letter and a quant tier, and whose
    # backslashes are invalid JSON escapes for anything that builds a request
    # by hand.
    [string]$Alias = "",
    [switch]$Share,
    [string]$ApiKey
)
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ paths ---
$Root   = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Everything large this script downloads goes on the big drive: the weights,
# and llama.cpp itself (its CUDA runtime alone unpacks to about a gigabyte).
# Only the logs stay under %LOCALAPPDATA%, where collect-logs.ps1 looks for them.
function Get-BigDrive {
    $preferred = $env:QWEN5090_DRIVE
    if (-not $preferred) { $preferred = "E:" }
    if (Test-Path "$preferred\") { return $preferred }
    $best = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
            Sort-Object -Property FreeSpace -Descending | Select-Object -First 1
    if (-not $best) { return $env:SystemDrive }
    Write-Host "WARNING: $preferred is not available - using $($best.DeviceID) instead." -ForegroundColor Yellow
    return $best.DeviceID
}
$BigDrive  = Get-BigDrive
$LlamaHome = Join-Path $BigDrive "Qwen5090\llamacpp"

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

# The template that makes tool calling work, kept in the repo rather than on
# whichever drive it was first written to: it is part of the product, it needs
# to survive a re-download, and it is the only reason an agent client can drive
# this model at all.
if (-not $ChatTemplate -and -not $StockTemplate -and $Model -match "(?i)deepseek") {
    $bundled = Join-Path $PSScriptRoot "templates\deepseek-v4-hermes.jinja"
    if (Test-Path $bundled) { $ChatTemplate = $bundled }
}

# Bytes of KV cache per token, read off the GGUF header rather than guessed:
# deepseek4 is 43 blocks with head_count_kv=1 and key/value lengths of 512, so
# 43 * 1024 * 2 bytes at f16. The experts live in system RAM on this path, but
# the cache does not - it is in VRAM, and at a long context it is the thing
# that decides whether the server starts. An upper bound: V4's hybrid attention
# compresses some layers, so the real figure is this or lower.
$KvBytesPerToken = 43 * 1024 * 2

# ------------------------------------------------------------- model dir ----
if (-not $ModelDir) {
    if ($env:QWEN5090_MODEL_DIR) {
        $ModelDir = $env:QWEN5090_MODEL_DIR
    } else {
        $ModelDir = Join-Path $BigDrive "Qwen5090\models"
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

# Same arithmetic vLLM's profiler does on the other backend, for the same
# reason: saying it now beats a CUDA allocation failure four minutes in.
$kvGB = [math]::Round(($Ctx * $KvBytesPerToken) / 1GB, 1)
$kvNote = if ($KvQuant -eq "q8_0") { " (halved by -KvQuant q8_0)" }
          elseif ($KvQuant -eq "q4_0") { " (quartered by -KvQuant q4_0)" } else { "" }
if ($KvQuant -eq "q8_0") { $kvGB = [math]::Round($kvGB / 2, 1) }
if ($KvQuant -eq "q4_0") { $kvGB = [math]::Round($kvGB / 4, 1) }
Write-Host ("   KV cache: about {0} GB in VRAM for {1} tokens{2}" -f $kvGB, $Ctx, $kvNote)
if ($vramFreeGB -gt 0 -and $kvGB -gt ($vramFreeGB - 4)) {
    Warn ("that leaves under 4 GB of VRAM for the layers and the compute buffers. " +
          "Either drop -Ctx, or pass -KvQuant q8_0 to halve the cache.")
}

if ($entry) {
    if ($Download -and $driveFreeGB -lt ($entry.SizeGB + 5)) {
        Die "$ModelDir has $driveFreeGB GB free and this needs about $($entry.SizeGB + 5) GB. Pick another drive with -ModelDir."
    }
    # Experts can only be resident where they are computed. With --cpu-moe that
    # is system RAM and nothing else, so counting free VRAM toward residency
    # overstates what this machine can hold - measured consequence: a 47-second
    # fixed cost per request, which is the expert weights being re-read from
    # the SSD every time. -NCpuMoe moves some of them onto the GPU and is the
    # lever that actually reduces it.
    $expertHomeGB = if ($NCpuMoe -gt 0) { $ramFreeGB + $vramFreeGB } else { $ramFreeGB }
    if ($NCpuMoe -le 0 -and $vramFreeGB -gt 8) {
        Write-Host ("   NOTE: --cpu-moe keeps every expert in RAM, so {0} GB of VRAM sits idle." -f $vramFreeGB)
        Write-Host  "         -NCpuMoe 30 moves about 13 of the 43 layers' experts onto the GPU."
    }
    if ($expertHomeGB -ge $entry.ResidentGB) {
        $msg = "$($entry.ResidentGB - $expertHomeGB) GB short of the $($entry.ResidentGB) GB this build needs resident. " +
               "Below about 70% of the weights in memory every token waits on the SSD, and the server reads as hung rather than slow."
        if (-not $Force) { Die "$msg`n       Pick a smaller build, add RAM, or pass -Force to try anyway." }
        Warn "$msg -Force given, going ahead."
    } else {
        # Two different regimes, and quoting the wrong one is worse than
        # quoting none. With every expert on the CPU, 58 GiB cycles through a
        # page cache too small to hold it and the re-read repeats on EVERY
        # request. With a slice of them pinned in VRAM the working set fits,
        # and the cost is paid once per server start instead.
        $short = $entry.ResidentGB - $expertHomeGB
        if ($NCpuMoe -gt 0) {
            Warn ("{0} GB short of resident. Measured on a 32 GB machine with -NCpuMoe 30: about 33 s on the first request after a start, then ~2.4 s for a warm one, and 13.6-20.9 tok/s generation." -f $short)
        } else {
            Warn ("{0} GB short of resident, and with --cpu-moe that much streams off the SSD on EVERY request - the page cache cannot hold it, so nothing stays warm. Measured on a 32 GB machine: about 47 s of fixed cost per request, 46 tok/s prefill, 4.5 tok/s generation. -NCpuMoe 30 removed the per-request part entirely." -f $short)
        }
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
# Sizes come back with the names: a 62 GB file that stopped early looks exactly
# like a finished one on disk, and the only thing that tells them apart is what
# the Hub says it should weigh.
function Get-ModelFiles {
    param([string]$Repo, [string]$Quant)
    $info = Invoke-RestMethod -Uri "https://huggingface.co/api/models/${Repo}?blobs=true" -TimeoutSec 60
    $files = $info.siblings |
             Where-Object { $_.rfilename -like "*.gguf" -and $_.rfilename -notlike "*dspark*" }
    if ($Quant) { $files = $files | Where-Object { $_.rfilename -like "*$Quant*" } }
    return @($files | Sort-Object -Property rfilename |
             ForEach-Object { [pscustomobject]@{ Path = $_.rfilename; Size = [long]($_.size) } })
}

function Get-HubFile {
    param([string]$Repo, [string]$RelPath, [string]$Dest, [long]$ExpectedSize = 0)
    $url = "https://huggingface.co/$Repo/resolve/main/$RelPath"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null

    # Windows' own curl speaks TLS through Schannel, which drops multi-gigabyte
    # transfers with
    #   curl: (56) schannel: failed to read data from server: SEC_E_DECRYPT_FAILURE
    # at some arbitrary point - measured here at 6.87 GB of 62. curl's --retry
    # does not cover that: it retries timeouts and 5xx, not a receive error, so
    # --retry-all-errors is the flag that matters. And because the failure
    # recurs, one curl invocation is not enough either - each attempt resumes
    # with -C - from what is already on disk, and the loop only gives up when
    # an attempt adds nothing.
    $stalled = 0
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $before = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($ExpectedSize -gt 0 -and $before -ge $ExpectedSize) { return }
        if ($attempt -gt 1) {
            Say ("  resuming at {0:N1} GB (attempt {1})" -f ($before / 1GB), $attempt)
        }
        $curlArgs = @("-L", "--fail", "--retry", "10", "--retry-delay", "5",
                      "--retry-all-errors", "-C", "-", "-o", $Dest, $url)
        if ($env:HF_TOKEN) { $curlArgs = @("-H", "Authorization: Bearer $env:HF_TOKEN") + $curlArgs }
        & curl.exe @curlArgs
        $rc = $LASTEXITCODE
        $after = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }

        # 33 is "this server will not let me resume", which is what curl says
        # when the file is already complete.
        if ($rc -eq 0 -or $rc -eq 33) {
            if ($ExpectedSize -gt 0 -and $after -lt $ExpectedSize) {
                Die ("$RelPath stopped at {0:N1} GB of {1:N1} GB and the server reported success. Run Install again to resume." -f ($after / 1GB), ($ExpectedSize / 1GB))
            }
            return
        }
        if ($after -le $before) { $stalled++ } else { $stalled = 0 }
        if ($stalled -ge 3) {
            Die "download failed: $RelPath (curl $rc) and three attempts in a row moved nothing.
       What is on disk is kept, so a later run resumes rather than restarting."
        }
    }
    Die "download failed: $RelPath - gave up after 40 resume attempts."
}

$localRepoDir = Join-Path $ModelDir ($repo -replace "/", "--")
$wanted = @()
if ($DownloadOnly) { $Download = $true }
if ($Download) {
    Say "listing $repo ($quant)"
    $wanted = Get-ModelFiles -Repo $repo -Quant $quant
    if (-not $wanted) { Die "no GGUF matching '$quant' in $repo" }
    $totalGB = ($wanted | Measure-Object -Property Size -Sum).Sum / 1GB
    Say ("$($wanted.Count) file(s), {0:N1} GB - interrupted transfers resume, they do not restart" -f $totalGB)
    foreach ($f in $wanted) {
        $dest = Join-Path $localRepoDir $f.Path
        $have = if (Test-Path $dest) { (Get-Item $dest).Length } else { 0 }
        # Not "the file exists": a transfer that died at 6.87 GB leaves a file
        # that exists, and skipping it here is how a truncated model reaches
        # llama.cpp and fails there instead, saying something unrelated.
        if ($f.Size -gt 0 -and $have -ge $f.Size) {
            Say ("  have $($f.Path) ({0:N1} GB)" -f ($have / 1GB))
        } else {
            if ($have -gt 0) {
                Say ("  resume $($f.Path) - {0:N1} of {1:N1} GB on disk" -f ($have / 1GB), ($f.Size / 1GB))
            } else {
                Say ("  get  $($f.Path) ({0:N1} GB)" -f ($f.Size / 1GB))
            }
            Get-HubFile -Repo $repo -RelPath $f.Path -Dest $dest -ExpectedSize $f.Size
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
)
# ...and the template, which has to be settled BEFORE --jinja. llama.cpp's own
# help: "only commonly used templates are accepted (unless --jinja is set
# before this flag)" - so with --jinja already on the line, a built-in name is
# no longer looked up, it is taken as a literal jinja template. `deepseek3`
# is a valid template with no variables, so it renders to the nine characters
# "deepseek3" and that becomes the model's entire prompt. Silently: no error,
# no warning, just a server answering nonsense.
if ($ChatTemplate) {
    if (Test-Path $ChatTemplate) {
        # A file is unambiguous and needs no ordering care.
        $llamaArgs += @("--chat-template-file", (Resolve-Path $ChatTemplate).Path)
    } else {
        $llamaArgs += @("--chat-template", $ChatTemplate)
    }
}
if (-not $Alias) {
    $Alias = if ($Model -match "(?i)deepseek") { "deepseek-v4-flash" }
             else { [IO.Path]::GetFileNameWithoutExtension($first.Name) }
}
$llamaArgs += @(
    "--alias", $Alias
    "--jinja"              # ...tool calling needs the real chat template
    "-fa", "on"
    "--cache-reuse", "256" # An agent resends the same system prompt and tool
                           # definitions on every step, and prefill here costs
                           # 47 s of fixed overhead plus 46 tok/s. Reusing a
                           # shared prefix through KV shifting is worth more on
                           # this backend than on any fast one.
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
if ($ReasoningFormat) { $llamaArgs += @("--reasoning-format", $ReasoningFormat) }
if ($ReasoningEffort) { $llamaArgs += @("--reasoning-effort", $ReasoningEffort) }
if ($KvQuant)       { $llamaArgs += @("-ctk", $KvQuant, "-ctv", $KvQuant) }
if ($draftPath)     { $llamaArgs += @("-md", $draftPath) }
if ($ApiKey)        { $llamaArgs += @("--api-key", $ApiKey) }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $LogDir "serve-gguf-$stamp.log"
Say "serving $($first.Name) as `"$Alias`" on http://localhost:$Port/v1  (log: $log)"
Say "reasoning=$ReasoningFormat$(if ($ReasoningEffort) { " effort=$ReasoningEffort" }) kv=$(if ($KvQuant) { $KvQuant } else { 'f16' }) cpu_moe=$(if ($NCpuMoe -gt 0) { "first $NCpuMoe layers" } else { 'all' })"
Say "first load reads $(if ($entry) { $entry.SizeGB } else { '?' }) GB off the disk - give it a few minutes"
if (-not $KvQuant) {
    Write-Host "   if it dies allocating the KV cache, retry with a smaller -Ctx or -KvQuant q8_0" -ForegroundColor DarkGray
}

# EAP back to Continue before the server runs, and this is not tidiness: with
# it left at Stop, `2>&1` promotes native stderr into PowerShell's error stream
# where a single line becomes a TERMINATING error. llama.cpp writes its entire
# log to stderr, so the server was killed by its own first line of output -
# loaded 58 GB, printed one line, died. The redirection is what makes the log
# file complete, so the preference is what has to give.
$ErrorActionPreference = "Continue"
& $server @llamaArgs 2>&1 | Tee-Object -FilePath $log
exit $LASTEXITCODE
