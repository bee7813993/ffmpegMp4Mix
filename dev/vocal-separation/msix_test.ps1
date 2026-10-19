# Store 版（MSIX）として登録したぴたトラックを UI Automation で動かし、ボーカル分離が Store 版の前提どおり動くかを確かめる。
#   A: 実フォルダー %LOCALAPPDATA%\PitaTrack\models に標準モデルがある状態で、一覧・「モデルフォルダーを開く」・ライセンス表示を見る
#   B: 標準モデルを退避した状態で実行し、エンジンのダウンロード確認が出ないこと、モデルの初回ダウンロードがどこに落ちるか
#      （実フォルダーか LocalCache か）、分離が動くこと、「モデルフォルダーを開く」がその場所を開くこと、
#      そこに置いた GGUF（と同名 .json）が一覧に出ることを見る
# 事前に dev\build_msix.ps1 -Register -DevIdentity で登録しておく。
# MSIX パッケージの中で動くシェル（AI アシスタントのツールなど）から実行すると、%LOCALAPPDATA% がそのパッケージの仮想化で
# 合成ビューに見えて実フォルダーを変えられないので、実フォルダーの確認と操作は WMI（CIM_DataFile、Win32_Process.Create で起動した
# パッケージ外の PowerShell）に任せる（Get-OutsideFiles、Invoke-OutsidePackage）。
param(
    [string]$VideoFile,
    [string]$ShotDir,
    [string]$PackageName = 'PitaTrack.Dev',
    [switch]$Karaoke,
    # A だけ（ダウンロードと分離をしない。ライセンス表示と「モデルフォルダーを開く」の確認用）
    [switch]$SkipSeparation,
    # B で標準モデルを退避しない（初回ダウンロードは起こさず、分離だけを確かめる。素材を変えて試すとき）
    [switch]$KeepModels,
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
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, System.Text.StringBuilder lParam);
'@

New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null
$BM_CLICK = 0x00F5
$report = New-Object System.Collections.ArrayList
function Note { param([string]$Text) Write-Host $Text; [void]$report.Add($Text) }

# ---- パッケージの情報 ----
$package = Get-AppxPackage -Name $PackageName
if ($null -eq $package) { throw "package not registered: $PackageName" }
$pfn = $package.PackageFamilyName
$installLocation = $package.InstallLocation
$localCacheModels = Join-Path $env:LOCALAPPDATA ('Packages\' + $pfn + '\LocalCache\Local\PitaTrack\models')
$realModels = Join-Path $env:LOCALAPPDATA 'PitaTrack\models'
$realModelsWmiPath = '\\Users\\' + $env:USERNAME + '\\AppData\\Local\\PitaTrack\\models\\'
$localCacheWmiPath = ($localCacheModels.Substring(2) -replace '\\', '\\') + '\\'
$standardFiles = @('kim_mel_vocals-Q8_0.gguf', 'kim_mel_vocals-Q8_0.LICENSE.txt', 'karaoke_anvuew-Q8_0.gguf', 'karaoke_anvuew-Q8_0.LICENSE.txt')
$backupDir = Join-Path $env:LOCALAPPDATA 'Temp\pitatrack_msix_test_backup'
Note ('package: ' + $package.PackageFullName + ' @ ' + $installLocation)
Note ('ffmpeg in package: ' + ((& (Join-Path $installLocation 'tools\ffmpeg.exe') -version 2>&1 | Select-Object -First 1)))
Note ('engine in package: ' + (Test-Path -LiteralPath (Join-Path $installLocation 'tools\bsroformer\bs_roformer-cli.exe')) + ' (' + ((Get-ChildItem -LiteralPath (Join-Path $installLocation 'tools\bsroformer') -File | ForEach-Object { $_.Name }) -join ', ') + ')')
Note ('license files in package: ' + ((Get-ChildItem -LiteralPath (Join-Path $installLocation 'licenses') -Recurse -File | ForEach-Object { $_.FullName.Substring($installLocation.Length + 1) }) -join ', '))

# パッケージ外（仮想化なし）の PowerShell でスクリプトを動かして終わるまで待つ
function Invoke-OutsidePackage {
    param([string]$Script)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded) }
    if ($r.ReturnValue -ne 0) { throw ('Win32_Process.Create failed: ' + $r.ReturnValue) }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
}
# パッケージ外から見たフォルダーの中身（WMI。実行側のシェルの仮想化に惑わされない）
function Get-OutsideFiles {
    param([string]$WmiPath)
    @(Get-CimInstance CIM_DataFile -Filter ("Drive='C:' AND Path='" + $WmiPath + "'") | ForEach-Object { $_.FileName + '.' + $_.Extension + ' (' + $_.FileSize + ')' })
}
Note ('real models folder (outside): ' + ((Get-OutsideFiles $realModelsWmiPath) -join ', '))
Note ('LocalCache models folder (outside): ' + ((Get-OutsideFiles $localCacheWmiPath) -join ', '))

