@echo off
setlocal
set "psScript=%~dp0mixtrack_ffmpeg_gui.ps1"
if not exist "%psScript%" set "psScript=%~dp0tools\mixtrack_ffmpeg_gui.ps1"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%psScript%" %*
