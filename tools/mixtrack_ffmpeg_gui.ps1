[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$ValidateOnly,
    [switch]$CliDefaults,
    [int]$UseVideoAudio = 0,
    [string]$OutFile,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files
)

$ErrorActionPreference = 'Stop'
$Script:CliMode = $CliDefaults.IsPresent
$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:RootDir = $Script:ScriptDir
$parentDir = Split-Path -Parent $Script:ScriptDir
if (-not (Test-Path -LiteralPath (Join-Path $Script:RootDir 'mixtrack_ffmpeg.bat')) -and
    -not [string]::IsNullOrWhiteSpace($parentDir) -and
    (Test-Path -LiteralPath (Join-Path $parentDir 'mixtrack_ffmpeg.bat'))) {
    $Script:RootDir = $parentDir
}
$Script:ToolDir = Join-Path $Script:RootDir 'tools'
$Script:AppDir = $Script:RootDir
$Script:ConfigPath = Join-Path $Script:ScriptDir 'mixtrack_ffmpeg_gui.settings.json'
$Script:Settings = $null
$Script:VideoFile = $null
$Script:AudioFiles = @()
$Script:DefaultOutputPath = $null
$Script:SavedOutputPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$Script:AutoOffsetReference = $null

function New-DefaultSettings {
    [PSCustomObject]@{
        TrackNames          = [PSCustomObject]@{
            '1' = 'オンボーカル'
            '2' = 'オフボーカル'
        }
        LaterName           = 'トラック'
        OutputSuffix        = '_mixed'
        TrackNameCandidates = @('オンボーカル', 'オフボーカル', 'トラック')
        DelayMode           = 'copy'
        ReencodeBitrate     = '256k'
        OffsetStepMs        = 100
        AutoOffsetAlways    = $false
    }
}

function ConvertTo-SettingFlag {
    param([object]$Value)

    if ($Value -is [bool]) {
        return $Value
    }

    return ([string]$Value).Trim() -eq 'true'
}

function ConvertTo-OffsetStepMs {
    param([object]$Value)

    $stepMs = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$stepMs) -and $stepMs -gt 0) {
        return $stepMs
    }

    return 100
}

function ConvertTo-DelayMode {
    param([object]$Value)

    if (([string]$Value).Trim() -eq 'reencode') {
        return 'reencode'
    }

    return 'copy'
}

function Test-ReencodeBitrateText {
    param([string]$Value)

    return ([string]$Value).Trim() -match '^\d+(\.\d+)?[kKmM]?$'
}

function ConvertTo-ReencodeBitrate {
    param([object]$Value)

    $text = ([string]$Value).Trim()
    if (Test-ReencodeBitrateText $text) {
        return $text
    }

    return '256k'
}

function Get-SupportFilePath {
    param([string]$FileName)

    $directories = @($Script:ToolDir, $Script:ScriptDir, $Script:RootDir)
    foreach ($directory in $directories) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        $path = Join-Path $directory $FileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    return Join-Path $Script:ToolDir $FileName
}

function Read-BatchDefaultSettings {
    $settings = New-DefaultSettings
    $map = Get-TrackNameMap $settings
    $laterName = [string]$settings.LaterName
    $suffix = [string]$settings.OutputSuffix
    $delayMode = [string]$settings.DelayMode
    $reencodeBitrate = [string]$settings.ReencodeBitrate
    $batchPath = Join-Path $Script:RootDir 'mixtrack_ffmpeg.bat'

    if (-not (Test-Path -LiteralPath $batchPath)) {
        return $settings
    }

    foreach ($line in (Get-Content -LiteralPath $batchPath -Encoding Default)) {
        if ($line -match '^\s*:') {
            break
        }
        if ($line -match '^\s*set\s+"?TRACKNAME_(\d+)=(.*?)"?\s*$' -and $Matches[2] -notlike '*%*') {
            $map[$Matches[1]] = $Matches[2]
            continue
        }
        if ($line -match '^\s*set\s+"?TRACKNAME_LATER=(.*?)"?\s*$' -and $Matches[1] -notlike '*%*') {
            $laterName = $Matches[1]
            continue
        }
        if ($line -match '^\s*(?:if\s+.*?\s+)?set\s+"?OUTPUT_SUFFIX=(.*?)"?\s*$' -and $Matches[1] -notlike '*%*') {
            $suffix = $Matches[1]
            continue
        }
        if ($line -match '^\s*set\s+"?DELAY_MODE=(.*?)"?\s*$' -and $Matches[1] -notlike '*%*') {
            $delayMode = $Matches[1]
            continue
        }
        if ($line -match '^\s*set\s+"?REENCODE_BITRATE=(.*?)"?\s*$' -and $Matches[1] -notlike '*%*') {
            $reencodeBitrate = $Matches[1]
            continue
        }
    }

    ConvertTo-SavedSettings -TrackNames $map -LaterName $laterName -OutputSuffix $suffix -DelayMode $delayMode -ReencodeBitrate $reencodeBitrate
}

function Get-TrackNameMap {
    param([object]$Settings)

    $map = @{}
    if ($null -eq $Settings -or $null -eq $Settings.TrackNames) {
        return $map
    }

    if ($Settings.TrackNames -is [System.Collections.IDictionary]) {
        foreach ($key in @($Settings.TrackNames.Keys)) {
            $map[[string]$key] = [string]$Settings.TrackNames[$key]
        }
        return $map
    }

    foreach ($property in $Settings.TrackNames.PSObject.Properties) {
        $map[[string]$property.Name] = [string]$property.Value
    }
    return $map
}

function Get-SortedTrackNameKeys {
    param([System.Collections.IDictionary]$TrackNames)

    return @($TrackNames.Keys) |
        Where-Object { [string]$_ -match '^\d+$' } |
        Sort-Object { [int]([string]$_) }
}

function Add-UniqueStringValue {
    param(
        [System.Collections.ArrayList]$List,
        [object]$Value
    )

    if ($null -eq $Value) {
        return
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    foreach ($current in $List) {
        if ([string]$current -eq $text) {
            return
        }
    }

    [void]$List.Add($text)
}

function ConvertTo-TrackNameCandidateList {
    param([object]$Candidates)

    $list = New-Object System.Collections.ArrayList
    if ($null -eq $Candidates) {
        return @()
    }

    if ($Candidates -is [string]) {
        Add-UniqueStringValue -List $list -Value $Candidates
    }
    else {
        foreach ($candidate in @($Candidates)) {
            Add-UniqueStringValue -List $list -Value $candidate
        }
    }

    return @($list.ToArray())
}

function Get-TrackNameCandidates {
    param([object]$Settings)

    $hasCandidates = $false
    $rawCandidates = $null
    if ($null -ne $Settings) {
        if ($Settings -is [System.Collections.IDictionary]) {
            $hasCandidates = $Settings.Contains('TrackNameCandidates')
            if ($hasCandidates) {
                $rawCandidates = $Settings['TrackNameCandidates']
            }
        }
        elseif ($null -ne $Settings.PSObject.Properties['TrackNameCandidates']) {
            $hasCandidates = $true
            $rawCandidates = $Settings.TrackNameCandidates
        }
    }

    if ($hasCandidates) {
        return @(ConvertTo-TrackNameCandidateList -Candidates $rawCandidates)
    }

    $list = New-Object System.Collections.ArrayList
    $map = Get-TrackNameMap $Settings
    foreach ($key in (Get-SortedTrackNameKeys $map)) {
        Add-UniqueStringValue -List $list -Value $map[$key]
    }
    if ($null -ne $Settings) {
        Add-UniqueStringValue -List $list -Value $Settings.LaterName
        $profiles = ConvertTo-TrackCountProfiles $Settings.TrackCountProfiles
        foreach ($count in $profiles.Keys) {
            $profileMap = Get-TrackNameMap $profiles[$count]
            foreach ($key in (Get-SortedTrackNameKeys $profileMap)) {
                Add-UniqueStringValue -List $list -Value $profileMap[$key]
            }
        }
    }

    return @($list.ToArray())
}

function ConvertTo-TrackCountProfiles {
    param([object]$Profiles)

    $entries = @{}
    if ($null -ne $Profiles) {
        $pairs = @()
        if ($Profiles -is [System.Collections.IDictionary]) {
            foreach ($key in @($Profiles.Keys)) {
                $pairs += [PSCustomObject]@{ Name = [string]$key; Value = $Profiles[$key] }
            }
        }
        else {
            foreach ($property in $Profiles.PSObject.Properties) {
                $pairs += [PSCustomObject]@{ Name = [string]$property.Name; Value = $property.Value }
            }
        }

        foreach ($pair in $pairs) {
            $count = 0
            if (-not [int]::TryParse($pair.Name, [ref]$count) -or $count -le 0 -or $null -eq $pair.Value) {
                continue
            }

            $names = [ordered]@{}
            $map = Get-TrackNameMap $pair.Value
            foreach ($key in (Get-SortedTrackNameKeys $map)) {
                if (-not [string]::IsNullOrWhiteSpace($map[$key])) {
                    $names[[string][int]$key] = [string]$map[$key]
                }
            }
            $entries[$count] = [PSCustomObject]@{
                TrackNames   = $names
                OutputSuffix = [string]$pair.Value.OutputSuffix
            }
        }
    }

    $result = [ordered]@{}
    foreach ($count in ($entries.Keys | Sort-Object)) {
        $result[[string]$count] = $entries[$count]
    }
    return $result
}

function Get-TrackCountProfile {
    param(
        [object]$Settings,
        [int]$TrackCount
    )

    if ($null -eq $Settings -or $TrackCount -le 0 -or $null -eq $Settings.TrackCountProfiles) {
        return $null
    }

    $key = [string]$TrackCount
    $profiles = $Settings.TrackCountProfiles
    if ($profiles -is [System.Collections.IDictionary]) {
        if ($profiles.Contains($key)) {
            return $profiles[$key]
        }
        return $null
    }

    $property = $profiles.PSObject.Properties[$key]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}

function Get-OutputSuffix {
    param(
        [object]$Settings,
        [int]$TrackCount = 0
    )

    $countProfile = Get-TrackCountProfile -Settings $Settings -TrackCount $TrackCount
    if ($null -ne $countProfile -and -not [string]::IsNullOrWhiteSpace([string]$countProfile.OutputSuffix)) {
        return [string]$countProfile.OutputSuffix
    }

    $suffix = [string]$Settings.OutputSuffix
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        return '_mixed'
    }
    return $suffix
}

function ConvertTo-SavedSettings {
    param(
        [hashtable]$TrackNames,
        [string]$LaterName,
        [string]$OutputSuffix,
        [string[]]$TrackNameCandidates = $null,
        [string]$DelayMode = 'copy',
        [string]$ReencodeBitrate = '256k',
        [object]$OffsetStepMs = 100,
        [object]$AutoOffsetAlways = $false,
        [object]$TrackCountProfiles = $null
    )

    $orderedNames = [ordered]@{}
    foreach ($key in (Get-SortedTrackNameKeys $TrackNames)) {
        $orderedNames[[string]$key] = [string]$TrackNames[$key]
    }

    $candidates = New-Object System.Collections.ArrayList
    if ($PSBoundParameters.ContainsKey('TrackNameCandidates')) {
        foreach ($candidate in @($TrackNameCandidates)) {
            Add-UniqueStringValue -List $candidates -Value $candidate
        }
    }
    else {
        foreach ($key in (Get-SortedTrackNameKeys $TrackNames)) {
            Add-UniqueStringValue -List $candidates -Value $TrackNames[$key]
        }
        Add-UniqueStringValue -List $candidates -Value $LaterName
    }

    [PSCustomObject]@{
        TrackNames          = $orderedNames
        LaterName           = $LaterName
        OutputSuffix        = $OutputSuffix
        TrackCountProfiles  = ConvertTo-TrackCountProfiles $TrackCountProfiles
        TrackNameCandidates = @($candidates.ToArray())
        DelayMode           = ConvertTo-DelayMode $DelayMode
        ReencodeBitrate     = ConvertTo-ReencodeBitrate $ReencodeBitrate
        OffsetStepMs        = ConvertTo-OffsetStepMs $OffsetStepMs
        AutoOffsetAlways    = ConvertTo-SettingFlag $AutoOffsetAlways
    }
}

function Read-Settings {
    $settings = Read-BatchDefaultSettings

    if (Test-Path -LiteralPath $Script:ConfigPath) {
        try {
            $json = Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8
            $loaded = $json | ConvertFrom-Json
            if ($null -ne $loaded) {
                $settings = $loaded
            }
        }
        catch {
            if ($Script:CliMode) {
                Write-Host "GUI版の設定ファイルを読み込めなかったため、初期設定を使います。$($_.Exception.Message)"
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "設定ファイルを読み込めませんでした。初期設定で起動します。`r`n`r`n$($_.Exception.Message)",
                    'ffmpegMp4Mix GUI',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            $settings = Read-BatchDefaultSettings
        }
    }

    $map = Get-TrackNameMap $settings
    if (-not $map.ContainsKey('1') -or [string]::IsNullOrWhiteSpace($map['1'])) {
        $map['1'] = 'オンボーカル'
    }
    if (-not $map.ContainsKey('2') -or [string]::IsNullOrWhiteSpace($map['2'])) {
        $map['2'] = 'オフボーカル'
    }

    $laterName = [string]$settings.LaterName
    if ([string]::IsNullOrWhiteSpace($laterName)) {
        $laterName = 'トラック'
    }

    $suffix = [string]$settings.OutputSuffix
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        $suffix = '_mixed'
    }

    $convertParams = @{
        TrackNames      = $map
        LaterName       = $laterName
        OutputSuffix    = $suffix
        DelayMode       = [string]$settings.DelayMode
        ReencodeBitrate = [string]$settings.ReencodeBitrate
        OffsetStepMs    = $settings.OffsetStepMs
        AutoOffsetAlways = $settings.AutoOffsetAlways
        TrackCountProfiles = $settings.TrackCountProfiles
    }
    if ($null -ne $settings.PSObject.Properties['TrackNameCandidates']) {
        $convertParams.TrackNameCandidates = @(Get-TrackNameCandidates -Settings $settings)
    }

    ConvertTo-SavedSettings @convertParams
}

function Save-Settings {
    param([object]$Settings)

    $json = $Settings | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Script:ConfigPath -Value $json -Encoding UTF8
}

function Get-TrackNameDefaultsSignature {
    param([object]$Settings)

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('later=' + [string]$Settings.LaterName)
    $map = Get-TrackNameMap $Settings
    foreach ($key in (Get-SortedTrackNameKeys $map)) {
        [void]$parts.Add('0:' + $key + '=' + $map[$key])
    }

    $profiles = ConvertTo-TrackCountProfiles $Settings.TrackCountProfiles
    foreach ($count in $profiles.Keys) {
        $profileMap = Get-TrackNameMap $profiles[$count]
        foreach ($key in (Get-SortedTrackNameKeys $profileMap)) {
            [void]$parts.Add($count + ':' + $key + '=' + $profileMap[$key])
        }
    }
    return ($parts -join "`n")
}

function Test-TrackNameDefaultsChanged {
    param(
        [object]$OldSettings,
        [object]$NewSettings
    )

    return (Get-TrackNameDefaultsSignature $OldSettings) -cne (Get-TrackNameDefaultsSignature $NewSettings)
}

function Get-DefaultTrackName {
    param(
        [object]$Settings,
        [int]$TrackIndex,
        [int]$TrackCount = 0
    )

    $key = [string]$TrackIndex
    $countProfile = Get-TrackCountProfile -Settings $Settings -TrackCount $TrackCount
    if ($null -ne $countProfile) {
        $profileMap = Get-TrackNameMap $countProfile
        if ($profileMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($profileMap[$key])) {
            return $profileMap[$key]
        }
    }

    $map = Get-TrackNameMap $Settings
    if ($map.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($map[$key])) {
        return $map[$key]
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.LaterName)) {
        return [string]$Settings.LaterName
    }

    return 'トラック'
}

function Get-DefaultOutputPath {
    param(
        [string]$VideoFile,
        [object]$Settings,
        [int]$TrackCount = 0
    )

    if ([string]::IsNullOrWhiteSpace($VideoFile)) {
        return ''
    }

    $directory = Split-Path -Parent $VideoFile
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile)
    Join-Path $directory ($baseName + (Get-OutputSuffix -Settings $Settings -TrackCount $TrackCount) + '.mp4')
}

function Test-VideoSelected {
    return -not [string]::IsNullOrWhiteSpace([string]$Script:VideoFile)
}

function Get-InitialDirectory {
    param([string[]]$Paths)

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (Test-Path -LiteralPath $path -PathType Container) {
            return [System.IO.Path]::GetFullPath($path)
        }

        $directory = Split-Path -Parent $path
        if (-not [string]::IsNullOrWhiteSpace($directory) -and (Test-Path -LiteralPath $directory -PathType Container)) {
            return [System.IO.Path]::GetFullPath($directory)
        }
    }

    return $Script:AppDir
}

function Test-Mp4FilePath {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Mp4ExtensionPath $FilePath)) {
        return $false
    }

    return Test-Path -LiteralPath $FilePath -PathType Leaf
}

