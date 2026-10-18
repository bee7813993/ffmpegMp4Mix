[CmdletBinding()]
param(
    [string]$OutputDir
)

# 配布用ZIP（dist\PitaTrack_v<版>.zip）を作ります。
# 版は tools\setup.ps1 の $Script:AppVersion から読み取ります。
# git で管理しているファイルだけを入れ、dev フォルダー、Store 版用の msix フォルダー、.git* は除きます（ffmpeg.exe は入りません）。

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'dist'
}

$setupText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\setup.ps1') -Raw -Encoding UTF8
if ($setupText -notmatch '\$Script:AppVersion\s*=\s*''([^'']+)''') {
    throw 'tools\setup.ps1 から版を読み取れませんでした。'
}
$version = $Matches[1]

$files = @(git -C $repoRoot -c core.quotepath=off ls-files) | Where-Object { $_ -notmatch '^(dev/|msix/|\.git)' }
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
    throw 'git ls-files でファイル一覧を取得できませんでした。'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$zipPath = Join-Path (Resolve-Path -LiteralPath $OutputDir) ('PitaTrack_v{0}.zip' -f $version)
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# ZIP内のパス区切りは / にする（Compress-Archive は \ になるため使わない）
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $sourcePath = Join-Path $repoRoot ($file -replace '/', '\')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $sourcePath, 'PitaTrack/' + $file, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}
finally {
    $archive.Dispose()
}

Write-Host ('作成しました: ' + $zipPath)
Write-Host ('  ' + $files.Count + ' ファイル')
