[CmdletBinding()]
param(
    # 確かめる ffmpeg.exe
    [Parameter(Mandatory = $true)]
    [string]$FfmpegPath,
    # make_test_media.py で作った素材のフォルダー
    [Parameter(Mandatory = $true)]
    [string]$MediaDir,
    # 出力、ログ、結果（test-report.md）を置くフォルダー
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    # ライセンスと部品の確認を飛ばし、使い方だけを確かめる（ほかの ffmpeg と比べるとき）
    [switch]$UsageOnly
)

# ぴたトラックの使い方どおりに ffmpeg.exe を動かして確かめます。
#   1. -version、-buildconf、-L と部品の一覧: LGPL で、GPL の部品も外部のライブラリも入っていないこと
#   2. tools\mixtrack_ffmpeg_gui.ps1 の Build-FfmpegArguments が作る引数で MP4 にまとめる
#      （-itsoffset で遅らせるコピー、-ss で早めるコピー、adelay と aac の再エンコード）
#      まとめた各トラックの音の出だしが、動画の音声とそろっていることも確かめる
#   3. 自動調整の AudioOffsetAnalyzer（-f f32le で標準出力に取り出す）で各形式を読み、ずれを推定する
#   4. ボーカル分離: ConvertTo-SeparationWav（44.1 kHz float の WAV に変換）、New-SeparationDerivedTrack（amerge・pan・alimiter で
#      元音源 − ステム × k を .m4a に書く）、Export-SeparationStem（ステムを .m4a に書く）。ステムには元音源そのものを使い、
#      オフボーカル（1 と −1）がほぼ無音に、リデュース（−8 dB）が元の約 40% になることを見る。
#      MP4 の中の AC-3 / E-AC-3 の元音源も変換できることを見る
# 関数と C# は GUI のスクリプトから読み込むので、GUI を変えればこのテストもそれに従います。
# ファイル名、フォルダー名、トラック名には日本語と空白を使います。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$guiScript = Join-Path $repoRoot 'tools\mixtrack_ffmpeg_gui.ps1'
$FfmpegPath = (Resolve-Path -LiteralPath $FfmpegPath).Path
$MediaDir = (Resolve-Path -LiteralPath $MediaDir).Path
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$media = [System.IO.File]::ReadAllText((Join-Path $MediaDir 'media.json'), $utf8) | ConvertFrom-Json

# 音の出だしの許容差（ADTS の AAC は先頭の 1024 サンプルを捨てないので、そのぶんも含む）
$onsetToleranceMs = 40
# 自動調整の許容差
$autoToleranceMs = 25

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace PitaTrackFfmpegTest
{
    public class RunResult
    {
        public int ExitCode;
        public byte[] Output;
        public string Error;
        public string CommandLine;
    }

    public static class Ffmpeg
    {
        public static RunResult Run(string fileName, string arguments, string workingDirectory)
        {
            ProcessStartInfo info = new ProcessStartInfo(fileName, arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardErrorEncoding = Encoding.UTF8;
            if (!string.IsNullOrEmpty(workingDirectory))
            {
                info.WorkingDirectory = workingDirectory;
            }

            using (Process process = Process.Start(info))
            {
                Task<string> error = process.StandardError.ReadToEndAsync();
                MemoryStream output = new MemoryStream();
                process.StandardOutput.BaseStream.CopyTo(output);
                process.WaitForExit();

                RunResult result = new RunResult();
                result.ExitCode = process.ExitCode;
                result.Output = output.ToArray();
                result.Error = error.Result;
                return result;
            }
        }

        public static float[] ToSamples(byte[] bytes)
        {
            float[] samples = new float[bytes.Length / 4];
            Buffer.BlockCopy(bytes, 0, samples, 0, samples.Length * 4);
            return samples;
        }

        // 振幅が初めて threshold 以上になる位置（秒）。なければ -1
        public static double FindOnset(float[] samples, int sampleRate, double threshold)
        {
            for (int i = 0; i < samples.Length; i++)
            {
                if (Math.Abs(samples[i]) >= threshold)
                {
                    return (double)i / sampleRate;
                }
            }
            return -1;
        }
    }
}
'@

# ---- ぴたトラックの関数と C# を GUI のスクリプトから読み込む ----

$tokens = $null
$parseErrors = $null
$guiAst = [System.Management.Automation.Language.Parser]::ParseFile($guiScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('GUI のスクリプトを読めませんでした: ' + $parseErrors[0].Message)
}
foreach ($functionName in @('Build-FfmpegArguments', 'ConvertTo-DelayMode', 'Test-ReencodeBitrateText', 'ConvertTo-ReencodeBitrate', 'Format-FfmpegDuration', 'ConvertTo-CommandLineArgument', 'New-TrackItem',
        'Get-CommandLine', 'Read-SharedTextFile', 'Invoke-SeparationProcess', 'Assert-SeparationProcessSucceeded', 'ConvertTo-SeparationWav', 'Get-SeparationReduceGains', 'New-SeparationDerivedTrack', 'Export-SeparationStem')) {
    $definition = $guiAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    if ($null -eq $definition) {
        throw ($functionName + ' が ' + $guiScript + ' に見つかりません。')
    }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# ボーカル分離の関数が使うリミッターの指定（スクリプト変数）も GUI から読む。
# Invoke-SeparationProcess は待つあいだ WinForms の DoEvents を呼ぶので、そのアセンブリも読み込む
$limiterAssignment = $guiAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$Script:SeparationLimiterFilter'
    }, $true)
