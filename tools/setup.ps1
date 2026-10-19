[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Uninstall,
    [switch]$FfmpegOnly,
    [switch]$SendToOnly,
    [switch]$RemoveSendTo,
    [switch]$Detach
)

# ぴたトラック のセットアップ
#   引数なし      : %LOCALAPPDATA%\Programs\PitaTrack にインストール（更新）する画面を開く
#   -Uninstall    : アンインストール
#   -FfmpegOnly   : このフォルダー（tools）に ffmpeg.exe をダウンロードする画面を開く
#   -SendToOnly   : このフォルダーのまま使う場合に、送るメニューへ登録する（makesendto.bat）
#   -RemoveSendTo : 送るメニューから削除する（removesendto.bat）
#   -Detach       : コンソールを残さないよう、見えないウインドウで開き直す（setup.bat）

$ErrorActionPreference = 'Stop'

# アプリの版。配布ZIPの名前（dev\build_release.ps1）にも使います。
$Script:AppVersion = '2.2.0'
$Script:AppName = 'ぴたトラック'
$Script:Publisher = 'bee7813993'
$Script:ProjectUrl = 'https://github.com/bee7813993/ffmpegMp4Mix'
$Script:GuiShortcutName = 'ぴたトラック'
$Script:CliShortcutName = 'ぴたトラック (CLI版)'
# ffmpegMp4Mix の頃の送るメニュー名
$Script:OldShortcutNames = @('mixtrack_ffmpeg_gui', 'mixtrack_ffmpeg')
$Script:SettingsFileName = 'mixtrack_ffmpeg_gui.settings.json'
# ショートカットとアンインストールから使う起動用ファイル（インストール時にこのPCで作る）
$Script:LauncherName = 'PitaTrack.exe'
$Script:IconFileName = 'pitatrack.ico'

# ダウンロードする ffmpeg（dev\ffmpeg-lgpl でビルドした LGPL 版。GitHub Release の ffmpeg-<版>-pitatrack<番号>）。
# 版を上げるときは、その Release の zip の URL と SHA256（Release の SHA256SUMS.txt）を一緒に変えます。
$Script:FfmpegUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/download/ffmpeg-9.0.2-pitatrack3/ffmpeg-9.0.2-pitatrack3-lgpl-win64.zip'
$Script:FfmpegSha256 = '1ac800f3f3b7ffdaa791c8ebd35403779daa4603920a82a267f86723af969079'
$Script:FfmpegSizeText = '約2MB'
# ffmpeg.exe と一緒に取り出すライセンスのファイル（LGPL の全文、ソースの場所、ビルドの指定）を置く tools の下のフォルダー
$Script:FfmpegLicenseDirName = 'ffmpeg-licenses'

$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SourceRoot = Split-Path -Parent $Script:ScriptDir
$Script:InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PitaTrack'
$Script:UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PitaTrack'

$Script:Busy = $false
$Script:CancelRequested = $false
$Script:ProgressBar = $null
$Script:StatusLabel = $null

function Get-FullPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-SamePath {
    param(
        [string]$Left,
        [string]$Right
    )

    return (Get-FullPath $Left).Equals((Get-FullPath $Right), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ErrorText {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return $exception.Message
}

function Test-CancelError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    return $ErrorRecord.Exception -is [System.OperationCanceledException]
}

# ---- ショートカット ----

function Get-ShortcutPaths {
    $sendTo = [Environment]::GetFolderPath('SendTo')
    return [PSCustomObject]@{
        SendToGui = Join-Path $sendTo ($Script:GuiShortcutName + '.lnk')
        SendToCli = Join-Path $sendTo ($Script:CliShortcutName + '.lnk')
        Desktop   = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) ($Script:GuiShortcutName + '.lnk')
        StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) ($Script:GuiShortcutName + '.lnk')
        OldSendTo = @($Script:OldShortcutNames | ForEach-Object { Join-Path $sendTo ($_ + '.lnk') })
    }
}

function Get-ShortcutTarget {
    param([string]$Path)

    try {
        $shell = New-Object -ComObject WScript.Shell
        return [string]$shell.CreateShortcut($Path).TargetPath
    }
    catch {
        return ''
    }
}

