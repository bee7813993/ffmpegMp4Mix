echo %USERPROFILE%\AppData\Roaming\Microsoft\Windows\SendTo\shortcut

echo set WshShell = WScript.CreateObject("WScript.Shell") >shortcut.vbs
echo set oShellLink = WshShell.CreateShortcut(("%USERPROFILE%\AppData\Roaming\Microsoft\Windows\SendTo\mixtrack_ffmpeg" ^& ".lnk")) >>shortcut.vbs
echo oShellLink.TargetPath = "%~dp0mixtrack_ffmpeg.bat" >>shortcut.vbs
echo oShellLink.WindowStyle = 1 >>shortcut.vbs
echo oShellLink.Save >>shortcut.vbs
shortcut.vbs
