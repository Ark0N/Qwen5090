<#
.SYNOPSIS
  Qwen 5090 control panel — WPF GUI over install.ps1 / run.ps1.

.DESCRIPTION
  One window to install everything, start/stop the vLLM server, and chat with
  the model (streaming, with dimmed thinking tokens). Launch by double-clicking
  Qwen5090.cmd; no dependencies beyond Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-24.04",
    [switch]$AutoInstall
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:RepoRoot = $PSScriptRoot

# ------------------------------------------------------------------ UI layout
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Qwen 5090 — Local AI Control Panel"
        Width="920" Height="680" MinWidth="760" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#FF17171C">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFDDDDE4"/></Style>
    <Style TargetType="Label"><Setter Property="Foreground" Value="#FFDDDDE4"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFDDDDE4"/></Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF2A2A33"/>
      <Setter Property="Foreground" Value="#FFEFEFF5"/>
      <Setter Property="BorderBrush" Value="#FF3D3D48"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FF20202A"/>
      <Setter Property="Foreground" Value="#FFE8E8EE"/>
      <Setter Property="BorderBrush" Value="#FF3D3D48"/>
      <Setter Property="Padding" Value="6,4"/>
    </Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#FF20202A" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="GPU:" FontWeight="Bold" Margin="0,0,6,0"/>
        <TextBlock x:Name="TxtGpuS" Text="checking..." Margin="0,0,18,0"/>
        <TextBlock Text="WSL:" FontWeight="Bold" Margin="0,0,6,0"/>
        <TextBlock x:Name="TxtWslS" Text="checking..." Margin="0,0,18,0"/>
        <TextBlock Text="Model:" FontWeight="Bold" Margin="0,0,6,0"/>
        <TextBlock x:Name="TxtModelS" Text="unknown" Margin="0,0,18,0"/>
        <TextBlock Text="Server:" FontWeight="Bold" Margin="0,0,6,0"/>
        <TextBlock x:Name="TxtServerS" Text="stopped" Margin="0,0,18,0"/>
        <Button x:Name="BtnRefresh" Content="Refresh" Padding="8,2"/>
      </StackPanel>
    </Border>

    <TabControl Grid.Row="1" Background="#FF17171C" BorderBrush="#FF3D3D48">

      <TabItem Header="  Setup  ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnInstall" Content="Install / Repair" FontWeight="Bold" Background="#FF3A5F1F"/>
            <CheckBox x:Name="ChkSkipDownload" Content="Skip 17 GB model download (fetch on first run instead)" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBox x:Name="TxtSetupLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                   Background="#FF14141A" Text="Click 'Install / Repair' to set everything up (WSL2, Ubuntu, vLLM, model).&#10;A reboot may be needed once; the app re-opens automatically afterwards.&#10;"/>
        </Grid>
      </TabItem>

      <TabItem Header="  Server  ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnStart" Content="Start server" FontWeight="Bold" Background="#FF3A5F1F"/>
            <Button x:Name="BtnStop" Content="Stop" IsEnabled="False"/>
            <Label Content="Port:" VerticalAlignment="Center"/>
            <TextBox x:Name="TxtPort" Text="8000" Width="60" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Label Content="Context:" VerticalAlignment="Center"/>
            <ComboBox x:Name="CmbCtx" Width="110" VerticalAlignment="Center" SelectedIndex="1" Margin="0,0,12,0">
              <ComboBoxItem Content="65536"/>
              <ComboBoxItem Content="131072"/>
              <ComboBoxItem Content="262144"/>
            </ComboBox>
            <CheckBox x:Name="ChkMtp" Content="Speculative decoding (MTP)" IsChecked="True" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBox x:Name="TxtServerLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                   Background="#FF14141A" Text="Server output appears here. First start takes a minute or two (model load + CUDA graphs).&#10;API: http://localhost:8000/v1&#10;"/>
        </Grid>
      </TabItem>

      <TabItem Header="  Chat  ">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <CheckBox x:Name="ChkThink" Content="Thinking mode" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <Label Content="Effort:" VerticalAlignment="Center"/>
            <ComboBox x:Name="CmbEffort" Width="90" VerticalAlignment="Center" SelectedIndex="0" Margin="0,0,12,0">
              <ComboBoxItem Content="default"/>
              <ComboBoxItem Content="low"/>
              <ComboBoxItem Content="medium"/>
              <ComboBoxItem Content="high"/>
              <ComboBoxItem Content="xhigh"/>
            </ComboBox>
            <Button x:Name="BtnClear" Content="Clear history" Padding="8,3"/>
          </StackPanel>
          <RichTextBox x:Name="RtbChat" Grid.Row="1" IsReadOnly="True"
                       VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="13"
                       Background="#FF14141A" BorderBrush="#FF3D3D48" Foreground="#FFE8E8EE"/>
          <Grid Grid.Row="2" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtInput" Grid.Column="0" FontSize="13" Margin="0,0,8,0"/>
            <Button x:Name="BtnSend" Grid.Column="1" Content="Send" FontWeight="Bold" Background="#FF3A5F1F" Margin="0"/>
          </Grid>
        </Grid>
      </TabItem>

    </TabControl>
  </Grid>
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in 'TxtGpuS','TxtWslS','TxtModelS','TxtServerS','BtnRefresh',
                  'BtnInstall','ChkSkipDownload','TxtSetupLog',
                  'BtnStart','BtnStop','TxtPort','CmbCtx','ChkMtp','TxtServerLog',
                  'ChkThink','CmbEffort','BtnClear','RtbChat','TxtInput','BtnSend') {
    Set-Variable -Name $name -Value $Window.FindName($name)
}

