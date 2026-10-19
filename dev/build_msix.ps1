[CmdletBinding()]
param(
    # 既定は Partner Center の「製品 ID」の値（ぴたトラック）
    [string]$IdentityName = 'YFRTeam.36059D6F4B72A',
    [string]$Publisher = 'CN=7F20441E-C8F2-4A45-B847-6FECA63733DB',
    [string]$PublisherDisplayName = 'YFRTeam',
    [string]$OutputDir,
    # 作ったフォルダーをこの PC に登録して試す（Windows の開発者モードが必要）
    [switch]$Register,
    # 試験用の ID（PitaTrack.Dev）で作る。この PC に -Register して試すときに付ける。
    # Store の ID のまま登録すると、同じ PC に Store から入れるときにぶつかるため
    [switch]$DevIdentity,
    # 手元でビルドした ffmpeg（dev\ffmpeg-lgpl\build.sh の出力 ffmpeg-<版>-pitatrack<n>-lgpl-win64 フォルダー）を、
    # Release の zip の代わりに入れる。Release を作る前に試すためのもので、Store に出すパッケージには使わない
    [string]$FfmpegDir
)

# Store 版（MSIX）のパッケージ dist\PitaTrack_<版>_x64.msix を作ります。
#   - 版は tools\setup.ps1 の $Script:AppVersion から読み取ります（4 つ目は 0。Store が使うため）。
#   - 起動用の PitaTrack.exe（tools\PitaTrackLauncher.cs）を .NET Framework の csc でビルドします。
#   - 右クリックメニューの PitaTrackShell.dll（msix\PitaTrackShell）を Visual Studio の C++ でビルドします。
#   - ffmpeg は、dev\ffmpeg-lgpl でビルドした LGPL 版の GitHub Release（下の $ffmpegRelease）からダウンロードし、
#     SHA256 を確かめて tools\ffmpeg.exe に入れます。ライセンスの文書とソース（tar.xz）も licenses\FFmpeg に入れます
#     （LGPL 2.1 の第 4 節。ソースを実行形式と一緒に届けるため）。ダウンロードしたものは dist\ffmpeg-cache に残します。
#   - ボーカル分離のエンジン BSRoformer.cpp（Windows Vulkan 版の zip。URL と SHA256 は tools\mixtrack_ffmpeg_gui.ps1 から読む）を
#     ダウンロードし、SHA256 を確かめて exe と dll を tools\bsroformer に入れます。Store の規約で実行ファイルをあとからダウンロード
#     できないためです。ライセンス文（BSRoformer.cpp と ggml の MIT License）も licenses\BSRoformer.cpp に入れます。
#     ダウンロードしたものは dist\bsroformer-cache に残します。bs_roformer-cli.exe は Visual C++ ランタイムを使うので、
#     マニフェスト（msix\AppxManifest.xml）で Microsoft.VCLibs.140.00.UWPDesktop に依存します（Store が一緒に入れる）。
#   - アプリの「設定 → ライセンス」で見せる licenses\README.txt は msix\licenses-README.txt から作ります。
#   - setup.ps1 などのインストール用ファイルは入れません（アプリが ffmpeg をダウンロードすることもない）。
#   - パッケージは署名しません。Store に出すと Microsoft が署名します。
#     この PC で試すときは -Register -DevIdentity を付け、署名なしのフォルダー（dist\msix-layout）を試験用の ID でそのまま登録します。
#     右クリックメニューは、登録したあとエクスプローラーを再起動すると出ます。
# 必要なもの: Visual Studio（C++ によるデスクトップ開発）と Windows SDK（makeappx.exe）。
#   -Register で試すときは Microsoft.VCLibs.140.00.UWPDesktop（x64）も要ります（Visual Studio や Store のアプリと一緒に入っていることが多い。
#   なければ Windows SDK の ExtensionSDKs\Microsoft.VCLibs.Desktop\14.0\Appx\Retail\x64\Microsoft.VCLibs.x64.14.00.Desktop.appx を Add-AppxPackage で入れる）

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'dist'
}
if ($DevIdentity) {
    $IdentityName = 'PitaTrack.Dev'
    $Publisher = 'CN=PitaTrackDev'
}
elseif ($Register) {
    Write-Warning ('Store の ID（' + $IdentityName + '）のまま登録します。この PC に Store から入れる前に外してください。試すだけなら -DevIdentity を付けてください。')
}

