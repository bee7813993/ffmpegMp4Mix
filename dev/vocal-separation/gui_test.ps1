# UI Automation で GUI を操作して「分離して追加」→「保存」まで通す。
param(
    [string]$VideoFile,
    [string]$ShotDir,
    [switch]$Karaoke,
    [switch]$AllCandidates,
    [switch]$NoTwoStage,
    [switch]$CloseInsteadOfAdopt,
    [switch]$Reduce,
    [switch]$SettingsShot,
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@

$guiScript = 'J:\Git\ffmpegMp4Mix\.claude\worktrees\vocal-separation-feasibility-fce4b3\tools\mixtrack_ffmpeg_gui.ps1'
New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null
$BM_CLICK = 0x00F5

# 所有されたウィンドウ（モーダルダイアログ）は UIA ではオーナーの子として見える
function Find-Window {
    param([string]$Name, [int]$Timeout = 60, [System.Windows.Automation.AutomationElement]$Parent = $null, [int]$ProcessId = 0)
    $deadline = (Get-Date).AddSeconds($Timeout)
    $conditions = @(
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $Name),
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Window)))
    # 同名の別インスタンス（別の PitaTrack）を掴まないようにプロセスで絞る
    if ($ProcessId -gt 0) { $conditions += New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $ProcessId }
    $condition = New-Object System.Windows.Automation.AndCondition $conditions
    # 所有ウィンドウはオーナーの子に見えることが多いが、オーナーが前面でないと最上位に出ることもあるので、
    # 同じプロセスの最上位ウィンドウも探す
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

