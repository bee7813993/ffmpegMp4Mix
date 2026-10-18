[CmdletBinding()]
param(
    # Store に出すときは Partner Center の「製品 ID」の値にする
    [string]$IdentityName = 'PitaTrack.Dev',
    [string]$Publisher = 'CN=PitaTrackDev',
    [string]$PublisherDisplayName = 'bee7813993',
    [string]$OutputDir,
    # 作ったフォルダーをこの PC に登録して試す（Windows の開発者モードが必要）
    [switch]$Register
)

# Store 版（MSIX）のパッケージ dist\PitaTrack_<版>_x64.msix を作ります。
#   - 版は tools\setup.ps1 の $Script:AppVersion から読み取ります（4 つ目は 0。Store が使うため）。
#   - 起動用の PitaTrack.exe（tools\PitaTrackLauncher.cs）を .NET Framework の csc でビルドします。
#   - 右クリックメニューの PitaTrackShell.dll（msix\PitaTrackShell）を Visual Studio の C++ でビルドします。
#   - ffmpeg は、dev\ffmpeg-lgpl でビルドした LGPL 版の GitHub Release（下の $ffmpegRelease）からダウンロードし、
#     SHA256 を確かめて tools\ffmpeg.exe に入れます。ライセンスの文書とソース（tar.xz）も licenses\FFmpeg に入れます
#     （LGPL 2.1 の第 4 節。ソースを実行形式と一緒に届けるため）。ダウンロードしたものは dist\ffmpeg-cache に残します。
#   - アプリの「設定 → ライセンス」で見せる licenses\README.txt は msix\licenses-README.txt から作ります。
#   - setup.ps1 などのインストール用ファイルは入れません（アプリが ffmpeg をダウンロードすることもない）。
#   - パッケージは署名しません。Store に出すと Microsoft が署名します。
#     この PC で試すときは -Register を付け、署名なしのフォルダー（dist\msix-layout）をそのまま登録します。
#     右クリックメニューは、登録したあとエクスプローラーを再起動すると出ます。
# 必要なもの: Visual Studio（C++ によるデスクトップ開発）と Windows SDK（makeappx.exe）

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'dist'
}

# 同梱する ffmpeg（dev\ffmpeg-lgpl でビルドした LGPL 版。GitHub Release の ffmpeg-<版>-pitatrack<番号>）。
# 版を上げるときは、新しい Release の SHA256SUMS.txt の値で下を一緒に変えます
# （ZIP 版は tools\setup.ps1 の $Script:FfmpegUrl と $Script:FfmpegSha256）。
$ffmpegVersion = '9.0.2'
$ffmpegRelease = 'ffmpeg-9.0.2-pitatrack1'
$ffmpegFiles = [ordered]@{
    'ffmpeg-9.0.2-pitatrack1-lgpl-win64.zip'  = '34e93b6949d16ac109b15abf93826fc5f4af6fdf51a8d469a16eadec49d90eae'
    'ffmpeg-9.0.2-pitatrack1-build-files.zip' = '3aa32fcac067acffbd7170b09148086b20b59fe796cab4225bcd11b9b643c5c3'
    'ffmpeg-9.0.2.tar.xz'                     = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
    'ffmpeg-9.0.2.tar.xz.asc'                 = 'd617fd94ea354dadd2a8bb16243d37c44e1e9729b06b6ad58fe30bfb0fa943f2'
}
$ffmpegReleaseUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/' + $ffmpegRelease
$ffmpegDownloadUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/download/' + $ffmpegRelease + '/'

$setupText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\setup.ps1') -Raw -Encoding UTF8
if ($setupText -notmatch '\$Script:AppVersion\s*=\s*''(\d+)\.(\d+)\.(\d+)''') {
    throw 'tools\setup.ps1 から版（x.y.z）を読み取れませんでした。'
}
$version = '{0}.{1}.{2}.0' -f $Matches[1], $Matches[2], $Matches[3]

