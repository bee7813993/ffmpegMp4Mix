[CmdletBinding(PositionalBinding = $false)]
param(
    # 試験するぴたトラックのブランチ（GitHub からダウンロードする）
    [string]$RepoRef = 'claude/dazzling-chebyshev-451c67',
    # 報告書の名前に付ける区別。省略すると SAC の状態（Eval / On / Off）
    [string]$Label,
    # 試験はせず、イベント ログだけを集める（ログを読むのに管理者が要ったときに、管理者の PowerShell で使う）
    [switch]$LogsOnly,
    # -LogsOnly で集める期間（時間）
    [int]$LogHours = 3,
    # 作業フォルダー
    [string]$Root = 'C:\sactest',
    # 飛ばす試験（T1 = setup.bat、Window = GUI の画面を開く）。ホストで試しに動かすとき用。-File で渡すときは T1,Window のように書く
    [string[]]$Skip = @(),
    # ダウンロードせずに使うぴたトラックの ZIP（中に ffmpegMp4Mix-* フォルダーがあるもの）
    [string]$RepoZipPath,
    # ダウンロードせずに使う ffmpeg.exe
    [string]$FfmpegExePath
)

# ぴたトラックを、スマート アプリ コントロール（SAC）の下で試します。仮想マシンの中の PowerShell で実行します。
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1
# SAC が「評価」のときと「オン」のときに 1 回ずつ実行し、C:\sactest\report-*.txt を比べます。
# PowerShell が制限モード（ConstrainedLanguage）になっても最後まで動くよう、.NET を直接呼ばずにコマンドレットだけで書いています。
# 試験の内容:
#   T1  ダウンロードした印（MOTW）が付いた setup.bat を開く（SAC は危険な拡張子のファイルをブロックする）
#   T2  gyan.dev の ffmpeg.exe（署名なし）を起動する（印あり / 印なし）
#   T3  PowerShell の言語モード、Add-Type、WinForms
#   T3b ぴたトラックの GUI スクリプト（印を外したもの）: 読み込み（約 1,000 行の Add-Type）、自動調整（CLI 版と同じ）、画面を開く
#   T4  ffmpeg で、ぴたトラックと同じ形の MP4 にまとめる

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# powershell -File では配列にならず "T1,Window" の 1 つの文字列で届くので、カンマで分ける
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$ffmpegUrl = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip'
$ffmpegSha256 = '60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA'
$repoUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/archive/refs/heads/' + $RepoRef + '.zip'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$startTime = Get-Date
$Script:Report = @()

function Add-Line {
    param([string]$Text = '')

    $Script:Report += $Text
    Write-Host $Text
}

function Add-Section {
    param([string]$Title)

    Add-Line ''
    Add-Line ('==== ' + $Title + ' ====')
}

function Get-SacState {
    $state = ''
    try {
        $state = [string](Get-MpComputerStatus -ErrorAction Stop).SmartAppControlState
    }
    catch {
        $state = '不明'
    }
    return $state
}

# ダウンロードしたときと同じ「インターネットから来た」印（MOTW）を付ける
function Set-Motw {
    param(
        [string]$Path,
        [string]$Url
    )

    Set-Content -Path $Path -Stream Zone.Identifier -Value @('[ZoneTransfer]', 'ZoneId=3', ('HostUrl=' + $Url))
}