function Get-StatusTexts {
    param([System.Windows.Automation.AutomationElement]$Root)
    $labels = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $result = @()
    foreach ($label in $labels) {
        if ($label.Current.ClassName -match 'STATIC') { $result += [string]$label.Current.Name }
    }
    return $result
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

function Save-Shot {
    param([System.Windows.Automation.AutomationElement]$Window, [string]$Name)
    Start-Sleep -Milliseconds 400
    $hwnd = [IntPtr]$Window.Current.NativeWindowHandle
    $r = $Window.Current.BoundingRectangle
    $rc = New-Object 'Win32.Native+RECT'
    if ([Win32.Native]::GetWindowRect($hwnd, [ref]$rc) -and ($rc.Right - $rc.Left) -gt 0) { $w = $rc.Right - $rc.Left; $h = $rc.Bottom - $rc.Top } else { $w = [int]$r.Width; $h = [int]$r.Height }
    $bitmap = New-Object System.Drawing.Bitmap $w, $h
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    # 他のウィンドウ（ユーザーが使っている Slack など）が手前にあっても撮れるよう、画面コピーではなく
    # PrintWindow(PW_RENDERFULLCONTENT) でウィンドウ自身の内容を描かせる
    $hdc = $graphics.GetHdc()
    $printed = [Win32.Native]::PrintWindow($hwnd, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    if (-not $printed) { $graphics.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bitmap.Size) }
    $path = Join-Path $ShotDir ($Name + '.png')
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    Write-Host "shot: $path"
}

function Get-Text {
    param([System.Windows.Automation.AutomationElement]$Element)
    return [string]$Element.Current.Name
}

function Wait-Gone {
    param([string]$Name, [int]$Timeout, [System.Windows.Automation.AutomationElement]$Parent, [string]$ShotPrefix)
    $deadline = (Get-Date).AddSeconds($Timeout)
    $condition = New-Object System.Windows.Automation.AndCondition @(
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $Name),
        (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Window)))
    $rootCondition = New-Object System.Windows.Automation.AndCondition @($condition, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $Parent.Current.ProcessId))
    $lastStatus = ''
    $shotTaken = $false
    while ((Get-Date) -lt $deadline) {
        $window = $Parent.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
        if ($null -eq $window) { $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $rootCondition) }
        if ($null -eq $window) { return $true }
        try {
            foreach ($t in (Get-StatusTexts -Root $window)) {
                if ($t -match '分離しています|変換|書き出し|ダウンロード|完了|中止') {
                    if ($t -ne $lastStatus) { Write-Host ('  status: ' + $t); $lastStatus = $t }
                    if (-not $shotTaken -and $t -match '\d+%') { Save-Shot -Window $window -Name ($ShotPrefix + '_progress'); $shotTaken = $true }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ---- 起動 ----
$arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" "{1}"' -f $guiScript, $VideoFile
$gui = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
Write-Host "gui pid $($gui.Id)"
$main = Find-Window -Name 'ぴたトラック' -Timeout 90 -ProcessId $gui.Id
Start-Sleep -Seconds 2
Save-Shot -Window $main -Name '1_main'

if ($SettingsShot) {
    # 設定ダイアログの見た目だけ撮って閉じる
    $settingsButton = Find-Control -Root $main -Name '設定'
    Click-Control $settingsButton
    $settingsDialog = Find-Window -Name '設定' -Timeout 15 -Parent $main
    Start-Sleep -Milliseconds 800
    Save-Shot -Window $settingsDialog -Name '0_settings'
    $settingsCancel = Find-Control -Root $settingsDialog -Name 'キャンセル'
    Click-Control $settingsCancel
    Start-Sleep -Milliseconds 500
}

# ---- 元動画の音声をトラックにしてから、その行を元に「ボーカル分離」 ----
$videoAudioCheck = Find-Control -Root $main -Name '元動画の音声を1トラック目に使用'
Click-Control $videoAudioCheck
Start-Sleep -Seconds 1
Save-Shot -Window $main -Name '1b_main_with_video_audio'
$separateButton = Find-Control -Root $main -Name 'ボーカル分離'
Click-Control $separateButton
$dialog = Find-Window -Name 'ボーカル分離' -Timeout 20 -Parent $main
Start-Sleep -Milliseconds 500
if ($Karaoke) {
    $karaokeCheck = Find-Control -Root $dialog -Name 'コーラスを残してボーカルカット（リードボーカルだけ除く）'
    Click-Control $karaokeCheck
    Start-Sleep -Milliseconds 300
}
if ($AllCandidates) {
    $allCheck = Find-Control -Root $dialog -Name '全モデルで候補を作る'
    Click-Control $allCheck
    Start-Sleep -Milliseconds 300
}
if ($NoTwoStage) {
    $twoStageCheck = Find-Control -Root $dialog -Name 'ボーカルだけを取り出してからリードを除く（2 段方式・おすすめ）'
    Click-Control $twoStageCheck
    Start-Sleep -Milliseconds 300
}
if ($Reduce) {
    $reduceCheck = Find-Control -Root $dialog -Name 'ボーカルリデュース'
    Click-Control $reduceCheck
    Start-Sleep -Milliseconds 300
}
foreach ($combo in $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::ComboBox)))) {
    try { Write-Host ('  combo: ' + $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) } catch { Write-Host '  combo: (no value pattern)' }
}
Save-Shot -Window $dialog -Name '2_dialog'
$runButton = Find-Control -Root $dialog -Name '実行'
Click-Control $runButton
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# 結果の面（「採用したトラックを追加」ボタン）が出るまで待つ
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$adoptButton = $null
$lastStatus = ''
$shotTaken = $false
$promptSeen = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    # 初回のダウンロード確認（メッセージボックス）が出たら内容を記録して「はい」を押す
    $box = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), '#32770'))
    if ($null -ne $box) {
        if (-not $promptSeen) { Save-Shot -Window $box -Name '2b_download_prompt'; $promptSeen = $true }
        foreach ($t in $box.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ($t.Current.Name -and $t.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { Write-Host ('  prompt: ' + $t.Current.Name.Replace("`r`n", ' / ')) } }
        $yes = $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'はい(Y)'))
        if ($null -eq $yes) { $yes = $box.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'OK')) }
        if ($null -ne $yes) { $yes.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-Host '  prompt answered' }
        continue
    }
    try { $adoptButton = Find-Control -Root $dialog -Name '採用したトラックを追加' -Timeout 1 } catch { $adoptButton = $null }
    if ($null -ne $adoptButton) { break }
    foreach ($t in (Get-StatusTexts -Root $dialog)) {
        if ($t -match '分離しています|変換|書き出し|ダウンロード') {
            if ($t -ne $lastStatus) { Write-Host ('  status: ' + $t); $lastStatus = $t }
            if (-not $shotTaken -and $t -match '\d+%') { Save-Shot -Window $dialog -Name '3_dialog_progress'; $shotTaken = $true }
        }
    }
}
Write-Host ('results shown: {0} after {1:N0} s' -f ($null -ne $adoptButton), $sw.Elapsed.TotalSeconds)
if ($null -eq $adoptButton) { throw 'results did not appear' }
Start-Sleep -Milliseconds 500
Save-Shot -Window $dialog -Name '3b_results'
foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match 'できました') { Write-Host ('  result status: ' + $t) } }