# ------------------------------------------------------------------ state
$script:SetupProc = $null
$script:ServerProc = $null
$script:ServerUp = $false
$script:ModelId = "unsloth/Qwen3.8-27B-NVFP4"
$script:Messages = New-Object System.Collections.ArrayList
$script:ChatQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:ChatBusy = $false
$script:ChatPS = $null
$script:ChatHandle = $null
$script:Tails = New-Object System.Collections.ArrayList
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(3)
$script:PingTask = $null
$script:TickCount = 0

$doc = New-Object Windows.Documents.FlowDocument
$script:ChatPara = New-Object Windows.Documents.Paragraph
$doc.Blocks.Add($script:ChatPara)
$RtbChat.Document = $doc

# ------------------------------------------------------------------ helpers
function Add-Tail([string]$path, $box) {
    foreach ($old in @($script:Tails | Where-Object { $_.Path -eq $path })) { $script:Tails.Remove($old) }
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    $null = $script:Tails.Add(@{ Path = $path; Pos = [long]0; Box = $box })
}

function Read-Tails {
    foreach ($t in $script:Tails) {
        if (-not (Test-Path $t.Path)) { continue }
        try {
            $fs = [IO.File]::Open($t.Path, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -le $t.Pos) { continue }
                $null = $fs.Seek($t.Pos, 'Begin')
                $sr = New-Object IO.StreamReader($fs)
                $new = $sr.ReadToEnd()
                $t.Pos = $fs.Length
                if ($new) { $t.Box.AppendText($new); $t.Box.ScrollToEnd() }
            } finally { $fs.Dispose() }
        } catch { }
    }
}

function Add-Log($box, [string]$msg) {
    $box.AppendText("[gui] $msg`r`n")
    $box.ScrollToEnd()
}

function Add-ChatRun([string]$text, [string]$color, [switch]$Bold, [switch]$Italic) {
    $run = New-Object Windows.Documents.Run($text)
    $run.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString($color))
    if ($Bold) { $run.FontWeight = 'Bold' }
    if ($Italic) { $run.FontStyle = 'Italic' }
    $script:ChatPara.Inlines.Add($run)
    $RtbChat.ScrollToEnd()
}

function Get-WslDistros {
    try { return ((& wsl -l -q) -replace "`0", "" | Where-Object { $_ -ne "" }) } catch { return @() }
}