# 同梱する ffmpeg（dev\ffmpeg-lgpl でビルドした LGPL 版。GitHub Release の ffmpeg-<版>-pitatrack<番号>）。
# 版を上げるときは、新しい Release の SHA256SUMS.txt の値で下を一緒に変えます
# （ZIP 版は tools\setup.ps1 の $Script:FfmpegUrl と $Script:FfmpegSha256）。
$ffmpegVersion = '9.0.2'
$ffmpegRelease = 'ffmpeg-9.0.2-pitatrack2'
$ffmpegFiles = [ordered]@{
    'ffmpeg-9.0.2-pitatrack2-lgpl-win64.zip'  = 'abcf7a24f697fb1886e52cdf382700493390a70e6b68b1abcc0f39c3ce03b2ad'
    'ffmpeg-9.0.2-pitatrack2-build-files.zip' = '9f391e9aaf02076892e696f9d0f9d1a8b6126a94d735433ae03be94e850ca356'
    'ffmpeg-9.0.2.tar.xz'                     = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
    'ffmpeg-9.0.2.tar.xz.asc'                 = 'd617fd94ea354dadd2a8bb16243d37c44e1e9729b06b6ad58fe30bfb0fa943f2'
}
$ffmpegReleaseUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/' + $ffmpegRelease
$ffmpegDownloadUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/download/' + $ffmpegRelease + '/'

# 同梱するボーカル分離のエンジン BSRoformer.cpp（Windows Vulkan 版の zip）。URL と SHA256 は、ZIP 版が初回にダウンロードするものと
# 同じにするため tools\mixtrack_ffmpeg_gui.ps1 の $Script:BsRoformerUrl と $Script:BsRoformerSha256 から読み取ります（下の $guiText）。
# zip にはライセンス文が入っていないので、BSRoformer.cpp（zip と同じタグ）と ggml の LICENSE を別にダウンロードして licenses\BSRoformer.cpp に入れます。
# ggml は BSRoformer.cpp の CI がビルド時に master を clone するので、そのビルドの時点の LICENSE（コミット）を指します。
# エンジンの版を上げるときは GUI 側の URL と SHA256 を変え、LICENSE が変わっていれば下の SHA256 も一緒に変えます。
$bsroformerRepoUrl = 'https://github.com/chenmozhijin/BSRoformer.cpp'
$bsroformerLicenseFiles = [ordered]@{
    'LICENSE.txt'      = @{ Url = 'https://raw.githubusercontent.com/chenmozhijin/BSRoformer.cpp/__TAG__/LICENSE'; Sha256 = '17e44bda56c005659ece5e56b6a8dfcb5361c2fa45e8e1b202ed1871c9c55dd7' }
    'ggml-LICENSE.txt' = @{ Url = 'https://raw.githubusercontent.com/ggml-org/ggml/bc0cac483baee73dec1b690b6d024a4dad13ab3e/LICENSE'; Sha256 = '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d' }
}

$guiText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\mixtrack_ffmpeg_gui.ps1') -Raw -Encoding UTF8
if ($guiText -notmatch '\$Script:BsRoformerUrl\s*=\s*''(https://[^'']+/releases/download/([^/'']+)/([^/'']+\.zip))''') {
    throw 'tools\mixtrack_ffmpeg_gui.ps1 から $Script:BsRoformerUrl を読み取れませんでした。'
}
$bsroformerUrl = $Matches[1]
$bsroformerTag = $Matches[2]
$bsroformerZipName = $Matches[3]
if ($guiText -notmatch '\$Script:BsRoformerSha256\s*=\s*''([0-9A-Fa-f]{64})''') {
    throw 'tools\mixtrack_ffmpeg_gui.ps1 から $Script:BsRoformerSha256 を読み取れませんでした。'
}
$bsroformerSha256 = $Matches[1]
$bsroformerReleaseUrl = $bsroformerRepoUrl + '/releases/tag/' + $bsroformerTag
$bsroformerLicenseFiles['LICENSE.txt'].Url = $bsroformerLicenseFiles['LICENSE.txt'].Url.Replace('__TAG__', $bsroformerTag)
# 分離モデルの配布元（licenses\README.txt に書く。モデル自体はパッケージに入れず、アプリが初回にダウンロードする）
if ($guiText -notmatch '\$Script:SeparationModelsReleaseUrl\s*=\s*''(https://[^'']+)/releases/download/([^/'']+)/?''') {
    throw 'tools\mixtrack_ffmpeg_gui.ps1 から $Script:SeparationModelsReleaseUrl を読み取れませんでした。'
}
$modelsReleaseUrl = $Matches[1] + '/releases/tag/' + $Matches[2]

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