function Test-Mp4ExtensionPath {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return $false
    }

    return [System.IO.Path]::GetExtension($FilePath).Equals('.mp4', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FirstMp4FilePath {
    param([string[]]$FilePaths)

    foreach ($filePath in @($FilePaths)) {
        if (Test-Mp4ExtensionPath $filePath) {
            return [System.IO.Path]::GetFullPath($filePath)
        }
    }

    return $null
}

function Split-TrackDropFiles {
    param(
        [string[]]$FilePaths,
        [bool]$VideoAlreadySelected
    )

    $videoFile = $null
    $trackFiles = @()

    foreach ($filePath in @($FilePaths)) {
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath($filePath)
        if (-not $VideoAlreadySelected -and [string]::IsNullOrWhiteSpace($videoFile) -and (Test-Mp4FilePath $fullPath)) {
            $videoFile = $fullPath
            continue
        }

        $trackFiles += $fullPath
    }

    [PSCustomObject]@{
        VideoFile  = $videoFile
        TrackFiles = $trackFiles
    }
}

function Initialize-InputFiles {
    param(
        [string[]]$InputFiles,
        [object]$Settings
    )

    $Script:VideoFile = $null
    $Script:AudioFiles = @()

    $inputFiles = @($InputFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $videoIndex = -1
    for ($index = 0; $index -lt $inputFiles.Count; $index++) {
        if ([System.IO.Path]::GetExtension($inputFiles[$index]).Equals('.mp4', [System.StringComparison]::OrdinalIgnoreCase)) {
            $videoIndex = $index
            break
        }
    }

    if ($videoIndex -ge 0) {
        $Script:VideoFile = [System.IO.Path]::GetFullPath($inputFiles[$videoIndex])
    }

    for ($index = 0; $index -lt $inputFiles.Count; $index++) {
        if ($index -eq $videoIndex) {
            continue
        }
        $Script:AudioFiles += [System.IO.Path]::GetFullPath($inputFiles[$index])
    }

    $Script:DefaultOutputPath = Get-DefaultOutputPath -VideoFile $Script:VideoFile -Settings $Settings -TrackCount $Script:AudioFiles.Count
}

function ConvertTo-CommandLineArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-CommandLine {
    param(
        [string]$FileName,
        [string[]]$Arguments
    )

    $parts = @((ConvertTo-CommandLineArgument $FileName))
    foreach ($argument in $Arguments) {
        $parts += ConvertTo-CommandLineArgument $argument
    }
    return ($parts -join ' ')
}

function ConvertTo-OffsetMs {
    param([object]$Value)

    $text =([string]$Value).Normalize([System.Text.NormalizationForm]::FormKC).Replace([string][char]0x2212, '-').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 0
    }
    if ($text -notmatch '^[+-]?[0-9]+$') {
        return $null
    }

    $offsetMs = 0
    if (-not [int]::TryParse($text, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$offsetMs)) {
        return $null
    }
    return $offsetMs
}

function Format-OffsetMs {
    param([int]$OffsetMs)

    if ($OffsetMs -gt 0) {
        return '+' + [string]$OffsetMs
    }

    return [string]$OffsetMs
}

function Format-FfmpegDuration {
    param([int]$OffsetMs)

    return ([string][Math]::Abs([long]$OffsetMs)) + 'ms'
}

function New-TrackItem {
    param(
        [string]$SourceFile,
        [bool]$IsVideoAudio,
        [string]$Title,
        [int]$OffsetMs = 0,
        [string]$OffsetNote = '',
        [string]$OffsetNoteLevel = ''
    )

    [PSCustomObject]@{
        SourceFile      = $SourceFile
        IsVideoAudio    = $IsVideoAudio
        Title           = $Title
        OffsetMs        = $OffsetMs
        OffsetNote      = $OffsetNote
        OffsetNoteLevel = $OffsetNoteLevel
        InputIndex      = $null
    }
}

function Format-AutoOffsetNote {
    param([object]$Result)

    $offsetText = (Format-OffsetMs ([int]$Result.OffsetMs)) + 'ms'
    switch ([string]$Result.Level) {
        '高' { $note = "自動調整: ${offsetText}（信頼度: 高）" }
        '中' { $note = "自動調整: ${offsetText}（信頼度: 中）。念のため確認してください。" }
        default { $note = "自動調整: 判定できなかったため変更していません（候補: ${offsetText}、信頼度: 低）。" }
    }
    if ($Result.EdgeWarning) {
        $note += "`r`nずれが探せる範囲（±180秒）を超えている可能性があります。"
    }
    if ($Result.DriftWarning) {
        $note += "`r`n" + ('テンポか長さが違う可能性があります（曲の途中で最大 {0:0}ms ずれます）。' -f $Result.DriftMs)
    }
    return $note
}

function ConvertTo-BatchValue {
    param(
        [string]$Value,
        [switch]$ForEcho
    )

    $text = ([string]$Value) -replace "[`r`n]+", ' '
    $text = $text.Replace('"', '')
    if ($ForEcho) {
        $text = $text -replace '[&<>|^]', ' '
    }
    return $text.Replace('%', '%%')
}

function Write-CliDefaults {
    param(
        [string[]]$InputFiles,
        [bool]$UseVideoAudio,
        [string]$OutFile
    )

    Initialize-InputFiles -InputFiles $InputFiles -Settings $Script:Settings
    $tracks = @()
    if ($UseVideoAudio -and (Test-VideoSelected)) {
        $tracks += [PSCustomObject]@{ SourceFile = $Script:VideoFile; IsVideoAudio = $true }
    }
    foreach ($audioFile in $Script:AudioFiles) {
        $tracks += [PSCustomObject]@{ SourceFile = $audioFile; IsVideoAudio = $false }
    }
    $trackCount = $tracks.Count

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('set "CLI_OUTPUT_SUFFIX=' + (ConvertTo-BatchValue (Get-OutputSuffix -Settings $Script:Settings -TrackCount $trackCount)) + '"')
    $lines.Add('set "CLI_DELAY_MODE=' + (ConvertTo-DelayMode $Script:Settings.DelayMode) + '"')
    $lines.Add('set "CLI_REENCODE_BITRATE=' + (ConvertTo-ReencodeBitrate $Script:Settings.ReencodeBitrate) + '"')

    $reference = $null
    $ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
    $autoOffset = (ConvertTo-SettingFlag $Script:Settings.AutoOffsetAlways) -and (Test-VideoSelected)
    if ($autoOffset) {
        Write-Host '自動調整: 動画の音声を解析しています...'
        try {
            $reference = [AudioOffsetAnalyzer]::Load($ffmpegPath, $Script:VideoFile)
        }
        catch {
            Write-Host '自動調整: 動画の音声を解析できなかったため、自動調整をしません。'
            $autoOffset = $false
        }
    }

    for ($index = 0; $index -lt $trackCount; $index++) {
        $position = $index + 1
        $track = $tracks[$index]
        $name = Get-DefaultTrackName -Settings $Script:Settings -TrackIndex $position -TrackCount $trackCount
        $offsetMs = 0
        $level = ''
        $note = ''
        if ($autoOffset -and -not $track.IsVideoAudio) {
            Write-Host ('自動調整中 ({0}/{1}): {2}' -f $position, $trackCount, [System.IO.Path]::GetFileName($track.SourceFile))
            try {
                $result = [AudioOffsetAnalyzer]::Analyze($reference, [AudioOffsetAnalyzer]::Load($ffmpegPath, $track.SourceFile))
                $note = Format-AutoOffsetNote $result
                switch ([string]$result.Level) {
                    '高' { $level = 'high' }
                    '中' { $level = 'medium' }
                    default { $level = 'low' }
                }
                if ($level -ne 'low') {
                    $offsetMs = [int]$result.OffsetMs
                }
            }
            catch {
                $level = 'low'
                $note = '自動調整できませんでした: ' + $_.Exception.GetBaseException().Message
            }
        }

        $lines.Add(('set "CLI_NAME_{0}={1}"' -f $position, (ConvertTo-BatchValue $name)))
        $lines.Add(('set "CLI_OFFSET_{0}={1}"' -f $position, (Format-OffsetMs $offsetMs)))
        $lines.Add(('set "CLI_LEVEL_{0}={1}"' -f $position, $level))
        $lines.Add(('set "CLI_NOTE_{0}={1}"' -f $position, (ConvertTo-BatchValue $note -ForEcho)))
    }
    $lines.Add('set "CLI_DEFAULTS_LOADED=1"')
    [System.IO.File]::WriteAllLines($OutFile, $lines, [System.Text.Encoding]::GetEncoding(932))
}

function Get-AutoOffsetReference {
    param(
        [string]$FfmpegPath,
        [string]$VideoFile
    )

    $file = Get-Item -LiteralPath $VideoFile
    $cache = $Script:AutoOffsetReference
    if ($null -ne $cache -and $cache.Path -eq $file.FullName -and $cache.Length -eq $file.Length -and $cache.WriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
        return $cache.Features
    }

    $features = [AudioOffsetAnalyzer]::Load($FfmpegPath, $file.FullName)
    $Script:AutoOffsetReference = [PSCustomObject]@{
        Path       = $file.FullName
        Length     = $file.Length
        WriteTicks = $file.LastWriteTimeUtc.Ticks
        Features   = $features
    }
    return $features
}

function Set-OffsetCellNote {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$Note,
        [string]$NoteLevel
    )

    $cell = $Row.Cells[2]
    $cell.ToolTipText = $Note
    switch ($NoteLevel) {
        'warn' { $cell.Style.BackColor = Get-UiColor 'WarningSoft' }
        'error' { $cell.Style.BackColor = Get-UiColor 'DangerSoft' }
        default { $cell.Style.BackColor = [System.Drawing.Color]::Empty }
    }

    if ($null -ne $Row.Tag) {
        $Row.Tag.OffsetNote = $Note
        $Row.Tag.OffsetNoteLevel = $NoteLevel
    }
}

function Copy-TrackOffsets {
    param(
        [object[]]$Items,
        [object[]]$SourceItems
    )

    $remaining = New-Object System.Collections.ArrayList
    foreach ($sourceItem in @($SourceItems)) {
        [void]$remaining.Add($sourceItem)
    }

    foreach ($item in @($Items)) {
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            $sourceItem = $remaining[$index]
            if ([bool]$sourceItem.IsVideoAudio -eq [bool]$item.IsVideoAudio -and
                ([string]$sourceItem.SourceFile).Equals([string]$item.SourceFile, [System.StringComparison]::OrdinalIgnoreCase)) {
                $item.OffsetMs = [int]$sourceItem.OffsetMs
                $item.OffsetNote = [string]$sourceItem.OffsetNote
                $item.OffsetNoteLevel = [string]$sourceItem.OffsetNoteLevel
                $remaining.RemoveAt($index)
                break
            }
        }
    }
}

function Show-ErrorMessage {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'ffmpegMp4Mix GUI',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function New-UiColor {
    param(
        [int]$Red,
        [int]$Green,
        [int]$Blue
    )

    return [System.Drawing.Color]::FromArgb($Red, $Green, $Blue)
}

function Get-UiColor {
    param([string]$Name)

    switch ($Name) {
        'Background' { return (New-UiColor 246 248 250) }
        'Surface' { return (New-UiColor 255 255 255) }
        'SurfaceAlt' { return (New-UiColor 250 251 252) }
        'Border' { return (New-UiColor 208 215 222) }
        'BorderStrong' { return (New-UiColor 140 149 159) }
        'Text' { return (New-UiColor 36 41 47) }
        'MutedText' { return (New-UiColor 87 96 106) }
        'Accent' { return (New-UiColor 37 99 235) }
        'AccentHover' { return (New-UiColor 29 78 216) }
        'AccentSoft' { return (New-UiColor 219 234 254) }
        'Danger' { return (New-UiColor 220 38 38) }
        'DangerSoft' { return (New-UiColor 254 242 242) }
        'WarningSoft' { return (New-UiColor 255 247 214) }
        default { return (New-UiColor 255 255 255) }
    }
}

function New-UiFont {
    param(
        [single]$Size = 9.0,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    return New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $Size, $Style
}

function Set-FormTheme {
    param([System.Windows.Forms.Form]$Form)

    $Form.BackColor = Get-UiColor 'Background'
    $Form.ForeColor = Get-UiColor 'Text'
    $Form.Font = New-UiFont 9
}

function Set-LabelTheme {
    param(
        [System.Windows.Forms.Label]$Label,
        [switch]$Muted
    )

    $Label.Font = New-UiFont 9
    $Label.BackColor = Get-UiColor 'Background'
    $Label.ForeColor = if ($Muted) { Get-UiColor 'MutedText' } else { Get-UiColor 'Text' }
}

function Set-PathLabelTheme {
    param([System.Windows.Forms.Label]$Label)

    $Label.Font = New-UiFont 9
    $Label.BackColor = Get-UiColor 'Surface'
    $Label.ForeColor = Get-UiColor 'Text'
    $Label.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Label.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 6, 0, 6, 0
}

function Set-TextBoxTheme {
    param([System.Windows.Forms.TextBox]$TextBox)

    $TextBox.Font = New-UiFont 9
    $TextBox.BackColor = Get-UiColor 'Surface'
    $TextBox.ForeColor = Get-UiColor 'Text'
    $TextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
}

function Set-ButtonTheme {
    param(
        [System.Windows.Forms.Button]$Button,
        [ValidateSet('Default', 'Primary', 'Danger')]
        [string]$Kind = 'Default'
    )

    $Button.Font = New-UiFont 9
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatAppearance.BorderSize = 1

    if ($Kind -eq 'Primary') {
        $Button.BackColor = Get-UiColor 'Accent'
        $Button.ForeColor = Get-UiColor 'Surface'
        $Button.FlatAppearance.BorderColor = Get-UiColor 'Accent'
        $Button.FlatAppearance.MouseOverBackColor = Get-UiColor 'AccentHover'
        $Button.FlatAppearance.MouseDownBackColor = Get-UiColor 'AccentHover'
        return
    }

    if ($Kind -eq 'Danger') {
        $Button.BackColor = Get-UiColor 'DangerSoft'
        $Button.ForeColor = Get-UiColor 'Danger'
        $Button.FlatAppearance.BorderColor = Get-UiColor 'Border'
        $Button.FlatAppearance.MouseOverBackColor = Get-UiColor 'Surface'
        $Button.FlatAppearance.MouseDownBackColor = Get-UiColor 'DangerSoft'
        return
    }

    $Button.BackColor = Get-UiColor 'Surface'
    $Button.ForeColor = Get-UiColor 'Text'
    $Button.FlatAppearance.BorderColor = Get-UiColor 'Border'
    $Button.FlatAppearance.MouseOverBackColor = Get-UiColor 'AccentSoft'
    $Button.FlatAppearance.MouseDownBackColor = Get-UiColor 'AccentSoft'
}

function Set-CheckBoxTheme {
    param([System.Windows.Forms.CheckBox]$CheckBox)

    $CheckBox.Font = New-UiFont 9
    $CheckBox.BackColor = Get-UiColor 'Background'
    $CheckBox.ForeColor = Get-UiColor 'Text'
}

function Set-ComboBoxTheme {
    param([System.Windows.Forms.ComboBox]$ComboBox)

    $ComboBox.Font = New-UiFont 9
    $ComboBox.BackColor = Get-UiColor 'Surface'
    $ComboBox.ForeColor = Get-UiColor 'Text'
    $ComboBox.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
}

function Set-GridTheme {
    param([System.Windows.Forms.DataGridView]$Grid)

    $Grid.Font = New-UiFont 9
    $Grid.BackgroundColor = Get-UiColor 'Surface'
    $Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Grid.GridColor = Get-UiColor 'Border'
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.RowHeadersVisible = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $Grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
    $Grid.ColumnHeadersHeight = 30
    $Grid.RowTemplate.Height = 28
    $Grid.DefaultCellStyle.BackColor = Get-UiColor 'Surface'
    $Grid.DefaultCellStyle.ForeColor = Get-UiColor 'Text'
    $Grid.DefaultCellStyle.SelectionBackColor = Get-UiColor 'Accent'
    $Grid.DefaultCellStyle.SelectionForeColor = Get-UiColor 'Surface'
    $Grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 6, 0, 6, 0
    $Grid.AlternatingRowsDefaultCellStyle.BackColor = Get-UiColor 'SurfaceAlt'
    $Grid.AlternatingRowsDefaultCellStyle.ForeColor = Get-UiColor 'Text'
    $Grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = Get-UiColor 'Accent'
    $Grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = Get-UiColor 'Surface'
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = Get-UiColor 'SurfaceAlt'
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = Get-UiColor 'MutedText'
    $Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Get-UiColor 'SurfaceAlt'
    $Grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = Get-UiColor 'MutedText'
    $Grid.ColumnHeadersDefaultCellStyle.Font = New-UiFont 9 ([System.Drawing.FontStyle]::Bold)
}

function Get-TrackSourceText {
    param([object]$Item)

    return [System.IO.Path]::GetFileName([string]$Item.SourceFile)
}

function Get-TrackTypeText {
    param([object]$Item)

    if ($Item.IsVideoAudio) {
        return '元動画'
    }

    return [System.IO.Path]::GetExtension([string]$Item.SourceFile).TrimStart('.').ToUpperInvariant()
}

function Add-TrackNameCandidateToGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Name,
        [int]$TrackNameColumnIndex = 1
    )

    $nameText = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($nameText)) {
        return
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($item in @(Get-TrackNameCandidateValuesFromGrid -Grid $Grid)) {
        Add-UniqueStringValue -List $list -Value $item
    }

    foreach ($item in $list) {
        if ([string]$item -eq $nameText) {
            return
        }
    }

    [void]$list.Add($nameText)
    Set-TrackNameCandidateValuesToGrid -Grid $Grid -Candidates @($list.ToArray()) -TrackNameColumnIndex $TrackNameColumnIndex
}

function Set-TrackNameCellValue {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$RowIndex,
        [string]$Value,
        [int]$TrackNameColumnIndex = 1
    )

    if ($null -eq $Grid -or $RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) {
        return $false
    }
    if ($TrackNameColumnIndex -lt 0 -or $TrackNameColumnIndex -ge $Grid.Columns.Count) {
        return $false
    }
    if ($Grid.Rows[$RowIndex].IsNewRow) {
        return $false
    }

    $valueText = [string]$Value
    Add-TrackNameCandidateToGrid -Grid $Grid -Name $valueText -TrackNameColumnIndex $TrackNameColumnIndex
    $Grid.Rows[$RowIndex].Cells[$TrackNameColumnIndex].Value = $valueText

    if ($null -ne $Grid.Rows[$RowIndex].Tag -and $null -ne $Grid.Rows[$RowIndex].Tag.PSObject.Properties['Title']) {
        $Grid.Rows[$RowIndex].Tag.Title = $valueText
    }

    return $true
}

function Get-TrackNameCandidateValuesFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $null -eq $Grid.Tag) {
        return @()
    }

    if ($Grid.Tag -is [string]) {
        return @([string]$Grid.Tag)
    }

    return @($Grid.Tag)
}

function Set-TrackNameCandidateValuesToGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Candidates,
        [int]$TrackNameColumnIndex = 1
    )

    $list = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Candidates)) {
        Add-UniqueStringValue -List $list -Value $candidate
    }

    $Grid.Tag = @($list.ToArray())

    if ($TrackNameColumnIndex -lt 0 -or $TrackNameColumnIndex -ge $Grid.Columns.Count) {
        return
    }

    $column = $Grid.Columns[$TrackNameColumnIndex]
    if ($column -is [System.Windows.Forms.DataGridViewComboBoxColumn]) {
        $column.Items.Clear()
        foreach ($candidate in @($Grid.Tag)) {
            [void]$column.Items.Add([string]$candidate)
        }
    }
}

function New-TrackNameAutoCompleteSource {
    param([System.Windows.Forms.DataGridView]$Grid)

    $source = New-Object System.Windows.Forms.AutoCompleteStringCollection
    $values = [string[]]@(Get-TrackNameCandidateValuesFromGrid -Grid $Grid)
    if ($values.Count -gt 0) {
        $source.AddRange($values)
    }
    Write-Output -NoEnumerate $source
}