# ---- トラック名のセルをクリックすると候補メニューが出て、選ぶと名前が変わるか ----
try {
    $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Table)))
    if ($null -eq $gridElement) { $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::DataGrid))) }
    if ($null -eq $gridElement) { throw 'grid element not found' }
    $gridHwnd = [IntPtr]$gridElement.Current.NativeWindowHandle
    $gridRect = $gridElement.Current.BoundingRectangle
    $findNameCell = {
        foreach ($c in $gridElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            # DataGridView のセル名は「<列見出し> Row <n>」だが、日本語環境では「<列見出し> 行 <n>」になる。
            # 行 0 は「（元の音源）」でメニューが出ないので、最初の生成トラック（行 1）を使う
            if ([string]$c.Current.Name -match '^トラック名 (Row|行) 1$') { return $c }
        }
        return $null
    }
    $nameCell = & $findNameCell
    if ($null -eq $nameCell) {
        $names = @(); foreach ($c in $gridElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ($c.Current.Name) { $names += [string]$c.Current.Name } }
        throw ('name cell not found; grid elements: ' + ($names -join ' | '))
    }
    $before = '(no value pattern)'
    try { $before = [string]$nameCell.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }
    Write-Host ('  name before pick: ' + $before)
    # グリッドのクライアント座標でセルの中央を左クリック（メッセージ送信なので実際のマウスは動かさない）
    $cellRect = $nameCell.Current.BoundingRectangle
    $cx = [int]($cellRect.X + $cellRect.Width / 2 - $gridRect.X)
    $cy = [int]($cellRect.Y + $cellRect.Height / 2 - $gridRect.Y)
    $lParam = [IntPtr](($cy -shl 16) -bor ($cx -band 0xFFFF))
    $menuTypeCondition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Menu)
    $menuCondition = New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $gui.Id), $menuTypeCondition)
    # ドロップダウンはダイアログに所有されるので、UIA ではダイアログ（かメインウィンドウ）の下に見える。最上位に出ることもある
    $findMenu = {
        $m = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Children, $menuTypeCondition)
        if ($null -eq $m) { $m = $main.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $menuTypeCondition) }
        if ($null -eq $m) { $m = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $menuCondition) }
        return $m
    }
    # WinForms はマウスアップ時に WindowFromPoint がそのコントロールでないと Click を起こさない（他のウィンドウに
    # 隠れていると CellClick が出ない）。そこでクリックの間だけダイアログを最前面にする（アクティブにはしない）
    $dialogHwnd = [IntPtr]$dialog.Current.NativeWindowHandle
    [void][Win32.Native]::SetWindowPos($dialogHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
    Start-Sleep -Milliseconds 300
    [void][Win32.Native]::PostMessage($gridHwnd, 0x0201, [IntPtr]1, $lParam)
    [void][Win32.Native]::PostMessage($gridHwnd, 0x0202, [IntPtr]::Zero, $lParam)
    # アプリが前面でないとき、ユーザーが他のウィンドウを触るとメニューはすぐ閉じるので、クリック直後から短い間隔で探す
    $menu = $null
    $menuDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $menuDeadline -and $null -eq $menu) { $menu = & $findMenu; if ($null -eq $menu) { Start-Sleep -Milliseconds 50 } }
    if ($null -eq $menu) {
        $tops = @(); foreach ($t in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $gui.Id))) { $tops += ('{0}/{1}/{2}' -f $t.Current.ControlType.ProgrammaticName, $t.Current.ClassName, $t.Current.Name) }
        throw ('candidate menu did not appear; top-level windows: ' + ($tops -join ' | '))
    }
    $items = @($menu.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::MenuItem))))
    Write-Host ('  candidate menu items: ' + (($items | ForEach-Object { $_.Current.Name }) -join ' / '))
    Save-Shot -Window $menu -Name '3a_name_candidates'
    # 今の名前と違う候補を選んで、変わったことが分かるようにする
    $pick = $items | Where-Object { [string]$_.Current.Name -ne $before } | Select-Object -First 1
    if ($null -eq $pick) { $pick = $items[0] }
    $pickName = [string]$pick.Current.Name
    $pick.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 700
    if ($null -ne (& $findMenu)) {
        Write-Host '  menu still open after pick; sending Escape'
        [void][Win32.Native]::PostMessage([IntPtr]$menu.Current.NativeWindowHandle, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
        [void][Win32.Native]::PostMessage([IntPtr]$menu.Current.NativeWindowHandle, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 500
    }
    $nameCell = & $findNameCell
    $after = '(cell not found)'
    if ($null -ne $nameCell) { try { $after = $nameCell.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $after = '(no value pattern)' } }
    Write-Host ('  picked "' + $pickName + '" -> name after pick: ' + $after)
    Save-Shot -Window $dialog -Name '3a2_results_renamed'
} catch { Write-Host ('  candidate menu test skipped: ' + $_.Exception.Message) }
finally { if ($null -ne $dialogHwnd -and $dialogHwnd -ne [IntPtr]::Zero) { [void][Win32.Native]::SetWindowPos($dialogHwnd, [IntPtr](-2), 0, 0, 0, 0, 0x0013) } }

# プレビュー再生を 3 秒
$playButton = Find-Control -Root $dialog -Name '▶ 再生'
Click-Control $playButton
Start-Sleep -Seconds 3
Save-Shot -Window $dialog -Name '3c_results_playing'
foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '^\d+:\d\d / \d+:\d\d$' -or $t -match 'プレビュー') { Write-Host ('  playback: ' + $t) } }
# 再生したまま別の行（2 つ目の生成トラック）を選ぶ → 位置を保ったまま切り替わるはず
try {
    # グリッドにフォーカスを移して ↓ キーを送り、次の行（2 つ目の生成トラック）に移る
    $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Table)))
    if ($null -eq $gridElement) { $gridElement = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::DataGrid))) }
    if ($null -eq $gridElement) { throw 'grid element not found' }
    $gridElement.SetFocus()
    Start-Sleep -Milliseconds 300
    $gridHwnd = [IntPtr]$gridElement.Current.NativeWindowHandle
    [void][Win32.Native]::PostMessage($gridHwnd, 0x0100, [IntPtr]0x28, [IntPtr]::Zero)
    [void][Win32.Native]::PostMessage($gridHwnd, 0x0101, [IntPtr]0x28, [IntPtr]::Zero)
    Write-Host ('  sent VK_DOWN to grid hwnd ' + $gridHwnd)
    Start-Sleep -Seconds 2
    foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '^\d+:\d\d / \d+:\d\d$' -or $t -match 'プレビュー') { Write-Host ('  playback after switch: ' + $t) } }
    Save-Shot -Window $dialog -Name '3d_results_switched'
    if ($Reduce) {
        # 2 行目はリデュース（cut, reduce, ... の順）。ボーカル量のスライダーに → キーを 3 回送る
        foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '^ボーカル [+-]\d+dB$') { Write-Host ('  level before: ' + $t) } }
        $sliders = @($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Slider))) | Where-Object { -not $_.Current.IsOffscreen } | Sort-Object { $_.Current.BoundingRectangle.Y })
        Write-Host ('  visible sliders: ' + $sliders.Count)
        if ($sliders.Count -ge 2) {
            $levelSlider = $sliders[0]
            $levelSlider.SetFocus()
            Start-Sleep -Milliseconds 300
            $levelHwnd = [IntPtr]$levelSlider.Current.NativeWindowHandle
            for ($k = 0; $k -lt 3; $k++) {
                [void][Win32.Native]::PostMessage($levelHwnd, 0x0100, [IntPtr]0x27, [IntPtr]::Zero)
                [void][Win32.Native]::PostMessage($levelHwnd, 0x0101, [IntPtr]0x27, [IntPtr]::Zero)
                Start-Sleep -Milliseconds 150
            }
            Start-Sleep -Seconds 2
            foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '^ボーカル [+-]\d+dB$' -or $t -match '^\d+:\d\d / \d+:\d\d$') { Write-Host ('  after level change: ' + $t) } }
            Save-Shot -Window $dialog -Name '3e_results_level'
        }
    }
} catch { Write-Host ('  switch test skipped: ' + $_.Exception.Message) }

