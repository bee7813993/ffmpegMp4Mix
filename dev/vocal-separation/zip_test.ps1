# ZIP 版の流れを確かめる: tools\ffmpeg.exe も tools\bsroformer もない状態で GUI を開き、ボーカル分離の「実行」で
# setup.ps1 -FfmpegOnly のダウンロード画面（Release の zip、SHA256 照合）→ 分離エンジンのダウンロード確認 → 分離 まで通す。
param(
    [string]$GuiScript,
    [string]$VideoFile,
    [string]$ShotDir,
    [int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
'@
New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null
$BM_CLICK = 0x00F5
$report = New-Object System.Collections.ArrayList
function Note { param([string]$Text) Write-Host $Text; [void]$report.Add($Text) }
$toolsDir = Split-Path -Parent $GuiScript
Note ('tools\ffmpeg.exe before: ' + (Test-Path -LiteralPath (Join-Path $toolsDir 'ffmpeg.exe')) + ' / tools\bsroformer before: ' + (Test-Path -LiteralPath (Join-Path $toolsDir 'bsroformer')))

function Find-Window {
    param([string]$Name, [int]$Timeout = 60, [System.Windows.Automation.AutomationElement]$Parent = $null, [int]$ProcessId = 0)
    $deadline = (Get-Date).AddSeconds($Timeout)
    $conditions = @(
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $Name),
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Window)))
    if ($ProcessId -gt 0) { $conditions += New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $ProcessId }
    $condition = New-Object System.Windows.Automation.AndCondition $conditions
    $rootCondition = $null
    if ($null -ne $Parent) {
        $rootCondition = New-Object System.Windows.Automation.AndCondition @($condition, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $Parent.Current.ProcessId))
    } else {
        $Parent = [System.Windows.Automation.AutomationElement]::RootElement
    }
    while ((Get-Date) -lt $deadline) {
        $window = $Parent.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
        if ($null -eq $window -and $null -ne $rootCondition) { $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $rootCondition) }
        if ($null -ne $window) { return $window }
        Start-Sleep -Milliseconds 300
    }
    throw "window not found: $Name"
}
function Find-Control {
    param([System.Windows.Automation.AutomationElement]$Root, [string]$Name, [int]$Timeout = 10)
    $deadline = (Get-Date).AddSeconds($Timeout)
    $condition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $Name
    while ((Get-Date) -lt $deadline) {
        $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -ne $element) { return $element }
        Start-Sleep -Milliseconds 300
    }
    throw "control not found: $Name"
}
function Click-Control {
    param([System.Windows.Automation.AutomationElement]$Element)
    $hwnd = [IntPtr]$Element.Current.NativeWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { throw "no hwnd for $($Element.Current.Name)" }
    [void][Win32.Native]::PostMessage($hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
}
function Get-StatusTexts {
    param([System.Windows.Automation.AutomationElement]$Root)
    $result = @()
    foreach ($label in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($label.Current.ClassName -match 'STATIC') { $result += [string]$label.Current.Name }
    }
    return $result
}
function Save-Shot {
    param([System.Windows.Automation.AutomationElement]$Window, [string]$Name)
    Start-Sleep -Milliseconds 400
    $hwnd = [IntPtr]$Window.Current.NativeWindowHandle
    $r = $Window.Current.BoundingRectangle
    $rc = New-Object 'Win32.Native+RECT'
    if ([Win32.Native]::GetWindowRect($hwnd, [ref]$rc) -and ($rc.Right - $rc.Left) -gt 0) { $w = $rc.Right - $rc.Left; $h = $rc.Bottom - $rc.Top } else { $w = [int]$r.Width; $h = [int]$r.Height }
    $bitmap = New-Object System.Drawing.Bitmap $w, $h
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    $printed = [Win32.Native]::PrintWindow($hwnd, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    if (-not $printed) { $graphics.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bitmap.Size) }
    $path = Join-Path $ShotDir ($Name + '.png')
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    Write-Host "shot: $path"
}
function Answer-MessageBox {
    param([System.Windows.Automation.AutomationElement]$Owner, [int]$OwnerProcessId, [string]$ShotName)
    $boxCondition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), '#32770'
    $box = $Owner.FindFirst([System.Windows.Automation.TreeScope]::Children, $boxCondition)
    if ($null -eq $box) { $box = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $OwnerProcessId), $boxCondition))) }
    if ($null -eq $box) { return $null }
    if ($ShotName) { Save-Shot -Window $box -Name $ShotName }
    $texts = @()
    foreach ($t in $box.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ($t.Current.Name -and $t.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { $texts += [string]$t.Current.Name } }
    $yes = $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'はい(Y)'))
    if ($null -eq $yes) { $yes = $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'OK')) }
    if ($null -ne $yes) { $yes.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    return ($texts -join ' / ')
}