function Update-Status {
    try {
        $g = (& nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null) -split ',\s*'
        $TxtGpuS.Text = if ($g.Count -ge 2) { "$($g[0].Trim()) (driver $($g[1].Trim()))" } else { "no NVIDIA GPU?" }
    } catch { $TxtGpuS.Text = "driver missing" }

    $distros = Get-WslDistros
    if ($distros -contains $Distro) {
        & wsl -d $Distro -- bash -c "test -x `$HOME/.qwen5090/venv/bin/vllm" 2>$null
        $TxtWslS.Text = if ($LASTEXITCODE -eq 0) { "$Distro + vLLM ready" } else { "$Distro (vLLM not installed)" }
        $cachePath = "`$HOME/.cache/huggingface/hub/models--$($script:ModelId -replace '/','--')"
        & wsl -d $Distro -- bash -c "test -d $cachePath" 2>$null
        $TxtModelS.Text = if ($LASTEXITCODE -eq 0) { "downloaded" } else { "not downloaded" }
    } else {
        $TxtWslS.Text = "not installed"
        $TxtModelS.Text = "not downloaded"
    }
}

function Set-ServerStatus([string]$text, [string]$color) {
    $TxtServerS.Text = $text
    $TxtServerS.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString($color))
}

# ------------------------------------------------------------------ setup
function Start-Install {
    if (-not $script:IsAdmin) {
        $r = [Windows.MessageBox]::Show("Installing needs Administrator rights.`nRelaunch the app as Administrator?",
            "Qwen 5090", "YesNo", "Question")
        if ($r -eq "Yes") {
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -AutoInstall"
            $Window.Close()
        }
        return
    }
    $BtnInstall.IsEnabled = $false
    $outLog = Join-Path $env:TEMP "qwen5090-setup.out.log"
    $errLog = Join-Path $env:TEMP "qwen5090-setup.err.log"
    Add-Tail $outLog $TxtSetupLog
    Add-Tail $errLog $TxtSetupLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\install.ps1`" -Unattended -Distro $Distro"
    if ($ChkSkipDownload.IsChecked) { $psArgs += " -SkipDownload" }
    Add-Log $TxtSetupLog "Starting installer (this can take 15-40 min incl. the model download)..."
    $script:SetupProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}

function Complete-Install {
    $code = $script:SetupProc.ExitCode
    $script:SetupProc = $null
    $BtnInstall.IsEnabled = $true
    switch ($code) {
        0 {
            Add-Log $TxtSetupLog "Install complete. Go to the Server tab and click 'Start server'."
            Update-Status
        }
        3010 {
            Add-Log $TxtSetupLog "Windows needs one reboot to finish enabling WSL2."
            $r = [Windows.MessageBox]::Show("Windows needs to reboot once to finish enabling WSL2.`nThe app re-opens automatically after you log back in.`n`nReboot now?",
                "Qwen 5090", "YesNo", "Question")
            if ($r -eq "Yes") { Restart-Computer -Force }
        }
        default { Add-Log $TxtSetupLog "Install FAILED (exit code $code) - see the log above, fix the issue, and click Install/Repair again." }
    }
}