if ($null -eq $limiterAssignment) {
    throw ('$Script:SeparationLimiterFilter が ' + $guiScript + ' に見つかりません。')
}
. ([scriptblock]::Create($limiterAssignment.Extent.Text))
Add-Type -AssemblyName System.Windows.Forms

$addType = $guiAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type' -and
        @($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'TypeDefinition' }).Count -gt 0
    }, $true)
if ($null -eq $addType) {
    throw ('AudioOffsetAnalyzer の C# が ' + $guiScript + ' に見つかりません。')
}
$elements = @($addType.CommandElements)
for ($index = 0; $index -lt $elements.Count; $index++) {
    if ($elements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq 'TypeDefinition') {
        Add-Type -TypeDefinition $elements[$index + 1].Value -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
        break
    }
}

# ---- 道具 ----

$Script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Group,
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    $Script:Results.Add([PSCustomObject]@{ Group = $Group; Name = $Name; Ok = $Ok; Detail = $Detail })
    $mark = if ($Ok) { 'OK' } else { 'NG' }
    Write-Host ('{0} [{1}] {2}: {3}' -f $mark, $Group, $Name, $Detail)
}

function Invoke-TestFfmpeg {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory = $OutputDir
    )

    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $result = [PitaTrackFfmpegTest.Ffmpeg]::Run($FfmpegPath, $argumentLine, $WorkingDirectory)
    $result.CommandLine = (ConvertTo-CommandLineArgument $FfmpegPath) + ' ' + $argumentLine
    return $result
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Format-Ms {
    param([double]$Seconds)

    return ([Math]::Round($Seconds * 1000)).ToString() + ' ms'
}

# ffmpeg -i で一覧を読む（出力を指定しないので終了コードは 1 になる）
function Get-StreamInfo {
    param([string]$Path)

    $result = Invoke-TestFfmpeg -Arguments @('-hide_banner', '-nostdin', '-i', $Path)
    $streams = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in ($result.Error -split "`r?`n")) {
        if ($line -match '^\s*Stream #0:(\d+)[^:]*: (Video|Audio): (\w+)') {
            $current = [PSCustomObject]@{ Type = $Matches[2]; Codec = $Matches[3]; Title = $null; Handler = $null }
            $streams.Add($current)
        }
        elseif ($null -ne $current -and $line -match '^\s+(title|name)\s*: (.*)$') {
            # MP4 では title は udta の name として書かれ、読むと name になる
            $current.Title = $Matches[2].Trim()
        }
        elseif ($null -ne $current -and $line -match '^\s+handler_name\s*: (.*)$') {
            $current.Handler = $Matches[1].Trim()
        }
    }
    return , $streams.ToArray()
}

