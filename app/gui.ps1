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
    [switch]$AutoInstall,
    [switch]$AutoCleanup,
    # Both are only ever passed by this script to its own elevated relaunch, so
    # the model choice (and a gated repo's token) survive the UAC prompt.
    [string]$Model = "",
    [string]$HfTokenFile = ""
)
$ErrorActionPreference = "Stop"

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:RepoRoot = $PSScriptRoot

# ------------------------------------------------------------------ logging
# Everything lands in %LOCALAPPDATA%\Qwen5090\logs so failures leave a trace
# even when the hidden console dies. Logs older than 14 days are pruned.
$script:LogDir = Join-Path $env:LOCALAPPDATA "Qwen5090\logs"
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:GuiLog = Join-Path $script:LogDir ("gui-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Write-GuiLog([string]$msg) {
    try { Add-Content -Path $script:GuiLog -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $msg) -Encoding UTF8 } catch { }
}
Get-ChildItem $script:LogDir -Filter *.log -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-GuiLog "GUI starting | admin=$script:IsAdmin | distro=$Distro | autoInstall=$AutoInstall | autoCleanup=$AutoCleanup | repo=$script:RepoRoot | ps=$($PSVersionTable.PSVersion)"

# Any terminating error anywhere in the script gets logged + shown, instead of
# the hidden PowerShell window silently vanishing.
trap {
    $detail = "FATAL: $($_ | Out-String)  at: $($_.ScriptStackTrace)"
    Write-GuiLog $detail
    try {
        [Windows.MessageBox]::Show("Qwen 5090 hit a fatal error.`nDetails were logged to:`n$script:GuiLog`n`n$($_.Exception.Message)",
            "Qwen 5090", "OK", "Error") | Out-Null
    } catch { }
    break
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http

# ------------------------------------------------------------------ UI layout
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Qwen3.8-27B 5090 — Local AI Control Panel"
        Width="960" Height="700" MinWidth="820" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#FF0F1115"
        FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>

    <!-- Scrollbars: slim dark thumb, invisible page-buttons (keep these first,
         later styles reference them via StaticResource). -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="#39404E" CornerRadius="4" Margin="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollPageButton" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton x:Name="PageUp" Style="{StaticResource ScrollPageButton}" Command="ScrollBar.PageUpCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton x:Name="PageDown" Style="{StaticResource ScrollPageButton}" Command="ScrollBar.PageDownCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageLeftCommand"/>
                <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageRightCommand"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E6E9EF"/></Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A93A5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1C212B"/>
      <Setter Property="Foreground" Value="#DCE1EA"/>
      <Setter Property="BorderBrush" Value="#3A4250"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Neutral button -->
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#DCE1EA"/>
      <Setter Property="Background" Value="#232936"/>
      <Setter Property="BorderBrush" Value="#303748"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2B3342"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1D222C"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Primary action button (accent green) -->
    <Style x:Key="AccentButton" TargetType="Button">
      <Setter Property="Foreground" Value="#0E1206"/>
      <Setter Property="Background" Value="#76B900"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#85CE0D"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#639C00"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Destructive action button (cleanup) -->
    <Style x:Key="DangerButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F1707A"/>
      <Setter Property="Background" Value="#2A191C"/>
      <Setter Property="BorderBrush" Value="#5A2830"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#3A2126"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#241518"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Single-line inputs (port, chat box); Tag doubles as placeholder text -->
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#E6E9EF"/>
      <Setter Property="Background" Value="#11141B"/>
      <Setter Property="BorderBrush" Value="#2A303C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="CaretBrush" Value="#76B900"/>
      <Setter Property="SelectionBrush" Value="#3E5A10"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <Grid>
                <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                <TextBlock x:Name="Hint" Text="{TemplateBinding Tag}" Foreground="#5A6375"
                           FontSize="{TemplateBinding FontSize}" Margin="12,0" VerticalAlignment="Center"
                           IsHitTestVisible="False" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value=""><Setter TargetName="Hint" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#76B900"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Read-only log panes -->
    <Style x:Key="LogBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="#C4CBD8"/>
      <Setter Property="Background" Value="#11141B"/>
      <Setter Property="BorderBrush" Value="#232834"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="SelectionBrush" Value="#3E5A10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9D1DE"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" BorderBrush="#3A4250"
                      BorderThickness="1.5" Background="#11141B" VerticalAlignment="Center">
                <Path x:Name="Check" Data="M 3,7 L 6,10 L 11,3" Stroke="#0E1206" StrokeThickness="2"
                      Visibility="Collapsed" SnapsToDevicePixels="False"/>
              </Border>
              <ContentPresenter Margin="7,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#76B900"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#76B900"/>
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#76B900"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E6E9EF"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="10,6" Margin="3,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#262C38"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2E3542"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E6E9EF"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#1C212B" BorderBrush="#2A303C" BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" Margin="0,0,10,0" VerticalAlignment="Center"
                            Data="M 0 0 L 4 4 L 8 0" Stroke="#8A93A5" StrokeThickness="1.5"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4250"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#76B900"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="10,0,26,0"
                                VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                <Border Background="#1C212B" BorderBrush="#2A303C" BorderThickness="1" CornerRadius="6"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,3,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained" Margin="0,3"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Underline tabs above a card -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel Grid.Row="0" IsItemsHost="True" Margin="2,0,0,8" Background="Transparent"/>
              <Border Grid.Row="1" Background="#161A22" BorderBrush="#262B36" BorderThickness="1" CornerRadius="10" Padding="14">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <!-- Text colour belongs on the TabItem, NOT on the ContentPresenter in the
           template below. A header's logical parent is the TabItem, so inherited
           properties (TextElement.Foreground/FontSize/FontWeight) flow from here
           into the header's TextBlocks; anything set on the ContentPresenter is
           simply bypassed. Setting it there rendered the tab labels in WPF's
           default black on the #0F1115 window - about 1:1, i.e. invisible.
           The header TextBlocks keep Style="{x:Null}" so the implicit TextBlock
           style does not pin a colour and defeat the state triggers: a Style
           setter outranks inheritance, which would freeze all three tabs at one
           colour. Idle #AAB3C2 on #0F1115 measures ~8.9:1. -->
      <Setter Property="Foreground" Value="#AAB3C2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent"
                    CornerRadius="8,8,0,0" Padding="16,8" Margin="0,0,4,0">
              <ContentPresenter x:Name="Content" ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <!-- No TargetName: these set the property on the templated TabItem,
                   which is what the header actually inherits from. -->
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#171B24"/>
                <Setter Property="Foreground" Value="#E6EAF1"/>
              </Trigger>
              <!-- After the hover trigger on purpose: selected wins when both apply. -->
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1A1F29"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#76B900"/>
                <Setter Property="Foreground" Value="#F4F7FB"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Header status pill -->
    <Style x:Key="StatusPill" TargetType="Border">
      <Setter Property="Background" Value="#11141B"/>
      <Setter Property="BorderBrush" Value="#262B36"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="99"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0,0,8,4"/>
    </Style>
    <Style x:Key="PillLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#7C8494"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>

  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#161A22" BorderBrush="#262B36" BorderThickness="1"
            CornerRadius="10" Padding="16,12,16,8" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <!-- Buttons are docked BEFORE the title so a DockPanel reserves their width
             first: when the window is narrow the title ellipsizes instead of the
             action buttons silently clipping off the right edge. -->
        <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,10">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="TxtBusy" Text="" Visibility="Collapsed" FontFamily="Consolas" FontSize="14" FontWeight="Bold"
                       Foreground="#76B900" VerticalAlignment="Center" Width="16" TextAlignment="Center" Margin="0,0,10,0"
                       ToolTip="Working - progress streams in the tab below"/>
            <Button x:Name="BtnRefresh" Content="Refresh" Padding="12,6"/>
            <Button x:Name="BtnLogs" Content="Open logs" Padding="12,6"/>
            <Button x:Name="BtnDiag" Content="Collect diagnostics" Padding="12,6" Margin="0"/>
          </StackPanel>
          <!-- Inner DockPanel (not a horizontal StackPanel) so the text gets a
               finite width and TextTrimming can actually take effect. -->
          <DockPanel DockPanel.Dock="Left">
            <Border DockPanel.Dock="Left" Background="#76B900" CornerRadius="7" Width="32" Height="32" VerticalAlignment="Center">
              <TextBlock Text="Q" FontSize="18" FontWeight="Bold" Foreground="#0E1206"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"/>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Qwen3.8-27B 5090" FontSize="16" FontWeight="SemiBold" Foreground="#EDF0F5"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock Text="Local AI control panel for your RTX 5090" FontSize="11" Foreground="#7C8494"
                         TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </DockPanel>
        </DockPanel>
        <WrapPanel Grid.Row="1">
          <Border Style="{StaticResource StatusPill}">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotGpu" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="GPU" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtGpuS" Text="checking..." FontSize="12" Foreground="#C9D1DE" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource StatusPill}">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotWsl" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="WSL" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtWslS" Text="checking..." FontSize="12" Foreground="#C9D1DE" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource StatusPill}">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotModel" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="MODEL" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtModelS" Text="unknown" FontSize="12" Foreground="#C9D1DE" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource StatusPill}" Margin="0,0,0,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotServer" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="SERVER" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtServerS" Text="stopped" FontSize="12" Foreground="#8A93A5" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource StatusPill}" Margin="0,0,0,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotBridge" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="CLAUDE CODE" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtBridgeS" Text="bridge stopped" FontSize="12" Foreground="#8A93A5" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource StatusPill}" Margin="0,0,0,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="DotDsh" Width="8" Height="8" Fill="#4A5261" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="HARNESS" Style="{StaticResource PillLabel}"/>
              <TextBlock x:Name="TxtDshS" Text="stopped" FontSize="12" Foreground="#8A93A5" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
        </WrapPanel>
      </Grid>
    </Border>

    <TabControl Grid.Row="1">

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{x:Null}" Text="&#xE713;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Style="{x:Null}" Text="Setup" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,10">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
              <Button x:Name="BtnInstall" Content="Install / Repair" Style="{StaticResource AccentButton}"/>
              <CheckBox x:Name="ChkSkipDownload" Content="Skip the 22 GB model download (fetch on first run instead)"/>
            </StackPanel>
            <Button x:Name="BtnCleanup" Content="Cleanup / Uninstall" DockPanel.Dock="Right"
                    Style="{StaticResource DangerButton}" Margin="0"
                    ToolTip="Remove everything this app installed: the Ubuntu distro, the Python environment, and the downloaded model (~20+ GB freed)"/>
          </DockPanel>
          <WrapPanel Grid.Row="1" Margin="0,0,0,6">
            <TextBlock Text="Model" Style="{StaticResource FieldLabel}"/>
            <ComboBox x:Name="CmbModel" Width="228" SelectedIndex="0" VerticalAlignment="Center" Margin="0,0,14,6"
                      ToolTip="Which checkpoint to download and serve - hover an entry for details">
              <ComboBoxItem Content="Standard" Tag="unsloth/Qwen3.8-27B-NVFP4"
                            ToolTip="unsloth/Qwen3.8-27B-NVFP4 - the official Qwen3.8-27B release in NVFP4, about 22 GB, no account needed"/>
              <ComboBoxItem Content="Uncensored (no account)" Tag="sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4"
                            ToolTip="sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4 - huihui-ai's abliterated Qwen3.8-27B re-quantized to NVFP4, about 19 GB, public download. Refusals removed."/>
              <ComboBoxItem Content="Uncensored (sign-in)" Tag="orcarouter/Qwen3.8-27B-Uncensored-NVFP4"
                            ToolTip="orcarouter/Qwen3.8-27B-Uncensored-NVFP4 - a different abliterated build, about 23 GB. Gated on Hugging Face: accept its terms there and paste a read token."/>
              <ComboBoxItem Content="Qwen3.8-27B via NInfer (fastest)" Tag="neroued/Qwen3.8-27B-nvfp4-NInfer"
                            ToolTip="The same Qwen3.8-27B NVFP4 weights as Standard, served by NInfer instead of vLLM - a C++/CUDA engine built for this exact card. About twice the speed, and a very long prompt is read in seconds rather than minutes. Setup compiles the engine, which takes a while and happens once."/>
              <ComboBoxItem Content="Qwen3.6-35B-A3B via NInfer" Tag="neroued/Qwen3.6-35B-A3B-NInfer"
                            ToolTip="A mixture-of-experts model: 35B total but only 3B active per token, so it answers far faster than any of the others - around 590 tokens/second. Text only, and an older Qwen release than 3.8."/>
              <ComboBoxItem Content="DeepSeek V4-Flash (pruned, 63 GB)" Tag="puwaer/DeepSeek-V4-Flash-0731-reap-150b-gguf:Q2_K"
                            ToolTip="DeepSeek V4-Flash 0731 with its experts pruned from 284B to about 150B, then quantized to 2-bit. 63 GB on disk, served by llama.cpp from system RAM instead of vLLM from VRAM - so expect single-digit tokens per second on a 32 GB machine, not 80. Needs about 69 GB of RAM+VRAM to avoid paging off the SSD."/>
              <ComboBoxItem Content="DeepSeek V4-Flash (full, 105 GB)" Tag="unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-IQ3_XXS"
                            ToolTip="The intact DeepSeek V4-Flash 0731 weights at 3-bit: 105 GB, and about 112 GB of RAM+VRAM to hold them. This one needs a 128 GB machine - on 32 GB it will not start."/>
            </ComboBox>
            <TextBlock Text="HF token" Style="{StaticResource FieldLabel}"/>
            <!-- Tag is the shared TextBox style's placeholder text (shown while empty). -->
            <TextBox x:Name="TxtHfToken" Width="200" Height="30" VerticalAlignment="Center" IsEnabled="False"
                     Tag="hf_..." Margin="0,0,12,6"
                     ToolTip="Only needed for the sign-in build: a READ token from huggingface.co/settings/tokens. It is stored inside WSL, so you paste it once."/>
            <TextBlock x:Name="TxtModelHint" Text="" FontSize="11" Foreground="#FFE0B84C"
                       VerticalAlignment="Center" Margin="0,0,0,6" TextWrapping="Wrap" MaxWidth="240"/>
          </WrapPanel>
          <TextBox x:Name="TxtSetupLog" Grid.Row="2" Style="{StaticResource LogBox}"
                   Text="Ready when you are.&#10;&#10;Click  Install / Repair  to set everything up automatically:&#10;   1. WSL2 + Ubuntu 24.04 (silent, no prompts)&#10;   2. Python 3.13 + vLLM inside Linux&#10;   3. The Qwen3.8-27B model (~22 GB download)&#10;&#10;Every step streams live progress here. Re-running is always safe - finished steps are skipped.&#10;One reboot may be requested; the app re-opens automatically after you log back in.&#10;"/>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{x:Null}" Text="&#xE768;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Style="{x:Null}" Text="Server" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <!-- WrapPanel, not StackPanel: at the 820 px minimum width these
               controls are wider than the window and a StackPanel would clip
               the last one instead of moving it to a second line. -->
          <WrapPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="BtnStart" Content="Start server" Style="{StaticResource AccentButton}"/>
            <Button x:Name="BtnStop" Content="Stop" IsEnabled="False" Margin="0,0,16,6"/>
            <TextBlock Text="Port" Style="{StaticResource FieldLabel}"/>
            <!-- 92 px: the shared TextBox style adds 10 px of padding a side, so
                 a 64 px box left ~42 px of text area and clipped "8000". -->
            <TextBox x:Name="TxtPort" Text="8000" Width="92" Height="30" Padding="6,0" TextAlignment="Center"
                     VerticalAlignment="Center" Margin="0,0,14,6" ToolTip="API port (1-65535)"/>
            <TextBlock Text="Context" Style="{StaticResource FieldLabel}"/>
            <!-- Content is the label the user reads; Tag carries the exact token
                 count that run.ps1 needs (Start-Server reads Tag, never Content). -->
            <ComboBox x:Name="CmbCtx" Width="104" VerticalAlignment="Center" SelectedIndex="1" Margin="0,0,14,6"
                      ToolTip="Maximum context length - higher uses more VRAM">
              <!-- 262K needs a 4-bit KV cache to fit in 32 GB; serve.sh switches to
                   one automatically above 128K, so every entry here really starts.
                   SelectedIndex is 1 (128K): the fp8 path keeps MTP and runs ~80 tok/s,
                   against ~49 for the full window. -->
              <ComboBoxItem Content="64K" Tag="65536" ToolTip="65,536 tokens - pick this if you are gaming at the same time"/>
              <ComboBoxItem Content="128K" Tag="131072" ToolTip="131,072 tokens - the default, and the fastest setting: fp8 KV cache, MTP stays on, about 80 tok/s. Plenty of room for normal chats."/>
              <ComboBoxItem Content="262K" Tag="262144" ToolTip="262,144 tokens - the model's native maximum. It needs a 4-bit KV cache to fit in 32 GB, which costs speed: about 49 tok/s instead of 80, and pasting a very long document can take minutes before the reply starts. Pick it only when you actually need the room."/>
            </ComboBox>
            <CheckBox x:Name="ChkMtp" Content="MTP speed boost" ToolTip="Speculative decoding (multi-token prediction) - faster, leave on. Ignored above 128K context: it corrupts output when the KV cache is 4-bit, so the server turns it off for you." IsChecked="True" Margin="0,0,14,6"/>
            <CheckBox x:Name="ChkShare" Content="Share on network" ToolTip="Other devices on your Wi-Fi or tailnet (LAN/Tailscale) can use the API - asks for admin once per start" Margin="0,0,0,6"/>
          </WrapPanel>
          <TextBox x:Name="TxtServerLog" Grid.Row="1" Style="{StaticResource LogBox}"
                   Text="Server output appears here.&#10;The first start takes a minute or two (model load + CUDA graph capture).&#10;API endpoint: http://localhost:8000/v1  (OpenAI-compatible; any api_key works)&#10;"/>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{x:Null}" Text="&#xE8BD;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Style="{x:Null}" Text="Chat" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,10">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
              <CheckBox x:Name="ChkThink" Content="Thinking mode" IsChecked="True" Margin="0,0,14,0"
                        ToolTip="Let the model reason before answering - smarter but slower"/>
              <TextBlock Text="Effort" Style="{StaticResource FieldLabel}"/>
              <ComboBox x:Name="CmbEffort" Width="108" VerticalAlignment="Center" SelectedIndex="0"
                        ToolTip="How much thinking the model does before answering">
                <ComboBoxItem Content="default"/>
                <ComboBoxItem Content="low"/>
                <ComboBoxItem Content="medium"/>
                <ComboBoxItem Content="xhigh"/>
              </ComboBox>
            </StackPanel>
            <Button x:Name="BtnClear" Content="Clear history" DockPanel.Dock="Right" Padding="12,6" Margin="0"/>
          </DockPanel>
          <Border Grid.Row="1" Background="#11141B" BorderBrush="#232834" BorderThickness="1" CornerRadius="8" Padding="8,6">
            <RichTextBox x:Name="RtbChat" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                         FontFamily="Segoe UI" FontSize="13"
                         Background="Transparent" Foreground="#E6E9EF" BorderThickness="0"/>
          </Border>
          <Grid Grid.Row="2" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtInput" Grid.Column="0" Height="36" Margin="0,0,10,0"
                     Tag="Ask the model anything...  (Enter to send)"/>
            <Button x:Name="BtnSend" Grid.Column="1" Content="Send" Style="{StaticResource AccentButton}"
                    Height="36" MinWidth="96" Margin="0"/>
          </Grid>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{x:Null}" Text="&#xE943;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Style="{x:Null}" Text="Claude Code" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <WrapPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="BtnCcOpen" Content="Open Claude Code" Style="{StaticResource AccentButton}"
                    ToolTip="Start the bridge if it is not up, then open a Claude Code session in its own window, answered by the model on this PC"/>
            <Button x:Name="BtnCcStart" Content="Start bridge" Margin="0,0,8,6"
                    ToolTip="Start just the translation bridge - for a Claude Code that is already open, or one on another machine"/>
            <Button x:Name="BtnCcStop" Content="Stop bridge" IsEnabled="False" Margin="0,0,16,6"/>
            <TextBlock Text="Effort" Style="{StaticResource FieldLabel}"/>
            <!-- The chat template accepts these three and 400s on anything else,
                 "high" included - which is exactly what Claude Code sends. -->
            <ComboBox x:Name="CmbCcEffort" Width="104" SelectedIndex="2" VerticalAlignment="Center" Margin="0,0,14,6"
                      ToolTip="How hard the model thinks before it answers. Applies to the next bridge start.">
              <ComboBoxItem Content="low" ToolTip="Fastest, least thinking"/>
              <ComboBoxItem Content="medium" ToolTip="A middle setting"/>
              <ComboBoxItem Content="xhigh" ToolTip="The template's own default - best answers, slowest"/>
            </ComboBox>
            <TextBlock Text="Bridge port" Style="{StaticResource FieldLabel}"/>
            <TextBox x:Name="TxtCcPort" Text="4000" Width="92" Height="30" Padding="6,0" TextAlignment="Center"
                     VerticalAlignment="Center" Margin="0,0,0,6" ToolTip="Where the bridge listens (1-65535). Change it only if something else already uses 4000."/>
          </WrapPanel>
          <WrapPanel Grid.Row="1" Margin="0,0,0,6">
            <Button x:Name="BtnCcInstall" Content="Install Claude Code" Margin="0,0,8,6"
                    ToolTip="Install Claude Code inside Linux (about 30 seconds, no account needed). Opening a session does this for you the first time - this button is here if you would rather get it over with."/>
            <Button x:Name="BtnCcEnv" Content="Windows env" Margin="0,0,8,6"
                    ToolTip="For a Claude Code installed on Windows rather than inside WSL: prints the variables it needs and copies them to the clipboard"/>
            <Button x:Name="BtnCcDoctor" Content="Doctor" Margin="0,0,16,6"
                    ToolTip="Check the bridge end to end and print what it finds below"/>
            <CheckBox x:Name="ChkCcDebug" Content="Record traffic" Margin="0,0,14,6"
                      ToolTip="Debugging only: write every prompt, file and reply the bridge handles to ~/.qwen5090/debug inside Linux. Applies from the next bridge start. These files contain your actual conversations - delete them when you are done, and do not attach them to a bug report."/>
            <TextBlock x:Name="TxtCcHint" Text="" FontSize="11" Foreground="#8A93A5"
                       VerticalAlignment="Center" Margin="0,0,0,6"/>
          </WrapPanel>
          <TextBox x:Name="TxtCcLog" Grid.Row="2" Style="{StaticResource LogBox}"
                   Text="Claude Code, answered by the model on this PC instead of the cloud.&#10;&#10;Claude Code speaks one API and the server speaks another, so a small translation&#10;bridge runs inside Linux between them. These buttons drive it.&#10;&#10;   Open Claude Code   starts the bridge if needed, then opens a session in its own window&#10;   Windows env        for a Claude Code installed on Windows instead of inside WSL&#10;&#10;Start the model server on the Server tab first - the bridge asks it which model it is&#10;serving and configures itself from the answer.&#10;"/>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{x:Null}" Text="&#xE774;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="14" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock Style="{x:Null}" Text="DeepSeek Harness" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <WrapPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="BtnDshOpen" Content="Open harness" Style="{StaticResource AccentButton}"
                    ToolTip="Start the harness if it is not up, then open its Web UI in your browser"/>
            <Button x:Name="BtnDshStart" Content="Start" Margin="0,0,8,6"
                    ToolTip="Start the harness without opening a browser"/>
            <Button x:Name="BtnDshStop" Content="Stop" IsEnabled="False" Margin="0,0,16,6"/>
            <TextBlock Text="UI port" Style="{StaticResource FieldLabel}"/>
            <TextBox x:Name="TxtDshPort" Text="3080" Width="92" Height="30" Padding="6,0" TextAlignment="Center"
                     VerticalAlignment="Center" Margin="0,0,0,6" ToolTip="Where the harness Web UI listens (1-65535). Change it only if something else already uses 3080."/>
          </WrapPanel>
          <WrapPanel Grid.Row="1" Margin="0,0,0,6">
            <Button x:Name="BtnDshInstall" Content="Install harness" Margin="0,0,8,6"
                    ToolTip="Install the harness inside Linux (about a minute). Starting it does this for you the first time - this button is here if you would rather get it over with."/>
            <Button x:Name="BtnDshConfig" Content="Re-read server" Margin="0,0,8,6"
                    ToolTip="Point the harness at whatever the server is currently serving. Worth clicking after switching model or engine."/>
            <Button x:Name="BtnDshDoctor" Content="Doctor" Margin="0,0,16,6"
                    ToolTip="Check the harness end to end and print what it finds below"/>
            <TextBlock x:Name="TxtDshHint" Text="" FontSize="11" Foreground="#8A93A5"
                       VerticalAlignment="Center" Margin="0,0,0,6"/>
          </WrapPanel>
          <TextBox x:Name="TxtDshLog" Grid.Row="2" Style="{StaticResource LogBox}"
                   Text="The DeepSeek Harness - a coding agent you drive in your browser, answered by&#10;the model on this PC.&#10;&#10;Unlike Claude Code it speaks the same API the server does, so there is no&#10;translation bridge here. It just needs to be told where the server is, which&#10;these buttons do.&#10;&#10;   Open harness     starts it if needed, then opens the Web UI in your browser&#10;   Re-read server   re-point it after you switch model or engine&#10;&#10;Start the model server on the Server tab first - the harness asks it what it is&#10;serving and writes that into its own settings.&#10;"/>
        </Grid>
      </TabItem>

    </TabControl>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in 'TxtGpuS','TxtWslS','TxtModelS','TxtServerS','TxtBridgeS','BtnRefresh','BtnLogs','BtnDiag',
                  'DotGpu','DotWsl','DotModel','DotServer','DotBridge','TxtBusy',
                  'BtnInstall','BtnCleanup','ChkSkipDownload','TxtSetupLog',
                  'CmbModel','TxtHfToken','TxtModelHint',
                  'BtnStart','BtnStop','TxtPort','CmbCtx','ChkMtp','ChkShare','TxtServerLog',
                  'ChkThink','CmbEffort','BtnClear','RtbChat','TxtInput','BtnSend',
                  'BtnCcOpen','BtnCcStart','BtnCcStop','CmbCcEffort','TxtCcPort',
                  'BtnCcInstall','BtnCcEnv','BtnCcDoctor','ChkCcDebug','TxtCcHint','TxtCcLog',
                  'DotDsh','TxtDshS','BtnDshOpen','BtnDshStart','BtnDshStop','TxtDshPort',
                  'BtnDshInstall','BtnDshConfig','BtnDshDoctor','TxtDshHint','TxtDshLog') {
    Set-Variable -Name $name -Value $Window.FindName($name)
}