function Save-Download {
    param(
        [string]$Url,
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -ErrorAction Stop
}

# 新しく開いた窓（タイトルに Pattern を含む）を待つ。見つかったらプロセス、なければ $null
function Wait-NewWindow {
    param(
        [object[]]$BeforeIds,
        [string]$Pattern,
        [int]$Seconds
    )

    for ($i = 0; $i -lt $Seconds; $i++) {
        $found = Get-Process -ErrorAction SilentlyContinue | Where-Object { $BeforeIds -notcontains $_.Id -and $_.MainWindowTitle -like $Pattern } | Select-Object -First 1
        if ($null -ne $found) {
            return $found
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

# 外部コマンドを実行し、終了コードと出力（先頭の数行）を返す（制限モードでは [PSCustomObject] を作れないのでハッシュテーブル）
function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$Lines = 3
    )

    try {
        $output = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        $text = (@($output | Select-Object -First $Lines) | ForEach-Object { [string]$_ }) -join ' / '
        return @{ Started = $true; ExitCode = $code; Text = $text; All = @($output | ForEach-Object { [string]$_ }) }
    }
    catch {
        return @{ Started = $false; ExitCode = $null; Text = ('起動できませんでした: ' + $_.Exception.Message); All = @() }
    }
}

function Add-EventLogs {
    param([datetime]$Since)

    $logs = @(
        @{ Name = 'Microsoft-Windows-CodeIntegrity/Operational'; Ids = @(3033, 3034, 3076, 3077) },
        @{ Name = 'Microsoft-Windows-AppLocker/MSI and Script'; Ids = @() }
    )
    foreach ($log in $logs) {
        Add-Section ('イベント ログ: ' + $log.Name)
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log.Name; StartTime = $Since } -ErrorAction Stop)
        }
        catch {
            if ($_.Exception.Message -match 'No events|一致するイベントが見つかりません|イベントが見つかりませんでした') {
                Add-Line '（この期間のイベントなし）'
            }
            else {
                Add-Line ('読めませんでした: ' + $_.Exception.Message)
                Add-Line '→ 管理者の PowerShell で次を実行してください: powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1 -LogsOnly'
            }
            continue
        }
        $shown = @($events | Where-Object { $log.Ids.Count -eq 0 -or $log.Ids -contains $_.Id } | Select-Object -First 60)
        Add-Line ('全 ' + $events.Count + ' 件。うち表示 ' + $shown.Count + ' 件')
        foreach ($event in $shown) {
            $message = (($event.Message -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -First 3) -join ' / '
            Add-Line ((Get-Date -Date $event.TimeCreated -Format 'HH:mm:ss') + ' [' + $event.Id + '] ' + $message)
        }
    }
}

function Save-Report {
    param([string]$Name)

    $path = Join-Path $Root $Name
    $Script:Report | Out-File -FilePath $path -Encoding utf8
    Write-Host ''
    Write-Host ('報告書: ' + $path)
    Write-Host 'この報告書を、拡張セッションのコピーと貼り付けでホストに移すか、メモ帳で開いて中身を Claude に貼ってください。'
}

