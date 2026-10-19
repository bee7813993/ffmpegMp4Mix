# 標準モデルをフォルダーから外してから Install-SeparationModel でダウンロードし、SHA256 照合とライセンス文の配置を確かめる
param([string[]]$Keys = @('kim', 'anvuew'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$guiScript = 'J:\Git\ffmpegMp4Mix\.claude\worktrees\vocal-separation-feasibility-fce4b3\tools\mixtrack_ffmpeg_gui.ps1'
$text = [System.IO.File]::ReadAllText($guiScript, [System.Text.Encoding]::UTF8)
$start = $text.IndexOf('$ErrorActionPreference')
$end = $text.IndexOf('Initialize-InputFiles -InputFiles $Files')
$body = $text.Substring($start, $end - $start)
$body = $body.Replace('$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path', '$Script:ScriptDir = ''J:\Git\ffmpegMp4Mix\.claude\worktrees\vocal-separation-feasibility-fce4b3\tools''')
$body = $body.Replace('$Script:CliMode = $CliDefaults.IsPresent', '$Script:CliMode = $false')
$body = $body.Replace("if (`$ValidateOnly) {`r`n    exit 0`r`n}", '')
$body = $body.Replace("if (`$CliDefaults) {`r`n    Write-CliDefaults -InputFiles `$Files -UseVideoAudio (`$UseVideoAudio -eq 1) -OutFile `$OutFile`r`n    exit 0`r`n}", '')
. ([scriptblock]::Create($body))

$backup = Join-Path ([System.IO.Path]::GetTempPath()) 'PitaTrack_models_backup'
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$state = [PSCustomObject]@{ Running = $true; CancelRequested = $false }
$lastText = ''
$onProgress = {
    param([int]$percent, [string]$text)
    if ($text -ne $lastText -and ($percent % 25 -eq 0 -or $text -notmatch '%')) { Write-Host ('{0,3}% {1}' -f $percent, $text); Set-Variable -Name lastText -Value $text -Scope 1 }
}
foreach ($key in $Keys) {
    $model = Get-SeparationModel -Models (Get-SeparationModelList) -Key $key
    Write-Host ('== {0}: {1}' -f $key, $model.Url)
    foreach ($ext in '.gguf', '.LICENSE.txt') {
        $path = [System.IO.Path]::ChangeExtension($model.Path, $ext)
        if (Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination (Join-Path $backup (Split-Path -Leaf $path)) -Force }
    }
    $before = Get-SeparationModel -Models (Get-SeparationModelList) -Key $key
    Write-Host ('   available before: {0}' -f $before.Available)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Install-SeparationModel -Model $model -OnProgress $onProgress -State $state
    $after = Get-SeparationModel -Models (Get-SeparationModelList) -Key $key
    $hash = (Get-FileHash -LiteralPath $after.Path -Algorithm SHA256).Hash
    $licensePath = [System.IO.Path]::ChangeExtension($after.Path, '.LICENSE.txt')
    Write-Host ('   downloaded in {0:N0} s, available={1}, size={2:N0}, sha256 ok={3}, license file={4}' -f $sw.Elapsed.TotalSeconds, $after.Available, (Get-Item -LiteralPath $after.Path).Length, ($hash -eq $model.Sha256), (Test-Path -LiteralPath $licensePath))
    if (Test-Path -LiteralPath $licensePath) { Write-Host ('   license head: ' + (Get-Content -LiteralPath $licensePath -TotalCount 1)) }
}
Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'done'