# ---- UIA の道具 ----
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
# メッセージボックス（#32770）があれば本文を返して「はい」/OK を押す
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
# コンボボックスの項目を列挙する（展開して ComboLBox のリストを読む）
function Get-ComboItems {
    param([System.Windows.Automation.AutomationElement]$Combo)
    $items = @()
    try { $current = $Combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $current = '(no value)' }
    try {
        $pattern = $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $pattern.Expand()
        Start-Sleep -Milliseconds 400
        $list = $Combo.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::List)))
        if ($null -eq $list) { $list = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), 'ComboLBox')) }
        if ($null -ne $list) {
            foreach ($i in $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::ListItem)))) { $items += [string]$i.Current.Name }
        }
        $pattern.Collapse()
        Start-Sleep -Milliseconds 200
    } catch { }
    return [PSCustomObject]@{ Current = $current; Items = $items }
}
# 開いているエクスプローラーのウィンドウ。同じフォルダーが前から開いていても区別できるよう HWND も持つ
function Get-ExplorerWindows {
    $shell = New-Object -ComObject Shell.Application
    $result = @()
    foreach ($w in @($shell.Windows())) { try { $result += [PSCustomObject]@{ Hwnd = [long]$w.HWND; Path = [string]$w.Document.Folder.Self.Path; Window = $w } } catch { } }
    return $result
}
function Dump-Combos {
    param([System.Windows.Automation.AutomationElement]$Dialog, [string]$Prefix)
    $all = @()
    $index = 0
    foreach ($combo in @($Dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::ComboBox))))) {
        $info = Get-ComboItems -Combo $combo
        Note ($Prefix + ' combo ' + $index + ' current: ' + $info.Current + ' / items: ' + ($info.Items -join ' | '))
        $all += $info.Items
        $index++
    }
    return $all
}
# 「モデルフォルダーを開く」を押して、開いたエクスプローラーのフォルダーを返し、そのウィンドウを閉じる
function Test-OpenModelsFolder {
    param([System.Windows.Automation.AutomationElement]$Dialog, [long[]]$Before)
    Click-Control (Find-Control -Root $Dialog -Name 'モデルフォルダーを開く')
    $opened = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and $null -eq $opened) {
        Start-Sleep -Milliseconds 500
        foreach ($w in @(Get-ExplorerWindows)) { if ($Before -notcontains $w.Hwnd) { $opened = $w } }
    }
    if ($null -eq $opened) { return $null }
    $path = $opened.Path
    try { $opened.Window.Quit() } catch { }
    Start-Sleep -Seconds 1
    try { $Dialog.SetFocus() } catch { }
    Start-Sleep -Milliseconds 500
    return $path
}