# ------------------------------------------------------------------ state
$script:SetupProc = $null
$script:CleanupProc = $null
$script:ServerProc = $null
$script:DiagProc = $null
# Claude Code bridge: a child per one-shot action (start/stop/doctor/env), plus
# its own health ping. Bridge state is deliberately independent of $ServerProc -
# the bridge outlives this window, and one started outside the GUI must show up.
$script:BridgeProc = $null
$script:BridgeAction = ""
$script:BridgeUp = $false
$script:BridgePingTask = $null
$script:BridgeEnvLog = $null
# A 'start' that succeeded but is not answering the Windows-side ping a few
# seconds later means a bridge bound to loopback inside WSL was already up -
# started by claude-code.sh directly, or by an earlier session. It works; this
# window just cannot watch it. Explaining that beats a pill stuck on "stopped".
$script:BridgeConfirmBy = $null
# Set when the user asked for a session and Claude Code had to be installed
# first: the install runs as a child, so the session opens when it finishes.
$script:CcOpenAfterInstall = $false
# DeepSeek Harness: same shape as the bridge above - a child per one-shot
# action, its own health ping, and state independent of $ServerProc because the
# harness outlives this window and one started outside the GUI must show up.
$script:DshProc = $null
$script:DshAction = ""
$script:DshUp = $false
$script:DshPingTask = $null
# Set when the user asked to open the browser and the harness had to be
# installed or started first: the browser opens when that child finishes.
$script:DshOpenAfter = $false
$script:DiagZip = $null
$script:ServerUp = $false
# The id the running server reports (used in chat requests); the id the user
# picked on the Setup tab is what install/run get told about.
$script:ModelId = "unsloth/Qwen3.8-27B-NVFP4"
$script:ModelStandard = "unsloth/Qwen3.8-27B-NVFP4"
$script:ModelGated = "orcarouter/Qwen3.8-27B-Uncensored-NVFP4"   # the only entry needing a token
$script:ModelNinfer = "neroued/Qwen3.8-27B-nvfp4-NInfer"
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
$script:SpinnerFrames = @('|', '/', '-', '\')

$doc = New-Object Windows.Documents.FlowDocument
$doc.PagePadding = New-Object Windows.Thickness(4)
$RtbChat.Document = $doc
$script:ChatPara = $null   # created per message by New-ChatParagraph

# ------------------------------------------------------------------ helpers
function Get-SelectedModel {
    if ($CmbModel -and $CmbModel.SelectedItem) { return [string]$CmbModel.SelectedItem.Tag }
    return $script:ModelStandard
}

# An NInfer entry is served by a compiled engine rather than by vLLM, and its
# weights are one .ninfer container instead of a Hugging Face snapshot - so
# both the installer and the "is it downloaded" probe have to branch on it.
# The owner is the tell: NInfer publishes all five artifacts itself.
function Test-NinferModel([string]$id) {
    if (-not $id) { return $false }
    return ($id -like "neroued/*NInfer")
}

# A GGUF entry names its quant after a colon and is served by llama.cpp, not
# vLLM - a different binary, a different port, and not through WSL at all.
function Test-GgufModel([string]$id) {
    if (-not $id) { return $false }
    return ($id -match ":" -or $id -match "(?i)gguf")
}

function Get-ModelLabel([string]$id) {
    # The repo name without the owner: short enough for the status pill, but it
    # says which checkpoint - "uncensored" alone did not.
    if (-not $id) { return "" }
    return ($id -split '/')[-1]
}

function Get-SelectedModelLabel {
    return Get-ModelLabel (Get-SelectedModel)
}

function Update-ModelChoice {
    # Only the OrcaRouter entry is gated; the others download without an account.
    $sel = Get-SelectedModel
    $gated = $sel -eq $script:ModelGated
    $TxtHfToken.IsEnabled = $gated
    if ($gated) {
        $TxtModelHint.Text = "Gated: accept the terms on huggingface.co, then paste a read token (once)."
    } elseif (Test-GgufModel $sel) {
        # Say the cost here rather than three hours into a download.
        $TxtModelHint.Text = "Served from system RAM by llama.cpp - tens of GB to download, and far slower than the Qwen builds."
    } elseif (Test-NinferModel $sel) {
        # The compile is the surprising part - say so before Install is clicked.
        $TxtModelHint.Text = "About twice the speed of Standard. Setup compiles an engine for your card first, which takes a while and happens once."
    } else {
        $TxtModelHint.Text = ""
    }
    Update-Status
}

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

function New-Brush([string]$color) {
    New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString($color))
}

