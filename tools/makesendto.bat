@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%"
if not exist "%ROOT_DIR%mixtrack_ffmpeg.bat" (
    for %%I in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fI\"
)

set "SENDTO_DIR=%USERPROFILE%\AppData\Roaming\Microsoft\Windows\SendTo"
set "SHORTCUT_VBS=%TEMP%\ffmpegMp4Mix_shortcut.vbs"

echo %SENDTO_DIR%\shortcut

echo set WshShell = WScript.CreateObject("WScript.Shell") >"%SHORTCUT_VBS%"
echo set oShellLink = WshShell.CreateShortcut(("%SENDTO_DIR%\mixtrack_ffmpeg" ^& ".lnk")) >>"%SHORTCUT_VBS%"
echo oShellLink.TargetPath = "%ROOT_DIR%mixtrack_ffmpeg.bat" >>"%SHORTCUT_VBS%"
echo oShellLink.WindowStyle = 1 >>"%SHORTCUT_VBS%"
echo oShellLink.Save >>"%SHORTCUT_VBS%"
echo set oShellLink = WshShell.CreateShortcut(("%SENDTO_DIR%\mixtrack_ffmpeg_gui" ^& ".lnk")) >>"%SHORTCUT_VBS%"
echo oShellLink.TargetPath = "%ROOT_DIR%mixtrack_ffmpeg_gui.vbs" >>"%SHORTCUT_VBS%"
echo oShellLink.WindowStyle = 1 >>"%SHORTCUT_VBS%"
echo oShellLink.Save >>"%SHORTCUT_VBS%"
cscript //nologo "%SHORTCUT_VBS%"
del "%SHORTCUT_VBS%"
