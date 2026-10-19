# MPC-BE で保存した MP4 を開き、A キーで音声トラックを切り替えながら画面を保存する
param(
    [string]$VideoFile,
    [string]$ShotDir,
    [int]$Tracks = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Win32 -Name Native2 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null

$mpc = Start-Process -FilePath 'C:\Program Files\MPC-BE\mpc-be64.exe' -ArgumentList ('"{0}" /play' -f $VideoFile) -PassThru
Start-Sleep -Seconds 5
$mpc.Refresh()
$hwnd = $mpc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw 'MPC-BE window not found' }
$window = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
Write-Host ('window: ' + $window.Current.Name)

function Save-Shot {
    param([string]$Name)
    [void][Win32.Native2]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 300
    $r = $window.Current.BoundingRectangle
    $bitmap = New-Object System.Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bitmap.Size)
    $path = Join-Path $ShotDir ($Name + '.png')
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    Write-Host "shot: $path"
}

Save-Shot -Name 'mpc_1_start'
for ($i = 1; $i -le $Tracks; $i++) {
    [void][Win32.Native2]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('a')
    Start-Sleep -Milliseconds 700
    Save-Shot -Name ('mpc_2_track' + $i)
}
Start-Sleep -Milliseconds 500
[void]$mpc.CloseMainWindow()
Start-Sleep -Seconds 2
if (-not $mpc.HasExited) { $mpc.Kill() }
Write-Host 'mpc closed'