# まとめた MP4 のトラックを、開始の遅れを無音で埋めて 8 kHz モノラルで取り出す
function Get-PaddedTrackSamples {
    param(
        [string]$Path,
        [int]$AudioIndex
    )

    $result = Invoke-TestFfmpeg -Arguments @('-v', 'error', '-nostdin', '-i', $Path, '-map', ('0:a:' + $AudioIndex),
        '-af', 'aresample=async=1:first_pts=0', '-ac', '1', '-ar', '8000', '-f', 'f32le', '-')
    if ($result.ExitCode -ne 0) {
        throw ('トラックを取り出せませんでした: ' + $result.Error.Trim())
    }
    return , [PitaTrackFfmpegTest.Ffmpeg]::ToSamples($result.Output)
}

function Get-ComponentNames {
    param([string]$Option)

    $result = Invoke-TestFfmpeg -Arguments @('-hide_banner', ('-' + $Option))
    $text = $utf8.GetString($result.Output)
    $names = New-Object System.Collections.Generic.List[string]
    $started = $Option -eq 'protocols' -or $Option -eq 'bsfs'
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $started) {
            $started = $line -match '^\s*-{3,}\s*$'
            continue
        }
        if ($Option -eq 'protocols' -or $Option -eq 'bsfs') {
            if ($line -match '^\s*(\w+)\s*$') {
                $names.Add($Matches[1])
            }
        }
        elseif ($line -match '^\s*\S+\s+(\S+)') {
            foreach ($name in $Matches[1].Split(',')) {
                $names.Add($name)
            }
        }
    }
    return [PSCustomObject]@{ Names = @($names | Select-Object -Unique); Text = $text }
}

# ---- 1. ライセンスと部品 ----

$versionResult = Invoke-TestFfmpeg -Arguments @('-hide_banner', '-version')
$versionText = $utf8.GetString($versionResult.Output)
$versionLine = ($versionText -split "`r?`n")[0]
Write-Utf8File (Join-Path $OutputDir 'ffmpeg-version.txt') $versionText