$stopButton = Find-Control -Root $dialog -Name '■ 停止'
Click-Control $stopButton
Start-Sleep -Milliseconds 500

# 「保存...」で選択中のトラックを別名保存（共通ダイアログを UIA とウィンドウメッセージで操作）
# 前回は UIA の SetValue/Invoke が効かずダイアログが開いたままになり、その状態で後続の BM_CLICK が
# 所有側の「採用」まで押してしまった。閉じたことを確かめてから先へ進む。
$saveStuck = $false
try {
    $saveTarget = Join-Path $ShotDir 'saved_track_test.m4a'
    if (Test-Path -LiteralPath $saveTarget) { Remove-Item -LiteralPath $saveTarget -Force }
    $saveButton = Find-Control -Root $dialog -Name '保存...'
    Click-Control $saveButton
    # 共通ダイアログは所有ウィンドウの下に出ることも最上位に出ることもあるので両方探す
    try { $saveDialog = Find-Window -Name 'トラックを保存' -Timeout 6 -Parent $dialog } catch { $saveDialog = Find-Window -Name 'トラックを保存' -Timeout 6 -ProcessId $gui.Id }
    Start-Sleep -Milliseconds 800
    $saveCondition = New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'トラックを保存'), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Window)))
    $isSaveDialogOpen = {
        if ($null -ne $dialog.FindFirst([System.Windows.Automation.TreeScope]::Children, $saveCondition)) { return $true }
        return ($null -ne [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $gui.Id), $saveCondition))))
    }
    $waitSaveDialogClosed = { param([int]$seconds) $d = (Get-Date).AddSeconds($seconds); while ((Get-Date) -lt $d -and (& $isSaveDialogOpen)) { Start-Sleep -Milliseconds 300 } }
    $edit = $saveDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Edit)), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'ファイル名:'))))
    if ($null -eq $edit) { throw 'file name edit not found' }
    # ファイル名は WM_SETTEXT で直接入れる（キー入力ではないので入力補完の一覧が開かない）
    $editHwnd = [IntPtr]$edit.Current.NativeWindowHandle
    if ($editHwnd -ne [IntPtr]::Zero) { [void][Win32.Native]::SendMessage($editHwnd, 0x000C, [IntPtr]::Zero, $saveTarget) } else { $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($saveTarget) }
    Start-Sleep -Milliseconds 300
    try { Write-Host ('  file name field: ' + $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) } catch { }
    $okButton = $saveDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Button)), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), '保存(S)'))))
    if ($null -eq $okButton) { throw 'save button not found' }
    $okButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    & $waitSaveDialogClosed 5
    if (& $isSaveDialogOpen) {
        Write-Host '  save dialog still open; sending Enter to the file name field'
        if ($editHwnd -ne [IntPtr]::Zero) {
            [void][Win32.Native]::PostMessage($editHwnd, 0x0100, [IntPtr]0x0D, [IntPtr]::Zero)
            [void][Win32.Native]::PostMessage($editHwnd, 0x0101, [IntPtr]0x0D, [IntPtr]::Zero)
        }
        & $waitSaveDialogClosed 5
    }
    if (& $isSaveDialogOpen) {
        Write-Host '  save dialog did not close; cancelling it'
        $cancel = $saveDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'キャンセル'))
        if ($null -ne $cancel) { $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
        & $waitSaveDialogClosed 5
        if (& $isSaveDialogOpen) { $saveStuck = $true; throw 'save dialog stuck open' }
    } else {
        # リデュース量を変えた行は書き出し直してからコピーされるので、終わるまで待つ
        $saveDeadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $saveDeadline -and -not (Test-Path -LiteralPath $saveTarget)) { Start-Sleep -Milliseconds 500 }
    }
    Start-Sleep -Seconds 1
    Write-Host ('  saved copy exists: ' + (Test-Path -LiteralPath $saveTarget))
    foreach ($t in (Get-StatusTexts -Root $dialog)) { if ($t -match '保存しました|保存できません|書き出して') { Write-Host ('  save status: ' + $t) } }
    $box = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), '#32770'), (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), 'ぴたトラック'))))
    if ($null -ne $box) { foreach ($t in $box.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ($t.Current.Name) { Write-Host ('  messagebox: ' + $t.Current.Name) } }; throw 'message box after save' }
    # 書き出し直し中なら、ボタンが戻るまで待つ
    $busyDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $busyDeadline) { $texts = Get-StatusTexts -Root $dialog; if (-not ($texts | Where-Object { $_ -match '書き出して' })) { break }; Start-Sleep -Milliseconds 500 }
} catch { Write-Host ('  save test skipped: ' + $_.Exception.Message) }
if ($saveStuck) {
    # モーダルのまま続けると所有側のボタンがメッセージで押せてしまうので、ここで打ち切る
    Stop-Process -Id $gui.Id -Force
    throw 'save dialog stuck open; gui terminated'
}