function Set-Dot($dot, [string]$color) { $dot.Fill = New-Brush $color }

function New-ChatParagraph([string]$kind) {
    # One paragraph per message: 'user' and 'assistant' render as bubbles,
    # 'info' as plain dim text. Streaming runs append to the current paragraph.
    $p = New-Object Windows.Documents.Paragraph
    $p.Padding = New-Object Windows.Thickness(10, 7, 10, 7)
    $p.Margin = New-Object Windows.Thickness(0, 3, 0, 3)
    switch ($kind) {
        'user' {
            $p.Background = New-Brush "#FF1C2712"
            $p.BorderBrush = New-Brush "#FF2E4218"
            $p.BorderThickness = New-Object Windows.Thickness(1)
            $p.Margin = New-Object Windows.Thickness(60, 3, 0, 3)
        }
        'assistant' {
            $p.Background = New-Brush "#FF181D26"
            $p.BorderBrush = New-Brush "#FF242B38"
            $p.BorderThickness = New-Object Windows.Thickness(1)
            $p.Margin = New-Object Windows.Thickness(0, 3, 60, 3)
        }
        'info' {
            $p.Padding = New-Object Windows.Thickness(2)
        }
    }
    $RtbChat.Document.Blocks.Add($p)
    $script:ChatPara = $p
    $RtbChat.ScrollToEnd()
    return $p
}