# 前に -Register したパッケージがこのフォルダーを使っていたら、消す前に登録を外す。
# -Register のときは、別のフォルダー（ほかのワークツリーなど）から登録した署名なしのものも外す（同じ ID のまま登録し直せないため）。
# Store から入れたもの（署名あり）には触らない
$registered = @(Get-AppxPackage -Name $IdentityName | Where-Object { $_.InstallLocation -eq $layout -or ($Register -and $_.SignatureKind -eq 'None') })
foreach ($package in $registered) {
    Write-Host ('登録済みの ' + $package.PackageFullName + '（' + $package.InstallLocation + '）を外します。')
    $package | Remove-AppxPackage
}
if ($Register -and $null -eq (Get-AppxPackage -Name 'Microsoft.VCLibs.140.00.UWPDesktop' | Where-Object { $_.Architecture -eq 'X64' })) {
    # bs_roformer-cli.exe が使う Visual C++ ランタイム（マニフェストの PackageDependency）。Store に出すときは Store が一緒に入れる
    throw ('Microsoft.VCLibs.140.00.UWPDesktop（x64）が入っていないので、この PC に登録できません。' +
        'Windows SDK の ExtensionSDKs\Microsoft.VCLibs.Desktop\14.0\Appx\Retail\x64\Microsoft.VCLibs.x64.14.00.Desktop.appx を Add-AppxPackage で入れてください。')
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

# なければダウンロードし、SHA256 を確かめる（合わなければ消して止める。もう一度実行するとダウンロードし直す）
function Get-VerifiedFile {
    param([string]$Url, [string]$Path, [string]$Sha256)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host ('ダウンロード: ' + $Url)
        Invoke-WebRequest -Uri $Url -OutFile ($Path + '.part') -UseBasicParsing
        Move-Item -LiteralPath ($Path + '.part') -Destination $Path -Force
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -ne $Sha256) {
        Remove-Item -LiteralPath $Path -Force
        throw ((Split-Path -Leaf $Path) + ' の SHA256 が一致しません（' + $hash + '）。もう一度実行するとダウンロードし直します。')
    }
}

foreach ($name in $ffmpegFiles.Keys) {
    Get-VerifiedFile -Url ($ffmpegDownloadUrl + $name) -Path (Join-Path $ffmpegCache $name) -Sha256 $ffmpegFiles[$name]
}

# バイナリの zip: ffmpeg.exe は tools に、ほかのファイル（LICENSE.txt、BUILD.txt など）は licenses\FFmpeg に
$ffmpegExtract = Join-Path $objDir 'ffmpeg'
if ([string]::IsNullOrWhiteSpace($FfmpegDir)) {
    Expand-Archive -LiteralPath (Join-Path $ffmpegCache ($ffmpegRelease + '-lgpl-win64.zip')) -DestinationPath $ffmpegExtract -Force
}
else {
    # 手元のビルドで試す（licenses\README.txt の版と URL は Release のもののままなので、Store には出さない）
    Write-Warning ('Release の zip ではなく ' + $FfmpegDir + ' の ffmpeg を入れます（試験用）。')
    Copy-Item -LiteralPath $FfmpegDir -Destination $ffmpegExtract -Recurse
}
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

# ---- BSRoformer.cpp（ボーカル分離のエンジン。zip をダウンロードし、SHA256 を確かめて tools\bsroformer に入れる） ----

$bsroformerCache = Join-Path $OutputDir (Join-Path 'bsroformer-cache' $bsroformerTag)
New-Item -ItemType Directory -Path $bsroformerCache -Force | Out-Null
$bsroformerZip = Join-Path $bsroformerCache $bsroformerZipName
Get-VerifiedFile -Url $bsroformerUrl -Path $bsroformerZip -Sha256 $bsroformerSha256
foreach ($name in $bsroformerLicenseFiles.Keys) {
    Get-VerifiedFile -Url $bsroformerLicenseFiles[$name].Url -Path (Join-Path $bsroformerCache $name) -Sha256 $bsroformerLicenseFiles[$name].Sha256
}

