@echo off
rem Double-click launcher for the Qwen 5090 control panel.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gui.ps1"