function Add-ChatRun([string]$text, [string]$color, [switch]$Bold, [switch]$Italic) {
    if (-not $script:ChatPara) { $null = New-ChatParagraph 'info' }
    $run = New-Object Windows.Documents.Run($text)
    $run.Foreground = New-Brush $color
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
        if ($g.Count -ge 2) { $TxtGpuS.Text = "$($g[0].Trim()) (driver $($g[1].Trim()))"; Set-Dot $DotGpu "#FF76B900" }
        else { $TxtGpuS.Text = "no NVIDIA GPU?"; Set-Dot $DotGpu "#FFFF6B6B" }
    } catch { $TxtGpuS.Text = "driver missing"; Set-Dot $DotGpu "#FFFF6B6B" }

    $distros = Get-WslDistros
    if ($distros -contains $Distro) {
        & wsl -d $Distro -- bash -c "test -x `$HOME/.qwen5090/venv/bin/vllm" 2>$null
        if ($LASTEXITCODE -eq 0) { $TxtWslS.Text = "$Distro + vLLM ready"; Set-Dot $DotWsl "#FF76B900" }
        else { $TxtWslS.Text = "$Distro (vLLM not installed)"; Set-Dot $DotWsl "#FFE0B84C" }
        # A live server outranks the dropdown. The two disagree whenever the
        # user changes the selection while a server is up, or when the server was
        # started outside the GUI - and a pill reading "not downloaded" while a
        # different checkpoint is answering requests is the confusing case.
        if ($script:ServerUp -and $script:ModelId) {
            $TxtModelS.Text = "$(Get-ModelLabel $script:ModelId) - serving"
            $TxtModelS.ToolTip = $script:ModelId
            Set-Dot $DotModel "#FF76B900"
        } else {
            $label = Get-SelectedModelLabel
            $sel = Get-SelectedModel
            $TxtModelS.ToolTip = $sel
            # An NInfer artifact never lands in the Hugging Face cache - it is a
            # single container under ~/.qwen5090/ninfer/models - so probing the
            # cache path would report "not downloaded" for a model that is
            # sitting right there.
            if (Test-NinferModel $sel) {
                $probe = "test -s `$HOME/.qwen5090/ninfer/models/*.ninfer"
            } else {
                $probe = "test -d `$HOME/.cache/huggingface/hub/models--$($sel -replace '/','--')"
            }
            & wsl -d $Distro -- bash -c $probe 2>$null
            if ($LASTEXITCODE -eq 0) { $TxtModelS.Text = "$label - downloaded"; Set-Dot $DotModel "#FF76B900" }
            else { $TxtModelS.Text = "$label - not downloaded"; Set-Dot $DotModel "#FF4A5261" }
        }
    } else {
        $TxtWslS.Text = "not installed";   Set-Dot $DotWsl "#FF4A5261"
        $TxtModelS.ToolTip = Get-SelectedModel
        $TxtModelS.Text = "$(Get-SelectedModelLabel) - not downloaded"; Set-Dot $DotModel "#FF4A5261"
    }
}

function Set-ServerStatus([string]$text, [string]$color) {
    $TxtServerS.Text = $text
    $TxtServerS.Foreground = New-Brush $color
    Set-Dot $DotServer $color
}