# zip の exe と dll を tools\bsroformer に（GUI の Install-BsRoformer と同じ取り出し方）
$bsroformerExtract = Join-Path $objDir 'bsroformer'
Expand-Archive -LiteralPath $bsroformerZip -DestinationPath $bsroformerExtract -Force
$bsroformerDir = Join-Path $layout 'tools\bsroformer'
New-Item -ItemType Directory -Path $bsroformerDir -Force | Out-Null
Get-ChildItem -LiteralPath $bsroformerExtract -Recurse -File | Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.dll' } | Copy-Item -Destination $bsroformerDir
if (-not (Test-Path -LiteralPath (Join-Path $bsroformerDir 'bs_roformer-cli.exe') -PathType Leaf)) {
    throw 'ダウンロードした zip に bs_roformer-cli.exe が入っていません。'
}
$bsroformerLicenseDir = Join-Path $licenseDir 'BSRoformer.cpp'
New-Item -ItemType Directory -Path $bsroformerLicenseDir -Force | Out-Null
foreach ($name in $bsroformerLicenseFiles.Keys) {
    Copy-Item -LiteralPath (Join-Path $bsroformerCache $name) -Destination (Join-Path $bsroformerLicenseDir $name)
}

# ---- アプリのファイルとライセンス ----

Copy-Item -LiteralPath (Join-Path $repoRoot 'mixtrack_ffmpeg.bat') -Destination $layout
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $licenseDir 'PitaTrack')
foreach ($name in @('mixtrack_ffmpeg_gui.ps1', 'mixtrack_ffmpeg_gui.settings.json', 'pitatrack.ico')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot (Join-Path 'tools' $name)) -Destination (Join-Path $layout 'tools')
}
$licenseText = (Get-Content -LiteralPath (Join-Path $repoRoot 'msix\licenses-README.txt') -Raw -Encoding UTF8).Replace('__FFMPEG_VERSION__', $ffmpegVersion).Replace('__FFMPEG_RELEASE_URL__', $ffmpegReleaseUrl).Replace('__BSROFORMER_VERSION__', $bsroformerTag).Replace('__BSROFORMER_RELEASE_URL__', $bsroformerReleaseUrl).Replace('__MODELS_RELEASE_URL__', $modelsReleaseUrl)
if ($licenseText -match '__[A-Z_]+__') {
    throw ('msix\licenses-README.txt に埋めていない値があります: ' + $Matches[0])
}
[System.IO.File]::WriteAllText((Join-Path $licenseDir 'README.txt'), $licenseText, (New-Object System.Text.UTF8Encoding $true))

# ---- PitaTrack.exe ----

$iconPath = Join-Path $repoRoot 'tools\pitatrack.ico'
& $csc /nologo /target:winexe /platform:anycpu /optimize /codepage:65001 ('/win32icon:' + $iconPath) /r:System.Windows.Forms.dll ('/out:' + (Join-Path $layout 'PitaTrack.exe')) (Join-Path $repoRoot 'tools\PitaTrackLauncher.cs')
if ($LASTEXITCODE -ne 0) {
    throw 'PitaTrack.exe をビルドできませんでした。'
}

# ---- PitaTrackShell.dll（右クリックメニュー） ----

$shellSource = Join-Path $repoRoot 'msix\PitaTrackShell'
$clCommand = 'call "{0}" >nul 2>&1 && cl /nologo /LD /EHsc /O2 /W4 /utf-8 /MT /DUNICODE /D_UNICODE /Fo"{1}\\" "{2}\PitaTrackShell.cpp" /link /DEF:"{2}\PitaTrackShell.def" /OUT:"{3}\PitaTrackShell.dll" /IMPLIB:"{1}\PitaTrackShell.lib" shlwapi.lib shell32.lib ole32.lib user32.lib' -f $vcvars, $objDir, $shellSource, $layout
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

Write-Host ('作成しました: ' + $packagePath + ('（{0:N1} MB）' -f ((Get-Item -LiteralPath $packagePath).Length / 1MB)))
Write-Host ('  版 ' + $version + ' / ' + $IdentityName + ' / ' + $Publisher)
$ffmpegNote = if ([string]::IsNullOrWhiteSpace($FfmpegDir)) { $ffmpegRelease } else { '手元のビルド ' + $FfmpegDir + '（試験用）' }
Write-Host ('  ffmpeg ' + $ffmpegNote + ' / BSRoformer.cpp ' + $bsroformerTag)

if ($Register) {
    Add-AppxPackage -Register (Join-Path $layout 'AppxManifest.xml')
    Write-Host ('この PC に登録しました: ' + $layout)
    Write-Host '  右クリックメニューは、エクスプローラーを再起動すると出ます。'
    Write-Host ('  外すとき: Get-AppxPackage ' + $IdentityName + ' | Remove-AppxPackage')
}