if (-not $UsageOnly) {
    $sourceEnv = @{}
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'ffmpeg-source.env'))) {
        if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') {
            $sourceEnv[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $expectedVersion = 'ffmpeg version {0}-pitatrack{1} ' -f $sourceEnv['FFMPEG_VERSION'], $sourceEnv['PITATRACK_BUILD']
    Add-Result 'ライセンス' '-version' ($versionLine.StartsWith($expectedVersion)) $versionLine

    $buildconf = $utf8.GetString((Invoke-TestFfmpeg -Arguments @('-hide_banner', '-buildconf')).Output)
    Write-Utf8File (Join-Path $OutputDir 'ffmpeg-buildconf.txt') $buildconf
    $forbidden = @([regex]::Matches($buildconf, '--enable-(gpl|nonfree|version3|lib[\w-]+)\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
    $buildconfOk = $buildconf.Contains('--disable-everything') -and $buildconf.Contains('--disable-autodetect') -and $forbidden.Count -eq 0
    $detail = if ($forbidden.Count -gt 0) { '含まれている: ' + ($forbidden -join ' ') } else { '--enable-gpl、--enable-nonfree、--enable-version3、--enable-lib… なし。--disable-everything と --disable-autodetect あり' }
    Add-Result 'ライセンス' '-buildconf' $buildconfOk $detail

    $license = $utf8.GetString((Invoke-TestFfmpeg -Arguments @('-hide_banner', '-L')).Output)
    Write-Utf8File (Join-Path $OutputDir 'ffmpeg-license.txt') $license
    $licenseFlat = ($license -replace '\s+', ' ')
    $lgplOk = $licenseFlat.Contains('under the terms of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of the License') -and
        -not $licenseFlat.Contains('GNU General Public License as published')
    Add-Result 'ライセンス' '-L' $lgplOk 'GNU Lesser General Public License version 2.1 or later'

    $required = [ordered]@{
        decoders  = @('aac', 'mp3float', 'mp3', 'vorbis', 'opus', 'flac', 'alac', 'pcm_u8', 'pcm_s16le', 'pcm_s24le', 'pcm_s32le', 'pcm_f32le', 'ac3', 'eac3')
        encoders  = @('aac', 'pcm_f32le')
        demuxers  = @('mov', 'mp4', 'm4a', 'aac', 'mp3', 'wav', 'flac', 'ogg')
        muxers    = @('mp4', 'f32le', 'wav', 'ipod')
        filters   = @('adelay', 'aresample', 'amerge', 'pan', 'alimiter')
        protocols = @('file', 'pipe')
        bsfs      = @('aac_adtstoasc')
    }
    $componentText = New-Object System.Text.StringBuilder
    foreach ($option in $required.Keys) {
        $components = Get-ComponentNames $option
        [void]$componentText.AppendLine('==== ffmpeg -' + $option).AppendLine($components.Text)
        $missing = @($required[$option] | Where-Object { $components.Names -notcontains $_ })
        $external = @($components.Names | Where-Object { $_ -like 'lib*' })
        $ok = $missing.Count -eq 0 -and $external.Count -eq 0
        $detail = ($components.Names -join ', ')
        if ($option -eq 'encoders') {
            # エンコーダーは aac と pcm_f32le だけ（x264 などは入っていない）
            $ok = $ok -and $components.Names.Count -eq $required[$option].Count
        }
        if ($missing.Count -gt 0) {
            $detail = '足りない: ' + ($missing -join ', ') + ' / ある: ' + $detail
        }
        if ($external.Count -gt 0) {
            $detail = '外部ライブラリ: ' + ($external -join ', ') + ' / ' + $detail
        }
        Add-Result '部品' ('-' + $option) $ok $detail
    }
    Write-Utf8File (Join-Path $OutputDir 'ffmpeg-components.txt') $componentText.ToString()
}

# ---- 素材を日本語と空白の入った名前で用意する ----

$workDir = Join-Path $OutputDir '作業 フォルダー'
if (Test-Path -LiteralPath $workDir) {
    Remove-Item -LiteralPath $workDir -Recurse -Force
}
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$videoPath = Join-Path $workDir 'カラオケ 動画.mp4'
Copy-Item -LiteralPath (Join-Path $MediaDir $media.video) -Destination $videoPath
$files = @()
foreach ($file in $media.files) {
    $path = Join-Path $workDir ('音源 ' + $file.file)
    Copy-Item -LiteralPath (Join-Path $MediaDir $file.file) -Destination $path
    $files += [PSCustomObject]@{ Name = $file.file; Path = $path; Kind = $file.kind; Start = [double]$file.start; Codec = $file.codec }
}
$offsetForKind = @{ base = 0; early = [int]$media.earlyMs; late = - [int]$media.lateMs }

# ---- 2. MP4 にまとめる（ぴたトラックの Build-FfmpegArguments の引数そのもの） ----

$scenarios = @(
    @{ Name = 'copy-delay'; DelayMode = 'copy'; Kind = 'early'; Label = 'コピーで遅らせる（-itsoffset）' },
    @{ Name = 'copy-advance'; DelayMode = 'copy'; Kind = 'late'; Label = 'コピーで早める（-ss）' },
    @{ Name = 'copy-zero'; DelayMode = 'copy'; Kind = 'base'; Label = 'コピー（ずれなし）' },
    @{ Name = 'reencode-delay'; DelayMode = 'reencode'; Kind = 'early'; Label = 'AAC で再エンコードして遅らせる（adelay）' }
)

foreach ($scenario in $scenarios) {
    $group = 'まとめる: ' + $scenario.Label
    $offsetMs = $offsetForKind[$scenario.Kind]
    $tracks = @(New-TrackItem -SourceFile $videoPath -IsVideoAudio $true -Title '動画の音声')
    $expected = @([PSCustomObject]@{ Name = '動画の音声'; Codec = 'aac' })
    foreach ($file in @($files | Where-Object { $_.Kind -eq $scenario.Kind })) {
        $title = 'ガイド ' + $file.Name
        $tracks += New-TrackItem -SourceFile $file.Path -IsVideoAudio $false -Title $title -OffsetMs $offsetMs
        $codec = if ($scenario.DelayMode -eq 'reencode' -and $offsetMs -gt 0) { 'aac' } else { $file.Codec }
        $expected += [PSCustomObject]@{ Name = $title; Codec = $codec }
    }

    $outputPath = Join-Path $workDir ('カラオケ 動画_' + $scenario.Name + '.mp4')
    $Script:VideoFile = $videoPath
    $settings = [PSCustomObject]@{ DelayMode = $scenario.DelayMode; ReencodeBitrate = '256k' }
    $arguments = @('-y') + @(Build-FfmpegArguments -TrackItems $tracks -OutputPath $outputPath -Settings $settings)
    $result = Invoke-TestFfmpeg -Arguments $arguments -WorkingDirectory $workDir
    Write-Utf8File ([System.IO.Path]::ChangeExtension($outputPath, '.ffmpeg.log')) ($result.CommandLine + "`r`n`r`n" + $result.Error)

    $ok = $result.ExitCode -eq 0 -and (Test-Path -LiteralPath $outputPath)
    $detail = '終了コード ' + $result.ExitCode + '、トラック ' + $tracks.Count
    if (-not $ok) {
        $detail += ' / ' + (($result.Error.Trim() -split "`r?`n") | Select-Object -Last 3) -join ' '
    }
    Add-Result $group 'ffmpeg' $ok $detail
    if (-not $ok) {
        continue
    }

    $streams = Get-StreamInfo $outputPath
    $video = @($streams | Where-Object { $_.Type -eq 'Video' })
    $audio = @($streams | Where-Object { $_.Type -eq 'Audio' })
    Add-Result $group '映像' ($video.Count -eq 1 -and $video[0].Codec -eq 'h264') ('映像 ' + $video.Count + ' 本（' + (($video | ForEach-Object { $_.Codec }) -join ', ') + '、コピー）')
    if ($audio.Count -ne $expected.Count) {
        Add-Result $group '音声の数' $false ('音声 ' + $audio.Count + ' 本（' + $expected.Count + ' 本のはず）')
        continue
    }

    for ($index = 0; $index -lt $expected.Count; $index++) {
        $want = $expected[$index]
        $stream = $audio[$index]
        $samples = Get-PaddedTrackSamples -Path $outputPath -AudioIndex $index
        $onset = [PitaTrackFfmpegTest.Ffmpeg]::FindOnset($samples, 8000, 0.1)
        $errorMs = [Math]::Round(($onset - [double]$media.onset) * 1000)
        $ok = $stream.Codec -eq $want.Codec -and $stream.Handler -eq $want.Name -and $stream.Title -eq $want.Name -and
            $onset -ge 0 -and [Math]::Abs($errorMs) -le $onsetToleranceMs
        $detail = '{0}、名前「{1}」、出だし {2}（動画との差 {3} ms）' -f $stream.Codec, $stream.Handler, (Format-Ms $onset), $errorMs
        Add-Result $group ('音声 ' + $index + ': ' + $want.Name) $ok $detail
    }
}

# ---- 3. 自動調整: -f f32le で取り出して解析する（AudioOffsetAnalyzer.Decode / Analyze） ----

# 素材は 30 秒と短いので、ずれを探す範囲を 20 秒にする
# （既定の 180 秒は、2 つの長さの合計を超えると NormalizedCorrelation が配列の範囲を超える）
[AudioOffsetAnalyzer]::MaxLagSeconds = 20.0

$referenceSamples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $videoPath)
$reference = [AudioOffsetAnalyzer]::Extract($referenceSamples)
$referenceOnset = [PitaTrackFfmpegTest.Ffmpeg]::FindOnset($referenceSamples, [AudioOffsetAnalyzer]::SampleRate, 0.1)
Add-Result '取り出す（-f f32le）' $media.video ([Math]::Abs($referenceOnset - [double]$media.onset) * 1000 -le $onsetToleranceMs) ('{0} サンプル、出だし {1}' -f $referenceSamples.Length, (Format-Ms $referenceOnset))

foreach ($file in $files) {
    try {
        $samples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $file.Path)
    }
    catch {
        Add-Result '取り出す（-f f32le）' $file.Name $false $_.Exception.GetBaseException().Message
        continue
    }
    $seconds = $samples.Length / [double][AudioOffsetAnalyzer]::SampleRate
    $onset = [PitaTrackFfmpegTest.Ffmpeg]::FindOnset($samples, [AudioOffsetAnalyzer]::SampleRate, 0.1)
    $ok = [Math]::Abs($seconds - [double]$media.length) -le 0.1 -and [Math]::Abs($onset - $file.Start) * 1000 -le $onsetToleranceMs
    Add-Result '取り出す（-f f32le）' $file.Name $ok ('{0}、長さ {1:0.000} 秒、出だし {2}（{3} のはず）' -f $file.Codec, $seconds, (Format-Ms $onset), (Format-Ms $file.Start))

    $want = $offsetForKind[$file.Kind]
    $analysis = [AudioOffsetAnalyzer]::Analyze($reference, [AudioOffsetAnalyzer]::Extract($samples))
    $ok = [Math]::Abs($analysis.OffsetMs - $want) -le $autoToleranceMs -and $analysis.Level -ne '低'
    Add-Result '自動調整' $file.Name $ok ('推定 {0} ms（{1} ms のはず）、信頼度 {2}' -f $analysis.OffsetMs, $want, $analysis.Level)
}

# ---- 4. ボーカル分離: 44.1 kHz float の WAV に変換し、ステムとの差分を .m4a に書く（GUI の関数そのもの） ----

# ステムには元音源そのものを使う。MixGain × 元音源 + StemGain × ステム なので、オフボーカル（1 と −1）は無音、
# リデュース −8 dB は元の 10^(−8/20) ≈ 0.40 倍になるはず（AAC とリミッターのぶんの誤差を見込む）
$separationDir = Join-Path $workDir '分離 作業'
New-Item -ItemType Directory -Path $separationDir -Force | Out-Null
$mixWav = Join-Path $separationDir 'mix.wav'
$separationLog = Join-Path $separationDir 'ffmpeg-error.log'
$mixPeak = 0.0
try {
    ConvertTo-SeparationWav -FfmpegPath $FfmpegPath -SourceFile $videoPath -OutputPath $mixWav -LogPath $separationLog -State $null
    $info = (Invoke-TestFfmpeg -Arguments @('-hide_banner', '-nostdin', '-i', $mixWav)).Error
    $audioLine = (($info -split "`r?`n") | Where-Object { $_ -match 'Audio:' } | Select-Object -First 1)
    $mixSamples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $mixWav)
    foreach ($sample in $mixSamples) { $mixPeak = [Math]::Max($mixPeak, [Math]::Abs($sample)) }
    $ok = ($audioLine -match 'pcm_f32le') -and ($audioLine -match '44100 Hz') -and ($audioLine -match 'stereo') -and $mixPeak -gt 0.05
    Add-Result 'ボーカル分離' '変換（pcm_f32le、44100 Hz、ステレオの WAV）' $ok ('{0} / ピーク {1:0.000}' -f $audioLine.Trim(), $mixPeak)
}
catch {
    Add-Result 'ボーカル分離' '変換（pcm_f32le、44100 Hz、ステレオの WAV）' $false $_.Exception.GetBaseException().Message
}