function Complete-TrackNameEdit {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$TrackNameColumnIndex = 1
    )

    if ($null -eq $Grid) {
        return
    }

    $rowIndex = -1
    $typedText = $null
    if ($null -ne $Grid.CurrentCell -and $Grid.CurrentCell.ColumnIndex -eq $TrackNameColumnIndex) {
        $rowIndex = $Grid.CurrentCell.RowIndex
        $editingControl = $Grid.EditingControl -as [System.Windows.Forms.Control]
        if ($null -ne $editingControl) {
            $typedText = [string]$editingControl.Text
            Add-TrackNameCandidateToGrid -Grid $Grid -Name $typedText -TrackNameColumnIndex $TrackNameColumnIndex
        }
    }

    try {
        if ($Grid.IsCurrentCellDirty) {
            [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }
    catch {
    }

    [void]$Grid.EndEdit()

    if ($null -ne $typedText -and $rowIndex -ge 0 -and $rowIndex -lt $Grid.Rows.Count -and -not $Grid.Rows[$rowIndex].IsNewRow) {
        [void](Set-TrackNameCellValue -Grid $Grid -RowIndex $rowIndex -Value $typedText -TrackNameColumnIndex $TrackNameColumnIndex)
    }
}

function Set-TrackNameCandidateColumnItems {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object]$Settings,
        [int]$TrackNameColumnIndex = 1
    )

    if ($TrackNameColumnIndex -lt 0 -or $TrackNameColumnIndex -ge $Grid.Columns.Count) {
        return
    }

    $candidateValues = @()
    foreach ($candidate in (Get-TrackNameCandidates -Settings $Settings)) {
        $candidateValues += $candidate
    }
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $candidateValues += [string]$row.Cells[$TrackNameColumnIndex].Value
    }

    Set-TrackNameCandidateValuesToGrid -Grid $Grid -Candidates $candidateValues -TrackNameColumnIndex $TrackNameColumnIndex
}

function Add-TrackRow {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object]$Item
    )

    Add-TrackNameCandidateToGrid -Grid $Grid -Name ([string]$Item.Title)
    $rowIndex = $Grid.Rows.Add('', $Item.Title, (Format-OffsetMs ([int]$Item.OffsetMs)), (Get-TrackTypeText $Item), (Get-TrackSourceText $Item))
    $Grid.Rows[$rowIndex].Cells[4].ToolTipText = [string]$Item.SourceFile
    $Grid.Rows[$rowIndex].Tag = $Item
    Set-OffsetCellNote -Row $Grid.Rows[$rowIndex] -Note ([string]$Item.OffsetNote) -NoteLevel ([string]$Item.OffsetNoteLevel)
}

function Get-TrackItemsFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    Complete-TrackNameEdit -Grid $Grid

    $items = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }

        $tag = $row.Tag
        if ($null -eq $tag) {
            continue
        }

        $offsetMs = ConvertTo-OffsetMs $row.Cells[2].Value
        if ($null -eq $offsetMs) {
            $offsetMs = [int]$tag.OffsetMs
        }

        $items += New-TrackItem `
            -SourceFile ([string]$tag.SourceFile) `
            -IsVideoAudio ([bool]$tag.IsVideoAudio) `
            -Title ([string]$row.Cells[1].Value) `
            -OffsetMs $offsetMs `
            -OffsetNote ([string]$tag.OffsetNote) `
            -OffsetNoteLevel ([string]$tag.OffsetNoteLevel)
    }
    return $items
}

function Sync-AudioFilesFromGrid {
    param([System.Windows.Forms.DataGridView]$Grid)

    $audioFiles = @()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow -or $null -eq $row.Tag) {
            continue
        }

        if (-not [bool]$row.Tag.IsVideoAudio) {
            $audioFiles += [string]$row.Tag.SourceFile
        }
    }

    $Script:AudioFiles = $audioFiles
}

function Set-TrackItemsToGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Items
    )

    $Grid.Rows.Clear()
    foreach ($item in $Items) {
        Add-TrackRow -Grid $Grid -Item $item
    }
    Update-TrackNumbers -Grid $Grid
}

function Add-TrackFilesToGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string[]]$FilePaths,
        [object]$Settings
    )

    $firstAddedRow = -1
    $addedCount = 0
    $validFiles = @($FilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    $trackCount = $Grid.Rows.Count + $validFiles.Count

    foreach ($filePath in $validFiles) {
        $fullPath = [System.IO.Path]::GetFullPath($filePath)
        $Script:AudioFiles += $fullPath
        $trackIndex = $Grid.Rows.Count + 1
        $title = Get-DefaultTrackName -Settings $Settings -TrackIndex $trackIndex -TrackCount $trackCount
        $item = New-TrackItem -SourceFile $fullPath -IsVideoAudio $false -Title $title
        Add-TrackRow -Grid $Grid -Item $item

        if ($firstAddedRow -lt 0) {
            $firstAddedRow = $Grid.Rows.Count - 1
        }
        $addedCount++
    }

    if ($addedCount -gt 0) {
        Update-TrackNumbers -Grid $Grid
        $Grid.CurrentCell = $Grid.Rows[$firstAddedRow].Cells[1]
    }

    return $addedCount
}

function Remove-AudioFileFromState {
    param([string]$SourceFile)

    $updated = @()
    $removed = $false
    foreach ($audioFile in $Script:AudioFiles) {
        if (-not $removed -and [System.IO.Path]::GetFullPath($audioFile).Equals([System.IO.Path]::GetFullPath($SourceFile), [System.StringComparison]::OrdinalIgnoreCase)) {
            $removed = $true
            continue
        }
        $updated += $audioFile
    }
    $Script:AudioFiles = $updated
}

function Update-TrackNumbers {
    param([System.Windows.Forms.DataGridView]$Grid)

    for ($index = 0; $index -lt $Grid.Rows.Count; $index++) {
        if (-not $Grid.Rows[$index].IsNewRow) {
            $Grid.Rows[$index].Cells[0].Value = [string]($index + 1)
        }
    }
}

function Set-TrackNameCell {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$RowIndex,
        [int]$TrackNameColumnIndex = 1
    )

    if ($RowIndex -lt 0 -or $RowIndex -ge $Grid.Rows.Count) {
        return $false
    }
    if ($TrackNameColumnIndex -lt 0 -or $TrackNameColumnIndex -ge $Grid.Columns.Count) {
        return $false
    }
    if ($Grid.Rows[$RowIndex].IsNewRow) {
        return $false
    }

    $Grid.CurrentCell = $Grid.Rows[$RowIndex].Cells[$TrackNameColumnIndex]
    return $true
}

function Move-TrackNameCell {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$Delta,
        [int]$TrackNameColumnIndex = 1
    )

    if ($Grid.Rows.Count -eq 0) {
        return $false
    }

    if ($null -eq $Grid.CurrentCell) {
        $rowIndex = if ($Delta -lt 0) { $Grid.Rows.Count } else { -1 }
    }
    else {
        $rowIndex = $Grid.CurrentCell.RowIndex
    }

    return Set-TrackNameCell -Grid $Grid -RowIndex ($rowIndex + $Delta) -TrackNameColumnIndex $TrackNameColumnIndex
}

function Move-CurrentTrack {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$Delta
    )

    if ($null -eq $Grid.CurrentCell) {
        return
    }

    $oldIndex = $Grid.CurrentCell.RowIndex
    $newIndex = $oldIndex + $Delta
    if ($oldIndex -lt 0 -or $newIndex -lt 0 -or $newIndex -ge $Grid.Rows.Count) {
        return
    }

    $items = @(Get-TrackItemsFromGrid -Grid $Grid)
    if ($oldIndex -ge $items.Count -or $newIndex -ge $items.Count) {
        return
    }

    $current = $items[$oldIndex]
    $items[$oldIndex] = $items[$newIndex]
    $items[$newIndex] = $current
    Set-TrackItemsToGrid -Grid $Grid -Items $items
    Sync-AudioFilesFromGrid -Grid $Grid
    $Grid.CurrentCell = $Grid.Rows[$newIndex].Cells[1]
}

function Move-TrackToIndex {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$OldIndex,
        [int]$NewIndex
    )

    $rowCount = $Grid.Rows.Count
    if ($OldIndex -lt 0 -or $OldIndex -ge $rowCount) {
        return
    }

    if ($NewIndex -lt 0) {
        $NewIndex = 0
    }
    elseif ($NewIndex -gt $rowCount) {
        $NewIndex = $rowCount
    }

    if ($OldIndex -eq $NewIndex -or ($OldIndex + 1) -eq $NewIndex) {
        return
    }

    $items = @(Get-TrackItemsFromGrid -Grid $Grid)
    if ($OldIndex -ge $items.Count) {
        return
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        [void]$list.Add($item)
    }

    $current = $list[$OldIndex]
    $list.RemoveAt($OldIndex)
    if ($OldIndex -lt $NewIndex) {
        $NewIndex--
    }
    if ($NewIndex -gt $list.Count) {
        $NewIndex = $list.Count
    }

    $list.Insert($NewIndex, $current)
    Set-TrackItemsToGrid -Grid $Grid -Items @($list.ToArray())
    Sync-AudioFilesFromGrid -Grid $Grid
    $Grid.CurrentCell = $Grid.Rows[$NewIndex].Cells[1]
}

function Get-GridDropIndex {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$ScreenX,
        [int]$ScreenY
    )

    if ($Grid.Rows.Count -eq 0) {
        return 0
    }

    $screenPoint = New-Object System.Drawing.Point -ArgumentList $ScreenX, $ScreenY
    $point = $Grid.PointToClient($screenPoint)
    $hit = $Grid.HitTest($point.X, $point.Y)
    if ($hit.RowIndex -lt 0) {
        if ($point.Y -le $Grid.ColumnHeadersHeight) {
            return 0
        }
        return $Grid.Rows.Count
    }

    $dropIndex = $hit.RowIndex
    $rowBounds = $Grid.GetRowDisplayRectangle($hit.RowIndex, $false)
    if ($point.Y -gt ($rowBounds.Top + ($rowBounds.Height / 2))) {
        $dropIndex++
    }

    if ($dropIndex -lt 0) {
        return 0
    }
    if ($dropIndex -gt $Grid.Rows.Count) {
        return $Grid.Rows.Count
    }
    return $dropIndex
}

function Build-FfmpegArguments {
    param(
        [object[]]$TrackItems,
        [string]$OutputPath,
        [object]$Settings
    )

    $delayMode = ConvertTo-DelayMode $Settings.DelayMode
    $reencodeBitrate = ConvertTo-ReencodeBitrate $Settings.ReencodeBitrate

    $arguments = @('-i', $Script:VideoFile)
    $nextInputIndex = 1

    foreach ($item in $TrackItems) {
        $offsetMs = [int]$item.OffsetMs
        if ($item.IsVideoAudio -and $offsetMs -eq 0) {
            $item.InputIndex = 0
            continue
        }

        if ($offsetMs -lt 0) {
            $arguments += @('-ss', (Format-FfmpegDuration $offsetMs))
        }
        elseif ($offsetMs -gt 0 -and $delayMode -eq 'copy') {
            $arguments += @('-itsoffset', (Format-FfmpegDuration $offsetMs))
        }

        $arguments += @('-i', $item.SourceFile)
        $item.InputIndex = $nextInputIndex
        $nextInputIndex++
    }

    $arguments += @('-c:v', 'copy', '-c:a', 'copy', '-map', '0:v')

    for ($index = 0; $index -lt $TrackItems.Count; $index++) {
        $item = $TrackItems[$index]
        $mapValue = if ($item.IsVideoAudio) {
            ([string]$item.InputIndex) + ':a:0'
        }
        else {
            ([string]$item.InputIndex) + ':a'
        }

        $title = [string]$item.Title
        $arguments += @(
            '-map', $mapValue,
            ('-metadata:s:a:' + $index), ('title=' + $title),
            ('-metadata:s:a:' + $index), ('handler_name=' + $title)
        )

        if ([int]$item.OffsetMs -gt 0 -and $delayMode -eq 'reencode') {
            $arguments += @(
                ('-c:a:' + $index), 'aac',
                ('-b:a:' + $index), $reencodeBitrate,
                ('-filter:a:' + $index), ('adelay=' + [string][int]$item.OffsetMs + ':all=1')
            )
        }
    }

    $arguments += $OutputPath
    return $arguments
}

function Invoke-Ffmpeg {
    param(
        [string]$OutputPath,
        [object[]]$TrackItems
    )

    $ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ffmpegPath)) {
        throw "ffmpeg.exe が見つかりません。`r`n$ffmpegPath"
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        throw "出力先フォルダーが見つかりません。`r`n$outputDirectory"
    }

    if ([System.IO.Path]::GetFullPath($OutputPath).Equals([System.IO.Path]::GetFullPath($Script:VideoFile), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '出力ファイルに入力動画と同じファイルは指定できません。'
    }

    $arguments = @(Build-FfmpegArguments -TrackItems $TrackItems -OutputPath $OutputPath -Settings $Script:Settings)
    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ((Test-Path -LiteralPath $OutputPath) -and $Script:SavedOutputPaths.Contains($fullOutputPath)) {
        $arguments = @('-y') + $arguments
    }
    elseif (Test-Path -LiteralPath $OutputPath) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "出力ファイルはすでに存在します。上書きしますか？`r`n`r`n$OutputPath",
            'ffmpegMp4Mix GUI',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return $false
        }
        $arguments = @('-y') + $arguments
    }

    $argumentLine = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $ffmpegPath
    $processInfo.Arguments = $argumentLine
    $processInfo.WorkingDirectory = Split-Path -Parent $Script:VideoFile
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    [void]$process.Start()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        $logPath = [System.IO.Path]::ChangeExtension($OutputPath, '.ffmpeg.log')
        $logText = (Get-CommandLine -FileName $ffmpegPath -Arguments $arguments) + "`r`n`r`n" + $stderr
        [System.IO.File]::WriteAllText($logPath, $logText, [System.Text.Encoding]::UTF8)
        $message = "ffmpeg がエラー終了しました。ログを保存しました。`r`n`r`n$logPath"
        if ($stderr -match 'Error opening output') {
            $message += "`r`n`r`n出力ファイルがプレイヤーなどで開かれている可能性があります。閉じてから保存し直してください。"
        }
        throw $message
    }

    [void]$Script:SavedOutputPaths.Add($fullOutputPath)
    return $true
}

