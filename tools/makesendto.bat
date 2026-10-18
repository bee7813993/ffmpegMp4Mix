@echo off
rem Register PitaTrack in the Send To menu, pointing at this folder (for use without installing).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -SendToOnly
echo.
pause