# MP4 の中の AC-3 / E-AC-3 の元音源も、同じ変換で 44.1 kHz float の WAV にできること
foreach ($file in @($files | Where-Object { $_.Codec -eq 'ac3' -or $_.Codec -eq 'eac3' })) {
    $wavPath = Join-Path $separationDir ([System.IO.Path]::GetFileNameWithoutExtension($file.Name) + '.wav')
    try {
        ConvertTo-SeparationWav -FfmpegPath $FfmpegPath -SourceFile $file.Path -OutputPath $wavPath -LogPath $separationLog -State $null
        $info = (Invoke-TestFfmpeg -Arguments @('-hide_banner', '-nostdin', '-i', $wavPath)).Error
        $audioLine = (($info -split "`r?`n") | Where-Object { $_ -match 'Audio:' } | Select-Object -First 1)
        $samples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $wavPath)
        $onset = [PitaTrackFfmpegTest.Ffmpeg]::FindOnset($samples, [AudioOffsetAnalyzer]::SampleRate, 0.1)
        $ok = ($audioLine -match 'pcm_f32le') -and ($audioLine -match '44100 Hz') -and [Math]::Abs($onset - $file.Start) * 1000 -le $onsetToleranceMs
        Add-Result 'ボーカル分離' ('変換: ' + $file.Name) $ok ('{0} / 出だし {1}（{2} のはず）' -f $audioLine.Trim(), (Format-Ms $onset), (Format-Ms $file.Start))
    }
    catch {
        Add-Result 'ボーカル分離' ('変換: ' + $file.Name) $false $_.Exception.GetBaseException().Message
    }
}

