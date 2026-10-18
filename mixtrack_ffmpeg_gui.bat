@echo off
rem ぴたトラック（GUI版）を開きます。動画と音声ファイルをこのファイルにドロップしても開けます。
if not exist "%~dp0tools\mixtrack_ffmpeg_gui.ps1" goto missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\mixtrack_ffmpeg_gui.ps1" -Detach %*
exit /b 0

:missing
echo ぴたトラックに必要なファイルが見つかりません。
echo.
echo ZIPファイルの中から直接開いている場合は、ZIPファイルを右クリックして「すべて展開」を選び、
echo 展開したフォルダーから開いてください。
echo.
pause
exit /b 1
