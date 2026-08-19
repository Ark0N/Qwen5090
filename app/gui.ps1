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
    [switch]$AutoCleanup
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
        Title="Qwen 5090 — Local AI Control Panel"
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
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent"
                    Padding="16,8" Margin="0,0,4,0">
              <ContentPresenter x:Name="Content" ContentSource="Header"
                                TextElement.Foreground="#8A93A5" TextElement.FontSize="13"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Content" Property="TextElement.Foreground" Value="#C9D1DE"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#76B900"/>
                <Setter TargetName="Content" Property="TextElement.Foreground" Value="#EDF0F5"/>
                <Setter TargetName="Content" Property="TextElement.FontWeight" Value="SemiBold"/>
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
              <TextBlock Text="Qwen 5090" FontSize="16" FontWeight="SemiBold" Foreground="#EDF0F5"
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
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,12">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
              <Button x:Name="BtnInstall" Content="Install / Repair" Style="{StaticResource AccentButton}"/>
              <CheckBox x:Name="ChkSkipDownload" Content="Skip the 17 GB model download (fetch on first run instead)"/>
            </StackPanel>
            <Button x:Name="BtnCleanup" Content="Cleanup / Uninstall" DockPanel.Dock="Right"
                    Style="{StaticResource DangerButton}" Margin="0"
                    ToolTip="Remove everything this app installed: the Ubuntu distro, the Python environment, and the downloaded model (~20+ GB freed)"/>
          </DockPanel>
          <TextBox x:Name="TxtSetupLog" Grid.Row="1" Style="{StaticResource LogBox}"
                   Text="Ready when you are.&#10;&#10;Click  Install / Repair  to set everything up automatically:&#10;   1. WSL2 + Ubuntu 24.04 (silent, no prompts)&#10;   2. Python 3.13 + vLLM inside Linux&#10;   3. The Qwen3.8-27B model (~17 GB download)&#10;&#10;Every step streams live progress here. Re-running is always safe - finished steps are skipped.&#10;One reboot may be requested; the app re-opens automatically after you log back in.&#10;"/>
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
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="BtnStart" Content="Start server" Style="{StaticResource AccentButton}"/>
            <Button x:Name="BtnStop" Content="Stop" IsEnabled="False" Margin="0,0,16,0"/>
            <TextBlock Text="Port" Style="{StaticResource FieldLabel}"/>
            <TextBox x:Name="TxtPort" Text="8000" Width="64" Height="30" TextAlignment="Center" VerticalAlignment="Center" Margin="0,0,14,0"/>
            <TextBlock Text="Context" Style="{StaticResource FieldLabel}"/>
            <ComboBox x:Name="CmbCtx" Width="110" VerticalAlignment="Center" SelectedIndex="1" Margin="0,0,14,0"
                      ToolTip="Maximum context length in tokens - higher uses more VRAM">
              <ComboBoxItem Content="65536"/>
              <ComboBoxItem Content="131072"/>
              <ComboBoxItem Content="262144"/>
            </ComboBox>
            <CheckBox x:Name="ChkMtp" Content="MTP speed boost" ToolTip="Speculative decoding (multi-token prediction) - faster, leave on" IsChecked="True" Margin="0,0,14,0"/>
            <CheckBox x:Name="ChkShare" Content="Share on network" ToolTip="Other devices on your Wi-Fi or tailnet (LAN/Tailscale) can use the API - asks for admin once per start"/>
          </StackPanel>
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
              <ComboBox x:Name="CmbEffort" Width="96" VerticalAlignment="Center" SelectedIndex="0"
                        ToolTip="How much thinking the model does before answering">
                <ComboBoxItem Content="default"/>
                <ComboBoxItem Content="low"/>
                <ComboBoxItem Content="medium"/>
                <ComboBoxItem Content="high"/>
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

    </TabControl>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in 'TxtGpuS','TxtWslS','TxtModelS','TxtServerS','BtnRefresh','BtnLogs','BtnDiag',
                  'DotGpu','DotWsl','DotModel','DotServer','TxtBusy',
                  'BtnInstall','BtnCleanup','ChkSkipDownload','TxtSetupLog',
                  'BtnStart','BtnStop','TxtPort','CmbCtx','ChkMtp','ChkShare','TxtServerLog',
                  'ChkThink','CmbEffort','BtnClear','RtbChat','TxtInput','BtnSend') {
    Set-Variable -Name $name -Value $Window.FindName($name)
}