# ---- ビルドに使うもの ----

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw ('C# コンパイラーが見つかりません: ' + $csc)
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = $null
if (Test-Path -LiteralPath $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
}
$vcvars = if ($vsPath) { Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat' } else { $null }
if (-not $vcvars -or -not (Test-Path -LiteralPath $vcvars)) {
    throw 'Visual Studio の C++（x64）が見つかりません。「C++ によるデスクトップ開発」を入れてください。'
}

$makeappx = Get-ChildItem -Path (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') -Filter makeappx.exe -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' -and $_.Directory.Parent.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1
if ($null -eq $makeappx) {
    throw 'makeappx.exe が見つかりません。Windows SDK を入れてください。'
}

# ---- 置き場所 ----

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$layout = Join-Path $OutputDir 'msix-layout'
$objDir = Join-Path $OutputDir 'msix-obj'
$packagePath = Join-Path $OutputDir ('PitaTrack_{0}_x64.msix' -f $version)

# 前に -Register したパッケージがこのフォルダーを使っていたら、消す前に登録を外す
$registered = Get-AppxPackage -Name $IdentityName | Where-Object { $_.InstallLocation -eq $layout }
if ($null -ne $registered) {
    Write-Host ('登録済みの ' + $registered.PackageFullName + ' を外します。')
    $registered | Remove-AppxPackage
}
foreach ($directory in @($layout, $objDir)) {
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$licenseDir = Join-Path $layout 'licenses'
$ffmpegLicenseDir = Join-Path $licenseDir 'FFmpeg'
$ffmpegSourceDir = Join-Path $ffmpegLicenseDir 'source'
New-Item -ItemType Directory -Path (Join-Path $layout 'tools'), (Join-Path $layout 'Assets'), (Join-Path $licenseDir 'PitaTrack'), $ffmpegSourceDir -Force | Out-Null

# ---- ffmpeg（LGPL 版の Release をダウンロードし、SHA256 を確かめる） ----

$ffmpegCache = Join-Path $OutputDir (Join-Path 'ffmpeg-cache' $ffmpegRelease)
New-Item -ItemType Directory -Path $ffmpegCache -Force | Out-Null
$ProgressPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
foreach ($name in $ffmpegFiles.Keys) {
    $path = Join-Path $ffmpegCache $name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ('ダウンロード: ' + $ffmpegDownloadUrl + $name)
        Invoke-WebRequest -Uri ($ffmpegDownloadUrl + $name) -OutFile ($path + '.part') -UseBasicParsing
        Move-Item -LiteralPath ($path + '.part') -Destination $path -Force
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $ffmpegFiles[$name]) {
        Remove-Item -LiteralPath $path -Force
        throw ($name + ' の SHA256 が一致しません（' + $hash + '）。もう一度実行するとダウンロードし直します。')
    }
}

# バイナリの zip: ffmpeg.exe は tools に、ほかのファイル（LICENSE.txt、BUILD.txt など）は licenses\FFmpeg に
$ffmpegExtract = Join-Path $objDir 'ffmpeg'
Expand-Archive -LiteralPath (Join-Path $ffmpegCache ($ffmpegRelease + '-lgpl-win64.zip')) -DestinationPath $ffmpegExtract -Force
$ffmpegExe = Get-ChildItem -LiteralPath $ffmpegExtract -Recurse -Filter ffmpeg.exe | Select-Object -First 1
if ($null -eq $ffmpegExe) {
    throw 'ダウンロードした zip に ffmpeg.exe が入っていません。'
}
Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path $layout 'tools\ffmpeg.exe')
Get-ChildItem -LiteralPath $ffmpegExe.DirectoryName -File | Where-Object { $_.Name -ne 'ffmpeg.exe' } | Copy-Item -Destination $ffmpegLicenseDir
foreach ($name in $ffmpegFiles.Keys) {
    if ($name -notlike '*-lgpl-win64.zip') {
        Copy-Item -LiteralPath (Join-Path $ffmpegCache $name) -Destination $ffmpegSourceDir
    }
}

# ---- アプリのファイルとライセンス ----

Copy-Item -LiteralPath (Join-Path $repoRoot 'mixtrack_ffmpeg.bat') -Destination $layout
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $licenseDir 'PitaTrack')
foreach ($name in @('mixtrack_ffmpeg_gui.ps1', 'mixtrack_ffmpeg_gui.settings.json', 'pitatrack.ico')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot (Join-Path 'tools' $name)) -Destination (Join-Path $layout 'tools')
}
$licenseText = (Get-Content -LiteralPath (Join-Path $repoRoot 'msix\licenses-README.txt') -Raw -Encoding UTF8).Replace('__FFMPEG_VERSION__', $ffmpegVersion).Replace('__FFMPEG_RELEASE_URL__', $ffmpegReleaseUrl)
[System.IO.File]::WriteAllText((Join-Path $licenseDir 'README.txt'), $licenseText, (New-Object System.Text.UTF8Encoding $true))