# ------------------------------------------------------------------ setup
function Start-Install {
    # A GGUF build needs none of this: no distro, no venv, no elevation - just
    # the weights, on a Windows drive, because llama.cpp serves them from there.
    $model = Get-SelectedModel
    if (Test-GgufModel $model) {
        $BtnInstall.IsEnabled = $false
        $BtnCleanup.IsEnabled = $false
        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $outLog = Join-Path $script:LogDir "install-$ts.out.log"
        $errLog = Join-Path $script:LogDir "install-$ts.err.log"
        Add-Tail $outLog $TxtSetupLog
        Add-Tail $errLog $TxtSetupLog
        Add-Log $TxtSetupLog "Model: $model"
        Add-Log $TxtSetupLog "Downloading the weights - this is tens of GB and resumes if interrupted."
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\serve-gguf.ps1`" -Model `"$model`" -Download -DownloadOnly"
        Write-GuiLog "gguf download started | args: $psArgs"
        $script:SetupProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        $null = $script:SetupProc.Handle
        return
    }
    if (-not $script:IsAdmin) {
        $r = [Windows.MessageBox]::Show("Installing needs Administrator rights.`nRelaunch the app as Administrator?",
            "Qwen 5090", "YesNo", "Question")
        if ($r -eq "Yes") {
            $relaunch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -AutoInstall -Model $(Get-SelectedModel)"
            $tok = ""
            if ($TxtHfToken.Text) { $tok = $TxtHfToken.Text.Trim() }
            if ($tok) {
                # Elevation keeps the same user, so %LOCALAPPDATA% still resolves
                # here. Deliberately NOT the logs folder - collect-logs.ps1 zips
                # that up for bug reports. The elevated instance deletes it.
                $tokFile = Join-Path (Split-Path $script:LogDir -Parent) "hf-token.tmp"
                try {
                    Set-Content -LiteralPath $tokFile -Value $tok -Encoding ASCII -NoNewline
                    $relaunch += " -HfTokenFile `"$tokFile`""
                } catch { Write-GuiLog "could not stage the HF token: $($_.Exception.Message)" }
            }
            Start-Process powershell -Verb RunAs -ArgumentList $relaunch
            $Window.Close()
        }
        return
    }
    $BtnInstall.IsEnabled = $false
    $BtnCleanup.IsEnabled = $false
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "install-$ts.out.log"
    $errLog = Join-Path $script:LogDir "install-$ts.err.log"
    Add-Tail $outLog $TxtSetupLog
    Add-Tail $errLog $TxtSetupLog
    $model = Get-SelectedModel
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\install.ps1`" -Unattended -Distro $Distro -Model $model"
    # -Ninfer changes what install.ps1 does rather than just which weights it
    # fetches: it builds the environment without the 22 GB of Hugging Face
    # weights, compiles the engine, and records the model as the machine
    # default so later starts pick it up without the dropdown.
    if (Test-NinferModel $model) { $psArgs += " -Ninfer" }
    if ($ChkSkipDownload.IsChecked) { $psArgs += " -SkipDownload" }
    # Hand the token over in the environment rather than on the command line -
    # install.ps1 picks it up as the default for -HfToken.
    $token = ""
    if ($TxtHfToken.Text) { $token = $TxtHfToken.Text.Trim() }
    [Environment]::SetEnvironmentVariable("QWEN5090_HF_TOKEN", $token, "Process")
    Add-Log $TxtSetupLog "Model: $model"
    if ($model -eq $script:ModelGated -and -not $token) {
        Add-Log $TxtSetupLog "No Hugging Face token given - this build is gated, so the download only works if you already saved a token."
    }
    Add-Log $TxtSetupLog "Starting installer (this can take 15-40 min incl. the model download)..."
    Add-Log $TxtSetupLog "Logging to $outLog"
    Write-GuiLog "installer started | args: $psArgs"
    $script:SetupProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $null = $script:SetupProc.Handle   # cache now or .ExitCode reads $null after exit (PS 5.1)
}

function Complete-Install {
    $code = $script:SetupProc.ExitCode
    if ($null -eq $code) { $code = -1 }
    $script:SetupProc = $null
    $BtnInstall.IsEnabled = $true
    $BtnCleanup.IsEnabled = $true
    Write-GuiLog "installer exited | code=$code"
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

# ------------------------------------------------------------------ cleanup
function Start-Cleanup {
    $msg = "This removes everything Qwen 5090 installed:`n`n" +
           "  - The $Distro Linux distro`n" +
           "  - The Python environment and vLLM`n" +
           "  - The downloaded model (~22 GB)`n" +
           "  - Network sharing rules, desktop shortcut, startup entry`n`n" +
           "Around 20+ GB of disk space is freed. You can reinstall at any time`n" +
           "by clicking 'Install / Repair' again.`n`nRemove everything now?"
    $r = [Windows.MessageBox]::Show($msg, "Qwen 5090 - Cleanup", "YesNo", "Warning")
    if ($r -ne "Yes") { return }
    if (-not $script:IsAdmin) {
        $r2 = [Windows.MessageBox]::Show("Cleanup needs Administrator rights (to remove firewall rules).`nRelaunch the app as Administrator?",
            "Qwen 5090", "YesNo", "Question")
        if ($r2 -eq "Yes") {
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -AutoCleanup"
            $Window.Close()
        }
        return
    }
    Invoke-Cleanup
}

function Invoke-Cleanup {
    if ($script:ServerUp -or $script:ServerProc) { Stop-Server }
    $BtnCleanup.IsEnabled = $false
    $BtnInstall.IsEnabled = $false
    $BtnStart.IsEnabled = $false
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "cleanup-$ts.out.log"
    $errLog = Join-Path $script:LogDir "cleanup-$ts.err.log"
    Add-Tail $outLog $TxtSetupLog
    Add-Tail $errLog $TxtSetupLog
    $port = 8000
    $null = [int]::TryParse($TxtPort.Text, [ref]$port)
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\uninstall.ps1`" -Distro $Distro -Port $port"
    Add-Log $TxtSetupLog "Starting cleanup - removing the distro, the model, and sharing rules..."
    Add-Log $TxtSetupLog "Logging to $outLog"
    Write-GuiLog "cleanup started | args: $psArgs"
    $script:CleanupProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $null = $script:CleanupProc.Handle   # cache now or .ExitCode reads $null after exit (PS 5.1)
}

function Complete-Cleanup {
    $code = $script:CleanupProc.ExitCode
    if ($null -eq $code) { $code = -1 }
    $script:CleanupProc = $null
    $BtnCleanup.IsEnabled = $true
    $BtnInstall.IsEnabled = $true
    $BtnStart.IsEnabled = $true
    Write-GuiLog "cleanup exited | code=$code"
    if ($code -eq 0) {
        Add-Log $TxtSetupLog "Cleanup finished - everything is removed. Click 'Install / Repair' whenever you want it back."
    } else {
        Add-Log $TxtSetupLog "Cleanup FAILED (exit code $code) - see the log above; close any WSL windows and try again."
    }
    Update-Status
}

# ------------------------------------------------------------------ server
function Start-Server {
    $port = 0
    if (-not [int]::TryParse($TxtPort.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [Windows.MessageBox]::Show("Invalid port: $($TxtPort.Text)", "Qwen 5090") | Out-Null
        return
    }
    $ctx = [int]$CmbCtx.SelectedItem.Tag
    $BtnStart.IsEnabled = $false
    $BtnStop.IsEnabled = $true
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "server-$ts.out.log"
    $errLog = Join-Path $script:LogDir "server-$ts.err.log"
    Add-Tail $outLog $TxtServerLog
    Add-Tail $errLog $TxtServerLog
    $model = Get-SelectedModel
    if (Test-GgufModel $model) {
        # llama.cpp, natively on Windows - MTP is a vLLM feature and there is no
        # WSL in this path, so neither flag applies.
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\serve-gguf.ps1`" -Port $port -Ctx $ctx -Model `"$model`""
        if ($ChkShare.IsChecked) { $psArgs += " -Share" }
        Add-Log $TxtServerLog "Starting $model on port $port (context $ctx) with llama.cpp."
        Add-Log $TxtServerLog "This model is served from system RAM, so the first load reads tens of GB off the disk and generation is far slower than the Qwen builds."
    } else {
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\run.ps1`" -Port $port -Ctx $ctx -Distro $Distro -Model $model"
        if (-not $ChkMtp.IsChecked) { $psArgs += " -NoMtp" }
        if ($ChkShare.IsChecked) {
            $psArgs += " -Share"
            Add-Log $TxtServerLog "Network sharing requested - approve the admin prompt that appears."
        }
        Add-Log $TxtServerLog "Starting $model on port $port (context $ctx)... first start takes a minute or two."
    }
    Add-Log $TxtServerLog "Logging to $outLog"
    Write-GuiLog "server starting | args: $psArgs"
    Set-ServerStatus "starting..." "#FFE0B84C"
    $script:ServerProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}

function Stop-Server {
    try { & wsl -d $Distro -- bash -c "pkill -f 'vllm serve'" 2>$null } catch { }
    # The llama.cpp backend is a Windows process, so wsl pkill never sees it.
    try { Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force } catch { }
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
        try { $script:ServerProc.Kill() } catch { }
    }
    $script:ServerProc = $null
    $script:ServerUp = $false
    $BtnStart.IsEnabled = $true
    $BtnStop.IsEnabled = $false
    Set-ServerStatus "stopped" "#FF8A93A5"
    Add-Log $TxtServerLog "Server stopped."
    Write-GuiLog "server stopped by user"
}

function Start-Diagnostics {
    if ($script:DiagProc) { return }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:DiagZip = Join-Path ([Environment]::GetFolderPath('Desktop')) "qwen5090-diagnostics-$ts.zip"
    $diagLog = Join-Path $script:LogDir "diag-$ts.log"
    Add-Tail $diagLog $TxtSetupLog
    $BtnDiag.IsEnabled = $false
    Add-Log $TxtSetupLog "Collecting diagnostics (takes ~15-30s)..."
    Write-GuiLog "diagnostics started -> $script:DiagZip"
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\collect-logs.ps1`" -Distro $Distro -OutFile `"$script:DiagZip`""
    $script:DiagProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $diagLog -RedirectStandardError (Join-Path $script:LogDir "diag-$ts.err.log")
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
                    Write-GuiLog "server detected UP on port $($TxtPort.Text)"
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
                Write-GuiLog "server went DOWN (HTTP $([int]$resp.StatusCode))"
            }
            $resp.Dispose()
        } catch {
            if ($script:ServerUp) {
                $script:ServerUp = $false
                Set-ServerStatus "not responding" "#FFFF6B6B"
                $BtnStart.IsEnabled = $true
                Write-GuiLog "server went DOWN (no response)"
            }
        }
        return
    }
    $script:PingTask = $script:Http.GetAsync("http://localhost:$($TxtPort.Text)/v1/models")
}

# ------------------------------------------------------------ claude code
# Everything here shells out to claude-code.ps1, which shells out to
# scripts/claude-code.sh inside WSL. The GUI only ever starts children and
# reads their logs - the same contract the Setup and Server tabs keep.
function Set-BridgeStatus([string]$text, [string]$color) {
    $TxtBridgeS.Text = $text
    $TxtBridgeS.Foreground = New-Brush $color
    Set-Dot $DotBridge $color
}

function Get-CcPorts {
    # Returns @(serverPort, bridgePort), or $null after complaining about
    # whichever one is wrong. Both matter: the bridge is told where the model
    # server is, and a typo there fails 60 seconds later inside WSL.
    $bridge = 0
    if (-not [int]::TryParse($TxtCcPort.Text, [ref]$bridge) -or $bridge -lt 1 -or $bridge -gt 65535) {
        [Windows.MessageBox]::Show("Invalid bridge port: $($TxtCcPort.Text)", "Qwen 5090") | Out-Null
        return $null
    }
    $server = 0
    if (-not [int]::TryParse($TxtPort.Text, [ref]$server) -or $server -lt 1 -or $server -gt 65535) {
        [Windows.MessageBox]::Show("Invalid server port on the Server tab: $($TxtPort.Text)", "Qwen 5090") | Out-Null
        return $null
    }
    return @($server, $bridge)
}

function Get-CcEffort {
    if ($CmbCcEffort -and $CmbCcEffort.SelectedItem) { return [string]$CmbCcEffort.SelectedItem.Content }
    return "xhigh"
}