function Test-ShortcutInRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $target = Get-ShortcutTarget $Path
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $false
    }
    return (Get-FullPath $target).StartsWith((Get-FullPath $Root) + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function New-AppShortcut {
    param(
        [string]$Path,
        [string]$TargetPath,
        [string]$IconPath
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Description = $Script:AppName
    if (-not [string]::IsNullOrEmpty($IconPath) -and (Test-Path -LiteralPath $IconPath)) {
        $shortcut.IconLocation = $IconPath + ',0'
    }
    $shortcut.Save()
}

# Enabled のときは作り、そうでなければ Root 内を指すものだけ削除する
function Set-AppShortcut {
    param(
        [string]$Path,
        [string]$TargetPath,
        [bool]$Enabled,
        [string]$Root,
        [string]$IconPath
    )

    if ($Enabled) {
        New-AppShortcut -Path $Path -TargetPath $TargetPath -IconPath $IconPath
    }
    elseif ((Test-Path -LiteralPath $Path) -and (Test-ShortcutInRoot -Path $Path -Root $Root)) {
        Remove-Item -LiteralPath $Path -Force
    }
}

# 以前の送るメニュー（mixtrack_ffmpeg*）が指していたフォルダー
function Find-OldAppRoot {
    foreach ($path in (Get-ShortcutPaths).OldSendTo) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $target = Get-ShortcutTarget $path
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }
        $root = Split-Path -Parent $target
        if (Test-Path -LiteralPath $root -PathType Container) {
            return $root
        }
    }
    return $null
}

function Find-AppFile {
    param(
        [string]$Root,
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $null
    }
    foreach ($path in @((Join-Path (Join-Path $Root 'tools') $FileName), (Join-Path $Root $FileName))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }
    return $null
}

# ---- ファイルのコピーとアンインストール情報 ----

function Copy-AppFiles {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    $source = Get-FullPath $SourceRoot
    $destination = Get-FullPath $DestinationRoot
    if (Test-SamePath $source $destination) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $source -File)
    foreach ($folder in @('docs', 'tools')) {
        $path = Join-Path $source $folder
        if (Test-Path -LiteralPath $path -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $path -File -Recurse)
        }
    }

    # 設定と ffmpeg.exe は、すでにあるものを残す。ffmpeg のライセンスのファイルも ffmpeg.exe に合わせて残す
    $keepFfmpeg = Test-Path -LiteralPath (Join-Path $destination 'tools\ffmpeg.exe')
    $ffmpegLicensePrefix = 'tools\' + $Script:FfmpegLicenseDirName + '\'
    foreach ($file in $files) {
        # 起動用ファイルはコピーせず、インストール先で作り直す
        if ($file.Name.StartsWith('.') -or $file.Name -in @('ffplay.exe', 'ffprobe.exe', $Script:LauncherName)) {
            continue
        }

        $relativePath = $file.FullName.Substring($source.Length + 1)
        $target = Join-Path $destination $relativePath
        if ($file.Name -in @($Script:SettingsFileName, 'ffmpeg.exe') -and (Test-Path -LiteralPath $target)) {
            continue
        }
        if ($keepFfmpeg -and $relativePath.StartsWith($ffmpegLicensePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        # ダウンロードしたZIPの印を外し、起動のたびに警告が出ないようにする
        Unblock-File -LiteralPath $target
    }
}

function Register-Uninstall {
    param(
        [string]$InstallDir,
        [object]$Launch
    )

    $size = (Get-ChildItem -LiteralPath $InstallDir -File -Recurse | Measure-Object -Property Length -Sum).Sum
    if ($Launch.IsLauncher) {
        $uninstallString = '"' + $Launch.Target + '" /uninstall'
    }
    else {
        $uninstallString = '"' + (Get-PowerShellPath) + '" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'tools\setup.ps1') + '" -Uninstall'
    }
    $texts = [ordered]@{
        DisplayName     = $Script:AppName
        DisplayVersion  = $Script:AppVersion
        Publisher       = $Script:Publisher
        InstallLocation = $InstallDir
        UninstallString = $uninstallString
        URLInfoAbout    = $Script:ProjectUrl
    }
    if (-not [string]::IsNullOrEmpty($Launch.IconPath)) {
        $texts['DisplayIcon'] = $Launch.IconPath
    }
    $numbers = [ordered]@{
        NoModify      = 1
        NoRepair      = 1
        EstimatedSize = [int]([long]$size / 1KB)
    }

    New-Item -Path $Script:UninstallKey -Force | Out-Null
    foreach ($name in $texts.Keys) {
        New-ItemProperty -Path $Script:UninstallKey -Name $name -Value $texts[$name] -PropertyType String -Force | Out-Null
    }
    foreach ($name in $numbers.Keys) {
        New-ItemProperty -Path $Script:UninstallKey -Name $name -Value $numbers[$name] -PropertyType DWord -Force | Out-Null
    }
}

# ---- 起動用ファイル（PitaTrack.exe） ----

# コンソールを出さずに PowerShell の画面を開く小さな exe。VBScript を使わずに済むよう、
# このPCの C# コンパイラーで作る（ダウンロードしたファイルではないので、開くときの警告も出ない）。
# ソースは tools\PitaTrackLauncher.cs（Store 版の dev\build_msix.ps1 と共通）。
$Script:LauncherSourceName = 'PitaTrackLauncher.cs'

function Get-PowerShellPath {
    return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Build-Launcher {
    param([string]$Root)

    $sourcePath = Join-Path $Script:ScriptDir $Script:LauncherSourceName
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw ('起動用の ' + $Script:LauncherName + ' のソース（' + $Script:LauncherSourceName + '）が見つかりません。')
    }
    $source = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)

    $target = Join-Path $Root $Script:LauncherName
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_' + [guid]::NewGuid().ToString('N') + '.exe')
    $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable = $true
    $parameters.OutputAssembly = $tempPath
    $parameters.CompilerOptions = '/target:winexe /platform:anycpu /optimize'
    $iconPath = Join-Path $Root (Join-Path 'tools' $Script:IconFileName)
    if (Test-Path -LiteralPath $iconPath) {
        $parameters.CompilerOptions += ' /win32icon:"' + $iconPath + '"'
    }
    [void]$parameters.ReferencedAssemblies.Add('System.dll')
    [void]$parameters.ReferencedAssemblies.Add('System.Windows.Forms.dll')

    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    try {
        $results = $provider.CompileAssemblyFromSource($parameters, $source)
    }
    finally {
        $provider.Dispose()
    }
    $errors = @($results.Errors | Where-Object { -not $_.IsWarning })
    if ($errors.Count -gt 0 -or -not (Test-Path -LiteralPath $tempPath)) {
        $detail = if ($errors.Count -gt 0) { $errors[0].ErrorText } else { '' }
        throw ('起動用の ' + $Script:LauncherName + ' を作れませんでした。' + $detail)
    }
    Move-Item -LiteralPath $tempPath -Destination $target -Force
    return $target
}