# ---- PitaTrack.exe ----

$iconPath = Join-Path $repoRoot 'tools\pitatrack.ico'
& $csc /nologo /target:winexe /platform:anycpu /optimize /codepage:65001 ('/win32icon:' + $iconPath) /r:System.Windows.Forms.dll ('/out:' + (Join-Path $layout 'PitaTrack.exe')) (Join-Path $repoRoot 'tools\PitaTrackLauncher.cs')
if ($LASTEXITCODE -ne 0) {
    throw 'PitaTrack.exe をビルドできませんでした。'
}

# ---- PitaTrackShell.dll（右クリックメニュー） ----

$shellSource = Join-Path $repoRoot 'msix\PitaTrackShell'
$clCommand = 'call "{0}" >nul 2>&1 && cl /nologo/LD /EHsc /O2 /W4 /utf-8 /MT /DUNICODE /D_UNICODE /Fo"{1}\\" "{2}\PitaTrackShell.cpp" /link /DEF:"{2}\PitaTrackShell.def" /OUT:"{3}\PitaTrackShell.dll" /IMPLIB:"{1}\PitaTrackShell.lib" shlwapi.lib shell32.lib ole32.lib user32.lib' -f $vcvars, $objDir, $shellSource, $layout
cmd /c $clCommand
if ($LASTEXITCODE -ne 0) {
    throw 'PitaTrackShell.dll をビルドできませんでした。'
}

# ---- ロゴ（pitatrack.ico の一番大きい画像から作る） ----

Add-Type -AssemblyName System.Drawing
$iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
$count = [BitConverter]::ToUInt16($iconBytes, 4)
$best = $null
for ($i = 0; $i -lt $count; $i++) {
    $entry = 6 + 16 * $i
    $width = if ($iconBytes[$entry] -eq 0) { 256 } else { [int]$iconBytes[$entry] }
    if ($null -eq $best -or $width -gt $best.Width) {
        $best = [PSCustomObject]@{
            Width  = $width
            Size   = [BitConverter]::ToInt32($iconBytes, $entry + 8)
            Offset = [BitConverter]::ToInt32($iconBytes, $entry + 12)
        }
    }
}
$isPng = $iconBytes[$best.Offset] -eq 0x89 -and $iconBytes[$best.Offset + 1] -eq 0x50
if ($isPng) {
    $stream = New-Object System.IO.MemoryStream -ArgumentList $iconBytes, $best.Offset, $best.Size
    $sourceImage = [System.Drawing.Image]::FromStream($stream)
}
else {
    $sourceImage = (New-Object System.Drawing.Icon $iconPath, $best.Width, $best.Width).ToBitmap()
}
foreach ($logo in @(@('StoreLogo', 50), @('Square44x44Logo', 44), @('Square150x150Logo', 150))) {
    $size = $logo[1]
    $bitmap = New-Object System.Drawing.Bitmap $size, $size
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($sourceImage, 0, 0, $size, $size)
    $graphics.Dispose()
    $bitmap.Save((Join-Path $layout ('Assets\' + $logo[0] + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
$sourceImage.Dispose()

# ---- マニフェスト ----

$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'msix\AppxManifest.xml') -Raw -Encoding UTF8
$values = [ordered]@{
    '__IDENTITY_NAME__'          = $IdentityName
    '__PUBLISHER__'              = $Publisher
    '__PUBLISHER_DISPLAY_NAME__' = $PublisherDisplayName
    '__VERSION__'                = $version
}
foreach ($key in $values.Keys) {
    $manifest = $manifest.Replace($key, [System.Security.SecurityElement]::Escape($values[$key]))
}
[System.IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding $false))

# ---- パッケージ ----

& $makeappx.FullName pack /o /d $layout /p $packagePath | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $makeappx.FullName pack /o /d $layout /p $packagePath
    throw 'makeappx でパッケージを作れませんでした。'
}

Write-Host ('作成しました: ' + $packagePath)
Write-Host ('  版 ' + $version + ' / ' + $IdentityName + ' / ' + $Publisher)

if ($Register) {
    Add-AppxPackage -Register (Join-Path $layout 'AppxManifest.xml')
    Write-Host ('この PC に登録しました: ' + $layout)
    Write-Host '  右クリックメニューは、エクスプローラーを再起動すると出ます。'
    Write-Host ('  外すとき: Get-AppxPackage ' + $IdentityName + ' | Remove-AppxPackage')
}