# setup.ps1 -FfmpegOnly の画面（別プロセス）が出ていれば「ダウンロード」を押して、出ているあいだ $true を返す
$setupCondition = New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'ぴたトラック - ffmpeg のダウンロード'), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Window)))
$Script:SetupSeen = $false
$Script:SetupClicked = $false
$Script:SetupError = $false
$Script:LastSetupStatus = ''
function Handle-SetupWindow {
    $setupWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $setupCondition)
    if ($null -eq $setupWindow) { return $false }
    if (-not $Script:SetupSeen) { $Script:SetupSeen = $true; Save-Shot -Window $setupWindow -Name 'Z2_ffmpeg_download'; Note ('setup window: ' + ((Get-StatusTexts -Root $setupWindow) -join ' | ')) }
    if (-not $Script:SetupClicked) {
        try { Click-Control (Find-Control -Root $setupWindow -Name 'ダウンロード' -Timeout 3); $Script:SetupClicked = $true; Note 'setup: clicked ダウンロード' } catch { }
    }
    foreach ($t in (Get-StatusTexts -Root $setupWindow)) {
        if ($t -match 'ダウンロード(して|でき|を中止)|確認して') {
            if ($t -ne $Script:LastSetupStatus) { Write-Host ('  setup status: ' + $t); $Script:LastSetupStatus = $t }
            if ($t -match 'できませんでした') { $Script:SetupError = $true }
        }
    }
    return $true
}

# ---- 起動（ZIP 版と同じく PowerShell で直接）。ffmpeg がないと、メインウィンドウより先にダウンロード画面が出る ----
$arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $GuiScript, $VideoFile
$gui = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
$main = $null
$deadline = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $deadline -and $null -eq $main) {
    Start-Sleep -Milliseconds 500
    if (Handle-SetupWindow) { if ($Script:SetupError) { throw 'ffmpeg のダウンロードに失敗しました' }; continue }
    try { $main = Find-Window -Name 'ぴたトラック' -Timeout 1 -ProcessId $gui.Id } catch { $main = $null }
}
if ($null -eq $main) { throw 'main window not found' }
Note ('gui pid ' + $gui.Id + ' / setup window seen before main: ' + $Script:SetupSeen)
Start-Sleep -Seconds 2
Click-Control (Find-Control -Root $main -Name '元動画の音声を1トラック目に使用')
Start-Sleep -Seconds 1
Click-Control (Find-Control -Root $main -Name 'ボーカル分離')
$dialog = Find-Window -Name 'ボーカル分離' -Timeout 20 -Parent $main
Start-Sleep -Milliseconds 800
Save-Shot -Window $dialog -Name 'Z1_dialog'
Click-Control (Find-Control -Root $dialog -Name '実行')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$adoptButton = $null
$lastStatus = ''
$prompts = @()
$errorSeen = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if (Handle-SetupWindow) { if ($Script:SetupError) { $errorSeen = $true; break }; continue }
    $answer = Answer-MessageBox -Owner $dialog -OwnerProcessId $gui.Id -ShotName ('Z3_prompt_' + $prompts.Count)
    if ($null -ne $answer) {
        $prompts += $answer
        Note ('prompt: ' + $answer.Replace("`r`n", ' / '))
        if ($answer -match 'エラー終了|できませんでした|入っていません|見つかりません') { $errorSeen = $true; break }
        continue
    }
    try { $adoptButton = Find-Control -Root $dialog -Name '採用したトラックを追加' -Timeout 1 } catch { $adoptButton = $null }
    if ($null -ne $adoptButton) { break }
    foreach ($t in (Get-StatusTexts -Root $dialog)) {
        if ($t -match '分離しています|変換|書き出し|ダウンロード') { if ($t -ne $lastStatus) { Write-Host ('  status: ' + $t); $lastStatus = $t } }
    }
}
$ffmpegExe = Join-Path $toolsDir 'ffmpeg.exe'
Note ('tools\ffmpeg.exe after: ' + (Test-Path -LiteralPath $ffmpegExe) + ($(if (Test-Path -LiteralPath $ffmpegExe) { ' / ' + ((& $ffmpegExe -version 2>&1 | Select-Object -First 1)) } else { '' })))
Note ('tools\ffmpeg-licenses: ' + ((Get-ChildItem -LiteralPath (Join-Path $toolsDir 'ffmpeg-licenses') -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '))
Note ('tools\bsroformer after: ' + ((Get-ChildItem -LiteralPath (Join-Path $toolsDir 'bsroformer') -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '))
Note ('results shown: ' + ($null -ne $adoptButton) + ' after ' + [int]$sw.Elapsed.TotalSeconds + ' s; setup window seen: ' + $Script:SetupSeen + '; prompts: ' + $prompts.Count + '; engine prompt seen: ' + (($prompts -join ' ') -match 'BSRoformer\.cpp（') + '; error seen: ' + $errorSeen)
if ($null -ne $adoptButton) {
    Save-Shot -Window $dialog -Name 'Z4_results'
    foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match 'できました') { Note ('result status: ' + $t) } }
    Click-Control (Find-Control -Root $dialog -Name '閉じる')
    Start-Sleep -Seconds 2
}
else {
    Save-Shot -Window $dialog -Name 'Z4_timeout'
    try { Click-Control (Find-Control -Root $dialog -Name 'キャンセル' -Timeout 3) } catch { }
    Start-Sleep -Seconds 1
}
Click-Control (Find-Control -Root $main -Name '閉じる')
Start-Sleep -Seconds 2
Note ('gui exited: ' + $gui.HasExited)
$report | Set-Content -LiteralPath (Join-Path $ShotDir 'report.txt') -Encoding UTF8
Write-Host 'done'
