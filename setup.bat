@echo off
rem ぴたトラック のセットアップ（インストール・更新）を開きます。
if not exist "%~dp0tools\setup.ps1" goto missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup.ps1" -Detach
exit /b 0

:missing
echo セットアップに必要なファイルが見つかりません。
echo.
echo ZIPファイルの中から直接開いている場合は、ZIPファイルを右クリックして「すべて展開」を選び、
echo 展開したフォルダーの setup を開いてください。
echo.
pause
exit /b 1
