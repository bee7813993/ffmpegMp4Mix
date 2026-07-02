Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(fso.BuildPath(scriptDir, "tools"), "mixtrack_ffmpeg_gui.ps1")
If Not fso.FileExists(psScript) Then
    psScript = fso.BuildPath(scriptDir, "mixtrack_ffmpeg_gui.ps1")
End If

command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(psScript)

For Each argument In WScript.Arguments
    command = command & " " & Quote(argument)
Next

shell.Run command, 1, False

Function Quote(value)
    Quote = """" & value & """"
End Function