if ($CloseInsteadOfAdopt) {
    # 閉じる → 何も追加せず、生成したファイルは削除されるはず
    $closeButton = Find-Control -Root $dialog -Name '閉じる'
    Click-Control $closeButton
    $gone = Wait-Gone -Name 'ボーカル分離' -Timeout 60 -Parent $main -ShotPrefix '3_dialog'
    Write-Host ('dialog closed (close): {0}' -f $gone)
    Start-Sleep -Seconds 1
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $VideoFile) -Filter '*_offvocal_*.m4a') + @(Get-ChildItem -LiteralPath (Split-Path -Parent $VideoFile) -Filter '*_karaoke_*.m4a')
    Write-Host ('  generated files left next to video: ' + $leftovers.Count)
    Write-Host ('  temp result dirs left: ' + @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'PitaTrack_sep_results_*' -Directory).Count)
    $closeButton = Find-Control -Root $main -Name '閉じる'
    Click-Control $closeButton
    Start-Sleep -Seconds 2
    Write-Host ('gui exited: ' + $gui.HasExited)
    return
}

# 採用して追加（リデュース量を変えていれば書き出し直しが入る）
Click-Control $adoptButton
$gone = Wait-Gone -Name 'ボーカル分離' -Timeout 180 -Parent $main -ShotPrefix '3_dialog'
Write-Host ('dialog closed: {0}' -f $gone)
if (-not $gone) { throw 'separation dialog did not close' }