# ---- 起動（AppExecutionAlias の pitatrack.exe。PitaTrack.Dev の ID で PowerShell が動く） ----
$alias = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $pfn + '\pitatrack.exe')
if (-not (Test-Path -LiteralPath $alias)) { throw "alias not found: $alias" }
function Start-Gui {
    param([string]$Prefix)
    $startedAt = Get-Date
    Start-Process -FilePath $alias -ArgumentList ('"' + $VideoFile + '"')
    $guiPid = 0
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and $guiPid -eq 0) {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
            if ($p.CommandLine -and $p.CommandLine.IndexOf($installLocation, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $p.CommandLine -match 'mixtrack_ffmpeg_gui\.ps1' -and $p.CreationDate -ge $startedAt.AddSeconds(-5)) { $guiPid = $p.ProcessId }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($guiPid -eq 0) { throw 'gui powershell not found' }
    $main = Find-Window -Name 'ぴたトラック' -Timeout 90 -ProcessId $guiPid
    $apps = @(tasklist /apps /fi ("PID eq " + $guiPid) /fo csv | ConvertFrom-Csv | ForEach-Object { $_.'Package Name' })
    Note ($Prefix + ' gui pid ' + $guiPid + ' / package identity: ' + ($apps -join ', '))
    Start-Sleep -Seconds 2
    Save-Shot -Window $main -Name ($Prefix + '_main')
    return [PSCustomObject]@{ Pid = $guiPid; Main = $main }
}
function Open-SeparationDialog {
    param([object]$Gui)
    Click-Control (Find-Control -Root $Gui.Main -Name 'ボーカル分離')
    $dialog = Find-Window -Name 'ボーカル分離' -Timeout 20 -Parent $Gui.Main
    Start-Sleep -Milliseconds 800
    return $dialog
}
function Close-Gui {
    param([object]$Gui)
    Click-Control (Find-Control -Root $Gui.Main -Name '閉じる')
    Start-Sleep -Seconds 2
    Note ('gui exited: ' + ($null -eq (Get-Process -Id $Gui.Pid -ErrorAction SilentlyContinue)))
}

# ======== A: 実フォルダーに標準モデルがある状態 ========
Note '==== A: standard models in the real folder'
$explorerBefore = @(Get-ExplorerWindows | ForEach-Object { $_.Hwnd })
$gui = Start-Gui -Prefix 'A1'
# 設定 → ライセンス（本文は WM_GETTEXT で読む）
Click-Control (Find-Control -Root $gui.Main -Name '設定')
$settingsDialog = Find-Window -Name '設定' -Timeout 15 -Parent $gui.Main
Start-Sleep -Milliseconds 500
Click-Control (Find-Control -Root $settingsDialog -Name 'ライセンス')
$licenseDialog = Find-Window -Name 'ライセンス' -Timeout 15 -Parent $settingsDialog
Start-Sleep -Milliseconds 2500
Save-Shot -Window $licenseDialog -Name 'A2_license'
$licenseText = ''
# 複数行の TextBox は UIA では Document として見える（Edit ではない）
$edit = $licenseDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.OrCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Document)), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Edit)))))
if ($null -ne $edit) {
    # 他プロセスのコントロールの本文は GetWindowText では取れないので WM_GETTEXTLENGTH / WM_GETTEXT で読む
    $editHwnd = [IntPtr]$edit.Current.NativeWindowHandle
    $length = [int][Win32.Native]::SendMessage($editHwnd, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
    $sb = New-Object System.Text.StringBuilder ($length + 1)
    [void][Win32.Native]::SendMessage($editHwnd, 0x000D, [IntPtr]($length + 1), $sb)
    $licenseText = $sb.ToString()
}
Note ('license text length ' + $licenseText.Length + '; BSRoformer section: ' + ($licenseText -match 'BSRoformer\.cpp と ggml') + '; models section: ' + ($licenseText -match 'ボーカル分離のモデル') + '; v0.1.0: ' + ($licenseText -match 'v0\.1\.0') + '; models release url: ' + ($licenseText -match 'releases/tag/separation-models-') + '; no placeholder left: ' + ($licenseText -notmatch '__[A-Z_]+__'))
Click-Control (Find-Control -Root $licenseDialog -Name '閉じる')
Start-Sleep -Milliseconds 500
Click-Control (Find-Control -Root $settingsDialog -Name 'キャンセル')
Start-Sleep -Milliseconds 500
# 元動画の音声をトラックにして「ボーカル分離」
Click-Control (Find-Control -Root $gui.Main -Name '元動画の音声を1トラック目に使用')
Start-Sleep -Seconds 1
$dialog = Open-SeparationDialog -Gui $gui
[void](Dump-Combos -Dialog $dialog -Prefix 'A3')
Save-Shot -Window $dialog -Name 'A3_dialog'
$openedA = Test-OpenModelsFolder -Dialog $dialog -Before $explorerBefore
Note ('A3 explorer opened: ' + $openedA + ' (real=' + [string]::Equals($openedA, $realModels, [StringComparison]::OrdinalIgnoreCase) + ', LocalCache=' + [string]::Equals($openedA, $localCacheModels, [StringComparison]::OrdinalIgnoreCase) + ')')
Click-Control (Find-Control -Root $dialog -Name 'キャンセル')
Start-Sleep -Milliseconds 800
Close-Gui -Gui $gui
if ($SkipSeparation) {
    $report | Set-Content -LiteralPath (Join-Path $ShotDir 'report.txt') -Encoding UTF8
    Write-Host 'done (A only)'
    return
}

# ======== B: 標準モデルを退避して初回ダウンロードを起こす ========
Note '==== B: standard models moved away (first download)'
$moveScript = '$src = Join-Path $env:LOCALAPPDATA ''PitaTrack\models''; $dst = ''' + $backupDir + '''; New-Item -ItemType Directory -Path $dst -Force | Out-Null; foreach ($n in @(''' + ($standardFiles -join ''',''') + ''')) { $p = Join-Path $src $n; if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination (Join-Path $dst $n) -Force } }'
$restoreScript = '$src = ''' + $backupDir + '''; $dst = Join-Path $env:LOCALAPPDATA ''PitaTrack\models''; New-Item -ItemType Directory -Path $dst -Force | Out-Null; foreach ($n in @(''' + ($standardFiles -join ''',''') + ''')) { $p = Join-Path $src $n; if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination (Join-Path $dst $n) -Force } }'
if ($KeepModels) {
    Note 'KeepModels: standard models stay in place (no first download)'
}
else {
    Invoke-OutsidePackage -Script $moveScript
    Note ('real models folder after move-away (outside): ' + ((Get-OutsideFiles $realModelsWmiPath) -join ', '))
}
$writeDir = $null
try {
    $gui = Start-Gui -Prefix 'B1'
    Click-Control (Find-Control -Root $gui.Main -Name '元動画の音声を1トラック目に使用')
    Start-Sleep -Seconds 1
    $dialog = Open-SeparationDialog -Gui $gui
    [void](Dump-Combos -Dialog $dialog -Prefix 'B2')
    if ($Karaoke) {
        Click-Control (Find-Control -Root $dialog -Name 'コーラスを残してボーカルカット（リードボーカルだけ除く）')
        Start-Sleep -Milliseconds 300
    }
    Save-Shot -Window $dialog -Name 'B2_dialog'
    # 実行
    Click-Control (Find-Control -Root $dialog -Name '実行')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $adoptButton = $null
    $lastStatus = ''
    $prompts = @()
    $modulesSeen = $false
    $shotTaken = $false
    $errorSeen = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $answer = Answer-MessageBox -Owner $dialog -OwnerProcessId $gui.Pid -ShotName ('B3_prompt_' + $prompts.Count)
        if ($null -ne $answer) {
            $prompts += $answer
            Note ('prompt: ' + $answer.Replace("`r`n", ' / '))
            if ($answer -match 'エラー終了|できませんでした|入っていません') { $errorSeen = $true; break }
            continue
        }
        try { $adoptButton = Find-Control -Root $dialog -Name '採用したトラックを追加' -Timeout 1 } catch { $adoptButton = $null }
        if ($null -ne $adoptButton) { break }
        foreach ($t in (Get-StatusTexts -Root $dialog)) {
            if ($t -match '分離しています|変換|書き出し|ダウンロード') {
                if ($t -ne $lastStatus) { Write-Host ('  status: ' + $t); $lastStatus = $t }
                if (-not $shotTaken -and $t -match '\d+%' -and $t -match '分離') { Save-Shot -Window $dialog -Name 'B4_progress'; $shotTaken = $true }
            }
        }
        if (-not $modulesSeen) {
            $cli = @(Get-Process -Name 'bs_roformer-cli' -ErrorAction SilentlyContinue)
            if ($cli.Count -gt 0) {
                try {
                    $mods = @($cli[0].Modules | Where-Object { $_.ModuleName -match '^(vcruntime140|msvcp140|vcomp140|ggml|vulkan-1)' } | ForEach-Object { $_.ModuleName + ' <- ' + $_.FileName })
                    if ($mods.Count -gt 0) {
                        $modulesSeen = $true
                        $apps = @(tasklist /apps /fi ("PID eq " + $cli[0].Id) /fo csv | ConvertFrom-Csv | ForEach-Object { $_.'Package Name' })
                        Note ('bs_roformer-cli.exe: ' + $cli[0].Path + ' / package identity: ' + ($apps -join ', '))
                        foreach ($m in $mods) { Note ('  module: ' + $m) }
                    }
                } catch { }
            }
        }
    }
    Note ('results shown: ' + ($null -ne $adoptButton) + ' after ' + [int]$sw.Elapsed.TotalSeconds + ' s; prompts: ' + $prompts.Count + '; engine download prompt seen: ' + (($prompts -join ' ') -match 'BSRoformer\.cpp（') + '; error seen: ' + $errorSeen)
    foreach ($candidate in @(@{ Name = 'real'; Path = $realModels; Wmi = $realModelsWmiPath }, @{ Name = 'LocalCache'; Path = $localCacheModels; Wmi = $localCacheWmiPath })) {
        $files = @(Get-OutsideFiles $candidate.Wmi)
        Note ($candidate.Name + ' models folder after download (outside): ' + ($files -join ', '))
        if (($files -join ' ') -match 'kim_mel_vocals-Q8_0\.gguf') { $writeDir = $candidate.Path }
    }
    if ($KeepModels) {
        Note ('models used from: ' + $writeDir + ' (no download expected; prompts: ' + $prompts.Count + ')')
    }
    else {
        Note ('downloads landed in: ' + $writeDir + '; model prompt showed that folder: ' + ($null -ne $writeDir -and ($prompts -join ' ').IndexOf($writeDir, [StringComparison]::OrdinalIgnoreCase) -ge 0))
    }
    if ($null -eq $adoptButton) {
        Save-Shot -Window $dialog -Name 'B4_timeout'
        throw ('results did not appear; status: ' + ((Get-StatusTexts -Root $dialog) -join ' | '))
    }
    Start-Sleep -Milliseconds 500
    Save-Shot -Window $dialog -Name 'B5_results'
    foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match 'できました') { Note ('result status: ' + $t) } }
    $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Table)))
    if ($null -eq $gridElement) { $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::DataGrid))) }
    if ($null -ne $gridElement) {
        $names = @()
        foreach ($c in $gridElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ([string]$c.Current.Name -match '^トラック名 (Row|行) \d+$') { try { $names += [string]$c.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { } }
        }
        Note ('result track names: ' + ($names -join ' | '))
    }
    $tempDirs = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'PitaTrack_sep_results_*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) })
    foreach ($d in $tempDirs) { Note ('results temp dir: ' + $d.FullName + ' / files: ' + ((Get-ChildItem -LiteralPath $d.FullName -File | ForEach-Object { '{0} ({1:N0})' -f $_.Name, $_.Length }) -join ', ')) }
    try {
        Click-Control (Find-Control -Root $dialog -Name '▶ 再生')
        Start-Sleep -Seconds 3
        foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '^\d+:\d\d / \d+:\d\d$') { Note ('playback: ' + $t) } }
        Click-Control (Find-Control -Root $dialog -Name '■ 停止')
        Start-Sleep -Milliseconds 500
    } catch { Note ('preview skipped: ' + $_.Exception.Message) }
    # 採用せずに閉じる（ユーザーのフォルダーに書かない）
    Click-Control (Find-Control -Root $dialog -Name '閉じる')
    Start-Sleep -Seconds 2
    foreach ($candidate in @(@{ Name = 'real'; Wmi = $realModelsWmiPath }, @{ Name = 'LocalCache'; Wmi = $localCacheWmiPath })) {
        Note ($candidate.Name + ' models folder after separation (outside): ' + ((Get-OutsideFiles $candidate.Wmi) -join ', '))
    }
    if ($null -ne $writeDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $writeDir -Filter '*.gguf' -ErrorAction SilentlyContinue)) { Note ('  sha256 ' + $f.Name + ' = ' + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()) }
    }

    # ダウンロードが落ちた場所に GGUF（と .json）を置いて一覧に出るか、「モデルフォルダーを開く」がその場所を開くか
    if ($null -ne $writeDir) {
        $customName = 'pitatrack_msix_test_custom'
        $customScript = '$d = ''' + $writeDir + '''; [System.IO.File]::WriteAllBytes((Join-Path $d ''' + $customName + '.gguf''), [byte[]](0x47, 0x47, 0x55, 0x46)); [System.IO.File]::WriteAllText((Join-Path $d ''' + $customName + '.json''), ''{"label": "MSIX test custom", "short": "msixtest", "role": "lead"}'', (New-Object System.Text.UTF8Encoding $false))'
        $customCleanup = '$d = ''' + $writeDir + '''; Remove-Item -LiteralPath (Join-Path $d ''' + $customName + '.gguf'') -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath (Join-Path $d ''' + $customName + '.json'') -Force -ErrorAction SilentlyContinue'
        Invoke-OutsidePackage -Script $customScript
        try {
            Note ('custom files placed (outside): ' + ((Get-OutsideFiles ($(if ($writeDir -eq $realModels) { $realModelsWmiPath } else { $localCacheWmiPath }))) -join ', '))
            $dialog2 = Open-SeparationDialog -Gui $gui
            $all = Dump-Combos -Dialog $dialog2 -Prefix 'B6'
            Note ('custom model listed: ' + (($all -join ' ') -match 'MSIX test custom'))
            Save-Shot -Window $dialog2 -Name 'B6_dialog_custom_model'
            $openedB = Test-OpenModelsFolder -Dialog $dialog2 -Before $explorerBefore
            Note ('B6 explorer opened: ' + $openedB + ' / same as the download folder: ' + [string]::Equals($openedB, $writeDir, [StringComparison]::OrdinalIgnoreCase))
            Click-Control (Find-Control -Root $dialog2 -Name 'キャンセル')
            Start-Sleep -Milliseconds 800
        } finally {
            Invoke-OutsidePackage -Script $customCleanup
        }
    }
    Close-Gui -Gui $gui
}
finally {
    if (-not $KeepModels) {
        Invoke-OutsidePackage -Script $restoreScript
        Note ('real models folder after restore (outside): ' + ((Get-OutsideFiles $realModelsWmiPath) -join ', '))
    }
    $report | Set-Content -LiteralPath (Join-Path $ShotDir 'report.txt') -Encoding UTF8
}
Write-Host 'done'