# GUI を開くもの（PitaTrack.exe。作れなければ mixtrack_ffmpeg_gui.bat）とアイコン
function Install-Launcher {
    param([string]$Root)

    try {
        $launcher = Build-Launcher -Root $Root
        return [PSCustomObject]@{
            Target     = $launcher
            IsLauncher = $true
            IconPath   = $launcher
            Error      = ''
        }
    }
    catch {
        $iconPath = Join-Path $Root (Join-Path 'tools' $Script:IconFileName)
        return [PSCustomObject]@{
            Target     = Join-Path $Root 'mixtrack_ffmpeg_gui.bat'
            IsLauncher = $false
            IconPath   = $(if (Test-Path -LiteralPath $iconPath) { $iconPath } else { '' })
            Error      = Get-ErrorText $_
        }
    }
}

# ---- ffmpeg のダウンロード ----

function Update-Progress {
    param(
        [int]$Percent,
        [string]$Text
    )

    if ($null -ne $Script:ProgressBar) {
        if ($Percent -lt 0) {
            $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        }
        else {
            $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $Script:ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
        }
    }
    if ($null -ne $Script:StatusLabel) {
        $Script:StatusLabel.Text = $Text
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Copy-StreamWithProgress {
    param(
        [System.IO.Stream]$Source,
        [System.IO.Stream]$Destination,
        [long]$Total,
        [string]$Label
    )

    $buffer = New-Object byte[] (256KB)
    $done = [long]0
    $lastReport = [Environment]::TickCount
    while ($true) {
        if ($Script:CancelRequested) {
            throw (New-Object System.OperationCanceledException)
        }
        $read = $Source.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }
        $Destination.Write($buffer, 0, $read)
        $done += $read
        if ([Environment]::TickCount - $lastReport -ge 100) {
            $percent = -1
            $amount = '{0:N1} MB' -f ($done / 1MB)
            if ($Total -gt 0) {
                $percent = [int]($done * 100 / $Total)
                $amount = '{0:N1} / {1:N1} MB' -f ($done / 1MB), ($Total / 1MB)
            }
            Update-Progress -Percent $percent -Text ($Label + '  ' + $amount)
            $lastReport = [Environment]::TickCount
        }
    }

    if ($Total -gt 0 -and $done -ne $Total) {
        throw '通信が途中で切れました。'
    }
}

function Save-Download {
    param(
        [string]$Url,
        [string]$Destination
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $request = [System.Net.WebRequest]::Create($Url)
    $request.UserAgent = 'PitaTrack-Setup/' + $Script:AppVersion
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 60000
    if ($null -ne $request.Proxy) {
        $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }

    $response = $request.GetResponse()
    try {
        $stream = $response.GetResponseStream()
        $file = [System.IO.File]::Create($Destination)
        try {
            Copy-StreamWithProgress -Source $stream -Destination $file -Total $response.ContentLength -Label 'ffmpeg をダウンロードしています...'
        }
        finally {
            $file.Dispose()
            $stream.Dispose()
        }
    }
    finally {
        $response.Close()
    }
}

function Expand-FfmpegExe {
    param(
        [string]$ZipPath,
        [string]$TargetToolsDir
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $partPath = Join-Path $TargetToolsDir 'ffmpeg.exe.part'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.Name -eq 'ffmpeg.exe' } | Select-Object -First 1
        if ($null -eq $entry) {
            throw 'ダウンロードしたファイルに ffmpeg.exe が入っていません。'
        }

        # ffmpeg.exe と同じフォルダーのファイル（ライセンスなど）を先に置き、ffmpeg.exe だけが残ることがないようにする
        $folder = $entry.FullName.Substring(0, $entry.FullName.Length - $entry.Name.Length)
        $licenseDir = Join-Path $TargetToolsDir $Script:FfmpegLicenseDirName
        if (Test-Path -LiteralPath $licenseDir) {
            Remove-Item -LiteralPath $licenseDir -Recurse -Force
        }
        foreach ($item in @($archive.Entries | Where-Object { $_.Name -ne '' -and $_.Name -ne 'ffmpeg.exe' -and $_.FullName -eq ($folder + $_.Name) })) {
            if (-not (Test-Path -LiteralPath $licenseDir)) {
                New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item, (Join-Path $licenseDir $item.Name), $true)
        }

        $source = $entry.Open()
        try {
            $file = [System.IO.File]::Create($partPath)
            try {
                Copy-StreamWithProgress -Source $source -Destination $file -Total $entry.Length -Label 'ffmpeg.exe を取り出しています...'
            }
            finally {
                $file.Dispose()
            }
        }
        finally {
            $source.Dispose()
        }
        Move-Item -LiteralPath $partPath -Destination (Join-Path $TargetToolsDir 'ffmpeg.exe') -Force
    }
    finally {
        $archive.Dispose()
        if (Test-Path -LiteralPath $partPath) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-Ffmpeg {
    param([string]$TargetToolsDir)

    if (-not (Test-Path -LiteralPath $TargetToolsDir)) {
        New-Item -ItemType Directory -Path $TargetToolsDir -Force | Out-Null
    }

    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_ffmpeg_' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Update-Progress -Percent 0 -Text 'ffmpeg をダウンロードしています...'
        Save-Download -Url $Script:FfmpegUrl -Destination $zipPath
        Update-Progress -Percent -1 -Text 'ダウンロードしたファイルを確認しています...'
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($hash -ne $Script:FfmpegSha256) {
            throw 'ダウンロードしたファイルが正しくありません（SHA256 が一致しません）。'
        }
        Expand-FfmpegExe -ZipPath $zipPath -TargetToolsDir $TargetToolsDir
    }
    finally {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- 画面 ----

function New-UiColor {
    param(
        [int]$Red,
        [int]$Green,
        [int]$Blue
    )

    return [System.Drawing.Color]::FromArgb($Red, $Green, $Blue)
}

function New-UiFont {
    param(
        [single]$Size = 9.0,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    return New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $Size, $Style
}

function New-SetupForm {
    param(
        [string]$Title,
        [int]$Height
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(560, $Height)
    $form.BackColor = New-UiColor 246 248 250
    $form.ForeColor = New-UiColor 36 41 47
    $form.Font = New-UiFont 9
    $iconPath = Join-Path $Script:ScriptDir $Script:IconFileName
    if (Test-Path -LiteralPath $iconPath) {
        $form.Icon = New-Object System.Drawing.Icon -ArgumentList $iconPath
    }
    $form.Add_FormClosing({
            param($formSender, $closingEvent)

            # 処理中に閉じようとしたら、ダウンロードの中止として扱う
            if ($Script:Busy) {
                $closingEvent.Cancel = $true
                $Script:CancelRequested = $true
            }
        })
    return $form
}

function Add-SetupLabel {
    param(
        [System.Windows.Forms.Form]$Form,
        [string]$Text,
        [int]$Top,
        [int]$Height = 22,
        [int]$Left = 20,
        [switch]$Muted,
        [switch]$Heading,
        [switch]$Path
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($Left, $Top)
    $label.Size = New-Object System.Drawing.Size((540 - $Left), $Height)
    $label.UseMnemonic = $false
    if ($Muted) {
        $label.ForeColor = New-UiColor 87 96 106
    }
    if ($Heading) {
        $label.Font = New-UiFont 13 ([System.Drawing.FontStyle]::Bold)
    }
    if ($Path) {
        $label.BackColor = New-UiColor 255 255 255
        $label.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.AutoEllipsis = $true
    }
    $Form.Controls.Add($label)
    return $label
}

function Add-SetupCheckBox {
    param(
        [System.Windows.Forms.Form]$Form,
        [string]$Text,
        [int]$Top,
        [bool]$Checked,
        [int]$Left = 20
    )

    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Text = $Text
    $checkBox.Location = New-Object System.Drawing.Point($Left, $Top)
    $checkBox.Size = New-Object System.Drawing.Size((540 - $Left), 24)
    $checkBox.Checked = $Checked
    $checkBox.UseMnemonic = $false
    $Form.Controls.Add($checkBox)
    return $checkBox
}

function Add-SetupButton {
    param(
        [System.Windows.Forms.Form]$Form,
        [string]$Text,
        [int]$Left,
        [int]$Top,
        [int]$Width,
        [switch]$Primary
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($Left, $Top)
    $button.Size = New-Object System.Drawing.Size($Width, 32)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $button.BackColor = New-UiColor 37 99 235
        $button.ForeColor = New-UiColor 255 255 255
        $button.FlatAppearance.BorderColor = New-UiColor 37 99 235
        $button.FlatAppearance.MouseOverBackColor = New-UiColor 29 78 216
    }
    else {
        $button.BackColor = New-UiColor 255 255 255
        $button.FlatAppearance.BorderColor = New-UiColor 208 215 222
        $button.FlatAppearance.MouseOverBackColor = New-UiColor 219 234 254
    }
    $Form.Controls.Add($button)
    return $button
}

function Add-SetupProgress {
    param(
        [System.Windows.Forms.Form]$Form,
        [int]$Top
    )

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(20, $Top)
    $progress.Size = New-Object System.Drawing.Size(520, 18)
    $progress.MarqueeAnimationSpeed = 30
    $Form.Controls.Add($progress)
    return $progress
}

function Show-Message {
    param(
        [string]$Text,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return [System.Windows.Forms.MessageBox]::Show($Text, $Script:AppName, $Buttons, $Icon)
}

# ---- インストール ----

function Invoke-Install {
    param([hashtable]$Options)

    $installDir = $Script:InstallDir
    $toolsDir = Join-Path $installDir 'tools'
    $notes = New-Object System.Collections.Generic.List[string]

    Update-Progress -Percent -1 -Text 'ファイルをコピーしています...'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $settingsPath = Join-Path $toolsDir $Script:SettingsFileName
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        $oldSettings = Find-AppFile -Root $Options.OldRoot -FileName $Script:SettingsFileName
        if ($null -ne $oldSettings) {
            Copy-Item -LiteralPath $oldSettings -Destination $settingsPath
            Unblock-File -LiteralPath $settingsPath
            $notes.Add('以前の設定を引き継ぎました。')
        }
    }
    Copy-AppFiles -SourceRoot $Script:SourceRoot -DestinationRoot $installDir

    Update-Progress -Percent -1 -Text 'ショートカットを作っています...'
    $launch = Install-Launcher -Root $installDir
    if (-not $launch.IsLauncher) {
        $notes.Add($launch.Error + ' 代わりに mixtrack_ffmpeg_gui.bat から開きます。')
    }
    $cliTarget = Join-Path $installDir 'mixtrack_ffmpeg.bat'
    $paths = Get-ShortcutPaths
    Set-AppShortcut -Path $paths.SendToGui -TargetPath $launch.Target -IconPath $launch.IconPath -Enabled $Options.SendTo -Root $installDir
    Set-AppShortcut -Path $paths.SendToCli -TargetPath $cliTarget -Enabled ($Options.SendTo -and $Options.Cli) -Root $installDir
    Set-AppShortcut -Path $paths.Desktop -TargetPath $launch.Target -IconPath $launch.IconPath -Enabled $Options.Desktop -Root $installDir
    Set-AppShortcut -Path $paths.StartMenu -TargetPath $launch.Target -IconPath $launch.IconPath -Enabled $Options.StartMenu -Root $installDir
    if ($Options.RemoveOld) {
        foreach ($path in $paths.OldSendTo) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
    Register-Uninstall -InstallDir $installDir -Launch $launch

    $ffmpegPath = Join-Path $toolsDir 'ffmpeg.exe'
    $ffmpegReady = Test-Path -LiteralPath $ffmpegPath
    if (-not $ffmpegReady) {
        $oldFfmpeg = Find-AppFile -Root $Options.OldRoot -FileName 'ffmpeg.exe'
        if ($null -ne $oldFfmpeg) {
            Update-Progress -Percent -1 -Text '以前のフォルダーから ffmpeg.exe をコピーしています...'
            Copy-Item -LiteralPath $oldFfmpeg -Destination $ffmpegPath
            Unblock-File -LiteralPath $ffmpegPath
            $ffmpegReady = $true
        }
    }
    if (-not $ffmpegReady) {
        try {
            Install-Ffmpeg -TargetToolsDir $toolsDir
            $ffmpegReady = $true
        }
        catch {
            if (Test-CancelError $_) {
                $notes.Add('ffmpeg のダウンロードを中止しました。ぴたトラックを開いたときに、もう一度ダウンロードできます。')
            }
            else {
                $notes.Add('ffmpeg をダウンロードできませんでした（' + (Get-ErrorText $_) + '）。ぴたトラックを開いたときに、もう一度ダウンロードできます。')
            }
        }
    }
    # 大きさを ffmpeg 込みで登録し直す
    Register-Uninstall -InstallDir $installDir -Launch $launch

    return [PSCustomObject]@{
        FfmpegReady = $ffmpegReady
        Notes       = $notes
        GuiTarget   = $launch.Target
    }
}

function Get-FfmpegPlanText {
    param([string]$OldRoot)

    if (Test-Path -LiteralPath (Join-Path $Script:InstallDir 'tools\ffmpeg.exe')) {
        return 'ffmpeg（動画の作成に必要）: インストール済みのものをそのまま使います。'
    }
    if ($null -ne (Find-AppFile -Root $Script:SourceRoot -FileName 'ffmpeg.exe')) {
        return 'ffmpeg（動画の作成に必要）: このフォルダーにある ffmpeg.exe を使います。'
    }
    if ($null -ne (Find-AppFile -Root $OldRoot -FileName 'ffmpeg.exe')) {
        return 'ffmpeg（動画の作成に必要）: 以前のフォルダーにある ffmpeg.exe を使います。'
    }
    return 'ffmpeg（動画の作成に必要）: インターネットから自動でダウンロードします（' + $Script:FfmpegSizeText + '）。'
}

function Get-InstallDoneText {
    param(
        [bool]$IsUpdate,
        [hashtable]$Options,
        [object]$Result
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($(if ($IsUpdate) { '更新が完了しました。' } else { 'インストールが完了しました。' }))
    if ($Options.SendTo) {
        $lines.Add('ファイルを選んで右クリック →「送る」→「ぴたトラック」で使えます（Windows 11 は「その他のオプションを確認」の中）。')
    }
    elseif ($Options.Desktop) {
        $lines.Add('デスクトップの「ぴたトラック」にファイルをドロップして使えます。')
    }
    foreach ($note in $Result.Notes) {
        $lines.Add($note)
    }
    if (-not (Test-SamePath $Script:SourceRoot $Script:InstallDir)) {
        $lines.Add('展開したフォルダーとZIPファイルは削除してかまいません。')
    }
    return $lines -join "`r`n"
}

function Show-InstallForm {
    $paths = Get-ShortcutPaths
    $isUpdate = Test-Path -LiteralPath (Join-Path $Script:InstallDir 'tools\mixtrack_ffmpeg_gui.ps1')
    $oldRoot = Find-OldAppRoot
    $oldSendToExists = @($paths.OldSendTo | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    $state = @{ Done = $false; GuiTarget = '' }

    $height = 500
    if ($oldSendToExists) {
        $height += 26
    }
    $form = New-SetupForm -Title ($Script:AppName + ' セットアップ') -Height $height

    $headingText = if ($isUpdate) { $Script:AppName + ' を v' + $Script:AppVersion + ' に更新します' } else { $Script:AppName + ' v' + $Script:AppVersion + ' をインストールします' }
    Add-SetupLabel -Form $form -Text $headingText -Top 18 -Height 30 -Heading | Out-Null
    Add-SetupLabel -Form $form -Text '動画と音声ファイルを、トラック名付きの1つの MP4 にまとめるアプリです。' -Top 54 -Muted | Out-Null
    Add-SetupLabel -Form $form -Text 'インストール先' -Top 88 -Muted | Out-Null
    Add-SetupLabel -Form $form -Text $Script:InstallDir -Top 110 -Height 26 -Path | Out-Null

    $top = 150
    $sendToCheck = Add-SetupCheckBox -Form $form -Text '右クリックの「送る」に追加する（おすすめ）' -Top $top -Checked ((-not $isUpdate) -or (Test-Path -LiteralPath $paths.SendToGui))
    $top += 26
    $cliCheck = Add-SetupCheckBox -Form $form -Text ('CLI版「' + $Script:CliShortcutName + '」も追加する') -Top $top -Left 40 -Checked ((-not $isUpdate) -or (Test-Path -LiteralPath $paths.SendToCli))
    $top += 26
    $desktopCheck = Add-SetupCheckBox -Form $form -Text 'デスクトップにショートカットを作る' -Top $top -Checked ((-not $isUpdate) -or (Test-Path -LiteralPath $paths.Desktop))
    $top += 26
    $startMenuCheck = Add-SetupCheckBox -Form $form -Text 'スタートメニューに追加する' -Top $top -Checked ((-not $isUpdate) -or (Test-Path -LiteralPath $paths.StartMenu))
    $top += 26
    $removeOldCheck = $null
    if ($oldSendToExists) {
        $removeOldCheck = Add-SetupCheckBox -Form $form -Text '以前の「送る」メニュー（mixtrack_ffmpeg）を削除する' -Top $top -Checked $true
        $top += 26
    }
    $checkBoxes = @($sendToCheck, $cliCheck, $desktopCheck, $startMenuCheck, $removeOldCheck) | Where-Object { $null -ne $_ }
    $cliCheck.Enabled = $sendToCheck.Checked
    $sendToCheck.Add_CheckedChanged({ $cliCheck.Enabled = $sendToCheck.Checked })

    $top += 10
    Add-SetupLabel -Form $form -Text (Get-FfmpegPlanText -OldRoot $oldRoot) -Top $top -Height 36 -Muted | Out-Null
    $top += 40
    $Script:ProgressBar = Add-SetupProgress -Form $form -Top $top
    $top += 26
    $Script:StatusLabel = Add-SetupLabel -Form $form -Text '' -Top $top -Height 110

    $buttonTop = $height - 52
    $installButton = Add-SetupButton -Form $form -Text $(if ($isUpdate) { '更新' } else { 'インストール' }) -Left 300 -Top $buttonTop -Width 140 -Primary
    $cancelButton = Add-SetupButton -Form $form -Text 'キャンセル' -Left 450 -Top $buttonTop -Width 90
    $form.AcceptButton = $installButton

    $installButton.Add_Click({
            if ($state.Done) {
                Start-Process -FilePath $state.GuiTarget
                $form.Close()
                return
            }

            $options = @{
                SendTo    = $sendToCheck.Checked
                Cli       = $cliCheck.Checked
                Desktop   = $desktopCheck.Checked
                StartMenu = $startMenuCheck.Checked
                RemoveOld = ($null -ne $removeOldCheck -and $removeOldCheck.Checked)
                OldRoot   = $oldRoot
            }

            foreach ($checkBox in $checkBoxes) {
                $checkBox.Enabled = $false
            }
            $installButton.Enabled = $false
            $Script:Busy = $true
            $Script:CancelRequested = $false
            try {
                $result = Invoke-Install -Options $options
                $state.Done = $true
                $state.GuiTarget = $result.GuiTarget
                $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $Script:ProgressBar.Value = $(if ($result.FfmpegReady) { 100 } else { 0 })
                $Script:StatusLabel.Text = Get-InstallDoneText -IsUpdate $isUpdate -Options $options -Result $result
                $installButton.Text = 'ぴたトラックを開く'
                $cancelButton.Text = '閉じる'
                $form.AcceptButton = $cancelButton
            }
            catch {
                $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $Script:ProgressBar.Value = 0
                $Script:StatusLabel.Text = ''
                Show-Message -Text ("インストールできませんでした。`r`n`r`n" + (Get-ErrorText $_)) -Icon Error | Out-Null
                foreach ($checkBox in $checkBoxes) {
                    $checkBox.Enabled = $true
                }
                $cliCheck.Enabled = $sendToCheck.Checked
            }
            finally {
                $Script:Busy = $false
                $installButton.Enabled = $true
            }
        })

    $cancelButton.Add_Click({
            if ($Script:Busy) {
                $Script:CancelRequested = $true
                $Script:StatusLabel.Text = '中止しています...'
                return
            }
            $form.Close()
        })

    [void]$form.ShowDialog()
}

# ---- ffmpeg だけをダウンロード（ぴたトラックが ffmpeg.exe を見つけられないとき） ----

function Show-FfmpegForm {
    $toolsDir = $Script:ScriptDir
    $form = New-SetupForm -Title ($Script:AppName + ' - ffmpeg のダウンロード') -Height 300

    Add-SetupLabel -Form $form -Text 'ffmpeg.exe が見つかりません' -Top 18 -Height 30 -Heading | Out-Null
    Add-SetupLabel -Form $form -Text ('ぴたトラックで MP4 を作るには ffmpeg が必要です。インターネットからダウンロードして、次のフォルダーに置きます（' + $Script:FfmpegSizeText + '）。') -Top 54 -Height 40 | Out-Null
    Add-SetupLabel -Form $form -Text $toolsDir -Top 98 -Height 26 -Path | Out-Null
    Add-SetupLabel -Form $form -Text '自分で用意する場合は、ffmpeg.exe をこのフォルダーに置いてください。' -Top 130 -Muted | Out-Null
    $Script:ProgressBar = Add-SetupProgress -Form $form -Top 164
    $Script:StatusLabel = Add-SetupLabel -Form $form -Text '' -Top 190 -Height 44

    $downloadButton = Add-SetupButton -Form $form -Text 'ダウンロード' -Left 300 -Top 248 -Width 140 -Primary
    $cancelButton = Add-SetupButton -Form $form -Text 'キャンセル' -Left 450 -Top 248 -Width 90
    $form.AcceptButton = $downloadButton

    $downloadButton.Add_Click({
            $downloadButton.Enabled = $false
            $Script:Busy = $true
            $Script:CancelRequested = $false
            try {
                Install-Ffmpeg -TargetToolsDir $toolsDir
                $Script:Busy = $false
                $form.Close()
                return
            }
            catch {
                $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $Script:ProgressBar.Value = 0
                if (Test-CancelError $_) {
                    $Script:StatusLabel.Text = 'ダウンロードを中止しました。'
                }
                else {
                    $Script:StatusLabel.Text = 'ダウンロードできませんでした。インターネットにつながっているか確認して、もう一度お試しください。' + "`r`n" + (Get-ErrorText $_)
                }
                $downloadButton.Text = 'もう一度'
            }
            finally {
                $Script:Busy = $false
                $downloadButton.Enabled = $true
            }
        })

    $cancelButton.Add_Click({
            if ($Script:Busy) {
                $Script:CancelRequested = $true
                $Script:StatusLabel.Text = '中止しています...'
                return
            }
            $form.Close()
        })

    [void]$form.ShowDialog()
    if (Test-Path -LiteralPath (Join-Path $toolsDir 'ffmpeg.exe')) {
        return 0
    }
    return 1
}

# ---- アンインストール ----

function Invoke-Uninstall {
    $installDir = $Script:InstallDir
    $answer = Show-Message -Text ("ぴたトラックをアンインストールしますか？`r`n`r`nショートカットと送るメニュー、設定、ffmpeg.exe も削除します。") -Buttons YesNo -Icon Question
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return 1
    }

    Set-Location -LiteralPath ([System.IO.Path]::GetTempPath())
    $paths = Get-ShortcutPaths
    foreach ($path in @($paths.SendToGui, $paths.SendToCli, $paths.Desktop, $paths.StartMenu)) {
        if ((Test-Path -LiteralPath $path) -and (Test-ShortcutInRoot -Path $path -Root $installDir)) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if (Test-Path -LiteralPath $Script:UninstallKey) {
        Remove-Item -LiteralPath $Script:UninstallKey -Recurse -Force
    }

    # ぴたトラックのフォルダーだと確認できたときだけ消す
    if (Test-Path -LiteralPath (Join-Path $installDir 'tools\mixtrack_ffmpeg_gui.ps1')) {
        try {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        catch {
            Show-Message -Text ("一部のファイルを削除できませんでした。ぴたトラックを閉じてから、次のフォルダーを削除してください。`r`n`r`n" + $installDir) -Icon Warning | Out-Null
            return 1
        }
    }

    Show-Message -Text 'ぴたトラックをアンインストールしました。' | Out-Null
    return 0
}

# ---- 送るメニューだけ登録・削除（このフォルダーのまま使う場合） ----

function Register-SendToHere {
    $root = $Script:SourceRoot
    $paths = Get-ShortcutPaths
    $launch = Install-Launcher -Root $root
    if (-not $launch.IsLauncher) {
        Write-Host ($launch.Error + ' 代わりに mixtrack_ffmpeg_gui.bat から開きます。')
    }
    New-AppShortcut -Path $paths.SendToGui -TargetPath $launch.Target -IconPath $launch.IconPath
    New-AppShortcut -Path $paths.SendToCli -TargetPath (Join-Path $root 'mixtrack_ffmpeg.bat')
    Write-Host '送るメニューに登録しました。'
    Write-Host ('  ' + $paths.SendToGui)
    Write-Host ('  ' + $paths.SendToCli)
}

function Unregister-SendTo {
    $paths = Get-ShortcutPaths
    $removed = 0
    foreach ($path in @($paths.SendToGui, $paths.SendToCli) + $paths.OldSendTo) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Host ('削除しました: ' + $path)
            $removed++
        }
    }
    if ($removed -eq 0) {
        Write-Host '削除する送るメニューはありませんでした。'
    }
}

# setup.bat から開いたときは、見えないウインドウで開き直す（コンソールを残さない）
if ($Detach) {
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    Start-Process -FilePath (Get-PowerShellPath) -ArgumentList $arguments -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if ($SendToOnly) {
    Register-SendToHere
    exit 0
}
if ($RemoveSendTo) {
    Unregister-SendTo
    exit 0
}
if ($Uninstall) {
    exit (Invoke-Uninstall)
}
if ($FfmpegOnly) {
    exit (Show-FfmpegForm)
}

Show-InstallForm
exit 0