Start-Sleep -Seconds 1
$main = Find-Window -Name 'ぴたトラック' -Timeout 10 -ProcessId $gui.Id
Save-Shot -Window $main -Name '4_main_after'

# ---- グリッドの内容 ----
$grids = $main.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Table)))
foreach ($grid in $grids) {
    $cells = $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Custom)))
    Write-Host ("grid: {0} custom elements" -f $cells.Count)
}
foreach ($n in (Get-StatusTexts -Root $main)) { if ($n -match '追加しました|一覧にあります') { Write-Host ('  main status: ' + $n) } }

# ---- 保存 ----
$saveButton = Find-Control -Root $main -Name '保存'
Click-Control $saveButton
$deadline = (Get-Date).AddSeconds(300)
$saved = $false
$boxCondition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), '#32770'
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    # 上書き確認などのメッセージボックスが出ていたら知らせる
    $box = $main.FindFirst([System.Windows.Automation.TreeScope]::Children, $boxCondition)
    if ($null -eq $box) { $box = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.AndCondition @((New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ProcessIdProperty), $gui.Id), $boxCondition))) }
    if ($null -ne $box) {
        Save-Shot -Window $box -Name '5_messagebox'
        foreach ($t in $box.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ($t.Current.Name) { Write-Host ('  messagebox: ' + $t.Current.Name) } }
        throw 'unexpected message box'
    }
    foreach ($n in (Get-StatusTexts -Root $main)) {
        if ($n -match '保存しました') { Write-Host ('  main status: ' + $n); $saved = $true }
    }
    if ($saved) { break }
}
Save-Shot -Window $main -Name '6_main_saved'
if (-not $saved) { throw 'save did not finish' }

# ---- 閉じる ----
$closeButton = Find-Control -Root $main -Name '閉じる'
Click-Control $closeButton
Start-Sleep -Seconds 2
Write-Host ('gui exited: ' + $gui.HasExited)