# ------------------------------------------------------------------ state
$script:SetupProc = $null
$script:CleanupProc = $null
$script:ServerProc = $null
$script:DiagProc = $null
$script:DiagZip = $null
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
$script:SpinnerFrames = @('|', '/', '-', '\')

$doc = New-Object Windows.Documents.FlowDocument
$doc.PagePadding = New-Object Windows.Thickness(4)
$RtbChat.Document = $doc
$script:ChatPara = $null   # created per message by New-ChatParagraph

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
        $cachePath = "`$HOME/.cache/huggingface/hub/models--$($script:ModelId -replace '/','--')"
        & wsl -d $Distro -- bash -c "test -d $cachePath" 2>$null
        if ($LASTEXITCODE -eq 0) { $TxtModelS.Text = "downloaded"; Set-Dot $DotModel "#FF76B900" }
        else { $TxtModelS.Text = "not downloaded"; Set-Dot $DotModel "#FF4A5261" }
    } else {
        $TxtWslS.Text = "not installed";   Set-Dot $DotWsl "#FF4A5261"
        $TxtModelS.Text = "not downloaded"; Set-Dot $DotModel "#FF4A5261"
    }
}

function Set-ServerStatus([string]$text, [string]$color) {
    $TxtServerS.Text = $text
    $TxtServerS.Foreground = New-Brush $color
    Set-Dot $DotServer $color
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
    $BtnCleanup.IsEnabled = $false
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "install-$ts.out.log"
    $errLog = Join-Path $script:LogDir "install-$ts.err.log"
    Add-Tail $outLog $TxtSetupLog
    Add-Tail $errLog $TxtSetupLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\install.ps1`" -Unattended -Distro $Distro"
    if ($ChkSkipDownload.IsChecked) { $psArgs += " -SkipDownload" }
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
           "  - The downloaded model (~17 GB)`n" +
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
    $ctx = [int]$CmbCtx.SelectedItem.Content
    $BtnStart.IsEnabled = $false
    $BtnStop.IsEnabled = $true
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $outLog = Join-Path $script:LogDir "server-$ts.out.log"
    $errLog = Join-Path $script:LogDir "server-$ts.err.log"
    Add-Tail $outLog $TxtServerLog
    Add-Tail $errLog $TxtServerLog
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RepoRoot\run.ps1`" -Port $port -Ctx $ctx -Distro $Distro"
    if (-not $ChkMtp.IsChecked) { $psArgs += " -NoMtp" }
    if ($ChkShare.IsChecked) {
        $psArgs += " -Share"
        Add-Log $TxtServerLog "Network sharing requested - approve the admin prompt that appears."
    }
    Add-Log $TxtServerLog "Starting server on port $port (context $ctx)... first start takes a minute or two."
    Add-Log $TxtServerLog "Logging to $outLog"
    Write-GuiLog "server starting | args: $psArgs"
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
$BtnCleanup.Add_Click({ Start-Cleanup })
$BtnStart.Add_Click({ Start-Server })
$BtnStop.Add_Click({ Stop-Server })
$BtnSend.Add_Click({ Send-ChatMessage })
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
    $busy = [bool]($script:SetupProc -or $script:CleanupProc -or $script:DiagProc -or
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
})
$timer.Start()

# Exceptions thrown inside event handlers land here instead of killing the app.
$Window.Dispatcher.Add_UnhandledException({
    Write-GuiLog ("UNHANDLED: " + ($_.Exception | Out-String))
    try { [Windows.MessageBox]::Show("Unexpected error (details logged to $script:GuiLog):`n$($_.Exception.Message)", "Qwen 5090") | Out-Null } catch { }
    $_.Handled = $true
})

$Window.Add_Loaded({
    Update-Status
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