if ($mixPeak -gt 0.05) {
    $reduceGains = Get-SeparationReduceGains -Db 8
    $derived = @(
        @{ Name = 'オフボーカル（元音源 − ステム）'; File = 'オフボーカル.m4a'; MixGain = 1.0; StemGain = -1.0; Ratio = 0.0; Tolerance = 0.03 },
        @{ Name = 'リデュース −8 dB'; File = 'リデュース.m4a'; MixGain = [double]$reduceGains[0]; StemGain = [double]$reduceGains[1]; Ratio = [Math]::Pow(10.0, -8.0 / 20.0); Tolerance = 0.08 }
    )
    foreach ($case in $derived) {
        $outputPath = Join-Path $separationDir $case.File
        try {
            New-SeparationDerivedTrack -FfmpegPath $FfmpegPath -MixWav $mixWav -StemWav $mixWav -MixGain $case.MixGain -StemGain $case.StemGain -OutputPath $outputPath -Bitrate '256k' -LogPath $separationLog -State $null
            $streams = @(Get-StreamInfo $outputPath | Where-Object { $_.Type -eq 'Audio' })
            $samples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $outputPath)
            $peak = 0.0
            foreach ($sample in $samples) { $peak = [Math]::Max($peak, [Math]::Abs($sample)) }
            $ratio = $peak / $mixPeak
            $ok = $streams.Count -eq 1 -and $streams[0].Codec -eq 'aac' -and [Math]::Abs($ratio - $case.Ratio) -le $case.Tolerance
            Add-Result 'ボーカル分離' $case.Name $ok ('{0}、ピーク比 {1:0.000}（{2:0.000} のはず）' -f (($streams | ForEach-Object { $_.Codec }) -join ', '), $ratio, $case.Ratio)
        }
        catch {
            Add-Result 'ボーカル分離' $case.Name $false $_.Exception.GetBaseException().Message
        }
    }

    $stemPath = Join-Path $separationDir 'ボーカルのみ.m4a'
    try {
        Export-SeparationStem -FfmpegPath $FfmpegPath -StemWav $mixWav -OutputPath $stemPath -Bitrate '256k' -LogPath $separationLog -State $null
        $streams = @(Get-StreamInfo $stemPath | Where-Object { $_.Type -eq 'Audio' })
        $samples = [AudioOffsetAnalyzer]::Decode($FfmpegPath, $stemPath)
        $peak = 0.0
        foreach ($sample in $samples) { $peak = [Math]::Max($peak, [Math]::Abs($sample)) }
        $ratio = $peak / $mixPeak
        $ok = $streams.Count -eq 1 -and $streams[0].Codec -eq 'aac' -and $ratio -ge 0.85 -and $ratio -le 1.05
        Add-Result 'ボーカル分離' 'ステムの書き出し（alimiter）' $ok ('{0}、ピーク比 {1:0.000}' -f (($streams | ForEach-Object { $_.Codec }) -join ', '), $ratio)
    }
    catch {
        Add-Result 'ボーカル分離' 'ステムの書き出し（alimiter）' $false $_.Exception.GetBaseException().Message
    }
}