function Start-BridgeAction([string]$action, [string]$switches) {
    # One child at a time: the script below serialises anyway (start waits for
    # the port to open, stop waits for it to close), and two at once would race
    # for the same port and both lose.
    if ($script:BridgeProc) {
        Add-Log $TxtCcLog "Busy with '$($script:BridgeAction)' - wait for it to finish."
        return
    }
    $ports = Get-CcPorts
    if (-not $ports) { return }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "claude-code-$action-$ts.log"
    $errLog = Join-Path $script:LogDir "claude-code-$action-$ts.err.log"
    Add-Tail $outLog $TxtCcLog
    Add-Tail $errLog $TxtCcLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\claude-code.ps1`"" +
              " -Distro $Distro -Port $($ports[0]) -BridgePort $($ports[1]) -Effort $(Get-CcEffort) $switches"
    Write-GuiLog "claude-code $action | args: $psArgs"
    $script:BridgeAction = $action
    $script:BridgeEnvLog = if ($action -eq "env") { $outLog } else { $null }
    $script:BridgeProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $null = $script:BridgeProc.Handle   # cache now or .ExitCode reads $null after exit (PS 5.1)
    $BtnCcStart.IsEnabled = $false
    $BtnCcStop.IsEnabled = $false
    $BtnCcEnv.IsEnabled = $false
    $BtnCcDoctor.IsEnabled = $false
    $BtnCcInstall.IsEnabled = $false
    $BtnCcOpen.IsEnabled = $false
}

function Test-ClaudeInstalled {
    # Synchronous, like the WSL probes Update-Status already does: one warm
    # `wsl -d ... bash -c` is a few hundred ms and this runs on a click, not on
    # the timer. The installer puts claude in ~/.local/bin, which a non-login
    # `bash -c` does not pick up by itself, so look there first and only then
    # fall back to whatever is on PATH.
    #
    # Do NOT put the lookup back behind a `PATH=$HOME/.local/bin:$PATH command
    # -v claude` prefix. $HOME and $PATH are expanded before the inner bash
    # parses the line, and the inherited Windows PATH holds
    # `C:\Program Files (x86)\...` on virtually every machine - the bare `(`
    # then dies with "syntax error near unexpected token", exit 2, which is
    # indistinguishable from "not installed". It reported a perfectly good
    # install as missing on every click.
    try {
        & wsl -d $Distro -- bash -c "test -x `"`$HOME/.local/bin/claude`" || command -v claude >/dev/null" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Update-CcHint {
    if (Test-ClaudeInstalled) {
        $TxtCcHint.Text = "Claude Code is installed."
    } else {
        $TxtCcHint.Text = "Claude Code is not installed yet - opening a session installs it (about 30 seconds)."
    }
}

function Install-ClaudeCode {
    Add-Log $TxtCcLog "Installing Claude Code inside Linux (about 30 seconds, no account needed)..."
    Start-BridgeAction "install-claude" "-InstallClaude"
}

function Test-BridgeReady {
    # The bridge reads the served model id and context length off /v1/models, so
    # without a server it dies with a message about a server, not about itself.
    if ($script:ServerUp) { return $true }
    $r = [Windows.MessageBox]::Show(
        "The model server is not running, and the bridge configures itself from it.`n`nStart the server first (Server tab)?",
        "Qwen 5090", "YesNo", "Warning")
    if ($r -eq "Yes") { Start-Server }
    return $false
}

function Get-CcDebugSwitch {
    if ($ChkCcDebug -and $ChkCcDebug.IsChecked) { return " -LogPayloads" }
    return ""
}

function Start-Bridge {
    if (-not (Test-BridgeReady)) { return }
    Add-Log $TxtCcLog "Starting the bridge on port $($TxtCcPort.Text) at effort $(Get-CcEffort)..."
    if ($ChkCcDebug.IsChecked) {
        Add-Log $TxtCcLog "Recording is ON: every prompt and reply will be written to ~/.qwen5090/debug inside Linux. Untick and restart the bridge to stop."
    }
    Set-BridgeStatus "starting..." "#FFE0B84C"
    Start-BridgeAction "start" "-Start -BindAll$(Get-CcDebugSwitch)"
}

function Stop-Bridge {
    Add-Log $TxtCcLog "Stopping the bridge..."
    Start-BridgeAction "stop" "-Stop"
}

function Start-BridgeDoctor { Start-BridgeAction "doctor" "-Doctor" }

function Copy-BridgeEnv {
    # The env verb only reads settings back - it does not start anything, and the
    # variables it prints point at a port that has to be live for them to be
    # worth pasting anywhere.
    if (-not $script:BridgeUp) {
        $r = [Windows.MessageBox]::Show(
            "The bridge is not running, and these variables only work while it is.`n`nStart it now?",
            "Qwen 5090", "YesNo", "Question")
        if ($r -eq "Yes") { Start-Bridge }
        return
    }
    if (-not (Test-BridgeReady)) { return }
    Add-Log $TxtCcLog "Collecting the variables a Windows Claude Code needs..."
    Start-BridgeAction "env" "-Windows"
}

function Open-ClaudeCode {
    if (-not (Test-BridgeReady)) { return }
    $ports = Get-CcPorts
    if (-not $ports) { return }
    # The session runs in a console window this GUI cannot read, so a missing
    # Claude Code would fail out of sight. Install it here, then open the
    # session from Complete-BridgeAction once the child is done.
    if (-not (Test-ClaudeInstalled)) {
        $r = [Windows.MessageBox]::Show(
            "Claude Code is not installed yet.`n`nInstall it now? It takes about 30 seconds, needs no account, and only has to happen once.",
            "Qwen 5090", "YesNo", "Question")
        if ($r -ne "Yes") { return }
        $script:CcOpenAfterInstall = $true
        Install-ClaudeCode
        return
    }
    # The one child that is NOT hidden: Claude Code is an interactive terminal
    # app, so it needs a real console. -NoExit keeps the window open when
    # something fails, which is the only place the user would see why.
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$script:RepoRoot\claude-code.ps1`"" +
              " -Distro $Distro -Port $($ports[0]) -BridgePort $($ports[1]) -Effort $(Get-CcEffort) -BindAll$(Get-CcDebugSwitch)"
    Write-GuiLog "claude-code session | args: $psArgs"
    Add-Log $TxtCcLog "Opening a Claude Code session in its own window (first start takes a few seconds)."
    Add-Log $TxtCcLog "It runs inside Linux, in your home directory there. Close that window to end the session."
    try {
        $null = Start-Process powershell -ArgumentList $psArgs
    } catch {
        Add-Log $TxtCcLog "Could not open the session window: $($_.Exception.Message)"
        Write-GuiLog "claude-code session FAILED to launch: $($_.Exception.Message)"
    }
}

function Complete-BridgeAction {
    $action = $script:BridgeAction
    $code = -1
    try { $code = $script:BridgeProc.ExitCode } catch { }
    if ($null -eq $code) { $code = -1 }   # no handle cached before exit (PS 5.1)
    $script:BridgeProc = $null
    $script:BridgeAction = ""
    $BtnCcEnv.IsEnabled = $true
    $BtnCcDoctor.IsEnabled = $true
    $BtnCcInstall.IsEnabled = $true
    $BtnCcOpen.IsEnabled = $true
    $BtnCcStart.IsEnabled = -not $script:BridgeUp
    $BtnCcStop.IsEnabled = $script:BridgeUp
    Write-GuiLog "claude-code $action exited with $code"

    if ($code -ne 0) {
        Add-Log $TxtCcLog "'$action' failed (exit $code) - see the output above."
        if ($action -eq "start") { Set-BridgeStatus "failed to start" "#FFFF6B6B" }
        if ($action -eq "install-claude") {
            $script:CcOpenAfterInstall = $false
            Add-Log $TxtCcLog "Claude Code was not installed, so no session was opened."
        }
        return
    }
    if ($action -eq "install-claude") {
        Update-CcHint
        if ($script:CcOpenAfterInstall) {
            $script:CcOpenAfterInstall = $false
            Add-Log $TxtCcLog "Installed - opening your session now."
            Open-ClaudeCode
        }
        return
    }
    if ($action -eq "start") {
        Add-Log $TxtCcLog "Bridge start finished - confirming it is reachable..."
        $script:BridgeConfirmBy = (Get-Date).AddSeconds(8)
        return
    }
    if ($action -eq "stop") {
        $script:BridgeConfirmBy = $null
        $script:BridgeUp = $false
        Set-BridgeStatus "bridge stopped" "#FF8A93A5"
        $BtnCcStart.IsEnabled = $true
        $BtnCcStop.IsEnabled = $false
        return
    }
    if ($action -eq "env" -and $script:BridgeEnvLog -and (Test-Path $script:BridgeEnvLog)) {
        # The child prints PowerShell assignments; lift them out for the clipboard
        # so the user can paste straight into their own window.
        try {
            $lines = @(Get-Content -LiteralPath $script:BridgeEnvLog |
                       Where-Object { $_ -match '^\s*\$env:[A-Z0-9_]+\s*=' } |
                       ForEach-Object { $_.Trim() })
            if ($lines.Count -gt 0) {
                Set-Clipboard -Value ($lines -join "`r`n")
                Add-Log $TxtCcLog "Copied $($lines.Count) variables to the clipboard - paste them into a PowerShell window, then run: claude"
                Add-Log $TxtCcLog "Keep that window for Qwen only; they apply to every 'claude' started from it, cloud sessions included."
            }
        } catch { Write-GuiLog "clipboard copy failed: $($_.Exception.Message)" }
    }
    $script:BridgeEnvLog = $null
}

function Test-BridgeHealth {
    # Same async shape as Test-ServerHealth: start on one tick, read on a later
    # one, so a bridge that is not there costs the UI nothing. Polled whatever
    # the GUI itself did, so a bridge from an earlier session is picked up too.
    if ($script:BridgePingTask) {
        if (-not $script:BridgePingTask.IsCompleted) { return }
        $task = $script:BridgePingTask
        $script:BridgePingTask = $null
        $alive = $false
        try {
            $resp = $task.Result
            $alive = $resp.IsSuccessStatusCode
            $resp.Dispose()
        } catch { $alive = $false }

        if ($alive) { $script:BridgeConfirmBy = $null }
        if ($alive -and -not $script:BridgeUp) {
            $script:BridgeUp = $true
            Set-BridgeStatus "bridge on port $($TxtCcPort.Text)" "#FF76B900"
            if (-not $script:BridgeProc) {
                $BtnCcStart.IsEnabled = $false
                $BtnCcStop.IsEnabled = $true
            }
            Write-GuiLog "bridge detected UP on port $($TxtCcPort.Text)"
            Add-Log $TxtCcLog "Bridge is up on http://127.0.0.1:$($TxtCcPort.Text) - Open Claude Code will use it."
        } elseif (-not $alive -and $script:BridgeUp) {
            $script:BridgeUp = $false
            Set-BridgeStatus "bridge stopped" "#FF8A93A5"
            if (-not $script:BridgeProc) {
                $BtnCcStart.IsEnabled = $true
                $BtnCcStop.IsEnabled = $false
            }
            Write-GuiLog "bridge went DOWN"
        }
        return
    }
    $port = 0
    if (-not [int]::TryParse($TxtCcPort.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return }
    $script:BridgePingTask = $script:Http.GetAsync("http://127.0.0.1:$port/health/liveliness")
}

# ------------------------------------------------------------------ harness
function Set-DshStatus([string]$text, [string]$color) {
    $TxtDshS.Text = $text
    $TxtDshS.Foreground = New-Brush $color
    Set-Dot $DotDsh $color
}

function Get-DshPorts {
    # Returns @(serverPort, uiPort), or $null after complaining about whichever
    # one is wrong. Both matter: the harness is told where the model server is,
    # and a typo there writes a route that points at nothing.
    $ui = 0
    if (-not [int]::TryParse($TxtDshPort.Text, [ref]$ui) -or $ui -lt 1 -or $ui -gt 65535) {
        [Windows.MessageBox]::Show("Invalid harness UI port: $($TxtDshPort.Text)", "Qwen 5090") | Out-Null
        return $null
    }
    $server = 0
    if (-not [int]::TryParse($TxtPort.Text, [ref]$server) -or $server -lt 1 -or $server -gt 65535) {
        [Windows.MessageBox]::Show("Invalid server port on the Server tab: $($TxtPort.Text)", "Qwen 5090") | Out-Null
        return $null
    }
    return @($server, $ui)
}

function Start-DshAction([string]$action, [string]$switches) {
    # One child at a time, for the same reason the bridge serialises: start
    # waits for the port to open and stop waits for it to close, so two at once
    # would race for the same port and both lose.
    if ($script:DshProc) {
        Add-Log $TxtDshLog "Busy with '$($script:DshAction)' - wait for it to finish."
        return
    }
    $ports = Get-DshPorts
    if (-not $ports) { return }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "deepseek-harness-$action-$ts.log"
    $errLog = Join-Path $script:LogDir "deepseek-harness-$action-$ts.err.log"
    Add-Tail $outLog $TxtDshLog
    Add-Tail $errLog $TxtDshLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\deepseek-harness.ps1`"" +
              " -Distro $Distro -Port $($ports[0]) -UiPort $($ports[1]) $switches"
    Write-GuiLog "deepseek-harness $action | args: $psArgs"
    $script:DshAction = $action
    $script:DshProc = Start-Process powershell -ArgumentList $psArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $null = $script:DshProc.Handle   # cache now or .ExitCode reads $null after exit (PS 5.1)
    $BtnDshStart.IsEnabled = $false
    $BtnDshStop.IsEnabled = $false
    $BtnDshOpen.IsEnabled = $false
    $BtnDshInstall.IsEnabled = $false
    $BtnDshConfig.IsEnabled = $false
    $BtnDshDoctor.IsEnabled = $false
}

function Test-DshInstalled {
    # Same shape and the same caveat as Test-ClaudeInstalled: one warm
    # `wsl -d ... bash -c`, and NO `PATH=...` assignment prefix. $HOME and $PATH
    # would be expanded before the inner bash parses the line, and the inherited
    # Windows PATH holds "C:\Program Files (x86)\..." on virtually every machine,
    # whose bare "(" dies with a syntax error that looks just like "not found".
    try {
        & wsl -d $Distro -- bash -c "test -x `"`$HOME/.dsh-runtime/node_modules/.bin/dsh`"" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-DshNode {
    # The harness needs Node >= 22.19 and deliberately will not install one. It
    # matters here because Ubuntu 24.04 - what install.ps1 provisions - ships
    # Node 18, so this is the expected state on a fresh box rather than an edge
    # case. Returns $true when node is new enough.
    #
    # Two traps here, both measured on the real machine (2026-08-25):
    # install-node puts node in ~/.local/bin, which a non-login `bash -c` does
    # not have on PATH - the same trap Test-ClaudeInstalled documents - so a
    # bare `command -v node` reported a just-installed Node as missing and the
    # GUI asked to install it again, forever. And the version payload must
    # contain no double quotes and no semicolons: the Windows->WSL re-join
    # strips inner double quotes even inside bash single quotes, so a
    # split(".") arrived at node as split(.) - a SyntaxError, exit 1,
    # indistinguishable from "too old". Full path first, `||` fallback to
    # PATH, and a quote-free payload (no spaces, so stripping cannot split
    # it). Never a PATH= assignment prefix - see Test-ClaudeInstalled.
    try {
        & wsl -d $Distro -- bash -c "`"`$HOME/.local/bin/node`" -e 'process.exit(parseInt(process.version.slice(1))>=22?0:1)' 2>/dev/null || node -e 'process.exit(parseInt(process.version.slice(1))>=22?0:1)'" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Update-DshHint {
    if (Test-DshInstalled) {
        $TxtDshHint.Text = "Harness is installed."
    } else {
        $TxtDshHint.Text = "Harness is not installed yet - Start installs it (about a minute)."
    }
}

function Test-DshReady {
    # The harness writes its provider route from whatever the server reports, so
    # starting it without one produces a harness with nothing to talk to.
    if ($script:ServerUp) { return $true }
    $r = [Windows.MessageBox]::Show(
        "The model server is not running, and the harness configures itself from it.`n`nStart the server first (Server tab)?",
        "Qwen 5090", "YesNo", "Warning")
    if ($r -eq "Yes") { Start-Server }
    return $false
}

function Install-DshNode {
    Add-Log $TxtDshLog "Installing Node.js inside Linux (about 25 MB, no root, one time)..."
    Start-DshAction "install-node" "-InstallNode"
}

function Install-Dsh {
    # Node first, and asked rather than assumed: it is a language runtime going
    # onto the user's machine, so it gets its own yes/no even though the button
    # they clicked was about the harness.
    if (-not (Test-DshNode)) {
        $r = [Windows.MessageBox]::Show(
            "The harness needs Node.js 22 or newer, and this Linux box does not have it." +
            "`n`n(Ubuntu 24.04 ships Node 18, so this is normal on a fresh install.)" +
            "`n`nInstall Node into your Linux home directory now? About 25 MB, no root needed.",
            "Qwen 5090", "YesNo", "Question")
        if ($r -ne "Yes") {
            Add-Log $TxtDshLog "Node was not installed, so the harness cannot be installed either."
            return
        }
        $script:DshOpenAfter = $false
        Install-DshNode
        return
    }
    Add-Log $TxtDshLog "Installing the harness inside Linux (about a minute)..."
    Start-DshAction "install" "-Install"
}

function Start-Dsh {
    if (-not (Test-DshReady)) { return }
    if (-not (Test-DshNode)) { Install-Dsh; return }
    Add-Log $TxtDshLog "Starting the harness on port $($TxtDshPort.Text)..."
    Set-DshStatus "starting..." "#FFE0B84C"
    Start-DshAction "start" ""
}

function Stop-Dsh {
    Add-Log $TxtDshLog "Stopping the harness..."
    Start-DshAction "stop" "-Stop"
}

function Start-DshDoctor { Start-DshAction "doctor" "-Doctor" }

function Update-DshConfig {
    if (-not (Test-DshReady)) { return }
    Add-Log $TxtDshLog "Re-reading the server and rewriting the harness route..."
    Start-DshAction "config" "-Config"
}

function Open-DshBrowser {
    $port = 0
    if (-not [int]::TryParse($TxtDshPort.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [Windows.MessageBox]::Show("Invalid harness UI port: $($TxtDshPort.Text)", "Qwen 5090") | Out-Null
        return
    }
    $url = "http://127.0.0.1:$port"
    Add-Log $TxtDshLog "Opening $url in your browser."
    try {
        Start-Process $url | Out-Null
    } catch {
        Write-GuiLog "could not open browser: $($_.Exception.Message)"
        Add-Log $TxtDshLog "Could not open a browser automatically - go to $url yourself."
    }
}

function Open-Dsh {
    # Start it if it is not up, and open the browser once it is. When a start is
    # needed the browser waits for the child to finish, because a page opened
    # against a port that is not listening yet just shows a refusal.
    if ($script:DshUp) { Open-DshBrowser; return }
    if (-not (Test-DshReady)) { return }
    $script:DshOpenAfter = $true
    Start-Dsh
}

function Complete-DshAction {
    $action = $script:DshAction
    $code = -1
    try { $code = $script:DshProc.ExitCode } catch { }
    if ($null -eq $code) { $code = -1 }   # no handle cached before exit (PS 5.1)
    $script:DshProc = $null
    $script:DshAction = ""
    $BtnDshOpen.IsEnabled = $true
    $BtnDshInstall.IsEnabled = $true
    $BtnDshConfig.IsEnabled = $true
    $BtnDshDoctor.IsEnabled = $true
    $BtnDshStart.IsEnabled = -not $script:DshUp
    $BtnDshStop.IsEnabled = $script:DshUp
    Write-GuiLog "deepseek-harness $action exited with $code"

    if ($code -ne 0) {
        $script:DshOpenAfter = $false
        Add-Log $TxtDshLog "'$action' failed (exit $code) - see the output above."
        if ($action -eq "start") { Set-DshStatus "failed to start" "#FFFF6B6B" }
        return
    }
    if ($action -eq "install-node") {
        Add-Log $TxtDshLog "Node installed - installing the harness now."
        Install-Dsh
        return
    }
    if ($action -eq "install") {
        Update-DshHint
        Add-Log $TxtDshLog "Harness installed."
        return
    }
    if ($action -eq "stop") {
        $script:DshUp = $false
        Set-DshStatus "stopped" "#FF8A93A5"
        $BtnDshStart.IsEnabled = $true
        $BtnDshStop.IsEnabled = $false
        return
    }
    if ($action -eq "start") {
        Update-DshHint
        Add-Log $TxtDshLog "Harness start finished - confirming it is reachable..."
        return
    }
}

function Test-DshHealth {
    # Same async shape as Test-BridgeHealth: started on one tick, read on a
    # later one, so a harness that is not there costs the UI nothing. Polled
    # whatever the GUI itself did, so one started outside it is picked up too.
    if ($script:DshPingTask) {
        if (-not $script:DshPingTask.IsCompleted) { return }
        $task = $script:DshPingTask
        $script:DshPingTask = $null
        $alive = $false
        try {
            $resp = $task.Result
            $alive = $resp.IsSuccessStatusCode
            $resp.Dispose()
        } catch { $alive = $false }

        if ($alive -and -not $script:DshUp) {
            $script:DshUp = $true
            Set-DshStatus "on port $($TxtDshPort.Text)" "#FF76B900"
            if (-not $script:DshProc) {
                $BtnDshStart.IsEnabled = $false
                $BtnDshStop.IsEnabled = $true
            }
            Write-GuiLog "harness detected UP on port $($TxtDshPort.Text)"
            Add-Log $TxtDshLog "Harness is up on http://127.0.0.1:$($TxtDshPort.Text)"
            if ($script:DshOpenAfter) {
                $script:DshOpenAfter = $false
                Open-DshBrowser
            }
        } elseif (-not $alive -and $script:DshUp) {
            $script:DshUp = $false
            Set-DshStatus "stopped" "#FF8A93A5"
            if (-not $script:DshProc) {
                $BtnDshStart.IsEnabled = $true
                $BtnDshStop.IsEnabled = $false
            }
            Write-GuiLog "harness went DOWN"
        }
        return
    }
    $port = 0
    if (-not [int]::TryParse($TxtDshPort.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return }
    $script:DshPingTask = $script:Http.GetAsync("http://127.0.0.1:$port/")
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
            # vLLM 0.27.1 streams the thinking text as 'reasoning'; other builds
            # use 'reasoning_content'. Accept either - reading only the latter
            # drops the entire thinking phase and the UI just sits there silent.
            $think = $null
            if ($delta.PSObject.Properties['reasoning'] -and $delta.reasoning) {
                $think = [string]$delta.reasoning
            } elseif ($delta.PSObject.Properties['reasoning_content'] -and $delta.reasoning_content) {
                $think = [string]$delta.reasoning_content
            }
            if ($think) { $queue.Enqueue(@{ t = 'think'; s = $think }) }
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
        $null = New-ChatParagraph 'info'
        Add-ChatRun "(server is not running - start it on the Server tab first)" "#FFFF6B6B" -Italic
        return
    }
    $TxtInput.Text = ""
    $null = New-ChatParagraph 'user'
    Add-ChatRun "You`n" "#FF76B900" -Bold
    Add-ChatRun $msg "#FFE6E9EF"
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

    $null = New-ChatParagraph 'assistant'
    Add-ChatRun "Qwen`n" "#FF4FC1FF" -Bold
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
            'think' { Add-ChatRun $item.s "#FF8A93A5" -Italic }
            'text'  { Add-ChatRun $item.s "#FFE6E9EF"; $null = $script:ChatReply.Append($item.s) }
            'err'   { Add-ChatRun "`n(error: $($item.s))`n" "#FFFF6B6B" -Italic; Write-GuiLog "chat error: $($item.s)" }
            'done'  {
                Add-ChatRun "`n" "#FFE6E9EF"
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
$BtnLogs.Add_Click({ Start-Process explorer.exe $script:LogDir })
$BtnDiag.Add_Click({ Start-Diagnostics })
$BtnInstall.Add_Click({ Start-Install })
$CmbModel.Add_SelectionChanged({ Update-ModelChoice })
$BtnCleanup.Add_Click({ Start-Cleanup })
$BtnStart.Add_Click({ Start-Server })
$BtnStop.Add_Click({ Stop-Server })
$BtnSend.Add_Click({ Send-ChatMessage })
$BtnCcOpen.Add_Click({ Open-ClaudeCode })
$BtnCcStart.Add_Click({ Start-Bridge })
$BtnCcStop.Add_Click({ Stop-Bridge })
$BtnCcEnv.Add_Click({ Copy-BridgeEnv })
$BtnCcDoctor.Add_Click({ Start-BridgeDoctor })
$BtnCcInstall.Add_Click({ Install-ClaudeCode })
$BtnDshOpen.Add_Click({ Open-Dsh })
$BtnDshStart.Add_Click({ Start-Dsh })
$BtnDshStop.Add_Click({ Stop-Dsh })
$BtnDshInstall.Add_Click({ Install-Dsh })
$BtnDshConfig.Add_Click({ Update-DshConfig })
$BtnDshDoctor.Add_Click({ Start-DshDoctor })
$BtnClear.Add_Click({
    $script:Messages.Clear()
    # One paragraph per message now, so clearing the current one would leave
    # every earlier bubble on screen - drop the whole document instead.
    $RtbChat.Document.Blocks.Clear()
    $script:ChatPara = $null   # Add-ChatRun starts a fresh paragraph
    Add-ChatRun "(history cleared)`n" "#FF8A93A5" -Italic
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
    # Spinner in the header: something is running that the user cannot see,
    # because every child process is hidden and logs into a tab below.
    $busy = [bool]($script:SetupProc -or $script:CleanupProc -or $script:DiagProc -or $script:BridgeProc -or
                   $script:DshProc -or
                   $script:ChatBusy -or ($script:ServerProc -and -not $script:ServerUp))
    if ($busy) {
        # [int] rounds to even, which makes the spinner stutter; floor it.
        $TxtBusy.Text = $script:SpinnerFrames[[int]([math]::Floor($script:TickCount / 2) % 4)]
        $TxtBusy.Visibility = [Windows.Visibility]::Visible
    } elseif ($TxtBusy.Visibility -eq [Windows.Visibility]::Visible) {
        $TxtBusy.Visibility = [Windows.Visibility]::Collapsed
    }
    if ($script:SetupProc -and $script:SetupProc.HasExited) { Complete-Install }
    if ($script:CleanupProc -and $script:CleanupProc.HasExited) { Complete-Cleanup }
    if ($script:BridgeProc -and $script:BridgeProc.HasExited) { Complete-BridgeAction }
    if ($script:DshProc -and $script:DshProc.HasExited) { Complete-DshAction }
    if ($script:BridgeConfirmBy -and (Get-Date) -gt $script:BridgeConfirmBy) {
        $script:BridgeConfirmBy = $null
        if (-not $script:BridgeUp) {
            Set-BridgeStatus "running, not watchable" "#FFE0B84C"
            $BtnCcStop.IsEnabled = $true
            Add-Log $TxtCcLog "The bridge is up, but bound to loopback inside Linux by something other than this app, so this window cannot watch it. Sessions work normally."
            Add-Log $TxtCcLog "To bring it under the app: click Stop bridge, then Start bridge."
            Write-GuiLog "bridge started but not visible from Windows (loopback-bound elsewhere)"
        }
    }
    if ($script:DiagProc -and $script:DiagProc.HasExited) {
        $script:DiagProc = $null
        $BtnDiag.IsEnabled = $true
        if (Test-Path $script:DiagZip) {
            Add-Log $TxtSetupLog "Diagnostics bundle saved to: $script:DiagZip"
            Write-GuiLog "diagnostics done -> $script:DiagZip"
            [Windows.MessageBox]::Show("Diagnostics bundle saved to your Desktop:`n$script:DiagZip`n`nAttach this file when reporting the issue.", "Qwen 5090") | Out-Null
        } else {
            Add-Log $TxtSetupLog "Diagnostics collection FAILED - check $script:LogDir"
            Write-GuiLog "diagnostics FAILED"
        }
    }
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
    # Offset from the server ping so the two never fire on the same tick.
    if ($script:TickCount % 7 -eq 3) { Test-BridgeHealth }
    if ($script:TickCount % 7 -eq 5) { Test-DshHealth }
})
$timer.Start()

# Exceptions thrown inside event handlers land here instead of killing the app.
$Window.Dispatcher.Add_UnhandledException({
    Write-GuiLog ("UNHANDLED: " + ($_.Exception | Out-String))
    try { [Windows.MessageBox]::Show("Unexpected error (details logged to $script:GuiLog):`n$($_.Exception.Message)", "Qwen 5090") | Out-Null } catch { }
    $_.Handled = $true
})

$Window.Add_Loaded({
    # -Model wins; otherwise open on whatever this machine last installed. The
    # dropdown used to reset to Standard on every launch, which meant someone
    # who had installed NInfer got vLLM back the next time they double-clicked
    # the launcher - the one place the choice most needed to stick.
    $preselect = $Model
    if (-not $preselect) {
        try {
            $recorded = (& wsl -d $Distro -- bash -c "cat `$HOME/.qwen5090/default-model 2>/dev/null" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $recorded) { $preselect = ([string]$recorded).Trim() }
        } catch { Write-GuiLog "could not read the recorded default model: $($_.Exception.Message)" }
    }
    if ($preselect) {
        foreach ($item in $CmbModel.Items) {
            if ([string]$item.Tag -eq $preselect) { $CmbModel.SelectedItem = $item; break }
        }
    }
    if ($HfTokenFile -and (Test-Path -LiteralPath $HfTokenFile)) {
        try {
            $TxtHfToken.Text = (Get-Content -LiteralPath $HfTokenFile -Raw).Trim()
            Remove-Item -LiteralPath $HfTokenFile -Force
        } catch { Write-GuiLog "could not read the staged HF token: $($_.Exception.Message)" }
    }
    Update-ModelChoice
    Update-Status
    Update-CcHint
    Update-DshHint
    Add-ChatRun "Local Qwen3.8-27B chat - start the server on the Server tab, then ask anything. Dim italic text is the model thinking.`n" "#FF8A93A5" -Italic
    if ($AutoInstall -and $script:IsAdmin) { Start-Install }
    # Confirmed pre-elevation in Start-Cleanup; the elevated instance just runs it.
    if ($AutoCleanup -and $script:IsAdmin) { Invoke-Cleanup }
})
$Window.Add_Closed({
    $timer.Stop()
    if ($script:ServerProc -and -not $script:ServerProc.HasExited) {
        # leave the server running; users can stop it from a new GUI session
    }
})

$null = $Window.ShowDialog()