if (-not (Test-Path -LiteralPath $Root)) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
}
$sacState = Get-SacState
if ([string]::IsNullOrWhiteSpace($Label)) {
    $Label = $sacState
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($LogsOnly) {
    Add-Line ('SAC の状態: ' + $sacState + ' / 集めた期間: 直近 ' + $LogHours + ' 時間')
    Add-EventLogs -Since ((Get-Date).AddHours(-$LogHours))
    Save-Report ('logs-' + $Label + '-' + $stamp + '.txt')
    exit 0
}

# ---- 環境 ----

Add-Section '環境'
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$policyState = ''
try {
    $policyState = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
}
catch {
}
Add-Line ('開始: ' + (Get-Date -Date $startTime -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('Windows: ' + $os.ProductName + ' ' + $os.DisplayVersion + ' (build ' + $os.CurrentBuild + '.' + $os.UBR + ')')
Add-Line ('SAC の状態: ' + $sacState + '（VerifiedAndReputablePolicyState=' + $policyState + '。0=オフ 1=オン 2=評価）')
Add-Line ('この試験スクリプトの言語モード: ' + $ExecutionContext.SessionState.LanguageMode)
Add-Line ('PowerShell: ' + $PSVersionTable.PSVersion)
Add-Line ('管理者で実行: ' + [bool]((whoami /groups) -match 'S-1-16-12288'))
Add-Line ('試験するブランチ: ' + $RepoRef)

# ---- 準備: ダウンロードと展開 ----

Add-Section '準備'
$downloads = Join-Path $Root 'downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$repoZip = $RepoZipPath
$ffmpegZip = Join-Path $downloads 'ffmpeg-9.0.2-essentials_build.zip'
try {
    if ([string]::IsNullOrWhiteSpace($repoZip)) {
        $repoZip = Join-Path $downloads ('repo-' + ($RepoRef -replace '[\\/:*?"<>|]', '-') + '.zip')
        if (Test-Path -LiteralPath $repoZip) {
            Remove-Item -LiteralPath $repoZip -Force
        }
        Save-Download -Url $repoUrl -Path $repoZip
    }
    if ([string]::IsNullOrWhiteSpace($FfmpegExePath)) {
        Save-Download -Url $ffmpegUrl -Path $ffmpegZip
    }
}
catch {
    Add-Line ('ダウンロードできませんでした: ' + $_.Exception.Message)
    Save-Report ('report-' + $Label + '-' + $stamp + '.txt')
    exit 1
}
Add-Line ('ぴたトラックの ZIP: ' + $repoZip)
if ([string]::IsNullOrWhiteSpace($FfmpegExePath)) {
    $hash = (Get-FileHash -LiteralPath $ffmpegZip -Algorithm SHA256).Hash
    Add-Line ('ffmpeg の ZIP の SHA256: ' + $(if ($hash -eq $ffmpegSha256) { '一致' } else { '不一致 ' + $hash }))
}
else {
    Add-Line ('ffmpeg.exe: ' + $FfmpegExePath + '（ダウンロードせずに使う）')
}

$run = Join-Path $Root ('run-' + $Label + '-' + $stamp)
$motwDir = Join-Path $run 'motw'
$plainDir = Join-Path $run 'plain'
# 展開は Windows の tar.exe で行う（Expand-Archive は、制限モードではモジュールの中で失敗することがある）
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
foreach ($directory in @($motwDir, $plainDir)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    & $tar -xf $repoZip -C $directory
    if ([string]::IsNullOrWhiteSpace($FfmpegExePath)) {
        & $tar -xf $ffmpegZip -C $directory
    }
    else {
        $bin = Join-Path $directory 'ffmpeg\bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Copy-Item -LiteralPath $FfmpegExePath -Destination $bin
    }
}
# エクスプローラーの「すべて展開」と同じく、展開したファイルにも印を付ける
Get-ChildItem -LiteralPath $motwDir -Recurse -File | ForEach-Object { Set-Motw -Path $_.FullName -Url $repoUrl }
$motwRepo = (Get-ChildItem -LiteralPath $motwDir -Directory | Where-Object { $_.Name -like 'ffmpegMp4Mix-*' } | Select-Object -First 1).FullName
$plainRepo = (Get-ChildItem -LiteralPath $plainDir -Directory | Where-Object { $_.Name -like 'ffmpegMp4Mix-*' } | Select-Object -First 1).FullName
$motwFfmpeg = (Get-ChildItem -LiteralPath $motwDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName
$plainFfmpeg = (Get-ChildItem -LiteralPath $plainDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName
Add-Line ('展開先: ' + $run)
Add-Line ('印あり: ' + $motwRepo)
Add-Line ('印なし: ' + $plainRepo)

# ---- T1: 印付きの setup.bat ----

Add-Section 'T1 印付きの setup.bat を開く'
if ($Skip -contains 'T1') {
    Add-Line '飛ばした（-Skip T1）'
}
else {
    $beforeIds = @(Get-Process | ForEach-Object { $_.Id })
    try {
        Start-Process -FilePath (Join-Path $motwRepo 'setup.bat') -WorkingDirectory $motwRepo -ErrorAction Stop
        Add-Line 'Start-Process: エラーなし'
    }
    catch {
        Add-Line ('Start-Process: エラー ' + $_.Exception.Message)
    }
    $setupWindow = Wait-NewWindow -BeforeIds $beforeIds -Pattern '*セットアップ*' -Seconds 20
    if ($null -ne $setupWindow) {
        Add-Line ('結果: セットアップの画面が開いた（ブロックされなかった）: ' + $setupWindow.MainWindowTitle)
        Stop-Process -Id $setupWindow.Id -Force
    }
    else {
        Add-Line '結果: 20 秒待ってもセットアップの画面は開かなかった（ブロックされた可能性。画面に SAC の通知が出ていたらスクリーンショットを）'
    }
    # setup.bat が残したコンソールなどを片付ける
    Get-Process -Name cmd, powershell -ErrorAction SilentlyContinue | Where-Object { $beforeIds -notcontains $_.Id } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- T2: ffmpeg.exe（署名なし） ----

Add-Section 'T2 gyan.dev の ffmpeg.exe を起動する'
$t2Motw = Invoke-Native -FilePath $motwFfmpeg -Arguments @('-hide_banner', '-version') -Lines 1
Add-Line ('印あり: ' + $(if ($t2Motw.Started) { '起動した（終了コード ' + $t2Motw.ExitCode + '）' } else { 'ブロック' }) + ' / ' + $t2Motw.Text)
$t2Plain = Invoke-Native -FilePath $plainFfmpeg -Arguments @('-hide_banner', '-version') -Lines 1
Add-Line ('印なし: ' + $(if ($t2Plain.Started) { '起動した（終了コード ' + $t2Plain.ExitCode + '）' } else { 'ブロック' }) + ' / ' + $t2Plain.Text)
$ffmpegWorks = $t2Plain.Started -and $t2Plain.ExitCode -eq 0

# ---- T3: PowerShell の言語モード ----

Add-Section 'T3 PowerShell（-File で印なしのスクリプトを実行）'
$probePath = Join-Path $run 'probe.ps1'
$probe = @'
"言語モード: " + $ExecutionContext.SessionState.LanguageMode
try { Add-Type -TypeDefinition 'public static class SacProbe { public static int Two() { return 2; } }' -ErrorAction Stop; "Add-Type: OK (" + [SacProbe]::Two() + ")" } catch { "Add-Type: NG " + $_.Exception.Message }
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $form = New-Object System.Windows.Forms.Form; $form.Dispose(); "WinForms: OK" } catch { "WinForms: NG " + $_.Exception.Message }
'@
Set-Content -LiteralPath $probePath -Value $probe -Encoding UTF8
$t3 = Invoke-Native -FilePath $powershellExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probePath) -Lines 10
foreach ($line in $t3.All) {
    Add-Line $line
}
if (-not $t3.Started) {
    Add-Line $t3.Text
}

# ---- T3b: ぴたトラックの GUI スクリプト ----

Add-Section 'T3b ぴたトラックの GUI スクリプト（印なし）'
$tools = Join-Path $plainRepo 'tools'
$gui = Join-Path $tools 'mixtrack_ffmpeg_gui.ps1'
if ($ffmpegWorks) {
    Copy-Item -LiteralPath $plainFfmpeg -Destination (Join-Path $tools 'ffmpeg.exe') -Force
}
# 自動調整をいつも行う設定にする
$settingsPath = Join-Path $tools 'mixtrack_ffmpeg_gui.settings.json'
$settingsText = (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8) -replace '"AutoOffsetAlways":\s*false', '"AutoOffsetAlways":  true'
Set-Content -LiteralPath $settingsPath -Value $settingsText -Encoding UTF8

$validate = Invoke-Native -FilePath $powershellExe -Arguments @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $gui, '-ValidateOnly') -Lines 5
Add-Line ('読み込み（-ValidateOnly、Add-Type を含む）: ' + $(if ($validate.Started -and $validate.ExitCode -eq 0) { 'OK' } else { 'NG（終了コード ' + $validate.ExitCode + '）' }))
if ($validate.Text) {
    Add-Line ('  出力: ' + $validate.Text)
}

$media = Join-Path $run 'media'
New-Item -ItemType Directory -Path $media -Force | Out-Null
$refWav = Join-Path $media 'ref.wav'
$video = Join-Path $media 'video.mp4'
$track = Join-Path $media 'track.m4a'
$mediaReady = $false
if ($ffmpegWorks) {
    # 高さの変わるビープ音を 90 秒。音声トラックはそれを 700ms 遅らせたもの
    # （60 秒だと自動調整が例外になり、150 秒以上だとこの音では判定できない。90 秒なら -700ms・信頼度 高になる）
    $beeps = "aevalsrc='0.6*sin(2*PI*(330+110*mod(floor(t*1.7),7))*t)*lt(mod(t*1.3,1),0.3)':s=44100:d=90"
    $made = @(
        (Invoke-Native -FilePath $plainFfmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', $beeps, '-c:a', 'pcm_s16le', $refWav)),
        (Invoke-Native -FilePath $plainFfmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=30:duration=90', '-i', $refWav, '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'aac', '-b:a', '128k', '-shortest', $video)),
        (Invoke-Native -FilePath $plainFfmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-i', $refWav, '-af', 'adelay=700:all=1', '-c:a', 'aac', '-b:a', '128k', $track))
    )
    $mediaReady = (@($made | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0) -and (Test-Path -LiteralPath $video) -and (Test-Path -LiteralPath $track)
    Add-Line ('試験用の動画と音声: ' + $(if ($mediaReady) { '作成した（音声は 700ms 遅らせてある）' } else { '作れなかった' }))
}
else {
    Add-Line '試験用の動画と音声: ffmpeg が動かないため作れない（自動調整と T4 は飛ばす）'
}

if ($mediaReady) {
    $defaultsPath = Join-Path $run 'cli-defaults.cmd'
    $cli = Invoke-Native -FilePath $powershellExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gui, '-CliDefaults', '-UseVideoAudio', '0', '-OutFile', $defaultsPath, $video, $track) -Lines 5
    Add-Line ('自動調整（-CliDefaults）: ' + $(if ($cli.Started -and $cli.ExitCode -eq 0 -and (Test-Path -LiteralPath $defaultsPath)) { 'OK' } else { 'NG（終了コード ' + $cli.ExitCode + '）' }))
    if ($cli.Text) {
        Add-Line ('  出力: ' + $cli.Text)
    }
    if (Test-Path -LiteralPath $defaultsPath) {
        Get-Content -LiteralPath $defaultsPath -Encoding Default | Where-Object { $_ -match 'CLI_(OFFSET|LEVEL|NOTE)_1|CLI_DEFAULTS_LOADED' } | ForEach-Object { Add-Line ('  ' + $_) }
    }
}

if ($Skip -contains 'Window') {
    Add-Line '画面: 飛ばした（-Skip Window）'
}
else {
    $beforeIds = @(Get-Process | ForEach-Object { $_.Id })
    $guiArguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $gui + '"'
    if ($mediaReady) {
        $guiArguments += ' "' + $video + '" "' + $track + '"'
    }
    try {
        Start-Process -FilePath $powershellExe -ArgumentList $guiArguments -ErrorAction Stop
        $window = Wait-NewWindow -BeforeIds $beforeIds -Pattern '*ぴたトラック*' -Seconds 60
        if ($null -ne $window) {
            Add-Line ('画面: 開いた（' + $window.MainWindowTitle + '）。自動調整のため 20 秒待ってから閉じます')
            Start-Sleep -Seconds 20
            $still = Get-Process -Id $window.Id -ErrorAction SilentlyContinue
            Add-Line ('  20 秒後: ' + $(if ($null -ne $still) { '動いている（' + $still.MainWindowTitle + '）' } else { '終了していた' }))
            Stop-Process -Id $window.Id -Force -ErrorAction SilentlyContinue
        }
        else {
            Add-Line '画面: 60 秒待っても開かなかった'
        }
    }
    catch {
        Add-Line ('画面: 起動できませんでした ' + $_.Exception.Message)
    }
    Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $beforeIds -notcontains $_.Id } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- T4: ffmpeg でまとめる ----

Add-Section 'T4 ffmpeg でまとめる（ぴたトラックと同じ形）'
if ($mediaReady) {
    $output = Join-Path $media 'mixed.mp4'
    $mix = Invoke-Native -FilePath $plainFfmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-i', $video, '-itsoffset', '0.7', '-i', $track, '-c:v', 'copy', '-c:a', 'copy', '-map', '0:v', '-map', '1:a', '-metadata:s:a:0', 'title=track1', '-metadata:s:a:0', 'handler_name=track1', $output)
    Add-Line ('結果: ' + $(if ($mix.Started -and $mix.ExitCode -eq 0 -and (Test-Path -LiteralPath $output)) { 'OK ' + $output } else { 'NG（終了コード ' + $mix.ExitCode + '）' + $mix.Text }))
}
else {
    Add-Line '飛ばした（試験用の動画と音声がない）'
}

# ---- イベント ログ ----

Add-EventLogs -Since $startTime
Add-Line ''
Add-Line ('終了: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Save-Report ('report-' + $Label + '-' + $stamp + '.txt')
