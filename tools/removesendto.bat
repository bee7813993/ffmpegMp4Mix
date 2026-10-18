@echo off
rem Remove the PitaTrack (and old ffmpegMp4Mix) shortcuts from the Send To menu.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -RemoveSendTo
echo.
pause
