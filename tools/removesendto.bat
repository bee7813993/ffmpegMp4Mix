@echo off
setlocal

set "SENDTO_DIR=%APPDATA%\Microsoft\Windows\SendTo"
set "REMOVED=0"

call :RemoveShortcut "mixtrack_ffmpeg.lnk"
call :RemoveShortcut "mixtrack_ffmpeg_gui.lnk"

if "%REMOVED%"=="0" (
    echo No ffmpegMp4Mix Send To shortcuts were found.
) else (
    echo Removed ffmpegMp4Mix Send To shortcuts.
)

echo.
pause
exit /b 0

:RemoveShortcut
set "SHORTCUT=%SENDTO_DIR%\%~1"
if exist "%SHORTCUT%" (
    del "%SHORTCUT%"
    echo Deleted: %SHORTCUT%
    set "REMOVED=1"
) else (
    echo Not found: %SHORTCUT%
)
exit /b 0
