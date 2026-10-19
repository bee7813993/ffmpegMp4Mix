# GUI を出さずに Invoke-Separation を試す。スクリプト本体の関数定義だけを読み込む。
param(
    [string]$SourceFile,
    [switch]$Karaoke,
    [switch]$VocalsOnly,
    [switch]$NoCut,
    [switch]$Reduce,
    [switch]$TwoStage,
    [switch]$AllCandidates,
    [string]$VocalModel = 'kim',
    [string]$LeadModel = 'frazer',
    [int]$ReduceDb = 12
)

$ErrorActionPreference = 'Stop'
$guiScript = 'J:\Git\ffmpegMp4Mix\.claude\worktrees\vocal-separation-feasibility-fce4b3\tools\mixtrack_ffmpeg_gui.ps1'
$text = [System.IO.File]::ReadAllText($guiScript, [System.Text.Encoding]::UTF8)

# 先頭の param ブロックと末尾の起動処理を外し、ScriptDir を固定する
$start = $text.IndexOf('$ErrorActionPreference')
$end = $text.IndexOf('Initialize-InputFiles -InputFiles $Files')
$body = $text.Substring($start, $end - $start)
$body = $body.Replace('$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path', '$Script:ScriptDir = ''J:\Git\ffmpegMp4Mix\.claude\worktrees\vocal-separation-feasibility-fce4b3\tools''')
$body = $body.Replace('$Script:CliMode = $CliDefaults.IsPresent', '$Script:CliMode = $false')
$body = $body.Replace("if (`$ValidateOnly) {`r`n    exit 0`r`n}", '')
$body = $body.Replace("if (`$CliDefaults) {`r`n    Write-CliDefaults -InputFiles `$Files -UseVideoAudio (`$UseVideoAudio -eq 1) -OutFile `$OutFile`r`n    exit 0`r`n}", '')
. ([scriptblock]::Create($body))

Write-Host '--- models'
Write-Host ('models dir: ' + (Get-SeparationModelsDir))
foreach ($m in Get-SeparationModelList) { Write-Host ('{0,-12} {1,-7} available={2} {3,-40} label="{4}" short="{5}"' -f $m.Key, $m.Role, $m.Available, $m.FileName, $m.Label, $m.Short) }
Write-Host ('--- saved separation settings: ' + (($Script:Settings.Separation | ConvertTo-Json -Compress)))

$state = [PSCustomObject]@{ Running = $true; CancelRequested = $false }
$onProgress = {
    param([int]$percent, [string]$text)
    Write-Host ('{0,3}% {1}' -f $percent, $text)
}
$request = [PSCustomObject]@{
    SourceFile    = $SourceFile
    VocalCut      = -not $NoCut.IsPresent
    VocalReduce   = $Reduce.IsPresent
    ReduceDb      = $ReduceDb
    Karaoke       = $Karaoke.IsPresent
    TwoStage      = $TwoStage.IsPresent
    VocalsOnly    = $VocalsOnly.IsPresent
    VocalModel    = $VocalModel
    LeadModel     = $LeadModel
    AllCandidates = $AllCandidates.IsPresent
    TrackNames    = (ConvertTo-SeparationSettings $Script:Settings.Separation).TrackNames
    Bitrate       = ConvertTo-ReencodeBitrate $Script:Settings.ReencodeBitrate
}
$models = @(Get-SeparationModelList)
Write-Host '--- plan'
$kinds = @(Get-SeparationKinds -Request $request -Models $models)
foreach ($k in $kinds) { Write-Host ('  kind {0,-8} stem={1,-22} suffix={2,-32} title={3}' -f $k.Key, $k.StemId, $k.Suffix, $k.Title) }
foreach ($r in @(Get-SeparationRunPlan -Kinds $kinds)) { Write-Host ('  run  {0,-22} model={1} input={2}' -f $r.Id, $r.ModelKey, $r.InputId) }

$ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
$cliPath = Get-BsRoformerCliPath
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$outputs = @(Invoke-Separation -Request $request -FfmpegPath $ffmpegPath -CliPath $cliPath -OnProgress $onProgress -State $state)
Write-Host ('elapsed {0:N1} s' -f $sw.Elapsed.TotalSeconds)
foreach ($output in $outputs) {
    Write-Host ('{0} -> {1} ({2:N1} MB)' -f $output.Title, (Split-Path -Leaf $output.Path), ((Get-Item -LiteralPath $output.Path).Length / 1MB))
}