# ---- 結果 ----

$failed = @($Script:Results | Where-Object { -not $_.Ok })
$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine('## ぴたトラックの使い方で ffmpeg.exe を確かめた結果').AppendLine()
[void]$report.AppendLine('- ffmpeg: `' + $versionLine + '`')
[void]$report.AppendLine('- 結果: ' + ($Script:Results.Count - $failed.Count) + ' / ' + $Script:Results.Count + ' 件 OK').AppendLine()
foreach ($group in @($Script:Results | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    [void]$report.AppendLine('### ' + $group).AppendLine()
    [void]$report.AppendLine('| | 確認 | 内容 |').AppendLine('|---|---|---|')
    foreach ($item in @($Script:Results | Where-Object { $_.Group -eq $group })) {
        $mark = if ($item.Ok) { 'OK' } else { '**NG**' }
        [void]$report.AppendLine(('| {0} | {1} | {2} |' -f $mark, $item.Name, ($item.Detail -replace '\|', '\|')))
    }
    [void]$report.AppendLine()
}
Write-Utf8File (Join-Path $OutputDir 'test-report.md') $report.ToString()
if (-not [string]::IsNullOrEmpty($env:GITHUB_STEP_SUMMARY)) {
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $report.ToString(), $utf8)
}

Write-Host ''
Write-Host ('{0} / {1} 件 OK。結果: {2}' -f ($Script:Results.Count - $failed.Count), $Script:Results.Count, (Join-Path $OutputDir 'test-report.md'))
if ($failed.Count -gt 0) {
    exit 1
}