# ------------------------------------------------------------------ server
function Start-Server {
    $port = 0
    if (-not [int]::TryParse($TxtPort.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [Windows.MessageBox]::Show("Invalid port: $($TxtPort.Text)", "Qwen 5090") | Out-Null
        return
    }
    $ctx = [int]$CmbCtx.SelectedItem.Content
    $BtnStart.IsEnabled = $false
    $BtnStop.IsEnabled = $true
    $outLog = Join-Path $env:TEMP "qwen5090-server.out.log"
    $errLog = Join-Path $env:TEMP "qwen5090-server.err.log"
    Add-Tail $outLog $TxtServerLog
    Add-Tail $errLog $TxtServerLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\run.ps1`" -Port $port -Ctx $ctx -Distro $Distro"
    if (-not $ChkMtp.IsChecked) { $psArgs += " -NoMtp" }
    Add-Log $TxtServerLog "Starting server on port $port (context $ctx)... first start takes a minute or two."
    Set-ServerStatus "starting..." "#FFE0B84C"
    $script:ServerProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}

function Stop-Server {
    try { & wsl -d $Distro -- bash -c "pkill -f 'vllm serve'" 2>$null } catch { }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
        try { $script:ServerProc.Kill() } catch { }
    }
    $script:ServerProc = $null
    $script:ServerUp = $false
    $BtnStart.IsEnabled = $true
    $BtnStop.IsEnabled = $false
    Set-ServerStatus "stopped" "#FF8A8A96"
    Add-Log $TxtServerLog "Server stopped."
}

function Test-ServerHealth {
    # Async so the UI never blocks; the result is consumed on a later tick.
    if ($script:PingTask) {
        if (-not $script:PingTask.IsCompleted) { return }
        $task = $script:PingTask
        $script:PingTask = $null
        try {
            $resp = $task.Result
            if ($resp.IsSuccessStatusCode) {
                if (-not $script:ServerUp) {
                    $script:ServerUp = $true
                    Set-ServerStatus "running on port $($TxtPort.Text)" "#FF76B900"
                    $BtnStart.IsEnabled = $false
                    $BtnStop.IsEnabled = $true    # works even for a server this GUI didn't start (pkill)
                    Add-Log $TxtServerLog "Server is READY - chat tab is live, API at http://localhost:$($TxtPort.Text)/v1"
                    try {
                        $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                        if ($json.data -and $json.data.Count -gt 0) { $script:ModelId = $json.data[0].id }
                    } catch { }
                }
            } elseif ($script:ServerUp) {
                $script:ServerUp = $false
                Set-ServerStatus "not responding" "#FFFF6B6B"
                $BtnStart.IsEnabled = $true
            }
            $resp.Dispose()
        } catch {
            if ($script:ServerUp) {
                $script:ServerUp = $false
                Set-ServerStatus "not responding" "#FFFF6B6B"
                $BtnStart.IsEnabled = $true
            }
        }
        return
    }
    $script:PingTask = $script:Http.GetAsync("http://localhost:$($TxtPort.Text)/v1/models")
}

# ------------------------------------------------------------------ chat
$chatWorker = {
    param($url, $json, $queue)
    $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
        $req.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, "application/json")
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $queue.Enqueue(@{ t = 'err'; s = "server error $([int]$resp.StatusCode): $err" })
            return
        }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object IO.StreamReader($stream)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line -or -not $line.StartsWith("data: ")) { continue }
            $payload = $line.Substring(6)
            if ($payload -eq "[DONE]") { break }
            try { $obj = $payload | ConvertFrom-Json } catch { continue }
            if (-not $obj.choices -or $obj.choices.Count -eq 0) { continue }
            $delta = $obj.choices[0].delta
            if ($delta.PSObject.Properties['reasoning_content'] -and $delta.reasoning_content) {
                $queue.Enqueue(@{ t = 'think'; s = [string]$delta.reasoning_content })
            }
            if ($delta.PSObject.Properties['content'] -and $delta.content) {
                $queue.Enqueue(@{ t = 'text'; s = [string]$delta.content })
            }
        }
    } catch {
        $queue.Enqueue(@{ t = 'err'; s = $_.Exception.Message })
    } finally {
        $queue.Enqueue(@{ t = 'done'; s = '' })
        if ($client) { $client.Dispose() }
    }
}

function Send-ChatMessage {
    if ($script:ChatBusy) { return }
    $msg = $TxtInput.Text.Trim()
    if (-not $msg) { return }
    if (-not $script:ServerUp) {
        Add-ChatRun "`n(server is not running - start it on the Server tab first)`n" "#FFFF6B6B" -Italic
        return
    }
    $TxtInput.Text = ""
    Add-ChatRun "`nyou > " "#FF76B900" -Bold
    Add-ChatRun "$msg`n" "#FFE8E8EE"
    $null = $script:Messages.Add(@{ role = "user"; content = $msg })

    $body = [ordered]@{
        model            = $script:ModelId
        messages         = @($script:Messages)
        stream           = $true
        temperature      = 0.7
        top_p            = 0.8
        top_k            = 20
        presence_penalty = 1.5
    }
    if (-not $ChkThink.IsChecked) {
        $body.chat_template_kwargs = @{ enable_thinking = $false }
    } elseif ($CmbEffort.SelectedIndex -gt 0) {
        $body.chat_template_kwargs = @{ reasoning_effort = [string]$CmbEffort.SelectedItem.Content }
    }
    $json = $body | ConvertTo-Json -Depth 8

    Add-ChatRun "qwen > " "#FF4FC1FF" -Bold
    $script:ChatBusy = $true
    $script:ChatReply = New-Object Text.StringBuilder
    $BtnSend.IsEnabled = $false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $script:ChatPS = [powershell]::Create()
    $script:ChatPS.Runspace = $rs
    $null = $script:ChatPS.AddScript($chatWorker).
        AddArgument("http://localhost:$($TxtPort.Text)/v1/chat/completions").
        AddArgument($json).AddArgument($script:ChatQueue)
    $script:ChatHandle = $script:ChatPS.BeginInvoke()
}

function Drain-ChatQueue {
    $item = $null
    while ($script:ChatQueue.TryDequeue([ref]$item)) {
        switch ($item.t) {
            'think' { Add-ChatRun $item.s "#FF8A8A96" -Italic }
            'text'  { Add-ChatRun $item.s "#FFE8E8EE"; $null = $script:ChatReply.Append($item.s) }
            'err'   { Add-ChatRun "`n(error: $($item.s))`n" "#FFFF6B6B" -Italic }
            'done'  {
                Add-ChatRun "`n" "#FFE8E8EE"
                if ($script:ChatReply.Length -gt 0) {
                    $null = $script:Messages.Add(@{ role = "assistant"; content = $script:ChatReply.ToString() })
                }
                $script:ChatBusy = $false
                $BtnSend.IsEnabled = $true
                if ($script:ChatPS) {
                    try { $script:ChatPS.EndInvoke($script:ChatHandle); $script:ChatPS.Runspace.Dispose(); $script:ChatPS.Dispose() } catch { }
                    $script:ChatPS = $null
                }
            }
        }
    }
}

# ------------------------------------------------------------------ events
$BtnRefresh.Add_Click({ Update-Status })
$BtnInstall.Add_Click({ Start-Install })
$BtnStart.Add_Click({ Start-Server })
$BtnStop.Add_Click({ Stop-Server })
$BtnSend.Add_Click({ Send-ChatMessage })
$BtnClear.Add_Click({
    $script:Messages.Clear()
    $script:ChatPara.Inlines.Clear()
    Add-ChatRun "(history cleared)`n" "#FF8A8A96" -Italic
})
$TxtInput.Add_KeyDown({ if ($_.Key -eq 'Return') { Send-ChatMessage } })
$ChkThink.Add_Checked({ if ($CmbEffort) { $CmbEffort.IsEnabled = $true } })
$ChkThink.Add_Unchecked({ $CmbEffort.IsEnabled = $false })

# ------------------------------------------------------------------ main loop
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $script:TickCount++
    Read-Tails
    Drain-ChatQueue
    if ($script:SetupProc -and $script:SetupProc.HasExited) { Complete-Install }
    if ($script:ServerProc -and $script:ServerProc.HasExited -and -not $script:ServerUp) {
        # wrapper died before the server came up -> surface it
        Set-ServerStatus "exited (see log)" "#FFFF6B6B"
        $BtnStart.IsEnabled = $true
        $BtnStop.IsEnabled = $false
        $script:ServerProc = $null
    }
    # Ping unconditionally so a server started outside this GUI (run.ps1, or a
    # previous session) is detected too; a refused connection fails instantly.
    if ($script:TickCount % 7 -eq 0) { Test-ServerHealth }
})
$timer.Start()

$Window.Add_Loaded({
    Update-Status
    Add-ChatRun "Local Qwen3.8-27B chat - start the server, then talk. Dim text = model thinking.`n" "#FF8A8A96" -Italic
    if ($AutoInstall -and $script:IsAdmin) { Start-Install }
})
$Window.Add_Closed({
    $timer.Stop()
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
        # leave the server running; users can stop it from a new GUI session
    }
})

$null = $Window.ShowDialog()