function Show-SettingsDialog {
    param([object]$CurrentSettings)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '設定'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(560, 672)
    $dialog.MinimumSize = New-Object System.Drawing.Size(520, 592)
    Set-FormTheme -Form $dialog

    $editor = [PSCustomObject]@{
        Common       = @{ Names = (Get-TrackNameMap $CurrentSettings); Suffix = [string]$CurrentSettings.OutputSuffix }
        Profiles     = @{}
        Current      = 0
        CurrentIndex = 0
        Suppress     = $false
    }
    $savedProfiles = ConvertTo-TrackCountProfiles $CurrentSettings.TrackCountProfiles
    foreach ($key in $savedProfiles.Keys) {
        $editor.Profiles[[int]$key] = @{ Names = (Get-TrackNameMap $savedProfiles[$key]); Suffix = [string]$savedProfiles[$key].OutputSuffix }
    }

    $comboCounts = New-Object System.Collections.ArrayList
    [void]$comboCounts.Add(0)
    foreach ($count in @(@(1..10) + @($editor.Profiles.Keys) | Sort-Object -Unique)) {
        [void]$comboCounts.Add([int]$count)
    }

    $profileLabel = New-Object System.Windows.Forms.Label
    $profileLabel.Text = 'トラック数'
    $profileLabel.Location = New-Object System.Drawing.Point(12, 15)
    $profileLabel.Size = New-Object System.Drawing.Size(70, 22)
    $profileLabel.Anchor = 'Left,Top'
    Set-LabelTheme -Label $profileLabel -Muted

    $profileCombo = New-Object System.Windows.Forms.ComboBox
    $profileCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $profileCombo.Location = New-Object System.Drawing.Point(88, 12)
    $profileCombo.Size = New-Object System.Drawing.Size(210, 22)
    $profileCombo.Anchor = 'Left,Top'
    $profileCombo.TabIndex = 0
    Set-ComboBoxTheme -ComboBox $profileCombo

    $profileCheck = New-Object System.Windows.Forms.CheckBox
    $profileCheck.Text = 'このトラック数専用の設定にする'
    $profileCheck.Location = New-Object System.Drawing.Point(310, 13)
    $profileCheck.Size = New-Object System.Drawing.Size(222, 24)
    $profileCheck.Anchor = 'Left,Top'
    $profileCheck.TabIndex = 1
    Set-CheckBoxTheme -CheckBox $profileCheck

    $profileHint = New-Object System.Windows.Forms.Label
    $profileHint.Text = '専用の設定がないトラック数で使います'
    $profileHint.Location = New-Object System.Drawing.Point(310, 15)
    $profileHint.Size = New-Object System.Drawing.Size(222, 22)
    $profileHint.Anchor = 'Left,Top'
    Set-LabelTheme -Label $profileHint -Muted

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 44)
    $grid.Size = New-Object System.Drawing.Size(520, 150)
    $grid.Anchor = 'Top,Left,Right'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.TabIndex = 2
    Set-GridTheme -Grid $grid

    $numberColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $numberColumn.HeaderText = '番号'
    $numberColumn.FillWeight = 25
    $grid.Columns.Add($numberColumn) | Out-Null

    $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $nameColumn.HeaderText = '初期トラック名'
    $nameColumn.FillWeight = 75
    $grid.Columns.Add($nameColumn) | Out-Null

    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Text = '+ 追加'
    $addButton.Location = New-Object System.Drawing.Point(12, 200)
    $addButton.Size = New-Object System.Drawing.Size(80, 28)
    $addButton.Anchor = 'Left,Top'
    $addButton.TabIndex = 3
    Set-ButtonTheme -Button $addButton

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = '- 削除'
    $deleteButton.Location = New-Object System.Drawing.Point(98, 200)
    $deleteButton.Size = New-Object System.Drawing.Size(80, 28)
    $deleteButton.Anchor = 'Left,Top'
    $deleteButton.TabIndex = 4
    Set-ButtonTheme -Button $deleteButton -Kind Danger

    $suffixLabel = New-Object System.Windows.Forms.Label
    $suffixLabel.Text = '出力接尾語'
    $suffixLabel.Location = New-Object System.Drawing.Point(196, 205)
    $suffixLabel.Size = New-Object System.Drawing.Size(80, 22)
    $suffixLabel.Anchor = 'Left,Top'
    Set-LabelTheme -Label $suffixLabel -Muted

    $suffixText = New-Object System.Windows.Forms.TextBox
    $suffixText.Location = New-Object System.Drawing.Point(282, 202)
    $suffixText.Size = New-Object System.Drawing.Size(250, 22)
    $suffixText.Anchor = 'Top,Left,Right'
    $suffixText.TabIndex = 5
    Set-TextBoxTheme -TextBox $suffixText

    $separator = New-Object System.Windows.Forms.Label
    $separator.Location = New-Object System.Drawing.Point(12, 238)
    $separator.Size = New-Object System.Drawing.Size(520, 1)
    $separator.Anchor = 'Top,Left,Right'
    $separator.BackColor = Get-UiColor 'Border'

    $candidateLabel = New-Object System.Windows.Forms.Label
    $candidateLabel.Text = 'トラック名候補 (1行1件)'
    $candidateLabel.Location = New-Object System.Drawing.Point(12, 246)
    $candidateLabel.Size = New-Object System.Drawing.Size(180, 22)
    $candidateLabel.Anchor = 'Left,Top'
    Set-LabelTheme -Label $candidateLabel -Muted

    $candidateText = New-Object System.Windows.Forms.TextBox
    $candidateText.Multiline = $true
    $candidateText.ScrollBars = 'Vertical'
    $candidateText.AcceptsReturn = $true
    $candidateText.Text = (Get-TrackNameCandidates -Settings $CurrentSettings) -join [Environment]::NewLine
    $candidateText.Location = New-Object System.Drawing.Point(12, 270)
    $candidateText.Size = New-Object System.Drawing.Size(520, 88)
    $candidateText.Anchor = 'Top,Left,Right'
    $candidateText.TabIndex = 6
    Set-TextBoxTheme -TextBox $candidateText

    $laterLabel = New-Object System.Windows.Forms.Label
    $laterLabel.Text = '未設定番号の初期名'
    $laterLabel.Location = New-Object System.Drawing.Point(12, 374)
    $laterLabel.Size = New-Object System.Drawing.Size(140, 22)
    $laterLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $laterLabel -Muted

    $laterText = New-Object System.Windows.Forms.TextBox
    $laterText.Text = [string]$CurrentSettings.LaterName
    $laterText.Location = New-Object System.Drawing.Point(158, 371)
    $laterText.Size = New-Object System.Drawing.Size(374, 22)
    $laterText.Anchor = 'Left,Right,Bottom'
    $laterText.TabIndex = 7
    Set-TextBoxTheme -TextBox $laterText

    $delayModeLabel = New-Object System.Windows.Forms.Label
    $delayModeLabel.Text = '遅らせる方法'
    $delayModeLabel.Location = New-Object System.Drawing.Point(12, 406)
    $delayModeLabel.Size = New-Object System.Drawing.Size(140, 22)
    $delayModeLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $delayModeLabel -Muted

    $delayModeCombo = New-Object System.Windows.Forms.ComboBox
    $delayModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$delayModeCombo.Items.Add('コピー（再エンコードなし）')
    [void]$delayModeCombo.Items.Add('再エンコード（AAC）')
    $delayModeCombo.SelectedIndex = if ((ConvertTo-DelayMode $CurrentSettings.DelayMode) -eq 'reencode') { 1 } else { 0 }
    $delayModeCombo.Location = New-Object System.Drawing.Point(158, 403)
    $delayModeCombo.Size = New-Object System.Drawing.Size(374, 22)
    $delayModeCombo.Anchor = 'Left,Right,Bottom'
    $delayModeCombo.TabIndex = 8
    Set-ComboBoxTheme -ComboBox $delayModeCombo

    $bitrateLabel = New-Object System.Windows.Forms.Label
    $bitrateLabel.Text = 'ビットレート'
    $bitrateLabel.Location = New-Object System.Drawing.Point(12, 438)
    $bitrateLabel.Size = New-Object System.Drawing.Size(140, 22)
    $bitrateLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $bitrateLabel -Muted

    $bitrateText = New-Object System.Windows.Forms.TextBox
    $bitrateText.Text = ConvertTo-ReencodeBitrate $CurrentSettings.ReencodeBitrate
    $bitrateText.Location = New-Object System.Drawing.Point(158, 435)
    $bitrateText.Size = New-Object System.Drawing.Size(120, 22)
    $bitrateText.Anchor = 'Left,Bottom'
    $bitrateText.TabIndex = 9
    $bitrateText.Enabled = $delayModeCombo.SelectedIndex -eq 1
    Set-TextBoxTheme -TextBox $bitrateText

    $offsetStepLabel = New-Object System.Windows.Forms.Label
    $offsetStepLabel.Text = 'オフセット増減幅(ms)'
    $offsetStepLabel.Location = New-Object System.Drawing.Point(12, 470)
    $offsetStepLabel.Size = New-Object System.Drawing.Size(140, 22)
    $offsetStepLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $offsetStepLabel -Muted

    $offsetStepText = New-Object System.Windows.Forms.TextBox
    $offsetStepText.Text = [string](ConvertTo-OffsetStepMs $CurrentSettings.OffsetStepMs)
    $offsetStepText.Location = New-Object System.Drawing.Point(158, 467)
    $offsetStepText.Size = New-Object System.Drawing.Size(120, 22)
    $offsetStepText.Anchor = 'Left,Bottom'
    $offsetStepText.TabIndex = 10
    Set-TextBoxTheme -TextBox $offsetStepText

    $autoOffsetCheck = New-Object System.Windows.Forms.CheckBox
    $autoOffsetCheck.Text = '自動調整を常に行う（開いたとき・トラック追加時・動画変更時）'
    $autoOffsetCheck.Checked = ConvertTo-SettingFlag $CurrentSettings.AutoOffsetAlways
    $autoOffsetCheck.Location = New-Object System.Drawing.Point(12, 500)
    $autoOffsetCheck.Size = New-Object System.Drawing.Size(520, 24)
    $autoOffsetCheck.Anchor = 'Left,Right,Bottom'
    $autoOffsetCheck.TabIndex = 11
    Set-CheckBoxTheme -CheckBox $autoOffsetCheck

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '保存'
    $okButton.Location = New-Object System.Drawing.Point(356, 586)
    $okButton.Size = New-Object System.Drawing.Size(84, 30)
    $okButton.Anchor = 'Right,Bottom'
    $okButton.TabIndex = 12
    Set-ButtonTheme -Button $okButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(448, 586)
    $cancelButton.Size = New-Object System.Drawing.Size(84, 30)
    $cancelButton.Anchor = 'Right,Bottom'
    $cancelButton.TabIndex = 13
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $cancelButton

    function Get-ProfileItemText {
        param([int]$Count)

        if ($Count -eq 0) {
            return '共通（下記以外のトラック数）'
        }
        $text = '{0}トラックのとき' -f $Count
        if ($editor.Profiles.ContainsKey($Count)) {
            $text += '（専用）'
        }
        return $text
    }

    function Update-ProfileItemTexts {
        $editor.Suppress = $true
        try {
            $selected = $profileCombo.SelectedIndex
            for ($index = 0; $index -lt $comboCounts.Count; $index++) {
                $text = Get-ProfileItemText ([int]$comboCounts[$index])
                if ([string]$profileCombo.Items[$index] -ne $text) {
                    $profileCombo.Items[$index] = $text
                }
            }
            $profileCombo.SelectedIndex = $selected
        }
        finally {
            $editor.Suppress = $false
        }
    }

    function Get-InheritedNames {
        param([int]$Count)

        $later = ([string]$laterText.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($later)) {
            $later = 'トラック'
        }

        $names = @{}
        for ($number = 1; $number -le $Count; $number++) {
            $key = [string]$number
            if ($editor.Common.Names.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$editor.Common.Names[$key])) {
                $names[$key] = [string]$editor.Common.Names[$key]
            }
            else {
                $names[$key] = $later
            }
        }
        return $names
    }

    function Read-NameGrid {
        [void]$grid.EndEdit()
        $names = @{}
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) {
                continue
            }

            $numberText = [string]$row.Cells[0].Value
            $nameText = [string]$row.Cells[1].Value
            $number = 0
            if (-not [int]::TryParse($numberText, [ref]$number) -or $number -le 0) {
                Show-ErrorMessage 'トラック番号には1以上の数字を入力してください。'
                return $null
            }
            if ([string]::IsNullOrWhiteSpace($nameText)) {
                Show-ErrorMessage '初期トラック名を入力してください。'
                return $null
            }
            $names[[string]$number] = $nameText
        }
        return $names
    }

    function Save-EditingProfile {
        $isCommon = $editor.Current -eq 0
        if (-not $isCommon -and -not $editor.Profiles.ContainsKey($editor.Current)) {
            return $true
        }

        $names = Read-NameGrid
        if ($null -eq $names) {
            return $false
        }

        $entry = @{ Names = $names; Suffix = ([string]$suffixText.Text).Trim() }
        if ($isCommon) {
            $editor.Common = $entry
        }
        else {
            $editor.Profiles[$editor.Current] = $entry
        }
        return $true
    }

    function Show-EditingProfile {
        $count = $editor.Current
        $isCommon = $count -eq 0
        $hasProfile = (-not $isCommon) -and $editor.Profiles.ContainsKey($count)
        $editable = $isCommon -or $hasProfile

        $editor.Suppress = $true
        $profileCheck.Visible = -not $isCommon
        $profileCheck.Checked = $hasProfile
        $profileHint.Visible = $isCommon
        $editor.Suppress = $false

        if ($isCommon) {
            $entry = $editor.Common
        }
        elseif ($hasProfile) {
            $entry = $editor.Profiles[$count]
        }
        else {
            $entry = @{ Names = (Get-InheritedNames $count); Suffix = [string]$editor.Common.Suffix }
        }

        $grid.Rows.Clear()
        foreach ($key in (Get-SortedTrackNameKeys $entry.Names)) {
            [void]$grid.Rows.Add($key, $entry.Names[$key])
        }
        $suffixText.Text = [string]$entry.Suffix

        $textColor = if ($editable) { Get-UiColor 'Text' } else { Get-UiColor 'MutedText' }
        $grid.ReadOnly = -not $editable
        $grid.DefaultCellStyle.ForeColor = $textColor
        $grid.AlternatingRowsDefaultCellStyle.ForeColor = $textColor
        $suffixText.ReadOnly = -not $editable
        $suffixText.ForeColor = $textColor
        $addButton.Enabled = $editable
        $deleteButton.Enabled = $editable
        if ($grid.Rows.Count -gt 0) {
            $grid.CurrentCell = $grid.Rows[0].Cells[1]
        }
    }

    $profileCombo.Add_SelectedIndexChanged({
        if ($editor.Suppress) {
            return
        }

        $newIndex = $profileCombo.SelectedIndex
        if (-not (Save-EditingProfile)) {
            $editor.Suppress = $true
            $profileCombo.SelectedIndex = $editor.CurrentIndex
            $editor.Suppress = $false
            return
        }

        $editor.CurrentIndex = $newIndex
        $editor.Current = [int]$comboCounts[$newIndex]
        Show-EditingProfile
    })

    $profileCheck.Add_CheckedChanged({
        if ($editor.Suppress -or $editor.Current -eq 0) {
            return
        }

        if ($profileCheck.Checked) {
            $editor.Profiles[$editor.Current] = @{ Names = (Get-InheritedNames $editor.Current); Suffix = [string]$editor.Common.Suffix }
        }
        else {
            [void]$editor.Profiles.Remove($editor.Current)
        }
        Update-ProfileItemTexts
        Show-EditingProfile
    })

    $addButton.Add_Click({
        $max = 0
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) {
                continue
            }
            $number = 0
            if ([int]::TryParse([string]$row.Cells[0].Value, [ref]$number) -and $number -gt $max) {
                $max = $number
            }
        }
        $rowIndex = $grid.Rows.Add([string]($max + 1), '')
        $grid.CurrentCell = $grid.Rows[$rowIndex].Cells[1]
        $grid.BeginEdit($true)
    })

    $deleteButton.Add_Click({
        if ($null -ne $grid.CurrentCell -and $grid.Rows.Count -gt 0) {
            $grid.Rows.RemoveAt($grid.CurrentCell.RowIndex)
        }
    })

    $delayModeCombo.Add_SelectedIndexChanged({
        $bitrateText.Enabled = $delayModeCombo.SelectedIndex -eq 1
    })

    $okButton.Add_Click({
        if (-not (Save-EditingProfile)) {
            return
        }

        $trackNames = @{}
        foreach ($key in @($editor.Common.Names.Keys)) {
            $trackNames[[string]$key] = [string]$editor.Common.Names[$key]
        }
        if (-not $trackNames.ContainsKey('1')) {
            $trackNames['1'] = 'オンボーカル'
        }
        if (-not $trackNames.ContainsKey('2')) {
            $trackNames['2'] = 'オフボーカル'
        }

        $later = [string]$laterText.Text
        if ([string]::IsNullOrWhiteSpace($later)) {
            $later = 'トラック'
        }

        $suffix = [string]$editor.Common.Suffix
        if ([string]::IsNullOrWhiteSpace($suffix)) {
            $suffix = '_mixed'
        }

        $delayMode = if ($delayModeCombo.SelectedIndex -eq 1) { 'reencode' } else { 'copy' }
        $bitrate = ([string]$bitrateText.Text).Trim()
        if ($delayMode -eq 'reencode' -and -not (Test-ReencodeBitrateText $bitrate)) {
            Show-ErrorMessage 'ビットレートは 256k のように入力してください。'
            return
        }

        $offsetStepMs = ConvertTo-OffsetMs $offsetStepText.Text
        if ($null -eq $offsetStepMs -or $offsetStepMs -le 0) {
            Show-ErrorMessage 'オフセット増減幅には1以上の整数（ミリ秒）を入力してください。'
            return
        }

        $profiles = @{}
        foreach ($count in @($editor.Profiles.Keys)) {
            $entry = $editor.Profiles[$count]
            $profiles[[string]$count] = [PSCustomObject]@{ TrackNames = $entry.Names; OutputSuffix = [string]$entry.Suffix }
        }

        $candidates = @(ConvertTo-TrackNameCandidateList -Candidates $candidateText.Lines)
        $newSettings = ConvertTo-SavedSettings -TrackNames $trackNames -LaterName $later -OutputSuffix $suffix -TrackNameCandidates $candidates -DelayMode $delayMode -ReencodeBitrate $bitrate -OffsetStepMs $offsetStepMs -AutoOffsetAlways $autoOffsetCheck.Checked -TrackCountProfiles $profiles
        Save-Settings $newSettings
        $dialog.Tag = $newSettings
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@(
        $profileLabel, $profileCombo, $profileCheck, $profileHint,
        $grid, $addButton, $deleteButton, $suffixLabel, $suffixText, $separator,
        $candidateLabel, $candidateText, $laterLabel, $laterText,
        $delayModeLabel, $delayModeCombo, $bitrateLabel, $bitrateText,
        $offsetStepLabel, $offsetStepText, $autoOffsetCheck, $okButton, $cancelButton
    ))

    $editor.Suppress = $true
    foreach ($count in $comboCounts) {
        [void]$profileCombo.Items.Add((Get-ProfileItemText ([int]$count)))
    }
    $profileCombo.SelectedIndex = 0
    $editor.Suppress = $false
    Show-EditingProfile

    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.Tag
    }
    return $CurrentSettings
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ffmpegMp4Mix GUI'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(880, 580)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 480)
    Set-FormTheme -Form $form

    $videoLabel = New-Object System.Windows.Forms.Label
    $videoLabel.Text = '動画'
    $videoLabel.Location = New-Object System.Drawing.Point(12, 14)
    $videoLabel.Size = New-Object System.Drawing.Size(70, 22)
    Set-LabelTheme -Label $videoLabel -Muted

    $videoText = New-Object System.Windows.Forms.Label
    $videoText.Text = [string]$Script:VideoFile
    $videoText.Location = New-Object System.Drawing.Point(88, 11)
    $videoText.Size = New-Object System.Drawing.Size(654, 22)
    $videoText.Anchor = 'Top,Left,Right'
    $videoText.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $videoText.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $videoText.AutoEllipsis = $true
    $videoText.UseMnemonic = $false
    Set-PathLabelTheme -Label $videoText

    $videoBrowseButton = New-Object System.Windows.Forms.Button
    $videoBrowseButton.Text = '参照...'
    $videoBrowseButton.Location = New-Object System.Drawing.Point(754, 8)
    $videoBrowseButton.Size = New-Object System.Drawing.Size(94, 28)
    $videoBrowseButton.Anchor = 'Top,Right'
    $videoBrowseButton.TabIndex = 0
    Set-ButtonTheme -Button $videoBrowseButton

    $useVideoAudio = New-Object System.Windows.Forms.CheckBox
    $useVideoAudio.Text = '元動画の音声を1トラック目に使用'
    $useVideoAudio.Location = New-Object System.Drawing.Point(12, 44)
    $useVideoAudio.Size = New-Object System.Drawing.Size(260, 24)
    $useVideoAudio.TabIndex = 1
    $useVideoAudio.Enabled = Test-VideoSelected
    Set-CheckBoxTheme -CheckBox $useVideoAudio

    $offsetToolTip = New-Object System.Windows.Forms.ToolTip

    $selectedOffsetLabel = New-Object System.Windows.Forms.Label
    $selectedOffsetLabel.Text = '選択トラック:'
    $selectedOffsetLabel.Location = New-Object System.Drawing.Point(12, 79)
    $selectedOffsetLabel.Size = New-Object System.Drawing.Size(80, 22)
    Set-LabelTheme -Label $selectedOffsetLabel -Muted

    $selectedOffsetMinusButton = New-Object System.Windows.Forms.Button
    $selectedOffsetMinusButton.Location = New-Object System.Drawing.Point(94, 74)
    $selectedOffsetMinusButton.Size = New-Object System.Drawing.Size(64, 28)
    $selectedOffsetMinusButton.TabIndex = 8
    Set-ButtonTheme -Button $selectedOffsetMinusButton

    $selectedOffsetPlusButton = New-Object System.Windows.Forms.Button
    $selectedOffsetPlusButton.Location = New-Object System.Drawing.Point(162, 74)
    $selectedOffsetPlusButton.Size = New-Object System.Drawing.Size(64, 28)
    $selectedOffsetPlusButton.TabIndex = 9
    Set-ButtonTheme -Button $selectedOffsetPlusButton

    $allOffsetLabel = New-Object System.Windows.Forms.Label
    $allOffsetLabel.Text = '全トラック:'
    $allOffsetLabel.Location = New-Object System.Drawing.Point(246, 79)
    $allOffsetLabel.Size = New-Object System.Drawing.Size(66, 22)
    Set-LabelTheme -Label $allOffsetLabel -Muted

    $allOffsetMinusButton = New-Object System.Windows.Forms.Button
    $allOffsetMinusButton.Location = New-Object System.Drawing.Point(314, 74)
    $allOffsetMinusButton.Size = New-Object System.Drawing.Size(64, 28)
    $allOffsetMinusButton.TabIndex = 10
    Set-ButtonTheme -Button $allOffsetMinusButton

    $allOffsetPlusButton = New-Object System.Windows.Forms.Button
    $allOffsetPlusButton.Location = New-Object System.Drawing.Point(382, 74)
    $allOffsetPlusButton.Size = New-Object System.Drawing.Size(64, 28)
    $allOffsetPlusButton.TabIndex = 11
    Set-ButtonTheme -Button $allOffsetPlusButton

    $allOffsetText = New-Object System.Windows.Forms.TextBox
    $allOffsetText.Location = New-Object System.Drawing.Point(462, 77)
    $allOffsetText.Size = New-Object System.Drawing.Size(64, 22)
    $allOffsetText.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
    $allOffsetText.TabIndex = 12
    Set-TextBoxTheme -TextBox $allOffsetText

    $allOffsetApplyButton = New-Object System.Windows.Forms.Button
    $allOffsetApplyButton.Text = 'ずらす'
    $allOffsetApplyButton.Location = New-Object System.Drawing.Point(530, 74)
    $allOffsetApplyButton.Size = New-Object System.Drawing.Size(64, 28)
    $allOffsetApplyButton.TabIndex = 13
    Set-ButtonTheme -Button $allOffsetApplyButton

    $autoOffsetButton = New-Object System.Windows.Forms.Button
    $autoOffsetButton.Text = '自動調整'
    $autoOffsetButton.Location = New-Object System.Drawing.Point(610, 74)
    $autoOffsetButton.Size = New-Object System.Drawing.Size(80, 28)
    $autoOffsetButton.TabIndex = 14
    Set-ButtonTheme -Button $autoOffsetButton

    $grid = New-Object TrackNameDataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 108)
    $grid.Size = New-Object System.Drawing.Size(730, 296)
    $grid.Anchor = 'Top,Left,Right,Bottom'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AllowDrop = $true
    $grid.TabIndex = 2
    Set-GridTheme -Grid $grid

    $numberColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $numberColumn.HeaderText = 'No.'
    $numberColumn.ReadOnly = $true
    $numberColumn.FillWeight = 8
    $grid.Columns.Add($numberColumn) | Out-Null

    $titleColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $titleColumn.HeaderText = 'トラック名'
    $titleColumn.FillWeight = 26
    $grid.Columns.Add($titleColumn) | Out-Null
    Set-TrackNameCandidateColumnItems -Grid $grid -Settings $Script:Settings

    $offsetColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $offsetColumn.HeaderText = 'オフセット(ms)'
    $offsetColumn.ToolTipText = '音声の開始タイミングをミリ秒でずらします。+ で遅らせる、- で早める'
    $offsetColumn.FillWeight = 16
    $offsetColumn.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
    $grid.Columns.Add($offsetColumn) | Out-Null

    $typeColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $typeColumn.HeaderText = '種類'
    $typeColumn.ReadOnly = $true
    $typeColumn.FillWeight = 10
    $typeColumn.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
    $grid.Columns.Add($typeColumn) | Out-Null

    $sourceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $sourceColumn.HeaderText = '入力ファイル'
    $sourceColumn.ReadOnly = $true
    $sourceColumn.FillWeight = 40
    $grid.Columns.Add($sourceColumn) | Out-Null

    $upButton = New-Object System.Windows.Forms.Button
    $upButton.Text = '↑ 上へ'
    $upButton.Location = New-Object System.Drawing.Point(754, 108)
    $upButton.Size = New-Object System.Drawing.Size(94, 30)
    $upButton.Anchor = 'Top,Right'
    $upButton.TabIndex = 3
    Set-ButtonTheme -Button $upButton

    $downButton = New-Object System.Windows.Forms.Button
    $downButton.Text = '↓ 下へ'
    $downButton.Location = New-Object System.Drawing.Point(754, 144)
    $downButton.Size = New-Object System.Drawing.Size(94, 30)
    $downButton.Anchor = 'Top,Right'
    $downButton.TabIndex = 4
    Set-ButtonTheme -Button $downButton

    $addTrackButton = New-Object System.Windows.Forms.Button
    $addTrackButton.Text = '+ 追加'
    $addTrackButton.Location = New-Object System.Drawing.Point(754, 188)
    $addTrackButton.Size = New-Object System.Drawing.Size(94, 30)
    $addTrackButton.Anchor = 'Top,Right'
    $addTrackButton.TabIndex = 5
    Set-ButtonTheme -Button $addTrackButton

    $deleteTrackButton = New-Object System.Windows.Forms.Button
    $deleteTrackButton.Text = '- 削除'
    $deleteTrackButton.Location = New-Object System.Drawing.Point(754, 224)
    $deleteTrackButton.Size = New-Object System.Drawing.Size(94, 30)
    $deleteTrackButton.Anchor = 'Top,Right'
    $deleteTrackButton.TabIndex = 6
    Set-ButtonTheme -Button $deleteTrackButton -Kind Danger

    $swapVideoButton = New-Object System.Windows.Forms.Button
    $swapVideoButton.Text = '↔ 動画と交換'
    $swapVideoButton.Location = New-Object System.Drawing.Point(754, 268)
    $swapVideoButton.Size = New-Object System.Drawing.Size(94, 30)
    $swapVideoButton.Anchor = 'Top,Right'
    $swapVideoButton.TabIndex = 7
    Set-ButtonTheme -Button $swapVideoButton
    $offsetToolTip.SetToolTip($swapVideoButton, '選択中の .mp4 トラックと、上の動画ファイルを入れ替えます')

    $outputLabel = New-Object System.Windows.Forms.Label
    $outputLabel.Text = '出力'
    $outputLabel.Location = New-Object System.Drawing.Point(12, 420)
    $outputLabel.Size = New-Object System.Drawing.Size(70, 22)
    $outputLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $outputLabel -Muted

    $outputText = New-Object System.Windows.Forms.TextBox
    $outputText.Text = [string]$Script:DefaultOutputPath
    $outputText.Location = New-Object System.Drawing.Point(88, 417)
    $outputText.Size = New-Object System.Drawing.Size(654, 22)
    $outputText.Anchor = 'Left,Right,Bottom'
    $outputText.TabIndex = 15
    Set-TextBoxTheme -TextBox $outputText

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = '参照...'
    $browseButton.Location = New-Object System.Drawing.Point(754, 414)
    $browseButton.Size = New-Object System.Drawing.Size(94, 28)
    $browseButton.Anchor = 'Right,Bottom'
    $browseButton.TabIndex = 16
    Set-ButtonTheme -Button $browseButton

    $settingsButton = New-Object System.Windows.Forms.Button
    $settingsButton.Text = '設定'
    $settingsButton.Location = New-Object System.Drawing.Point(12, 484)
    $settingsButton.Size = New-Object System.Drawing.Size(94, 30)
    $settingsButton.Anchor = 'Left,Bottom'
    $settingsButton.TabIndex = 17
    Set-ButtonTheme -Button $settingsButton

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = ''
    $statusLabel.Location = New-Object System.Drawing.Point(116, 490)
    $statusLabel.Size = New-Object System.Drawing.Size(478, 22)
    $statusLabel.Anchor = 'Left,Right,Bottom'
    Set-LabelTheme -Label $statusLabel -Muted

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '保存'
    $okButton.Location = New-Object System.Drawing.Point(656, 484)
    $okButton.Size = New-Object System.Drawing.Size(92, 30)
    $okButton.Anchor = 'Right,Bottom'
    $okButton.TabIndex = 18
    Set-ButtonTheme -Button $okButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '閉じる'
    $cancelButton.Location = New-Object System.Drawing.Point(756, 484)
    $cancelButton.Size = New-Object System.Drawing.Size(92, 30)
    $cancelButton.Anchor = 'Right,Bottom'
    $cancelButton.TabIndex = 19
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $cancelButton

    $suppressVideoAudioReset = $false
    $trackDragFormat = 'ffmpegMp4Mix.TrackRowIndex'
    $trackNameColumnIndex = 1
    $offsetColumnIndex = 2
    $typeColumnIndex = 3
    $sourceColumnIndex = 4
    $offsetErrorMessage = 'オフセットは整数（ミリ秒）で入力してください。元の値に戻しました。'
    $allOffsetErrorMessage = '全トラックをずらす量は整数（ミリ秒）で入力してください。'
    $autoOffsetState = [PSCustomObject]@{
        Running     = $false
        PendingAll  = $false
        PendingRows = New-Object System.Collections.ArrayList
    }
    $autoOffsetTimer = New-Object System.Windows.Forms.Timer
    $autoOffsetTimer.Interval = 150
    $trackDragState = [PSCustomObject]@{
        RowIndex = -1
        Box = [System.Drawing.Rectangle]::Empty
    }

    function Update-OffsetStepButtons {
        $stepMs = ConvertTo-OffsetStepMs $Script:Settings.OffsetStepMs
        $selectedOffsetMinusButton.Text = '-' + $stepMs + 'ms'
        $selectedOffsetPlusButton.Text = '+' + $stepMs + 'ms'
        $allOffsetMinusButton.Text = '-' + $stepMs + 'ms'
        $allOffsetPlusButton.Text = '+' + $stepMs + 'ms'
        $offsetToolTip.SetToolTip($selectedOffsetMinusButton, "選択中のトラックを ${stepMs}ms 早める (Ctrl+↓)")
        $offsetToolTip.SetToolTip($selectedOffsetPlusButton, "選択中のトラックを ${stepMs}ms 遅らせる (Ctrl+↑)")
        $offsetToolTip.SetToolTip($allOffsetMinusButton, "全トラックを ${stepMs}ms 早める (Ctrl+Shift+↓)")
        $offsetToolTip.SetToolTip($allOffsetPlusButton, "全トラックを ${stepMs}ms 遅らせる (Ctrl+Shift+↑)")
        $offsetToolTip.SetToolTip($allOffsetText, '全トラックをずらす量（ミリ秒）。+ で遅らせる、- で早める')
        $offsetToolTip.SetToolTip($autoOffsetButton, '動画の音声と聞き比べて、各トラックのオフセットを自動で合わせます')
    }

    function Step-TrackOffsets {
        param(
            [int]$Direction,
            [switch]$AllTracks
        )

        $stepMs = ConvertTo-OffsetStepMs $Script:Settings.OffsetStepMs
        Add-TrackOffsets -DeltaMs ($Direction * $stepMs) -AllTracks:$AllTracks
    }

    function Invoke-AllTrackOffsetInput {
        $deltaMs = ConvertTo-OffsetMs $allOffsetText.Text
        if ($null -eq $deltaMs) {
            $statusLabel.Text = $allOffsetErrorMessage
            return
        }
        if ($deltaMs -eq 0) {
            return
        }

        Add-TrackOffsets -DeltaMs $deltaMs -AllTracks
    }

    function Add-TrackOffsets {
        param(
            [int]$DeltaMs,
            [switch]$AllTracks
        )

        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex

        $rows = @()
        if ($AllTracks) {
            $rows = @($grid.Rows | Where-Object { -not $_.IsNewRow -and $null -ne $_.Tag })
        }
        elseif ($null -ne $grid.CurrentCell) {
            $rows = @($grid.Rows[$grid.CurrentCell.RowIndex])
        }
        elseif ($grid.SelectedRows.Count -gt 0) {
            $rows = @($grid.SelectedRows[0])
        }

        if ($rows.Count -eq 0) {
            Show-ErrorMessage 'オフセットを変更するトラックがありません。'
            return
        }

        foreach ($row in $rows) {
            $offsetMs = ConvertTo-OffsetMs $row.Cells[$offsetColumnIndex].Value
            if ($null -eq $offsetMs) {
                $offsetMs = [int]$row.Tag.OffsetMs
            }

            $offsetMs += $DeltaMs
            $row.Cells[$offsetColumnIndex].Value = Format-OffsetMs $offsetMs
            $row.Tag.OffsetMs = $offsetMs
            if (-not $AllTracks -or [string]$row.Tag.OffsetNoteLevel -ne 'error') {
                Set-OffsetCellNote -Row $row -Note '' -NoteLevel ''
            }
        }

        if ($statusLabel.Text -eq $offsetErrorMessage -or $statusLabel.Text -eq $allOffsetErrorMessage) {
            $statusLabel.Text = ''
        }
    }

    function Get-TrackRowCount {
        return @($grid.Rows | Where-Object { -not $_.IsNewRow -and $null -ne $_.Tag }).Count
    }

    function Update-DefaultOutputPath {
        $oldDefault = [string]$Script:DefaultOutputPath
        $Script:DefaultOutputPath = Get-DefaultOutputPath -VideoFile $Script:VideoFile -Settings $Script:Settings -TrackCount (Get-TrackRowCount)
        if ([string]::IsNullOrWhiteSpace([string]$outputText.Text) -or $outputText.Text -eq $oldDefault) {
            $outputText.Text = $Script:DefaultOutputPath
        }
    }

    function Reset-GridFromInputs {
        $previousItems = @(Get-TrackItemsFromGrid -Grid $grid)
        $includeVideoAudio = $useVideoAudio.Checked -and (Test-VideoSelected)
        $trackCount = @($Script:AudioFiles).Count + $(if ($includeVideoAudio) { 1 } else { 0 })
        $items = @()
        $trackNumber = 1
        if ($includeVideoAudio) {
            $items += New-TrackItem -SourceFile $Script:VideoFile -IsVideoAudio $true -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex $trackNumber -TrackCount $trackCount)
            $trackNumber++
        }

        foreach ($audioFile in $Script:AudioFiles) {
            $items += New-TrackItem -SourceFile $audioFile -IsVideoAudio $false -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex $trackNumber -TrackCount $trackCount)
            $trackNumber++
        }
        Copy-TrackOffsets -Items $items -SourceItems $previousItems
        Set-TrackItemsToGrid -Grid $grid -Items $items
    }

    function Set-VideoAudioTrackEnabled {
        param([bool]$Enabled)

        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        $items = @(Get-TrackItemsFromGrid -Grid $grid)
        $videoItem = $null
        $audioItems = @()

        foreach ($item in $items) {
            if ([bool]$item.IsVideoAudio) {
                if ($null -eq $videoItem) {
                    $videoItem = $item
                }
                continue
            }

            $audioItems += $item
        }

        if ($Enabled -and (Test-VideoSelected)) {
            if ($null -eq $videoItem) {
                $videoItem = New-TrackItem -SourceFile $Script:VideoFile -IsVideoAudio $true -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex 1 -TrackCount ($audioItems.Count + 1))
            }
            else {
                $videoItem.SourceFile = $Script:VideoFile
            }

            $items = @($videoItem) + $audioItems
        }
        else {
            $items = $audioItems
        }

        Set-TrackItemsToGrid -Grid $grid -Items $items
        Sync-AudioFilesFromGrid -Grid $grid
        Update-DefaultOutputPath
    }

    function Update-VideoAudioRows {
        $updated = $false
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow -or $null -eq $row.Tag) {
                continue
            }

            if ([bool]$row.Tag.IsVideoAudio) {
                $row.Tag.SourceFile = $Script:VideoFile
                $row.Cells[$typeColumnIndex].Value = Get-TrackTypeText $row.Tag
                $row.Cells[$sourceColumnIndex].Value = Get-TrackSourceText $row.Tag
                $row.Cells[$sourceColumnIndex].ToolTipText = [string]$row.Tag.SourceFile
                $updated = $true
            }
        }

        if (-not $updated -and $useVideoAudio.Checked) {
            Set-VideoAudioTrackEnabled -Enabled $true
        }
    }

    function Invoke-TrackGridTab {
        param([int]$Delta)

        if ($null -eq $grid.CurrentCell) {
            $currentRowIndex = if ($Delta -lt 0) { $grid.Rows.Count } else { -1 }
        }
        else {
            $currentRowIndex = [int]$grid.CurrentCell.RowIndex
        }

        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        if (-not (Set-TrackNameCell -Grid $grid -RowIndex ($currentRowIndex + $Delta) -TrackNameColumnIndex $trackNameColumnIndex)) {
            if ($Delta -gt 0) {
                $okButton.Focus() | Out-Null
            }
            else {
                [void]$form.SelectNextControl($grid, $false, $true, $true, $true)
            }
        }
    }

    function Show-TrackNameCandidateMenu {
        param([int]$RowIndex)

        if ($RowIndex -lt 0 -or $RowIndex -ge $grid.Rows.Count -or $grid.Rows[$RowIndex].IsNewRow) {
            return $false
        }

        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        [void](Set-TrackNameCell -Grid $grid -RowIndex $RowIndex -TrackNameColumnIndex $trackNameColumnIndex)

        $candidates = @(Get-TrackNameCandidateValuesFromGrid -Grid $grid | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        if ($candidates.Count -eq 0) {
            return $false
        }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.ShowImageMargin = $false
        $currentValue = [string]$grid.Rows[$RowIndex].Cells[$trackNameColumnIndex].Value

        foreach ($candidate in $candidates) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem
            $item.Text = [string]$candidate
            $item.Tag = [PSCustomObject]@{
                RowIndex = $RowIndex
                Name     = [string]$candidate
            }
            if ([string]$candidate -eq $currentValue) {
                $item.Checked = $true
            }
            $item.Add_Click({
                param($sender, $eventArgs)

                $data = $sender.Tag
                [void](Set-TrackNameCellValue -Grid $grid -RowIndex ([int]$data.RowIndex) -Value ([string]$data.Name) -TrackNameColumnIndex $trackNameColumnIndex)
                [void](Set-TrackNameCell -Grid $grid -RowIndex ([int]$data.RowIndex) -TrackNameColumnIndex $trackNameColumnIndex)
                $grid.Focus() | Out-Null
            })
            [void]$menu.Items.Add($item)
        }

        $cellRect = $grid.GetCellDisplayRectangle($trackNameColumnIndex, $RowIndex, $true)
        $menu.Show($grid, $cellRect.Left, $cellRect.Bottom)
        return $true
    }

    function Show-CurrentTrackNameCandidateMenu {
        $rowIndex = -1
        if ($null -ne $grid.CurrentCell) {
            $rowIndex = $grid.CurrentCell.RowIndex
        }
        elseif ($grid.SelectedRows.Count -gt 0) {
            $rowIndex = $grid.SelectedRows[0].Index
        }

        if ($rowIndex -lt 0) {
            return $false
        }

        return Show-TrackNameCandidateMenu -RowIndex $rowIndex
    }

    function Set-MainVideoFile {
        param([string]$VideoFile)

        if (-not (Test-Mp4FilePath $VideoFile)) {
            throw '動画ファイルには存在する .mp4 ファイルを指定してください。'
        }

        $Script:VideoFile = [System.IO.Path]::GetFullPath($VideoFile)
        $videoText.Text = $Script:VideoFile
        $useVideoAudio.Enabled = $true

        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow -and $null -ne $row.Tag) {
                Set-OffsetCellNote -Row $row -Note '' -NoteLevel ''
            }
        }
        Update-VideoAudioRows
        Update-DefaultOutputPath
        Request-AutoOffset
    }

    function Request-AutoOffset {
        param([object[]]$Rows = $null)

        if (-not (ConvertTo-SettingFlag $Script:Settings.AutoOffsetAlways)) {
            return
        }

        if ($null -eq $Rows) {
            $autoOffsetState.PendingAll = $true
        }
        else {
            foreach ($row in $Rows) {
                [void]$autoOffsetState.PendingRows.Add($row)
            }
        }
        $autoOffsetTimer.Stop()
        $autoOffsetTimer.Start()
    }

    function Invoke-AutoOffset {
        param(
            [object[]]$TargetRows = $null,
            [switch]$Automatic
        )

        if ($autoOffsetState.Running) {
            return
        }

        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        if (-not (Test-VideoSelected) -or -not (Test-Path -LiteralPath $Script:VideoFile -PathType Leaf)) {
            if (-not $Automatic) {
                Show-ErrorMessage '動画ファイルを指定してください。'
            }
            return
        }

        $ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
        if (-not (Test-Path -LiteralPath $ffmpegPath)) {
            if ($Automatic) {
                $statusLabel.Text = '自動調整: ffmpeg.exe が見つからないため調整できませんでした。'
            }
            else {
                Show-ErrorMessage "ffmpeg.exe が見つかりません。`r`n$ffmpegPath"
            }
            return
        }

        $candidateRows = if ($null -eq $TargetRows) { @($grid.Rows) } else { @($TargetRows) }
        $rows = @($candidateRows | Where-Object { $null -ne $_.DataGridView -and -not $_.IsNewRow -and $null -ne $_.Tag -and -not [bool]$_.Tag.IsVideoAudio })
        if ($rows.Count -eq 0) {
            if (-not $Automatic) {
                Show-ErrorMessage '自動調整するトラックがありません。'
            }
            return
        }

        $disabledControls = @($form.Controls | Where-Object { $_.Enabled -and -not ($_ -is [System.Windows.Forms.Label]) })
        foreach ($control in $disabledControls) {
            $control.Enabled = $false
        }
        $autoOffsetState.Running = $true
        $form.UseWaitCursor = $true
        $applied = 0
        $needsCheck = 0
        $unchanged = 0
        try {
            $statusLabel.Text = '自動調整中: 動画の音声を解析しています...'
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $reference = Get-AutoOffsetReference -FfmpegPath $ffmpegPath -VideoFile $Script:VideoFile
            }
            catch {
                $message = $_.Exception.GetBaseException().Message
                if ($Automatic) {
                    $statusLabel.Text = '自動調整: 動画の音声を解析できませんでした。'
                }
                else {
                    $statusLabel.Text = ''
                    Show-ErrorMessage ("動画の音声を解析できませんでした。`r`n`r`n" + $message)
                }
                return
            }

            for ($index = 0; $index -lt $rows.Count; $index++) {
                $row = $rows[$index]
                $sourceFile = [string]$row.Tag.SourceFile
                $statusLabel.Text = '自動調整中 ({0}/{1}): {2}' -f ($index + 1), $rows.Count, [System.IO.Path]::GetFileName($sourceFile)
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    $result = [AudioOffsetAnalyzer]::Analyze($reference, [AudioOffsetAnalyzer]::Load($ffmpegPath, $sourceFile))
                }
                catch {
                    Set-OffsetCellNote -Row $row -Note ('自動調整できませんでした: ' + $_.Exception.GetBaseException().Message) -NoteLevel 'error'
                    $unchanged++
                    continue
                }

                $note = Format-AutoOffsetNote $result
                if ($result.Level -eq '低') {
                    Set-OffsetCellNote -Row $row -Note $note -NoteLevel 'error'
                    $unchanged++
                    continue
                }

                $row.Cells[$offsetColumnIndex].Value = Format-OffsetMs ([int]$result.OffsetMs)
                $row.Tag.OffsetMs = [int]$result.OffsetMs
                if ($result.Level -eq '高' -and -not $result.DriftWarning) {
                    Set-OffsetCellNote -Row $row -Note $note -NoteLevel ''
                }
                else {
                    Set-OffsetCellNote -Row $row -Note $note -NoteLevel 'warn'
                    $needsCheck++
                }
                $applied++
            }

            $parts = @('{0}件調整' -f $applied)
            if ($needsCheck -gt 0) {
                $parts += '{0}件は要確認' -f $needsCheck
            }
            if ($unchanged -gt 0) {
                $parts += '{0}件は変更なし' -f $unchanged
            }
            $statusLabel.Text = '自動調整: ' + ($parts -join ' / ')
            if ($needsCheck + $unchanged -gt 0) {
                $statusLabel.Text += '（色付きのセルにマウスで詳細）'
            }
        }
        finally {
            $form.UseWaitCursor = $false
            $autoOffsetState.Running = $false
            foreach ($control in $disabledControls) {
                $control.Enabled = $true
            }
        }
    }

    function Get-DraggedTrackInfo {
        param([System.Windows.Forms.IDataObject]$Data)

        if (-not $Data.GetDataPresent($trackDragFormat)) {
            return $null
        }

        $rowIndex = [int]$Data.GetData($trackDragFormat)
        if ($rowIndex -lt 0 -or $rowIndex -ge $grid.Rows.Count) {
            return $null
        }

        $row = $grid.Rows[$rowIndex]
        if ($null -eq $row.Tag) {
            return $null
        }

        [PSCustomObject]@{
            RowIndex = $rowIndex
            Row      = $row
            Item     = $row.Tag
        }
    }

    function Test-TrackCanSwapToVideo {
        param([System.Windows.Forms.IDataObject]$Data)

        $trackInfo = Get-DraggedTrackInfo -Data $Data
        if ($null -eq $trackInfo -or [bool]$trackInfo.Item.IsVideoAudio) {
            return $false
        }

        return Test-Mp4FilePath ([string]$trackInfo.Item.SourceFile)
    }

    function Swap-TrackWithMainVideo {
        param([int]$RowIndex)

        if ($RowIndex -lt 0 -or $RowIndex -ge $grid.Rows.Count) {
            return
        }

        $row = $grid.Rows[$RowIndex]
        $tag = $row.Tag
        if ($null -eq $tag) {
            return
        }
        if ([bool]$tag.IsVideoAudio) {
            throw '元動画の音声トラックは動画欄と入れ替えできません。'
        }
        if (-not (Test-Mp4FilePath ([string]$tag.SourceFile))) {
            throw '動画欄と入れ替えできるのは .mp4 のトラックだけです。'
        }

        $newVideo = [System.IO.Path]::GetFullPath([string]$tag.SourceFile)
        $oldVideo = ''
        if (Test-VideoSelected) {
            $oldVideo = [System.IO.Path]::GetFullPath([string]$Script:VideoFile)
        }

        if ([string]::IsNullOrWhiteSpace($oldVideo)) {
            Remove-AudioFileFromState -SourceFile $newVideo
            $grid.Rows.RemoveAt($RowIndex)
            Update-TrackNumbers -Grid $grid
        }
        else {
            $tag.SourceFile = $oldVideo
            $row.Cells[$typeColumnIndex].Value = Get-TrackTypeText $tag
            $row.Cells[$sourceColumnIndex].Value = Get-TrackSourceText $tag
            $row.Cells[$sourceColumnIndex].ToolTipText = [string]$tag.SourceFile
        }

        Set-MainVideoFile -VideoFile $newVideo
        Sync-AudioFilesFromGrid -Grid $grid

        if ($grid.Rows.Count -gt 0) {
            $newIndex = [Math]::Min($RowIndex, $grid.Rows.Count - 1)
            $grid.CurrentCell = $grid.Rows[$newIndex].Cells[1]
        }
    }

    function Set-VideoDropEffect {
        param([System.Windows.Forms.DragEventArgs]$DragEvent)

        if ($autoOffsetState.Running) {
            $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::None
            return
        }
        if ($DragEvent.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            return
        }
        elseif (Test-TrackCanSwapToVideo -Data $DragEvent.Data) {
            $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::Move
            return
        }

        $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::None
    }

    function Invoke-VideoDrop {
        param([System.Windows.Forms.DragEventArgs]$DragEvent)

        if ($autoOffsetState.Running) {
            return
        }
        try {
            if ($DragEvent.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
                $droppedVideo = Get-FirstMp4FilePath @($DragEvent.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
                if ([string]::IsNullOrWhiteSpace($droppedVideo)) {
                    Show-ErrorMessage '動画欄には .mp4 ファイルをドロップしてください。'
                    return
                }

                Set-MainVideoFile -VideoFile $droppedVideo
                return
            }

            $trackInfo = Get-DraggedTrackInfo -Data $DragEvent.Data
            if ($null -ne $trackInfo) {
                Swap-TrackWithMainVideo -RowIndex $trackInfo.RowIndex
            }
        }
        catch {
            Show-ErrorMessage $_.Exception.Message
        }
    }

    function Add-VideoDropHandlers {
        param([System.Windows.Forms.Control]$Control)

        $Control.AllowDrop = $true
        $Control.Add_DragEnter({ Set-VideoDropEffect -DragEvent $_ })
        $Control.Add_DragOver({ Set-VideoDropEffect -DragEvent $_ })
        $Control.Add_DragDrop({ Invoke-VideoDrop -DragEvent $_ })
    }

    function Test-VideoDropArea {
        param([System.Windows.Forms.DragEventArgs]$DragEvent)

        $screenPoint = New-Object System.Drawing.Point -ArgumentList $DragEvent.X, $DragEvent.Y
        $point = $form.PointToClient($screenPoint)
        $area = [System.Drawing.Rectangle]::Union($videoLabel.Bounds, $videoText.Bounds)
        $area = [System.Drawing.Rectangle]::Union($area, $videoBrowseButton.Bounds)
        $area.Inflate(6, 6)
        return $area.Contains($point)
    }

    Add-VideoDropHandlers -Control $videoLabel
    Add-VideoDropHandlers -Control $videoText
    Add-VideoDropHandlers -Control $videoBrowseButton
    $form.AllowDrop = $true
    $form.Add_DragEnter({
        if (Test-VideoDropArea -DragEvent $_) {
            Set-VideoDropEffect -DragEvent $_
        }
        else {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })
    $form.Add_DragOver({
        if (Test-VideoDropArea -DragEvent $_) {
            Set-VideoDropEffect -DragEvent $_
        }
        else {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })
    $form.Add_DragDrop({
        if (Test-VideoDropArea -DragEvent $_) {
            Invoke-VideoDrop -DragEvent $_
        }
    })

    $videoBrowseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'MP4 files (*.mp4)|*.mp4|All files (*.*)|*.*'
        $dialog.Multiselect = $false
        $dialog.FileName = [System.IO.Path]::GetFileName([string]$Script:VideoFile)
        $dialog.InitialDirectory = Get-InitialDirectory -Paths @($Script:VideoFile)
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                Set-MainVideoFile -VideoFile $dialog.FileName
            }
            catch {
                Show-ErrorMessage $_.Exception.Message
            }
        }
    })

    $useVideoAudio.Add_CheckedChanged({
        if ($suppressVideoAudioReset) {
            return
        }
        Set-VideoAudioTrackEnabled -Enabled $useVideoAudio.Checked
        if ($grid.Rows.Count -gt 0) {
            $grid.CurrentCell = $grid.Rows[0].Cells[1]
        }
    })

    $grid.Add_TrackTabPressed({
        $delta = if ($_.Shift) { -1 } else { 1 }
        Invoke-TrackGridTab -Delta $delta
    })

    $grid.Add_TrackNameCandidatesPressed({
        [void](Show-CurrentTrackNameCandidateMenu)
    })

    $grid.Add_EditingControlShowing({
        if ($null -eq $grid.CurrentCell) {
            return
        }

        if ($grid.CurrentCell.ColumnIndex -eq $offsetColumnIndex) {
            $offsetTextBox = $_.Control -as [System.Windows.Forms.TextBox]
            if ($null -ne $offsetTextBox) {
                $offsetTextBox.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
            }
            return
        }

        if ($grid.CurrentCell.ColumnIndex -ne $trackNameColumnIndex) {
            return
        }

        $textBox = $_.Control -as [System.Windows.Forms.TextBox]
        if ($null -ne $textBox) {
            $textBox.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::Suggest
            $textBox.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::CustomSource
            $textBox.AutoCompleteCustomSource = New-TrackNameAutoCompleteSource -Grid $grid
            return
        }

        $combo = $_.Control -as [System.Windows.Forms.ComboBox]
        if ($null -ne $combo) {
            $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
            $combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
            $combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
        }
    })

    $grid.Add_CellParsing({
        if ($_.ColumnIndex -eq $offsetColumnIndex) {
            $offsetRow = $grid.Rows[$_.RowIndex]
            $offsetMs = ConvertTo-OffsetMs $_.Value
            if ($null -eq $offsetMs) {
                $_.Value = $offsetRow.Cells[$offsetColumnIndex].Value
                $statusLabel.Text = $offsetErrorMessage
            }
            else {
                $_.Value = Format-OffsetMs $offsetMs
                if ($null -ne $offsetRow.Tag) {
                    $offsetRow.Tag.OffsetMs = $offsetMs
                    Set-OffsetCellNote -Row $offsetRow -Note '' -NoteLevel ''
                }
                if ($statusLabel.Text -eq $offsetErrorMessage) {
                    $statusLabel.Text = ''
                }
            }
            $_.ParsingApplied = $true
            return
        }

        if ($_.ColumnIndex -ne $trackNameColumnIndex) {
            return
        }

        $text = [string]$_.Value
        Add-TrackNameCandidateToGrid -Grid $grid -Name $text -TrackNameColumnIndex $trackNameColumnIndex
        $_.Value = $text
        $_.ParsingApplied = $true
    })

    $grid.Add_CellValidating({
        if ($_.ColumnIndex -eq $trackNameColumnIndex) {
            Add-TrackNameCandidateToGrid -Grid $grid -Name ([string]$_.FormattedValue) -TrackNameColumnIndex $trackNameColumnIndex
        }
    })

    $grid.Add_CellEndEdit({
        if ($_.ColumnIndex -eq $trackNameColumnIndex) {
            Add-TrackNameCandidateToGrid -Grid $grid -Name ([string]$grid.Rows[$_.RowIndex].Cells[$_.ColumnIndex].Value) -TrackNameColumnIndex $trackNameColumnIndex
        }
    })

    $grid.Add_DataError({
        $_.ThrowException = $false
    })

    $grid.Add_MouseDown({
        $trackDragState.RowIndex = -1
        $trackDragState.Box = [System.Drawing.Rectangle]::Empty
        if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }

        $hit = $grid.HitTest($_.X, $_.Y)
        if ($hit.RowIndex -lt 0) {
            return
        }

        $trackDragState.RowIndex = $hit.RowIndex
        if ($hit.ColumnIndex -eq $offsetColumnIndex) {
            $grid.CurrentCell = $grid.Rows[$hit.RowIndex].Cells[$offsetColumnIndex]
        }
        else {
            [void](Set-TrackNameCell -Grid $grid -RowIndex $hit.RowIndex -TrackNameColumnIndex $trackNameColumnIndex)
        }

        $dragSize = [System.Windows.Forms.SystemInformation]::DragSize
        $trackDragState.Box = New-Object System.Drawing.Rectangle -ArgumentList `
            ($_.X - [int]($dragSize.Width / 2)),
            ($_.Y - [int]($dragSize.Height / 2)),
            $dragSize.Width,
            $dragSize.Height
    })

    $grid.Add_MouseUp({
        if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }

        $hit = $grid.HitTest($_.X, $_.Y)
        if ($hit.RowIndex -lt 0 -or $hit.ColumnIndex -ne $trackNameColumnIndex) {
            return
        }
        if ($trackDragState.RowIndex -ne $hit.RowIndex) {
            return
        }

        [void](Show-TrackNameCandidateMenu -RowIndex $hit.RowIndex)
        $trackDragState.RowIndex = -1
        $trackDragState.Box = [System.Drawing.Rectangle]::Empty
    })

    $grid.Add_MouseMove({
        if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $trackDragState.RowIndex -lt 0) {
            return
        }
        if ($trackDragState.Box.Width -le 0 -or $trackDragState.Box.Contains($_.X, $_.Y)) {
            return
        }

        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData($trackDragFormat, $false, [int]$trackDragState.RowIndex)
        [void]$grid.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Move)
        $trackDragState.RowIndex = -1
        $trackDragState.Box = [System.Drawing.Rectangle]::Empty
    })

    $grid.Add_DragEnter({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
        elseif ($_.Data.GetDataPresent($trackDragFormat)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Move
        }
        else {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })

    $grid.Add_DragOver({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
        elseif ($_.Data.GetDataPresent($trackDragFormat)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Move
        }
        else {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })

    $grid.Add_DragDrop({
        try {
            if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
                $droppedFiles = @($_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
                $dropFiles = Split-TrackDropFiles -FilePaths $droppedFiles -VideoAlreadySelected (Test-VideoSelected)
                $selectedVideoFromDrop = -not [string]::IsNullOrWhiteSpace([string]$dropFiles.VideoFile)
                if ($selectedVideoFromDrop) {
                    Set-MainVideoFile -VideoFile ([string]$dropFiles.VideoFile)
                }

                $addedCount = Add-TrackFilesToGrid -Grid $grid -FilePaths @($dropFiles.TrackFiles) -Settings $Script:Settings
                if ($addedCount -eq 0 -and -not $selectedVideoFromDrop) {
                    Show-ErrorMessage '追加できるファイルがありませんでした。'
                }
                if ($addedCount -gt 0) {
                    Request-AutoOffset -Rows @($grid.Rows | Select-Object -Last $addedCount)
                }
                Update-DefaultOutputPath
                return
            }

            if ($_.Data.GetDataPresent($trackDragFormat)) {
                $oldIndex = [int]$_.Data.GetData($trackDragFormat)
                $newIndex = Get-GridDropIndex -Grid $grid -ScreenX $_.X -ScreenY $_.Y
                Move-TrackToIndex -Grid $grid -OldIndex $oldIndex -NewIndex $newIndex
            }
        }
        catch {
            Show-ErrorMessage $_.Exception.Message
        }
    })

    $upButton.Add_Click({ Move-CurrentTrack -Grid $grid -Delta -1 })
    $downButton.Add_Click({ Move-CurrentTrack -Grid $grid -Delta 1 })
    $selectedOffsetMinusButton.Add_Click({ Step-TrackOffsets -Direction -1 })
    $selectedOffsetPlusButton.Add_Click({ Step-TrackOffsets -Direction 1 })
    $allOffsetMinusButton.Add_Click({ Step-TrackOffsets -Direction -1 -AllTracks })
    $allOffsetPlusButton.Add_Click({ Step-TrackOffsets -Direction 1 -AllTracks })
    $allOffsetApplyButton.Add_Click({ Invoke-AllTrackOffsetInput })
    $autoOffsetButton.Add_Click({ Invoke-AutoOffset })
    $autoOffsetTimer.Add_Tick({
        if ($autoOffsetState.Running) {
            return
        }
        $autoOffsetTimer.Stop()
        if ($form.IsDisposed -or -not $form.Visible) {
            return
        }

        $pendingAll = $autoOffsetState.PendingAll
        $pendingRows = @($autoOffsetState.PendingRows.ToArray())
        $autoOffsetState.PendingAll = $false
        $autoOffsetState.PendingRows.Clear()
        if ($pendingAll) {
            Invoke-AutoOffset -Automatic
        }
        elseif ($pendingRows.Count -gt 0) {
            Invoke-AutoOffset -TargetRows $pendingRows -Automatic
        }
    })
    $form.Add_FormClosing({
        if ($autoOffsetState.Running) {
            $_.Cancel = $true
        }
    })
    $form.Add_FormClosed({
        $autoOffsetTimer.Stop()
    })
    $allOffsetText.Add_Enter({ $form.AcceptButton = $allOffsetApplyButton })
    $allOffsetText.Add_Leave({ $form.AcceptButton = $okButton })

    $grid.Add_OffsetStepPressed({
        if ($_.AllTracks) {
            Step-TrackOffsets -Direction $_.Direction -AllTracks
        }
        else {
            Step-TrackOffsets -Direction $_.Direction
        }
    })

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        $keyEvent = $_
        $isOffsetKey = $keyEvent.Control -and -not $keyEvent.Alt -and
            ($keyEvent.KeyCode -eq [System.Windows.Forms.Keys]::Up -or $keyEvent.KeyCode -eq [System.Windows.Forms.Keys]::Down)
        if (-not $isOffsetKey) {
            return
        }

        $direction = if ($keyEvent.KeyCode -eq [System.Windows.Forms.Keys]::Up) { 1 } else { -1 }
        if ($keyEvent.Shift) {
            Step-TrackOffsets -Direction $direction -AllTracks
        }
        else {
            Step-TrackOffsets -Direction $direction
        }
        $keyEvent.Handled = $true
        $keyEvent.SuppressKeyPress = $true
    })

    $addTrackButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Media files (*.mp4;*.m4a;*.aac;*.mp3;*.wav;*.flac;*.ogg)|*.mp4;*.m4a;*.aac;*.mp3;*.wav;*.flac;*.ogg|All files (*.*)|*.*'
        $dialog.Multiselect = $true
        $dialog.InitialDirectory = Get-InitialDirectory -Paths @($Script:VideoFile)
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $addedCount = Add-TrackFilesToGrid -Grid $grid -FilePaths @($dialog.FileNames) -Settings $Script:Settings
            if ($addedCount -eq 0) {
                Show-ErrorMessage '追加できるファイルがありませんでした。'
            }
            else {
                Request-AutoOffset -Rows @($grid.Rows | Select-Object -Last $addedCount)
            }
            Update-DefaultOutputPath
        }
    })

    $deleteTrackButton.Add_Click({
        if ($null -eq $grid.CurrentCell) {
            Show-ErrorMessage '削除するトラックを選択してください。'
            return
        }

        $rowIndex = $grid.CurrentCell.RowIndex
        if ($rowIndex -lt 0 -or $rowIndex -ge $grid.Rows.Count) {
            return
        }

        $tag = $grid.Rows[$rowIndex].Tag
        if ($null -eq $tag) {
            return
        }

        if ([bool]$tag.IsVideoAudio) {
            $grid.Rows.RemoveAt($rowIndex)
            Update-TrackNumbers -Grid $grid
            $suppressVideoAudioReset = $true
            $useVideoAudio.Checked = $false
            $suppressVideoAudioReset = $false
        }
        else {
            Remove-AudioFileFromState -SourceFile ([string]$tag.SourceFile)
            $grid.Rows.RemoveAt($rowIndex)
            Update-TrackNumbers -Grid $grid
        }
        Update-DefaultOutputPath

        if ($grid.Rows.Count -gt 0) {
            $newIndex = [Math]::Min($rowIndex, $grid.Rows.Count - 1)
            $grid.CurrentCell = $grid.Rows[$newIndex].Cells[1]
        }
    })

    $swapVideoButton.Add_Click({
        if ($null -eq $grid.CurrentCell) {
            Show-ErrorMessage '動画と入れ替えるトラックを選択してください。'
            return
        }

        try {
            Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
            Swap-TrackWithMainVideo -RowIndex $grid.CurrentCell.RowIndex
        }
        catch {
            Show-ErrorMessage $_.Exception.Message
        }
    })

    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'MP4 files (*.mp4)|*.mp4|All files (*.*)|*.*'
        $dialog.FileName = [System.IO.Path]::GetFileName([string]$outputText.Text)
        $dialog.InitialDirectory = Get-InitialDirectory -Paths @($outputText.Text, $Script:VideoFile)
        $dialog.OverwritePrompt = $true
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputText.Text = $dialog.FileName
        }
    })

    $settingsButton.Add_Click({
        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        $oldSettings = $Script:Settings
        $Script:Settings = Show-SettingsDialog -CurrentSettings $Script:Settings
        Set-TrackNameCandidateColumnItems -Grid $grid -Settings $Script:Settings
        Update-OffsetStepButtons
        Update-DefaultOutputPath

        if (-not (Test-TrackNameDefaultsChanged -OldSettings $oldSettings -NewSettings $Script:Settings)) {
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            '現在のトラック名を新しい初期値で更新しますか？',
            'ffmpegMp4Mix GUI',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Reset-GridFromInputs
        }
    })

    $okButton.Add_Click({
        try {
            Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
            if (-not (Test-VideoSelected)) {
                Show-ErrorMessage '動画ファイルを指定してください。'
                return
            }
            if (-not (Test-Path -LiteralPath $Script:VideoFile -PathType Leaf)) {
                Show-ErrorMessage "動画ファイルが見つかりません。`r`n$Script:VideoFile"
                return
            }

            $trackItems = @(Get-TrackItemsFromGrid -Grid $grid)
            if ($trackItems.Count -eq 0) {
                Show-ErrorMessage '音声トラックがありません。'
                return
            }

            foreach ($item in $trackItems) {
                if ([string]::IsNullOrWhiteSpace([string]$item.Title)) {
                    Show-ErrorMessage '空のトラック名があります。'
                    return
                }
            }

            $outputPath = [string]$outputText.Text
            if ([string]::IsNullOrWhiteSpace($outputPath)) {
                Show-ErrorMessage '出力ファイルを指定してください。'
                return
            }

            $unadjustedTracks = @()
            for ($index = 0; $index -lt $trackItems.Count; $index++) {
                if ([string]$trackItems[$index].OffsetNoteLevel -eq 'error') {
                    $unadjustedTracks += '・{0}. {1}（{2}）' -f ($index + 1), $trackItems[$index].Title, [System.IO.Path]::GetFileName([string]$trackItems[$index].SourceFile)
                }
            }
            if ($unadjustedTracks.Count -gt 0) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    "自動調整でずれを判定できなかったトラックがあります。オフセットが合っていない可能性があります。`r`n`r`n" + ($unadjustedTracks -join "`r`n") + "`r`n`r`nこのまま保存しますか？",
                    'ffmpegMp4Mix GUI',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning,
                    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
                )
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    return
                }
            }

            $statusLabel.Text = '保存中...'
            $form.UseWaitCursor = $true
            $form.Refresh()

            $ran = Invoke-Ffmpeg -OutputPath $outputPath -TrackItems $trackItems
            if ($ran) {
                $statusLabel.Text = '保存しました: {0}（{1}）' -f [System.IO.Path]::GetFileName($outputPath), (Get-Date -Format 'HH:mm:ss')
            }
            else {
                $statusLabel.Text = ''
            }
        }
        catch {
            $statusLabel.Text = ''
            Show-ErrorMessage $_.Exception.Message
        }
        finally {
            $form.UseWaitCursor = $false
        }
    })

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Controls.AddRange(@(
        $videoLabel, $videoText, $videoBrowseButton, $useVideoAudio,
        $selectedOffsetLabel, $selectedOffsetMinusButton, $selectedOffsetPlusButton,
        $allOffsetLabel, $allOffsetMinusButton, $allOffsetPlusButton,
        $allOffsetText, $allOffsetApplyButton, $autoOffsetButton, $grid,
        $upButton, $downButton, $addTrackButton, $deleteTrackButton, $swapVideoButton,
        $outputLabel, $outputText, $browseButton, $settingsButton,
        $statusLabel, $okButton, $cancelButton
    ))

    Update-OffsetStepButtons
    Reset-GridFromInputs
    if ($grid.Rows.Count -gt 0) {
        $grid.CurrentCell = $grid.Rows[0].Cells[1]
    }

    $form.Add_Shown({
        if ($grid.Rows.Count -gt 0) {
            $grid.Focus() | Out-Null
            $grid.CurrentCell = $grid.Rows[0].Cells[1]
        }
        Request-AutoOffset
    })

    [void]$form.ShowDialog()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

public class TrackTabEventArgs : EventArgs
{
    public bool Shift { get; private set; }

    public TrackTabEventArgs(bool shift)
    {
        Shift = shift;
    }
}

public class OffsetStepEventArgs : EventArgs
{
    public int Direction { get; private set; }
    public bool AllTracks { get; private set; }

    public OffsetStepEventArgs(int direction, bool allTracks)
    {
        Direction = direction;
        AllTracks = allTracks;
    }
}

public class TrackNameDataGridView : DataGridView
{
    public event EventHandler<TrackTabEventArgs> TrackTabPressed;
    public event EventHandler TrackNameCandidatesPressed;
    public event EventHandler<OffsetStepEventArgs> OffsetStepPressed;

    private bool HandleOffsetStep(Keys keyData)
    {
        Keys keyCode = keyData & Keys.KeyCode;
        bool isCtrlArrow = (keyData & Keys.Control) == Keys.Control && (keyData & Keys.Alt) != Keys.Alt && (keyCode == Keys.Up || keyCode == Keys.Down);
        if (!isCtrlArrow)
        {
            return false;
        }

        EventHandler<OffsetStepEventArgs> handler = OffsetStepPressed;
        if (handler != null)
        {
            handler(this, new OffsetStepEventArgs(keyCode == Keys.Up ? 1 : -1, (keyData & Keys.Shift) == Keys.Shift));
        }
        return true;
    }

    private bool HandleTrackTab(Keys keyData)
    {
        if ((keyData & Keys.KeyCode) != Keys.Tab)
        {
            return false;
        }

        EventHandler<TrackTabEventArgs> handler = TrackTabPressed;
        if (handler != null)
        {
            handler(this, new TrackTabEventArgs((keyData & Keys.Shift) == Keys.Shift));
        }
        return true;
    }

    private bool HandleTrackNameCandidates(Keys keyData)
    {
        Keys keyCode = keyData & Keys.KeyCode;
        bool isAltArrow = (keyData & Keys.Alt) == Keys.Alt && (keyCode == Keys.Down || keyCode == Keys.Up);
        bool isF4 = keyCode == Keys.F4;
        if (!isAltArrow && !isF4)
        {
            return false;
        }

        EventHandler handler = TrackNameCandidatesPressed;
        if (handler != null)
        {
            handler(this, EventArgs.Empty);
        }
        return true;
    }

    protected override bool ProcessDialogKey(Keys keyData)
    {
        if (HandleOffsetStep(keyData))
        {
            return true;
        }
        if (HandleTrackNameCandidates(keyData))
        {
            return true;
        }
        if (HandleTrackTab(keyData))
        {
            return true;
        }
        return base.ProcessDialogKey(keyData);
    }

    protected override bool ProcessDataGridViewKey(KeyEventArgs e)
    {
        if (HandleOffsetStep(e.KeyData))
        {
            return true;
        }
        if ((e.Alt && (e.KeyCode == Keys.Down || e.KeyCode == Keys.Up)) || e.KeyCode == Keys.F4)
        {
            EventHandler handler = TrackNameCandidatesPressed;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
            return true;
        }
        if (e.KeyCode == Keys.Tab)
        {
            EventHandler<TrackTabEventArgs> handler = TrackTabPressed;
            if (handler != null)
            {
                handler(this, new TrackTabEventArgs(e.Shift));
            }
            return true;
        }
        return base.ProcessDataGridViewKey(e);
    }
}

public class AudioOffsetFeatures
{
    public float[] Samples;
    public double[] OnsetLow;
    public double[] OnsetFull;
    public double[][] Chroma;
}

public class AudioOffsetResult
{
    public int OffsetMs;
    public string Level;
    public double Score;
    public double SecondScore;
    public bool FineAligned;
    public double FineSharpness;
    public bool DriftWarning;
    public bool EdgeWarning;
    public double DriftMs;
    public double[] SegmentOffsetsMs;
}

public static class AudioOffsetAnalyzer
{
    public const int SampleRate = 8000;
    const int OnsetFrameSize = 256;
    const int OnsetHop = 80;
    const int ChromaFrameSize = 2048;
    const int ChromaHop = 400;
    const int ChromaRatio = ChromaHop / OnsetHop;
    const double FrameMs = 1000.0 * OnsetHop / SampleRate;

    public static double MaxLagSeconds = 180.0;
    public static double MaxDecodeSeconds = 900.0;

    public static AudioOffsetFeatures Load(string ffmpegPath, string inputPath)
    {
        return Extract(Decode(ffmpegPath, inputPath));
    }

    public static float[] Decode(string ffmpegPath, string inputPath)
    {
        ProcessStartInfo info = new ProcessStartInfo();
        info.FileName = ffmpegPath;
        info.Arguments = "-v error -nostdin -i \"" + inputPath + "\" -map 0:a:0 -vn -ac 1 -ar " + SampleRate +
            " -t " + MaxDecodeSeconds.ToString(CultureInfo.InvariantCulture) + " -f f32le -";
        info.UseShellExecute = false;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.CreateNoWindow = true;

        StringBuilder errors = new StringBuilder();
        using (Process process = new Process())
        {
            process.StartInfo = info;
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null)
                {
                    lock (errors) { errors.AppendLine(e.Data); }
                }
            };
            process.Start();
            process.BeginErrorReadLine();
            MemoryStream buffer = new MemoryStream();
            process.StandardOutput.BaseStream.CopyTo(buffer);
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException("音声を読み込めませんでした: " + Path.GetFileName(inputPath) + Environment.NewLine + errors.ToString().Trim());
            }

            byte[] bytes = buffer.ToArray();
            float[] samples = new float[bytes.Length / 4];
            Buffer.BlockCopy(bytes, 0, samples, 0, samples.Length * 4);
            if (samples.Length < SampleRate * 10)
            {
                throw new InvalidOperationException("音声が短すぎるため解析できません: " + Path.GetFileName(inputPath));
            }
            return samples;
        }
    }

    public static AudioOffsetFeatures Extract(float[] samples)
    {
        AudioOffsetFeatures features = new AudioOffsetFeatures();
        features.Samples = samples;
        ExtractOnsets(samples, out features.OnsetLow, out features.OnsetFull);
        features.Chroma = ExtractChroma(samples);
        return features;
    }

    static void ExtractOnsets(float[] samples, out double[] onsetLow, out double[] onsetFull)
    {
        int frames = (samples.Length - OnsetFrameSize) / OnsetHop + 1;
        double[] window = Hann(OnsetFrameSize);
        double binHz = (double)SampleRate / OnsetFrameSize;
        int lowEnd = (int)(250.0 / binHz);
        int fullEnd = (int)(3800.0 / binHz);
        double[] re = new double[OnsetFrameSize];
        double[] im = new double[OnsetFrameSize];
        double[] previous = new double[fullEnd + 1];
        double[] low = new double[frames];
        double[] full = new double[frames];

        for (int t = 0; t < frames; t++)
        {
            int offset = t * OnsetHop;
            for (int i = 0; i < OnsetFrameSize; i++)
            {
                re[i] = samples[offset + i] * window[i];
                im[i] = 0;
            }
            Fft(re, im, false);

            double lowSum = 0;
            double fullSum = 0;
            for (int k = 1; k <= fullEnd; k++)
            {
                double level = Math.Log(1.0 + 100.0 * Math.Sqrt(re[k] * re[k] + im[k] * im[k]));
                if (t > 0)
                {
                    double rise = level - previous[k];
                    if (rise > 0)
                    {
                        fullSum += rise;
                        if (k <= lowEnd)
                        {
                            lowSum += rise;
                        }
                    }
                }
                previous[k] = level;
            }
            low[t] = lowSum;
            full[t] = fullSum;
        }

        onsetLow = PrepareOnset(low);
        onsetFull = PrepareOnset(full);
    }

    static double[] PrepareOnset(double[] values)
    {
        int n = values.Length;
        int half = 25;
        double[] prefix = new double[n + 1];
        for (int i = 0; i < n; i++)
        {
            prefix[i + 1] = prefix[i] + values[i];
        }

        double[] result = new double[n];
        double mean = 0;
        for (int i = 0; i < n; i++)
        {
            int start = Math.Max(0, i - half);
            int end = Math.Min(n, i + half + 1);
            double local = (prefix[end] - prefix[start]) / (end - start);
            result[i] = Math.Max(0, values[i] - local);
            mean += result[i];
        }

        mean /= n;
        for (int i = 0; i < n; i++)
        {
            result[i] -= mean;
        }
        return result;
    }

    static double[][] ExtractChroma(float[] samples)
    {
        int frames = (samples.Length - ChromaFrameSize) / ChromaHop + 1;
        double[] window = Hann(ChromaFrameSize);
        double binHz = (double)SampleRate / ChromaFrameSize;
        int maxBin = (int)(2000.0 / binHz);
        int[] pitchClass = new int[maxBin + 1];
        for (int k = 0; k <= maxBin; k++)
        {
            double frequency = k * binHz;
            if (frequency < 65.0)
            {
                pitchClass[k] = -1;
                continue;
            }
            int note = (int)Math.Round(12.0 * Math.Log(frequency / 440.0, 2.0)) + 69;
            pitchClass[k] = ((note % 12) + 12) % 12;
        }

        double[][] chroma = new double[12][];
        for (int c = 0; c < 12; c++)
        {
            chroma[c] = new double[frames];
        }

        double[] re = new double[ChromaFrameSize];
        double[] im = new double[ChromaFrameSize];
        double[] energy = new double[frames];
        double[] vector = new double[12];
        for (int t = 0; t < frames; t++)
        {
            int offset = t * ChromaHop;
            for (int i = 0; i < ChromaFrameSize; i++)
            {
                re[i] = samples[offset + i] * window[i];
                im[i] = 0;
            }
            Fft(re, im, false);

            Array.Clear(vector, 0, 12);
            for (int k = 1; k <= maxBin; k++)
            {
                if (pitchClass[k] >= 0)
                {
                    vector[pitchClass[k]] += re[k] * re[k] + im[k] * im[k];
                }
            }

            double norm = 0;
            for (int c = 0; c < 12; c++)
            {
                vector[c] = Math.Sqrt(vector[c]);
                norm += vector[c] * vector[c];
            }
            energy[t] = norm;
            norm = Math.Sqrt(norm);
            for (int c = 0; c < 12; c++)
            {
                chroma[c][t] = norm > 0 ? vector[c] / norm : 0;
            }
        }

        double[] sorted = (double[])energy.Clone();
        Array.Sort(sorted);
        double quiet = sorted[sorted.Length / 2] * 0.001;
        for (int t = 0; t < frames; t++)
        {
            if (energy[t] <= quiet)
            {
                for (int c = 0; c < 12; c++)
                {
                    chroma[c][t] = 0;
                }
            }
        }

        for (int c = 0; c < 12; c++)
        {
            double mean = 0;
            for (int t = 0; t < frames; t++)
            {
                mean += chroma[c][t];
            }
            mean /= frames;
            for (int t = 0; t < frames; t++)
            {
                chroma[c][t] -= mean;
            }
        }
        return chroma;
    }

    public static AudioOffsetResult Analyze(AudioOffsetFeatures reference, AudioOffsetFeatures track)
    {
        int maxLag = (int)(MaxLagSeconds * 1000.0 / FrameMs);
        int shorter = Math.Min(reference.OnsetLow.Length, track.OnsetLow.Length);
        int minOverlap = Math.Max(shorter / 2, Math.Min(shorter, (int)(20000.0 / FrameMs)));

        double[] low = NormalizedCorrelation(new double[][] { reference.OnsetLow }, new double[][] { track.OnsetLow }, maxLag, minOverlap);
        double[] full = NormalizedCorrelation(new double[][] { reference.OnsetFull }, new double[][] { track.OnsetFull }, maxLag, minOverlap);
        int chromaMaxLag = maxLag / ChromaRatio + 1;
        int keyShift;
        double[] chroma = ChromaCorrelation(reference.Chroma, track.Chroma, chromaMaxLag, minOverlap / ChromaRatio, out keyShift);

        double[] combined = new double[2 * maxLag + 1];
        for (int i = 0; i < combined.Length; i++)
        {
            int lag = i - maxLag;
            combined[i] = (low[i] + full[i] + Interpolate(chroma, (double)lag / ChromaRatio + chromaMaxLag)) / 3.0;
        }

        double[] onset = new double[combined.Length];
        for (int i = 0; i < onset.Length; i++)
        {
            onset[i] = low[i] + full[i];
        }

        int exclusion = (int)(500.0 / FrameMs);
        int refineRadius = (int)(60.0 / FrameMs);
        List<int> peaks = TopPeaks(combined, 3, exclusion);
        AudioOffsetResult result = new AudioOffsetResult();
        int chosenPeak = peaks[0];
        double chosenLagMs = 0;
        double bestSharpness = 0;
        double secondSharpness = 0;
        for (int p = 0; p < peaks.Count; p++)
        {
            int peak = peaks[p];
            int refined = ArgMax(onset, Math.Max(0, peak - refineRadius), Math.Min(onset.Length, peak + refineRadius + 1));
            double coarseLagMs = (refined - maxLag + ParabolicPeak(onset, refined)) * FrameMs;
            if (p == 0)
            {
                chosenLagMs = coarseLagMs;
            }

            double fineLagMs;
            double sharpness;
            bool refinedOk = RefineWithPhat(reference.Samples, track.Samples, coarseLagMs, out fineLagMs, out sharpness);
            double usable = refinedOk ? sharpness : 0;
            if (usable > bestSharpness)
            {
                secondSharpness = bestSharpness;
                bestSharpness = usable;
                if (usable >= 10.0)
                {
                    result.FineAligned = true;
                    chosenPeak = peak;
                    chosenLagMs = fineLagMs;
                }
            }
            else if (usable > secondSharpness)
            {
                secondSharpness = usable;
            }
        }
        result.FineSharpness = bestSharpness;

        double second = double.MinValue;
        for (int i = 0; i < combined.Length; i++)
        {
            if (Math.Abs(i - chosenPeak) > exclusion && combined[i] > second)
            {
                second = combined[i];
            }
        }
        result.Score = combined[chosenPeak];
        result.SecondScore = second;

        double lagMs = chosenLagMs;
        result.SegmentOffsetsMs = MeasureSegments(reference, track, (int)Math.Round(lagMs / FrameMs), keyShift);
        double minimum = double.MaxValue;
        double maximum = double.MinValue;
        int valid = 0;
        foreach (double segment in result.SegmentOffsetsMs)
        {
            if (double.IsNaN(segment))
            {
                continue;
            }
            valid++;
            minimum = Math.Min(minimum, segment);
            maximum = Math.Max(maximum, segment);
        }
        if (valid >= 2)
        {
            result.DriftMs = maximum - minimum;
            result.DriftWarning = result.DriftMs > 80.0;
        }

        result.OffsetMs = (int)Math.Round(-lagMs);
        result.EdgeWarning = Math.Abs(chosenPeak - maxLag) >= maxLag - exclusion;
        double ratio = result.Score / Math.Max(result.SecondScore, 0.01);
        bool sharpWinner = bestSharpness >= 2.0 * Math.Max(secondSharpness, 5.0);
        if (result.EdgeWarning)
        {
            result.Level = "低";
        }
        else if (result.FineAligned && (ratio >= 1.5 || (sharpWinner && ratio >= 1.1)))
        {
            result.Level = "高";
        }
        else if (result.FineAligned && ratio >= 1.05)
        {
            result.Level = "中";
        }
        else if (!result.FineAligned && ratio >= 1.15 && result.Score >= 0.2 && valid == 3 && result.DriftMs <= 40.0)
        {
            result.Level = "中";
        }
        else
        {
            result.Level = "低";
        }

        if (result.DriftMs > 200.0)
        {
            result.Level = "低";
        }
        else if (result.DriftWarning && result.Level == "高")
        {
            result.Level = "中";
        }
        return result;
    }

    static List<int> TopPeaks(double[] values, int count, int separation)
    {
        List<int> candidates = new List<int>();
        for (int i = 0; i < values.Length; i++)
        {
            double left = i > 0 ? values[i - 1] : double.MinValue;
            double right = i < values.Length - 1 ? values[i + 1] : double.MinValue;
            if (values[i] >= left && values[i] > right)
            {
                candidates.Add(i);
            }
        }
        candidates.Sort(delegate(int x, int y) { return values[y].CompareTo(values[x]); });

        List<int> peaks = new List<int>();
        foreach (int candidate in candidates)
        {
            bool separated = true;
            foreach (int peak in peaks)
            {
                if (Math.Abs(peak - candidate) <= separation)
                {
                    separated = false;
                    break;
                }
            }
            if (separated)
            {
                peaks.Add(candidate);
                if (peaks.Count == count)
                {
                    break;
                }
            }
        }
        if (peaks.Count == 0)
        {
            peaks.Add(ArgMax(values, 0, values.Length));
        }
        return peaks;
    }

    static double[] MeasureSegments(AudioOffsetFeatures reference, AudioOffsetFeatures track, int lag, int keyShift)
    {
        int start = Math.Max(0, -lag);
        int end = Math.Min(reference.OnsetLow.Length, track.OnsetLow.Length - lag);
        int segmentLength = (end - start) / 3;
        double[] offsets = new double[] { double.NaN, double.NaN, double.NaN };
        if (segmentLength < (int)(15000.0 / FrameMs))
        {
            return offsets;
        }

        int radius = (int)(1000.0 / FrameMs);
        for (int s = 0; s < 3; s++)
        {
            int segmentStart = start + s * segmentLength;
            int segmentEnd = segmentStart + segmentLength;
            double bestScore = double.MinValue;
            int bestLag = lag;
            double[] scores = new double[2 * radius + 1];
            for (int d = -radius; d <= radius; d++)
            {
                int candidate = lag + d;
                double score = (LocalCorrelation(reference.OnsetLow, track.OnsetLow, segmentStart, segmentEnd, candidate, 1) +
                    LocalCorrelation(reference.OnsetFull, track.OnsetFull, segmentStart, segmentEnd, candidate, 1) +
                    LocalChromaCorrelation(reference.Chroma, track.Chroma, segmentStart, segmentEnd, candidate, keyShift)) / 3.0;
                scores[d + radius] = score;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestLag = candidate;
                }
            }
            if (bestScore >= 0.1)
            {
                offsets[s] = -(bestLag + ParabolicPeak(scores, bestLag - lag + radius)) * FrameMs;
            }
        }
        return offsets;
    }

    static double LocalCorrelation(double[] a, double[] b, int start, int end, int lag, int step)
    {
        double sxy = 0;
        double sxx = 0;
        double syy = 0;
        for (int t = start; t < end; t += step)
        {
            int u = t + lag;
            if (u < 0 || u >= b.Length || t >= a.Length)
            {
                continue;
            }
            sxy += a[t] * b[u];
            sxx += a[t] * a[t];
            syy += b[u] * b[u];
        }
        double denominator = Math.Sqrt(sxx * syy);
        return denominator > 0 ? sxy / denominator : 0;
    }

    static double LocalChromaCorrelation(double[][] a, double[][] b, int start, int end, int lag, int rotation)
    {
        int chromaStart = start / ChromaRatio;
        int chromaEnd = end / ChromaRatio;
        double chromaLag = (double)lag / ChromaRatio;
        int baseLag = (int)Math.Floor(chromaLag);
        double fraction = chromaLag - baseLag;
        double sxy = 0;
        double sxx = 0;
        double syy = 0;
        for (int c = 0; c < 12; c++)
        {
            double[] x = a[c];
            double[] y = b[(c + rotation) % 12];
            for (int t = chromaStart; t < chromaEnd && t < x.Length; t++)
            {
                int u = t + baseLag;
                if (u < 0 || u + 1 >= y.Length)
                {
                    continue;
                }
                double value = y[u] * (1 - fraction) + y[u + 1] * fraction;
                sxy += x[t] * value;
                sxx += x[t] * x[t];
                syy += value * value;
            }
        }
        double denominator = Math.Sqrt(sxx * syy);
        return denominator > 0 ? sxy / denominator : 0;
    }

    static double[] ChromaCorrelation(double[][] a, double[][] b, int maxLag, int minOverlap, out int keyShift)
    {
        int lengthA = a[0].Length;
        int lengthB = b[0].Length;
        int size = 1;
        while (size < lengthA + lengthB)
        {
            size <<= 1;
        }

        double[][] aRe = new double[12][];
        double[][] aIm = new double[12][];
        double[][] bRe = new double[12][];
        double[][] bIm = new double[12][];
        double[] prefixA = new double[lengthA + 1];
        double[] prefixB = new double[lengthB + 1];
        for (int c = 0; c < 12; c++)
        {
            aRe[c] = new double[size];
            aIm[c] = new double[size];
            bRe[c] = new double[size];
            bIm[c] = new double[size];
            Array.Copy(a[c], aRe[c], lengthA);
            Array.Copy(b[c], bRe[c], lengthB);
            Fft(aRe[c], aIm[c], false);
            Fft(bRe[c], bIm[c], false);
            for (int i = 0; i < lengthA; i++)
            {
                prefixA[i + 1] += a[c][i] * a[c][i];
            }
            for (int i = 0; i < lengthB; i++)
            {
                prefixB[i + 1] += b[c][i] * b[c][i];
            }
        }
        for (int i = 0; i < lengthA; i++)
        {
            prefixA[i + 1] += prefixA[i];
        }
        for (int i = 0; i < lengthB; i++)
        {
            prefixB[i + 1] += prefixB[i];
        }

        double[] bestScores = new double[2 * maxLag + 1];
        double bestPeak = double.MinValue;
        keyShift = 0;
        double[] re = new double[size];
        double[] im = new double[size];
        for (int rotation = 0; rotation < 12; rotation++)
        {
            Array.Clear(re, 0, size);
            Array.Clear(im, 0, size);
            for (int c = 0; c < 12; c++)
            {
                int d = (c + rotation) % 12;
                double[] xr = aRe[c];
                double[] xi = aIm[c];
                double[] yr = bRe[d];
                double[] yi = bIm[d];
                for (int k = 0; k < size; k++)
                {
                    re[k] += xr[k] * yr[k] + xi[k] * yi[k];
                    im[k] += xr[k] * yi[k] - xi[k] * yr[k];
                }
            }
            Fft(re, im, true);

            double[] scores = new double[2 * maxLag + 1];
            double peak = double.MinValue;
            for (int lag = -maxLag; lag <= maxLag; lag++)
            {
                int start = Math.Max(0, -lag);
                int end = Math.Min(lengthA, lengthB - lag);
                if (end - start < minOverlap)
                {
                    continue;
                }
                double denominator = Math.Sqrt((prefixA[end] - prefixA[start]) * (prefixB[end + lag] - prefixB[start + lag]));
                double score = denominator > 0 ? re[(lag + size) % size] / denominator : 0;
                scores[lag + maxLag] = score;
                peak = Math.Max(peak, score);
            }
            if (peak > bestPeak)
            {
                bestPeak = peak;
                bestScores = scores;
                keyShift = rotation;
            }
        }
        return bestScores;
    }

    static bool RefineWithPhat(float[] a, float[] b, double coarseLagMs, out double lagMs, out double sharpness)
    {
        lagMs = coarseLagMs;
        sharpness = 0;
        int center = (int)Math.Round(coarseLagMs * SampleRate / 1000.0);
        int size = 1 << 19;
        int start = Math.Max(0, -center);
        int end = Math.Min(a.Length, b.Length - center);
        if (end - start < SampleRate * 10)
        {
            return false;
        }

        int length = Math.Min(end - start, size / 2);
        int segmentStart = start + (end - start - length) / 2;
        double[] aRe = new double[size];
        double[] aIm = new double[size];
        double[] bRe = new double[size];
        double[] bIm = new double[size];
        for (int i = 0; i < length; i++)
        {
            double w = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / length);
            aRe[i] = a[segmentStart + i] * w;
            bRe[i] = b[segmentStart + i + center] * w;
        }
        Fft(aRe, aIm, false);
        Fft(bRe, bIm, false);

        int lowBin = (int)(100.0 * size / SampleRate);
        int highBin = (int)(3800.0 * size / SampleRate);
        for (int k = 0; k < size; k++)
        {
            int bin = k <= size / 2 ? k : size - k;
            double re = aRe[k] * bRe[k] + aIm[k] * bIm[k];
            double im = aRe[k] * bIm[k] - aIm[k] * bRe[k];
            double magnitude = Math.Sqrt(re * re + im * im);
            if (bin < lowBin || bin > highBin || magnitude <= 1e-12)
            {
                aRe[k] = 0;
                aIm[k] = 0;
                continue;
            }
            aRe[k] = re / magnitude;
            aIm[k] = im / magnitude;
        }
        Fft(aRe, aIm, true);

        int radius = SampleRate * 25 / 1000;
        int noiseRadius = SampleRate;
        double[] window = new double[2 * radius + 1];
        int bestIndex = 0;
        for (int d = -radius; d <= radius; d++)
        {
            window[d + radius] = aRe[(d + size) % size];
            if (window[d + radius] > window[bestIndex])
            {
                bestIndex = d + radius;
            }
        }

        double sumSquares = 0;
        int count = 0;
        int peak = bestIndex - radius;
        for (int d = -noiseRadius; d <= noiseRadius; d++)
        {
            if (Math.Abs(d - peak) <= 16)
            {
                continue;
            }
            double value = aRe[(d + size) % size];
            sumSquares += value * value;
            count++;
        }
        double noise = Math.Sqrt(sumSquares / Math.Max(count, 1));
        sharpness = noise > 0 ? window[bestIndex] / noise : 0;
        if (bestIndex == 0 || bestIndex == window.Length - 1)
        {
            return false;
        }

        lagMs = (center + peak + ParabolicPeak(window, bestIndex)) * 1000.0 / SampleRate;
        return true;
    }

    static double[] NormalizedCorrelation(double[][] a, double[][] b, int maxLag, int minOverlap)
    {
        int lengthA = a[0].Length;
        int lengthB = b[0].Length;
        double[] cross = new double[2 * maxLag + 1];
        double[] prefixA = new double[lengthA + 1];
        double[] prefixB = new double[lengthB + 1];
        int size = 1;
        while (size < lengthA + lengthB)
        {
            size <<= 1;
        }

        for (int d = 0; d < a.Length; d++)
        {
            double[] aRe = new double[size];
            double[] aIm = new double[size];
            double[] bRe = new double[size];
            double[] bIm = new double[size];
            Array.Copy(a[d], aRe, lengthA);
            Array.Copy(b[d], bRe, lengthB);
            Fft(aRe, aIm, false);
            Fft(bRe, bIm, false);
            for (int k = 0; k < size; k++)
            {
                double re = aRe[k] * bRe[k] + aIm[k] * bIm[k];
                double im = aRe[k] * bIm[k] - aIm[k] * bRe[k];
                aRe[k] = re;
                aIm[k] = im;
            }
            Fft(aRe, aIm, true);
            for (int lag = -maxLag; lag <= maxLag; lag++)
            {
                cross[lag + maxLag] += aRe[(lag + size) % size];
            }
            for (int i = 0; i < lengthA; i++)
            {
                prefixA[i + 1] += a[d][i] * a[d][i];
            }
            for (int i = 0; i < lengthB; i++)
            {
                prefixB[i + 1] += b[d][i] * b[d][i];
            }
        }

        for (int i = 0; i < lengthA; i++)
        {
            prefixA[i + 1] += prefixA[i];
        }
        for (int i = 0; i < lengthB; i++)
        {
            prefixB[i + 1] += prefixB[i];
        }

        double[] scores = new double[2 * maxLag + 1];
        for (int lag = -maxLag; lag <= maxLag; lag++)
        {
            int start = Math.Max(0, -lag);
            int end = Math.Min(lengthA, lengthB - lag);
            if (end - start < minOverlap)
            {
                continue;
            }
            double energyA = prefixA[end] - prefixA[start];
            double energyB = prefixB[end + lag] - prefixB[start + lag];
            double denominator = Math.Sqrt(energyA * energyB);
            scores[lag + maxLag] = denominator > 0 ? cross[lag + maxLag] / denominator : 0;
        }
        return scores;
    }

    static double Interpolate(double[] values, double position)
    {
        if (position <= 0)
        {
            return values[0];
        }
        if (position >= values.Length - 1)
        {
            return values[values.Length - 1];
        }
        int index = (int)Math.Floor(position);
        double fraction = position - index;
        return values[index] * (1 - fraction) + values[index + 1] * fraction;
    }

    static int ArgMax(double[] values, int start, int end)
    {
        int best = start;
        for (int i = start + 1; i < end; i++)
        {
            if (values[i] > values[best])
            {
                best = i;
            }
        }
        return best;
    }

    static double ParabolicPeak(double[] values, int index)
    {
        if (index <= 0 || index >= values.Length - 1)
        {
            return 0;
        }
        double left = values[index - 1];
        double center = values[index];
        double right = values[index + 1];
        double denominator = left - 2 * center + right;
        if (denominator >= 0)
        {
            return 0;
        }
        return Math.Max(-0.5, Math.Min(0.5, 0.5 * (left - right) / denominator));
    }

    static double[] Hann(int size)
    {
        double[] window = new double[size];
        for (int i = 0; i < size; i++)
        {
            window[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / size);
        }
        return window;
    }

    static void Fft(double[] re, double[] im, bool inverse)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1)
            {
                j ^= bit;
            }
            j ^= bit;
            if (i < j)
            {
                double temp = re[i]; re[i] = re[j]; re[j] = temp;
                temp = im[i]; im[i] = im[j]; im[j] = temp;
            }
        }

        for (int length = 2; length <= n; length <<= 1)
        {
            double angle = 2 * Math.PI / length * (inverse ? 1 : -1);
            double stepRe = Math.Cos(angle);
            double stepIm = Math.Sin(angle);
            int half = length >> 1;
            for (int i = 0; i < n; i += length)
            {
                double wRe = 1;
                double wIm = 0;
                for (int k = 0; k < half; k++)
                {
                    int a = i + k;
                    int b = a + half;
                    double tRe = re[b] * wRe - im[b] * wIm;
                    double tIm = re[b] * wIm + im[b] * wRe;
                    re[b] = re[a] - tRe;
                    im[b] = im[a] - tIm;
                    re[a] += tRe;
                    im[a] += tIm;
                    double nextRe = wRe * stepRe - wIm * stepIm;
                    wIm = wRe * stepIm + wIm * stepRe;
                    wRe = nextRe;
                }
            }
        }

        if (inverse)
        {
            for (int i = 0; i < n; i++)
            {
                re[i] /= n;
                im[i] /= n;
            }
        }
    }
}
'@ -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:Settings = Read-Settings

if ($ValidateOnly) {
    exit 0
}

if ($CliDefaults) {
    Write-CliDefaults -InputFiles $Files -UseVideoAudio ($UseVideoAudio -eq 1) -OutFile $OutFile
    exit 0
}

Initialize-InputFiles -InputFiles $Files -Settings $Script:Settings
Show-MainForm
