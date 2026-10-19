[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$ValidateOnly,
    [switch]$CliDefaults,
    [switch]$Detach,
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
# 設定がまだ保存されていないときに読む設定（先にあるものを使う）
$Script:ConfigFallbackPaths = @()
# Store 版（MSIX）はインストール先に書き込めないため、起動用の PitaTrack.exe が PITATRACK_PACKAGED=1 を渡す。
# 設定は %LOCALAPPDATA%\PitaTrack に保存する（実体は Windows がパッケージ専用の場所に振り替え、アンインストールで消える）。
# まだ保存していなければ、ZIP 版でインストールしたときの設定、なければ同梱の初期設定を読む。
$Script:Packaged = ($env:PITATRACK_PACKAGED -eq '1')
# パッケージ ファミリー名（Store 版だけ。Get-PackageFamilyName が初めて使うときに入れる）
$Script:PackageFamilyName = $null
# モデルフォルダーの実パス（Get-SeparationModelsRealDir が初めて調べたときに入れる）
$Script:SeparationModelsRealDir = $null
if ($Script:Packaged) {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $Script:ConfigFallbackPaths = @(
        (Join-Path $localAppData 'Programs\PitaTrack\tools\mixtrack_ffmpeg_gui.settings.json'),
        $Script:ConfigPath
    )
    $Script:ConfigPath = Join-Path $localAppData 'PitaTrack\mixtrack_ffmpeg_gui.settings.json'
}
$Script:Settings = $null
$Script:VideoFile = $null
$Script:AudioFiles = @()
$Script:DefaultOutputPath = $null
$Script:SavedOutputPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$Script:AutoOffsetReference = $null

# ボーカル分離に使う BSRoformer.cpp（Vulkan 版。GPU がなければ CPU で動く）。版を上げるときは URL と SHA256 を一緒に変えます。
$Script:BsRoformerUrl = 'https://github.com/chenmozhijin/BSRoformer.cpp/releases/download/v0.1.0/BSRoformer-windows-vulkan.zip'
$Script:BsRoformerSha256 = 'a47653911eb17f68e65bce15aed6c4f1bd277a5fbd48293c4e54f0b005b869a7'
$Script:BsRoformerSizeText = '約22MB'
# 分離モデル（GGUF）。Role は vocals（ボーカル全体を推定）か lead（リードボーカルだけを推定）。
# 置き場は %LOCALAPPDATA%\PitaTrack\models。初めて使うときにダウンロードする。
# 配布できるのはライセンスが明確な Kim（MIT）と anvuew（GPL-3.0）だけなので一覧はこの 2 つ。
# 他のモデルは自分で変換して同じフォルダーに置けば候補に出る（dev/vocal-separation/README.md）。
# 一覧にない .gguf も同じフォルダーに置けば候補に出る（名前に karaoke / kara / lead があれば lead 扱い）。
# 版を上げるときは URL と SHA256 を一緒に変えます。
$Script:SeparationModelsReleaseUrl = 'https://github.com/bee7813993/ffmpegMp4Mix/releases/download/separation-models-20261019/'
$Script:SeparationModels = @(
    [PSCustomObject]@{
        Key = 'kim'; Role = 'vocals'; FileName = 'kim_mel_vocals-Q8_0.gguf'; Label = 'Kim Mel-Roformer'; Short = 'Kim'
        Url = $Script:SeparationModelsReleaseUrl + 'kim_mel_vocals-Q8_0.gguf'; Sha256 = 'd659c1d839cccf47941a804c4ccd42b36f4b59b9f035cf7e36e22d323f787aa6'; SizeText = '約240MB'
        LicenseUrl = $Script:SeparationModelsReleaseUrl + 'kim_mel_vocals-Q8_0.LICENSE.txt'; License = 'MIT'; Author = 'Kimberley Jensen'; Source = 'https://huggingface.co/KimberleyJSN/melbandroformer'
    }
    [PSCustomObject]@{
        Key = 'anvuew'; Role = 'lead'; FileName = 'karaoke_anvuew-Q8_0.gguf'; Label = 'BS-Roformer Karaoke anvuew'; Short = 'anvuew'
        Url = $Script:SeparationModelsReleaseUrl + 'karaoke_anvuew-Q8_0.gguf'; Sha256 = '58c6d3322f039ca89ddf562d88a561e4102a9bdf53cb647e0c236c5b50bc710f'; SizeText = '約53MB'
        LicenseUrl = $Script:SeparationModelsReleaseUrl + 'karaoke_anvuew-Q8_0.LICENSE.txt'; License = 'GPL-3.0'; Author = 'anvuew'; Source = 'https://huggingface.co/anvuew/karaoke_bs_roformer'
    }
)
# 分離トラックの初期名。{model} はモデルの短い名前、{db} はリデュース量（-8 / +6）に置き換わる
$Script:SeparationDefaultTrackNames = [PSCustomObject]@{
    Cut     = 'オフボーカル'
    Reduce  = 'ボーカル {db}dB'
    Karaoke = 'コーラス入りオフボーカル'
    Vocals  = 'ボーカルのみ'
}
$Script:SeparationDefaultVocalModel = 'kim'
$Script:SeparationDefaultLeadModel = 'anvuew'

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

# ffmpeg.exe がなければ、セットアップのダウンロード画面を開いてから探し直す
function Request-Ffmpeg {
    $ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
    if (Test-Path -LiteralPath $ffmpegPath -PathType Leaf) {
        return $ffmpegPath
    }

    $setupScript = Join-Path $Script:ScriptDir 'setup.ps1'
    if (Test-Path -LiteralPath $setupScript -PathType Leaf) {
        $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (ConvertTo-CommandLineArgument $setupScript), '-FfmpegOnly')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -Wait
    }

    return Get-SupportFilePath -FileName 'ffmpeg.exe'
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
        [object]$TrackCountProfiles = $null,
        [object]$Separation = $null
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
        Separation          = ConvertTo-SeparationSettings $Separation
    }
}

# 読み込む設定ファイル（保存したもの、なければ ConfigFallbackPaths の順。どれもなければ $null）
function Get-SettingsReadPath {
    foreach ($path in @($Script:ConfigPath) + $Script:ConfigFallbackPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    return $null
}

function Read-Settings {
    $settings = Read-BatchDefaultSettings

    $configPath = Get-SettingsReadPath
    if ($null -ne $configPath) {
        try {
            $json = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
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
                    'ぴたトラック',
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
        Separation      = $settings.Separation
    }
    if ($null -ne $settings.PSObject.Properties['TrackNameCandidates']) {
        $convertParams.TrackNameCandidates = @(Get-TrackNameCandidates -Settings $settings)
    }

    ConvertTo-SavedSettings @convertParams
}

function Save-Settings {
    param([object]$Settings)

    $json = $Settings | ConvertTo-Json -Depth 8
    $configDirectory = Split-Path -Parent $Script:ConfigPath
    if (-not (Test-Path -LiteralPath $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
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
        'ぴたトラック',
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

function Set-RadioButtonTheme {
    param([System.Windows.Forms.RadioButton]$RadioButton)

    $RadioButton.Font = New-UiFont 9
    $RadioButton.BackColor = Get-UiColor 'Background'
    $RadioButton.ForeColor = Get-UiColor 'Text'
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
        [object]$Item,
        [int]$Index = -1
    )

    Add-TrackNameCandidateToGrid -Grid $Grid -Name ([string]$Item.Title)
    $values = @('', $Item.Title, (Format-OffsetMs ([int]$Item.OffsetMs)), (Get-TrackTypeText $Item), (Get-TrackSourceText $Item))
    if ($Index -lt 0 -or $Index -ge $Grid.Rows.Count) {
        $rowIndex = $Grid.Rows.Add($values)
    }
    else {
        # 指定した位置に差し込む（分離で作ったトラックを元のトラックの下に置くため）
        $Grid.Rows.Insert($Index, $values)
        $rowIndex = $Index
    }
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

    $ffmpegPath = Request-Ffmpeg
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
            'ぴたトラック',
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

# ---- ボーカル分離 ----
# BSRoformer.cpp の bs_roformer-cli を ffmpeg と同じく外部プロセスとして呼び、推定したステム
# （ボーカル / リードボーカル）と元音源の差分から、オフボーカルなどの派生トラックを作る。

function Get-BsRoformerDir {
    return Join-Path $Script:ToolDir 'bsroformer'
}

function Get-BsRoformerCliPath {
    return Join-Path (Get-BsRoformerDir) 'bs_roformer-cli.exe'
}

# モデル（GGUF）の置き場。インストール先が読み取り専用（Store 版）でも使えるようにユーザーのフォルダーに置く。
# 自分で探してきたモデルもここに置けば一覧に出る。
# Store 版では、Windows がこのフォルダーへの読み書きをパッケージ専用の場所（LocalCache）に振り替える（設定ファイルと同じ）
function Get-SeparationModelsDir {
    return Join-Path $env:LOCALAPPDATA 'PitaTrack\models'
}

# Store 版（パッケージの中）で動いているときのパッケージ ファミリー名。パッケージの外なら $null
function Get-PackageFamilyName {
    if ($null -eq $Script:PackageFamilyName) {
        $name = ''
        if ($Script:Packaged) {
            try {
                $name = [string][PitaTrackPackage]::GetFamilyName()
            }
            catch {
                $name = ''
            }
        }
        $Script:PackageFamilyName = $name
    }
    if ([string]::IsNullOrEmpty($Script:PackageFamilyName)) {
        return $null
    }
    return $Script:PackageFamilyName
}

# ユーザーに見せる・エクスプローラーで開くモデルフォルダーの実パス（フォルダーも作る）。
# Store 版では、Windows が Get-SeparationModelsDir への読み書きをパッケージ専用の場所
# （%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\models）に振り替えることがある。エクスプローラーは
# パッケージの外で動くので、振り替えられているときに元のパスを渡すと、振り替え前の（空の）フォルダーが開いてしまう。
# 振り替えの有無は Windows の入れ方で変わる（開発者モードで登録した署名なしのパッケージでは振り替えられなかった）ので、
# 小さなファイルを書いてどちらに落ちたかで判断する
function Get-SeparationModelsRealDir {
    $modelsDir = Get-SeparationModelsDir
    $familyName = Get-PackageFamilyName
    if ([string]::IsNullOrEmpty($familyName)) {
        return $modelsDir
    }
    if ($null -ne $Script:SeparationModelsRealDir) {
        return $Script:SeparationModelsRealDir
    }

    $result = $modelsDir
    try {
        if (-not (Test-Path -LiteralPath $modelsDir -PathType Container)) {
            New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
        }
        $markerName = '.pitatrack_' + [guid]::NewGuid().ToString('N')
        $marker = Join-Path $modelsDir $markerName
        [System.IO.File]::WriteAllText($marker, '')
        try {
            $redirectedDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $familyName + '\LocalCache\Local\PitaTrack\models')
            if (Test-Path -LiteralPath (Join-Path $redirectedDir $markerName) -PathType Leaf) {
                $result = $redirectedDir
            }
        }
        finally {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
    $Script:SeparationModelsRealDir = $result
    return $result
}

# モデルと同名の .json があれば表示名などを読む。
# 書式: {"label": "表示名", "short": "トラック名に使う短い名前", "role": "vocals か lead", "stem": 0}
# stem は、複数のステムを出すモデルで、ボーカル（リード）がどの番号か（省略時 0）
function Read-SeparationModelSidecar {
    param([string]$GgufPath)

    $jsonPath = [System.IO.Path]::ChangeExtension($GgufPath, '.json')
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        return $null
    }
    try {
        $data = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ($null -eq $data) {
        return $null
    }

    $result = @{}
    foreach ($name in 'label', 'short', 'role', 'stem') {
        $property = @($data.PSObject.Properties | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $result[$name] = ([string]$property.Value).Trim()
        }
    }
    if ($result.ContainsKey('stem')) {
        $stemIndex = 0
        if ([int]::TryParse($result['stem'], [ref]$stemIndex) -and $stemIndex -ge 0) {
            $result['stem'] = $stemIndex
        }
        else {
            $result.Remove('stem')
        }
    }
    if ($result.ContainsKey('role')) {
        $result['role'] = $result['role'].ToLowerInvariant()
        if ($result['role'] -ne 'vocals' -and $result['role'] -ne 'lead') {
            $result.Remove('role')
        }
    }
    return $result
}

# 登録済みのモデルに、モデルフォルダーにある未登録の .gguf を足した一覧。Available はファイルがあるか。
# 同名の .json があれば表示名・短い名前・用途を上書きする
function Get-SeparationModelList {
    $modelsDir = Get-SeparationModelsDir
    $list = New-Object System.Collections.ArrayList
    $knownFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($model in $Script:SeparationModels) {
        $path = Join-Path $modelsDir $model.FileName
        $label = [string]$model.Label
        $short = [string]$model.Short
        $role = [string]$model.Role
        $stem = 0
        $sidecar = Read-SeparationModelSidecar -GgufPath $path
        if ($null -ne $sidecar) {
            if ($sidecar.ContainsKey('label')) { $label = $sidecar['label'] }
            if ($sidecar.ContainsKey('short')) { $short = $sidecar['short'] }
            if ($sidecar.ContainsKey('role')) { $role = $sidecar['role'] }
            if ($sidecar.ContainsKey('stem')) { $stem = [int]$sidecar['stem'] }
        }
        [void]$list.Add([PSCustomObject]@{
            Key         = [string]$model.Key
            Role        = $role
            FileName    = [string]$model.FileName
            Label       = $label
            Short       = $short
            Recommended = $false
            Path        = $path
            Available   = (Test-Path -LiteralPath $path -PathType Leaf)
            Stem        = $stem
            Url         = [string]$model.Url
            Sha256      = [string]$model.Sha256
            SizeText    = [string]$model.SizeText
            LicenseUrl  = [string]$model.LicenseUrl
            License     = [string]$model.License
            Author      = [string]$model.Author
            Source      = [string]$model.Source
        })
        [void]$knownFiles.Add([string]$model.FileName)
    }

    if (Test-Path -LiteralPath $modelsDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $modelsDir -Filter '*.gguf' -File | Sort-Object Name)) {
            if ($knownFiles.Contains($file.Name)) {
                continue
            }
            $label = $file.BaseName
            $short = $file.BaseName
            $role = if ($file.BaseName -match 'karaoke|kara|lead') { 'lead' } else { 'vocals' }
            $stem = 0
            # ファイル名に付いた量子化の印（-Q8_0 など）と先頭の karaoke_ はキー（ファイル名の接尾辞に使う）から外す
            $key = $file.BaseName -replace '[-_](q\d_\d|f16|fp16|f32|fp32)$', '' -replace '^(karaoke|kara)[-_]', ''
            if ([string]::IsNullOrWhiteSpace($key) -or @($list | Where-Object { $_.Key -eq $key }).Count -gt 0) {
                $key = $file.BaseName
            }
            $sidecar = Read-SeparationModelSidecar -GgufPath $file.FullName
            if ($null -ne $sidecar) {
                if ($sidecar.ContainsKey('label')) { $label = $sidecar['label'] }
                if ($sidecar.ContainsKey('short')) { $short = $sidecar['short'] }
                elseif ($sidecar.ContainsKey('label')) { $short = $sidecar['label'] }
                if ($sidecar.ContainsKey('role')) { $role = $sidecar['role'] }
                if ($sidecar.ContainsKey('stem')) { $stem = [int]$sidecar['stem'] }
            }
            [void]$list.Add([PSCustomObject]@{
                Key         = $key
                Role        = $role
                FileName    = $file.Name
                Label       = $label
                Short       = $short
                Recommended = $false
                Path        = $file.FullName
                Available   = $true
                Stem        = $stem
                Url         = ''
                Sha256      = ''
                SizeText    = ''
                LicenseUrl  = ''
                License     = ''
                Author      = ''
                Source      = ''
            })
        }
    }

    return @($list.ToArray())
}

function Get-SeparationModel {
    param(
        [object[]]$Models,
        [string]$Key
    )

    foreach ($model in $Models) {
        if ($model.Key -eq $Key) {
            return $model
        }
    }
    throw "分離モデルの定義がありません: $Key"
}

# 分離に関する設定（選んだモデルなど）。古い設定ファイルには項目がないので既定値で補う。
# 「全モデルで候補を作る」は一回限りの操作なので覚えない
function ConvertTo-SeparationSettings {
    param([object]$Value)

    $vocalModel = $Script:SeparationDefaultVocalModel
    $leadModel = $Script:SeparationDefaultLeadModel
    $reduceDb = 8
    $twoStage = $true
    $trackNames = [ordered]@{}
    foreach ($property in $Script:SeparationDefaultTrackNames.PSObject.Properties) {
        $trackNames[$property.Name] = [string]$property.Value
    }
    if ($null -ne $Value) {
        $savedNames = $Value.TrackNames
        if ($null -ne $savedNames) {
            foreach ($name in @($trackNames.Keys)) {
                $candidate = [string]$savedNames.$name
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $trackNames[$name] = $candidate.Trim()
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Value.VocalModel)) {
            $vocalModel = ([string]$Value.VocalModel).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Value.LeadModel)) {
            $leadModel = ([string]$Value.LeadModel).Trim()
        }
        $parsedDb = 0
        if ([int]::TryParse(([string]$Value.ReduceDb).Trim(), [ref]$parsedDb) -and $parsedDb -ge -20 -and $parsedDb -le 40) {
            $reduceDb = $parsedDb
        }
        if ($null -ne $Value.TwoStage) {
            $twoStage = ConvertTo-SettingFlag $Value.TwoStage
        }
    }

    [PSCustomObject]@{
        VocalModel = $vocalModel
        LeadModel  = $leadModel
        ReduceDb   = $reduceDb
        TwoStage   = $twoStage
        TrackNames = [PSCustomObject]$trackNames
    }
}

# 初期名のひな形を実際の名前にする。{model} はモデルの短い名前、{db} はリデュース量（下げる 8 → -8、上げる 6 → +6）。
# IncludeModel（候補をまとめて作るとき）でひな形に {model} がなければ、名前の後ろに（モデル名）を付ける
function Expand-SeparationTitleTemplate {
    param(
        [string]$Template,
        [string]$ModelShort,
        [object]$Db,
        [bool]$IncludeModel,
        [string[]]$ExtraNotes
    )

    $dbText = ''
    if ($null -ne $Db) {
        $value = [int]$Db
        $dbText = if ($value -gt 0) { '-' + $value } elseif ($value -lt 0) { '+' + (-$value) } else { '±0' }
    }
    $title = ([string]$Template).Replace('{model}', $ModelShort).Replace('{db}', $dbText).Trim()
    $notes = @()
    if ($IncludeModel -and ([string]$Template) -notmatch '\{model\}') {
        $notes += $ModelShort
    }
    $notes += @($ExtraNotes)
    return Format-SeparationTitle -Base $title -Notes $notes
}

function Read-SharedTextFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    # 書き込み中のファイルも読めるように共有モードで開く
    $stream = New-Object System.IO.FileStream -ArgumentList $Path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([System.Text.Encoding]::UTF8)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

# 外部プロセスを隠しウィンドウで実行し、終わるまで画面を更新しながら待つ。
# 標準出力は途中経過として OnOutput に渡す（bs_roformer-cli の進捗表示用）。
function Invoke-SeparationProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [scriptblock]$OnOutput = $null,
        [object]$State = $null
    )

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_proc_' + [guid]::NewGuid().ToString('N'))
    $stdoutPath = $tempBase + '.out.log'
    $stderrPath = $tempBase + '.err.log'
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $process = Start-Process -FilePath $FilePath -ArgumentList $argumentLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try {
        # 終了前にハンドルを掴んでおかないと ExitCode が取れない（Start-Process の仕様）
        $null = $process.Handle
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
            if ($null -ne $State -and $State.CancelRequested) {
                try {
                    $process.Kill()
                }
                catch {
                }
                $process.WaitForExit()
                throw '中止しました。'
            }
            if ($null -ne $OnOutput) {
                & $OnOutput (Read-SharedTextFile $stdoutPath)
            }
        }
        $process.WaitForExit()

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = Read-SharedTextFile $stdoutPath
            StdErr   = Read-SharedTextFile $stderrPath
            Command  = Get-CommandLine -FileName $FilePath -Arguments $Arguments
        }
    }
    finally {
        $process.Dispose()
        foreach ($path in @($stdoutPath, $stderrPath)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-SeparationProcessSucceeded {
    param(
        [object]$Result,
        [string]$What,
        [string]$LogPath
    )

    if ($Result.ExitCode -eq 0) {
        return
    }

    $logText = $Result.Command + "`r`n`r`n" + $Result.StdOut + "`r`n" + $Result.StdErr
    [System.IO.File]::WriteAllText($LogPath, $logText, [System.Text.Encoding]::UTF8)
    $lastLine = @(($Result.StdErr -split "`r?`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    throw ("{0} がエラー終了しました（終了コード {1}）。ログを保存しました。`r`n`r`n{2}`r`n`r`n{3}" -f $What, $Result.ExitCode, $LogPath, ($lastLine -join ''))
}

function Save-SeparationDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [scriptblock]$OnPercent,
        [object]$State
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $request = [System.Net.WebRequest]::Create($Url)
    $request.UserAgent = 'PitaTrack'
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
            $total = $response.ContentLength
            $buffer = New-Object byte[] 65536
            $done = [long]0
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $file.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) {
                    & $OnPercent ([int](100 * $done / $total))
                }
                [System.Windows.Forms.Application]::DoEvents()
                if ($null -ne $State -and $State.CancelRequested) {
                    throw '中止しました。'
                }
            }
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

# BSRoformer.cpp の zip をダウンロードして SHA256 を確かめ、exe と dll を tools\bsroformer に置く
function Install-BsRoformer {
    param(
        [scriptblock]$OnProgress,
        [object]$State
    )

    $targetDir = Get-BsRoformerDir
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_bsroformer_' + [guid]::NewGuid().ToString('N') + '.zip')
    $extractDir = $zipPath + '.dir'
    try {
        $onPercent = {
            param([int]$percent)
            & $OnProgress $percent ('BSRoformer.cpp をダウンロードしています... {0}%' -f $percent)
        }
        & $OnProgress 0 'BSRoformer.cpp をダウンロードしています...'
        Save-SeparationDownload -Url $Script:BsRoformerUrl -Destination $zipPath -OnPercent $onPercent -State $State

        & $OnProgress 100 'ダウンロードしたファイルを確認しています...'
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($hash -ne $Script:BsRoformerSha256) {
            throw 'ダウンロードしたファイルが正しくありません（SHA256 が一致しません）。'
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $extractDir -Recurse -File | Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.dll' })) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $targetDir $file.Name) -Force
        }
        if (-not (Test-Path -LiteralPath (Get-BsRoformerCliPath) -PathType Leaf)) {
            throw 'ダウンロードしたファイルに bs_roformer-cli.exe が入っていません。'
        }
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# bs_roformer-cli.exe がなければダウンロードするか尋ねる。断られたら $null。
# Store 版は dev\build_msix.ps1 がエンジンを同梱するのでダウンロードしない（Store の規約で実行ファイルをあとから
# ダウンロードできず、インストール先にも書き込めないため）。それでもなければ、その旨を伝えて止める
function Request-BsRoformer {
    param(
        [System.Windows.Forms.IWin32Window]$Owner,
        [scriptblock]$OnProgress,
        [object]$State
    )

    $cliPath = Get-BsRoformerCliPath
    if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
        return $cliPath
    }

    if ($Script:Packaged) {
        throw ("この版のぴたトラックには、ボーカル分離のエンジン（BSRoformer.cpp）が入っていません。`r`n{0}`r`n`r`nStore 版はエンジンをあとからダウンロードできません。Microsoft Store からぴたトラックを入れ直してください。" -f $cliPath)
    }

    $message = "ボーカル分離には BSRoformer.cpp（{0}）が必要です。ダウンロードしますか？`r`n`r`n{1}`r`n→ {2}" -f $Script:BsRoformerSizeText, $Script:BsRoformerUrl, (Get-BsRoformerDir)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $message,
        'ぴたトラック',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return $null
    }

    Install-BsRoformer -OnProgress $OnProgress -State $State
    return $cliPath
}

# モデルの GGUF をダウンロードして SHA256 を確かめ、モデルフォルダーに置く（ライセンス文も隣に置く）
function Install-SeparationModel {
    param(
        [object]$Model,
        [scriptblock]$OnProgress,
        [object]$State
    )

    $modelsDir = Get-SeparationModelsDir
    if (-not (Test-Path -LiteralPath $modelsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
    }
    $partPath = [string]$Model.Path + '.part'
    try {
        $onPercent = {
            param([int]$percent)
            & $OnProgress $percent ('{0} をダウンロードしています... {1}%' -f $Model.Label, $percent)
        }
        & $OnProgress 0 ('{0} をダウンロードしています...' -f $Model.Label)
        Save-SeparationDownload -Url ([string]$Model.Url) -Destination $partPath -OnPercent $onPercent -State $State

        & $OnProgress 100 'ダウンロードしたファイルを確認しています...'
        $hash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash
        if ($hash -ne [string]$Model.Sha256) {
            throw 'ダウンロードしたファイルが正しくありません（SHA256 が一致しません）。'
        }
        Move-Item -LiteralPath $partPath -Destination ([string]$Model.Path) -Force

        if (-not [string]::IsNullOrWhiteSpace([string]$Model.LicenseUrl)) {
            try {
                Save-SeparationDownload -Url ([string]$Model.LicenseUrl) -Destination ([System.IO.Path]::ChangeExtension([string]$Model.Path, '.LICENSE.txt')) -OnPercent { param([int]$percent) } -State $State
            }
            catch {
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
    }
}

# モデルがなければダウンロードするか尋ねてから取得する。ダウンロードできないモデルは置き場を案内して止める。
# 断られたら $false
function Request-SeparationModel {
    param(
        [object]$Model,
        [System.Windows.Forms.IWin32Window]$Owner,
        [scriptblock]$OnProgress,
        [object]$State
    )

    if (Test-Path -LiteralPath ([string]$Model.Path) -PathType Leaf) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace([string]$Model.Url)) {
        throw ("分離モデルがありません。`r`n{0}`r`n`r`n{1} の GGUF ファイルをこの場所に置いてください。" -f $Model.Path, $Model.Label)
    }

    $message = "モデル「{0}」（{1}）がまだありません。ダウンロードしますか？`r`n`r`n作者: {2}`r`nライセンス: {3}`r`n元のモデル: {4}`r`n`r`n{5}`r`n→ {6}" -f $Model.Label, $Model.SizeText, $Model.Author, $Model.License, $Model.Source, $Model.Url, (Get-SeparationModelsRealDir)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $message,
        'ぴたトラック',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return $false
    }

    Install-SeparationModel -Model $Model -OnProgress $OnProgress -State $State
    return $true
}

# bs_roformer-cli は 44.1 kHz の WAV しか受け付けないので、ステレオ 32 bit float に変換する
function ConvertTo-SeparationWav {
    param(
        [string]$FfmpegPath,
        [string]$SourceFile,
        [string]$OutputPath,
        [string]$LogPath,
        [object]$State
    )

    $arguments = @('-y', '-v', 'error', '-i', $SourceFile, '-map', '0:a:0', '-vn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_f32le', $OutputPath)
    $result = Invoke-SeparationProcess -FilePath $FfmpegPath -Arguments $arguments -State $State
    Assert-SeparationProcessSucceeded -Result $result -What 'ffmpeg（音声の変換）' -LogPath $LogPath
}

function Invoke-BsRoformerCli {
    param(
        [string]$CliPath,
        [string]$ModelPath,
        [string]$InputWav,
        [string]$OutputWav,
        [string]$LogPath,
        [scriptblock]$OnPercent,
        [object]$State,
        [int]$StemIndex = 0
    )

    $progress = [PSCustomObject]@{ LastPercent = -1 }
    $onOutput = {
        param([string]$text)

        # 進捗は "[====>   ] 35 %" の形で標準出力に出る。最後の値だけ見る
        $found = [regex]::Matches($text, '(\d{1,3}) %')
        if ($found.Count -gt 0) {
            $percent = [int]$found[$found.Count - 1].Groups[1].Value
            if ($percent -ne $progress.LastPercent) {
                $progress.LastPercent = $percent
                & $OnPercent $percent
            }
        }
    }

    $result = Invoke-SeparationProcess -FilePath $CliPath -Arguments @($ModelPath, $InputWav, $OutputWav) -OnOutput $onOutput -State $State
    Assert-SeparationProcessSucceeded -Result $result -What 'bs_roformer-cli（ボーカル分離）' -LogPath $LogPath
    if (-not (Test-Path -LiteralPath $OutputWav -PathType Leaf)) {
        # 複数のステムを出すモデルは <名前>_stem_N.wav に分かれて出る。指定の番号を使い、残りは消す
        $stemBase = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($OutputWav), [System.IO.Path]::GetFileNameWithoutExtension($OutputWav))
        $wanted = '{0}_stem_{1}.wav' -f $stemBase, $StemIndex
        if (Test-Path -LiteralPath $wanted -PathType Leaf) {
            Move-Item -LiteralPath $wanted -Destination $OutputWav -Force
            Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($OutputWav)) -Filter ([System.IO.Path]::GetFileName($stemBase) + '_stem_*.wav') -File | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $OutputWav -PathType Leaf)) {
        throw 'bs_roformer-cli が出力ファイルを作りませんでした。'
    }
}

# 分離したトラックは元音源より大きなピークになることがあり、AAC にすると 0 dBFS を超えるので、
# 書き出す前にピークだけ抑える（latency=true で遅れを補正し、元音源とのタイミングを保つ）
$Script:SeparationLimiterFilter = 'alimiter=limit=0.98:level=false:latency=true'

# リデュース量 dB に対する元音源とステムの係数。出力 = MixGain × 元音源 + StemGain × ステム。
# 正（下げる）: 元音源 − (1 − 10^(−dB/20)) × ボーカル。
# 負（強調）: ボーカルを足すとピークが 0 dBFS を超えてリミッターが効きすぎるので、代わりに伴奏側を下げる
# （10^(dB/20) × 元音源 + (1 − 10^(dB/20)) × ボーカル。バランスは同じで全体は小さくなる）
function Get-SeparationReduceGains {
    param([int]$Db)

    if ($Db -ge 0) {
        return @(1.0, -(1.0 - [math]::Pow(10.0, -$Db / 20.0)))
    }
    $mixGain = [math]::Pow(10.0, $Db / 20.0)
    return @($mixGain, (1.0 - $mixGain))
}

# MixGain × 元音源 + StemGain × ステム を AAC で書き出す（オフボーカルは 1 と −1）。
# amix は負の重みを無視するので pan で計算する
function New-SeparationDerivedTrack {
    param(
        [string]$FfmpegPath,
        [string]$MixWav,
        [string]$StemWav,
        [double]$MixGain,
        [double]$StemGain,
        [string]$OutputPath,
        [string]$Bitrate,
        [string]$LogPath,
        [object]$State
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $mixText = $MixGain.ToString('0.######', $culture)
    $sign = if ($StemGain -lt 0) { '-' } else { '+' }
    $stemText = [math]::Abs($StemGain).ToString('0.######', $culture)
    $filter = ('[0:a][1:a]amerge=inputs=2,pan=stereo|c0={0}*c0{1}{2}*c2|c1={0}*c1{1}{2}*c3,' -f $mixText, $sign, $stemText) + $Script:SeparationLimiterFilter
    $arguments = @('-y', '-v', 'error', '-i', $MixWav, '-i', $StemWav, '-filter_complex', $filter, '-c:a', 'aac', '-b:a', $Bitrate, $OutputPath)
    $result = Invoke-SeparationProcess -FilePath $FfmpegPath -Arguments $arguments -State $State
    Assert-SeparationProcessSucceeded -Result $result -What 'ffmpeg（トラックの書き出し）' -LogPath $LogPath
}

function Export-SeparationStem {
    param(
        [string]$FfmpegPath,
        [string]$StemWav,
        [string]$OutputPath,
        [string]$Bitrate,
        [string]$LogPath,
        [object]$State
    )

    $arguments = @('-y', '-v', 'error', '-i', $StemWav, '-af', $Script:SeparationLimiterFilter, '-c:a', 'aac', '-b:a', $Bitrate, $OutputPath)
    $result = Invoke-SeparationProcess -FilePath $FfmpegPath -Arguments $arguments -State $State
    Assert-SeparationProcessSucceeded -Result $result -What 'ffmpeg（トラックの書き出し）' -LogPath $LogPath
}

function Get-SeparationOutputPath {
    param(
        [string]$SourceFile,
        [string]$Suffix
    )

    $directory = Split-Path -Parent $SourceFile
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    return Join-Path $directory ($baseName + $Suffix + '.m4a')
}

function Format-SeparationTitle {
    param(
        [string]$Base,
        [string[]]$Notes
    )

    $parts = @($Notes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        return $Base
    }
    return $Base + '（' + ($parts -join ' / ') + '）'
}

# リデュース量の表記。正でボーカルを下げる、負で上げる（強調）
function Format-SeparationReduceTitle {
    param([int]$Db)

    if ($Db -ge 0) {
        return 'ボーカル -{0}dB' -f $Db
    }
    return 'ボーカル +{0}dB' -f (-$Db)
}

# スライダーの横に出す目安。音量比 10^(−dB/20) を「約25%」「約2.0倍」で表す
function Format-SeparationLevelNote {
    param([int]$Db)

    if ($Db -eq 0) {
        return '（元のまま）'
    }
    $ratio = [math]::Pow(10.0, -$Db / 20.0)
    if ($Db -gt 0) {
        return '（約{0}%）' -f [math]::Round($ratio * 100)
    }
    return '（約{0}倍）' -f $ratio.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-SeparationReduceSuffix {
    param(
        [int]$Db,
        [string]$ModelKey
    )

    if ($Db -ge 0) {
        return '_vocal-{0}dB_{1}' -f $Db, $ModelKey
    }
    return '_vocal+{0}dB_{1}' -f (-$Db), $ModelKey
}

# 作るトラックの一覧。この順にトラックが追加される。
# StemId は引くステム（「モデル|入力」）。Factor が $null のものはステムそのまま書き出す。
# 「候補をまとめて作る」ではボーカルカットとコーラス残しをファイルのある全モデルで作り、トラック名にモデル名を付ける。
function Get-SeparationKinds {
    param(
        [object]$Request,
        [object[]]$Models
    )

    $all = [bool]$Request.AllCandidates
    $vocalKeys = @([string]$Request.VocalModel)
    $leadKeys = @([string]$Request.LeadModel)
    if ($all) {
        $vocalKeys = @($Models | Where-Object { $_.Role -eq 'vocals' -and $_.Available } | ForEach-Object { $_.Key })
        $leadKeys = @($Models | Where-Object { $_.Role -eq 'lead' -and $_.Available } | ForEach-Object { $_.Key })
    }
    $vocalModel = [string]$Request.VocalModel
    $twoStage = [bool]$Request.TwoStage

    # gains が $null のものはステムをそのまま書き出す
    $names = $Request.TrackNames
    if ($null -eq $names) {
        $names = (ConvertTo-SeparationSettings $null).TrackNames
    }
    # $template はひな形、$short はモデルの短い名前、$extra は「2段」などの補足
    $newKind = {
        param([string]$key, [string]$stemId, [object]$gains, [string]$suffix, [string]$template, [string]$short, [string[]]$extra, [string]$model, [object]$db, [bool]$hidden)
        [PSCustomObject]@{
            Key = $key; StemId = $stemId; Gains = $gains; Suffix = $suffix
            Title = Expand-SeparationTitleTemplate -Template $template -ModelShort $short -Db $db -IncludeModel $all -ExtraNotes $extra
            Template = $template; ModelShort = $short; IncludeModel = $all; ExtraNotes = @($extra | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            VocalModel = $model; Db = $db; Hidden = $hidden
        }
    }

    $kinds = @()
    if ($Request.VocalCut) {
        foreach ($key in $vocalKeys) {
            $short = (Get-SeparationModel -Models $Models -Key $key).Short
            $kinds += & $newKind 'cut' ($key + '|mix') @(1.0, -1.0) ('_offvocal_' + $key) ([string]$names.Cut) $short @() $key $null $false
        }
    }
    if ($Request.VocalReduce) {
        # 正で下げる、負で上げる（強調）
        $db = [int]$Request.ReduceDb
        $short = (Get-SeparationModel -Models $Models -Key $vocalModel).Short
        $kinds += & $newKind 'reduce' ($vocalModel + '|mix') (Get-SeparationReduceGains -Db $db) (Format-SeparationReduceSuffix -Db $db -ModelKey $vocalModel) ([string]$names.Reduce) $short @() $vocalModel $db $false
    }
    if ($Request.Karaoke) {
        foreach ($key in $leadKeys) {
            $short = (Get-SeparationModel -Models $Models -Key $key).Short
            if ($twoStage) {
                # ボーカルだけを取り出してからリードを推定する。元音源 − リード ＝ ボーカルモデルの伴奏 + コーラス成分
                $kinds += & $newKind 'karaoke' ($key + '|stem:' + $vocalModel) @(1.0, -1.0) ('_karaoke_' + $key + '_2stage') ([string]$names.Karaoke) $short @($(if ($all) { '2段' })) $vocalModel $null $false
            }
            else {
                $kinds += & $newKind 'karaoke' ($key + '|mix') @(1.0, -1.0) ('_karaoke_' + $key) ([string]$names.Karaoke) $short @() '' $null $false
            }
        }
    }
    if ($Request.VocalsOnly) {
        $short = (Get-SeparationModel -Models $Models -Key $vocalModel).Short
        $kinds += & $newKind 'vocals' ($vocalModel + '|mix') $null ('_vocals_' + $vocalModel) ([string]$names.Vocals) $short @() $vocalModel $null $false
    }
    if ($Request.VocalReduce) {
        # リデュースのプレビュー（伴奏とボーカルを同時に鳴らして量を変える）用に、
        # 同じモデルの伴奏とボーカルがなければ隠しトラックとして作っておく
        if (-not @($kinds | Where-Object { $_.Key -eq 'cut' -and $_.VocalModel -eq $vocalModel }).Count) {
            $kinds += & $newKind 'cut' ($vocalModel + '|mix') @(1.0, -1.0) ('_offvocal_' + $vocalModel) ([string]$names.Cut) $short @() $vocalModel $null $true
        }
        if (-not @($kinds | Where-Object { $_.Key -eq 'vocals' -and $_.VocalModel -eq $vocalModel }).Count) {
            $kinds += & $newKind 'vocals' ($vocalModel + '|mix') $null ('_vocals_' + $vocalModel) ([string]$names.Vocals) $short @() $vocalModel $null $true
        }
    }
    return $kinds
}

# 必要な bs_roformer-cli の実行一覧（重複なし、依存順）。StemId「モデル|mix」は元音源から、
# 「モデル|stem:ボーカルモデル」はそのボーカルモデルのステムから推定する
function Get-SeparationRunPlan {
    param([object[]]$Kinds)

    $runs = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($kind in $Kinds) {
        $modelKey, $inputId = ([string]$kind.StemId) -split '\|', 2
        if ($inputId -like 'stem:*') {
            $dependency = $inputId.Substring(5) + '|mix'
            if ($seen.Add($dependency)) {
                [void]$runs.Add([PSCustomObject]@{ Id = $dependency; ModelKey = $inputId.Substring(5); InputId = 'mix' })
            }
        }
        if ($seen.Add([string]$kind.StemId)) {
            [void]$runs.Add([PSCustomObject]@{ Id = [string]$kind.StemId; ModelKey = $modelKey; InputId = $inputId })
        }
    }
    return @($runs.ToArray())
}

# 変換 → 分離 → 書き出しを順に行い、作ったファイルとトラック名の一覧を返す。
# OutputDir を指定するとそこに書き出す（採用を決めるまでの一時置き場）。省略時は元の音源と同じフォルダー
function Invoke-Separation {
    param(
        [object]$Request,
        [string]$FfmpegPath,
        [string]$CliPath,
        [scriptblock]$OnProgress,
        [object]$State,
        [string]$OutputDir = ''
    )

    $models = @(Get-SeparationModelList)
    $kinds = @(Get-SeparationKinds -Request $Request -Models $models)
    if ($kinds.Count -eq 0) {
        if ($Request.AllCandidates -and ($Request.VocalCut -or $Request.Karaoke)) {
            throw ("候補になるモデルがありません。`r`n{0} に GGUF ファイルを置いてください。" -f (Get-SeparationModelsRealDir))
        }
        throw '作るトラックを選んでください。'
    }

    $runs = @(Get-SeparationRunPlan -Kinds $kinds)
    foreach ($run in $runs) {
        $model = Get-SeparationModel -Models $models -Key $run.ModelKey
        if (-not $model.Available) {
            throw ("分離モデルがありません。`r`n{0}`r`n`r`n{1} の GGUF ファイルをこの場所に置いてください。" -f $model.Path, $model.Label)
        }
    }

    $logPath = [System.IO.Path]::ChangeExtension((Get-SeparationOutputPath -SourceFile $Request.SourceFile -Suffix '_separate'), '.log')
    # OutputDir があるときは作業用 WAV もその下に残す（リデュース量を変えて作り直すのに使う。呼び出し側が消す）
    $keepWork = -not [string]::IsNullOrWhiteSpace($OutputDir)
    $tempDir = if ($keepWork) { Join-Path $OutputDir 'work' } else { Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_sep_' + [guid]::NewGuid().ToString('N')) }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        & $OnProgress 0 '音声を 44.1kHz の WAV に変換しています...'
        $mixWav = Join-Path $tempDir 'mix.wav'
        ConvertTo-SeparationWav -FfmpegPath $FfmpegPath -SourceFile $Request.SourceFile -OutputPath $mixWav -LogPath $logPath -State $State

        $stems = @{}
        $runCount = $runs.Count
        for ($runIndex = 0; $runIndex -lt $runCount; $runIndex++) {
            $run = $runs[$runIndex]
            $model = Get-SeparationModel -Models $models -Key $run.ModelKey
            $inputWav = if ($run.InputId -eq 'mix') { $mixWav } else { $stems[$run.InputId.Substring(5) + '|mix'] }
            $stemWav = Join-Path $tempDir ('stem{0}.wav' -f $runIndex)
            $stemLabel = if ($model.Role -eq 'lead') { 'リードボーカル' } else { 'ボーカル' }
            $percentBase = 5 + (85 * $runIndex / $runCount)
            $percentSpan = 85 / $runCount
            & $OnProgress ([int]$percentBase) ('{0} で{1}を分離しています ({2}/{3})...' -f $model.Short, $stemLabel, ($runIndex + 1), $runCount)
            $onPercent = {
                param([int]$percent)
                & $OnProgress ([int]($percentBase + $percentSpan * $percent / 100)) ('{0} で{1}を分離しています ({2}/{3}) {4}%' -f $model.Short, $stemLabel, ($runIndex + 1), $runCount, $percent)
            }
            Invoke-BsRoformerCli -CliPath $CliPath -ModelPath $model.Path -InputWav $inputWav -OutputWav $stemWav -LogPath $logPath -OnPercent $onPercent -State $State -StemIndex ([int]$model.Stem)
            $stems[$run.Id] = $stemWav
        }

        & $OnProgress 92 'トラックを書き出しています...'
        $outputs = @()
        foreach ($kind in $kinds) {
            $outputPath = Get-SeparationOutputPath -SourceFile $Request.SourceFile -Suffix $kind.Suffix
            if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
                $outputPath = Join-Path $OutputDir (Split-Path -Leaf $outputPath)
            }
            if ($null -eq $kind.Gains) {
                Export-SeparationStem -FfmpegPath $FfmpegPath -StemWav $stems[$kind.StemId] -OutputPath $outputPath -Bitrate $Request.Bitrate -LogPath $logPath -State $State
            }
            else {
                New-SeparationDerivedTrack -FfmpegPath $FfmpegPath -MixWav $mixWav -StemWav $stems[$kind.StemId] -MixGain ([double]$kind.Gains[0]) -StemGain ([double]$kind.Gains[1]) -OutputPath $outputPath -Bitrate $Request.Bitrate -LogPath $logPath -State $State
            }
            $outputs += [PSCustomObject]@{
                Path = $outputPath; Title = $kind.Title; Kind = $kind.Key; Hidden = [bool]$kind.Hidden
                VocalModel = [string]$kind.VocalModel; Db = $kind.Db
                Template = [string]$kind.Template; ModelShort = [string]$kind.ModelShort; IncludeModel = [bool]$kind.IncludeModel; ExtraNotes = @($kind.ExtraNotes)
                MixWav = $mixWav; StemWav = $stems[$kind.StemId]
            }
        }

        & $OnProgress 100 '完了'
        return $outputs
    }
    finally {
        if (-not $keepWork) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# 分離で作ったファイルを、元のトラックの下にトラック名付きで差し込む。
# 同じ音源から作ったので、オフセットは元のトラックと同じにする。同じファイルの行がすでにあれば追加しない
function Add-SeparatedTracksToGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Tracks,
        [int]$InsertIndex,
        [int]$OffsetMs = 0
    )

    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Grid.Rows) {
        if (-not $row.IsNewRow -and $null -ne $row.Tag -and -not [bool]$row.Tag.IsVideoAudio) {
            [void]$existing.Add([System.IO.Path]::GetFullPath([string]$row.Tag.SourceFile))
        }
    }

    $firstAddedRow = -1
    $addedCount = 0
    $index = $InsertIndex
    foreach ($track in $Tracks) {
        $path = [string]$track.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath($path)
        if ($existing.Contains($fullPath)) {
            continue
        }

        $item = New-TrackItem -SourceFile $fullPath -IsVideoAudio $false -Title ([string]$track.Title) -OffsetMs $OffsetMs
        Add-TrackRow -Grid $Grid -Item $item -Index $index
        if ($firstAddedRow -lt 0) {
            $firstAddedRow = [math]::Min($index, $Grid.Rows.Count - 1)
        }
        $index++
        $addedCount++
    }

    if ($addedCount -gt 0) {
        Update-TrackNumbers -Grid $Grid
        Sync-AudioFilesFromGrid -Grid $Grid
        $Grid.CurrentCell = $Grid.Rows[$firstAddedRow].Cells[1]
    }

    return $addedCount
}

# モデル選択のコンボボックスに、役割が合うモデルを並べる。戻り値はキーの配列（Items と同じ順）
function Set-SeparationModelComboItems {
    param(
        [System.Windows.Forms.ComboBox]$ComboBox,
        [object[]]$Models,
        [string]$Role,
        [string]$SelectedKey
    )

    $ComboBox.Items.Clear()
    $keys = @()
    foreach ($model in @($Models | Where-Object { $_.Role -eq $Role })) {
        $text = [string]$model.Label
        if (-not $model.Available) {
            $text += $(if ([string]::IsNullOrWhiteSpace([string]$model.Url)) { '（未配置）' } else { '（初回にダウンロード）' })
        }
        [void]$ComboBox.Items.Add($text)
        $keys += [string]$model.Key
    }

    $index = [array]::IndexOf($keys, $SelectedKey)
    if ($index -lt 0) {
        foreach ($wantAvailable in $true, $false) {
            for ($candidate = 0; $candidate -lt $keys.Count; $candidate++) {
                $model = Get-SeparationModel -Models $Models -Key $keys[$candidate]
                if ($model.Available -eq $wantAvailable -and ($wantAvailable -or -not [string]::IsNullOrWhiteSpace([string]$model.Url))) {
                    $index = $candidate
                    break
                }
            }
            if ($index -ge 0) {
                break
            }
        }
    }
    if ($index -lt 0 -and $keys.Count -gt 0) {
        $index = 0
    }
    $ComboBox.SelectedIndex = $index
    return $keys
}

# 「ボーカル分離」の画面。選択中のトラックを元に分離し、できたファイルをプレビュー付きの一覧で見せて、
# 採用するものだけを返す。実行中はこの画面の中で進捗を出す
function Show-SeparationDialog {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$SourceFile,
        [string]$SourceText,
        [object]$Settings
    )

    $state = [PSCustomObject]@{
        Running         = $false
        CancelRequested = $false
        Phase           = 'settings'
        Generated       = @()
        Bitrate         = '256k'
        Result          = $null
    }
    # プレビュー再生の状態。リデュースの行は伴奏（Player）とボーカル（Player2）を同時に鳴らして量を変える。
    # Pending は読み込みが終わってから移動する位置（秒）
    $playback = [PSCustomObject]@{
        Player        = $null
        Player2       = $null
        Tag           = $null
        Dual          = $false
        Pending       = $null
        Playing       = $false
        Updating      = $false
        LevelUpdating = $false
        Loading       = $false
        Error         = ''
    }
    $saved = ConvertTo-SeparationSettings $Settings.Separation
    # モデル一覧とコンボボックスのキー。フォルダーにモデルを足したあと画面に戻ったときに読み直す
    $modelState = [PSCustomObject]@{
        Models    = @(Get-SeparationModelList)
        VocalKeys = @()
        LeadKeys  = @()
    }
    # できたファイルは採用を決めるまでここに置き、採用したものだけ元のファイルと同じフォルダーへ移す
    $resultsDir = Join-Path ([System.IO.Path]::GetTempPath()) ('PitaTrack_sep_results_' + [guid]::NewGuid().ToString('N'))
    $sourceDir = Split-Path -Parent $SourceFile
    $logPath = [System.IO.Path]::ChangeExtension((Get-SeparationOutputPath -SourceFile $SourceFile -Suffix '_separate'), '.log')

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'ボーカル分離'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 452)
    Set-FormTheme -Form $dialog

    # ---- 設定の面 ----
    $settingsPanel = New-Object System.Windows.Forms.Panel
    $settingsPanel.Location = New-Object System.Drawing.Point(0, 0)
    $settingsPanel.Size = New-Object System.Drawing.Size(520, 344)
    $settingsPanel.BackColor = Get-UiColor 'Background'

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Text = '元のトラック'
    $sourceLabel.Location = New-Object System.Drawing.Point(12, 15)
    $sourceLabel.Size = New-Object System.Drawing.Size(76, 22)
    Set-LabelTheme -Label $sourceLabel -Muted

    $sourceValue = New-Object System.Windows.Forms.Label
    $sourceValue.Text = $SourceText
    $sourceValue.Location = New-Object System.Drawing.Point(88, 12)
    $sourceValue.Size = New-Object System.Drawing.Size(420, 22)
    $sourceValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $sourceValue.AutoEllipsis = $true
    $sourceValue.UseMnemonic = $false
    Set-PathLabelTheme -Label $sourceValue

    $kindLabel = New-Object System.Windows.Forms.Label
    $kindLabel.Text = '作るトラック'
    $kindLabel.Location = New-Object System.Drawing.Point(12, 51)
    $kindLabel.Size = New-Object System.Drawing.Size(76, 22)
    Set-LabelTheme -Label $kindLabel -Muted

    $cutCheck = New-Object System.Windows.Forms.CheckBox
    $cutCheck.Text = 'ボーカルカット（オフボーカル）'
    $cutCheck.Location = New-Object System.Drawing.Point(88, 48)
    $cutCheck.Size = New-Object System.Drawing.Size(420, 24)
    $cutCheck.Checked = $true
    $cutCheck.TabIndex = 0
    Set-CheckBoxTheme -CheckBox $cutCheck

    $reduceCheck = New-Object System.Windows.Forms.CheckBox
    $reduceCheck.Text = 'ボーカルリデュース'
    $reduceCheck.Location = New-Object System.Drawing.Point(88, 76)
    $reduceCheck.Size = New-Object System.Drawing.Size(150, 24)
    $reduceCheck.TabIndex = 1
    Set-CheckBoxTheme -CheckBox $reduceCheck

    $reduceUpDown = New-Object System.Windows.Forms.NumericUpDown
    $reduceUpDown.Location = New-Object System.Drawing.Point(240, 77)
    $reduceUpDown.Size = New-Object System.Drawing.Size(56, 22)
    $reduceUpDown.Minimum = -20
    $reduceUpDown.Maximum = 40
    $reduceUpDown.Value = [int]$saved.ReduceDb
    $reduceUpDown.TabIndex = 2
    $reduceUpDown.Font = New-UiFont 9

    $reduceUnitLabel = New-Object System.Windows.Forms.Label
    $reduceUnitLabel.Text = 'dB 下げる（結果画面で調節可）'
    $reduceUnitLabel.Location = New-Object System.Drawing.Point(300, 79)
    $reduceUnitLabel.Size = New-Object System.Drawing.Size(212, 22)
    Set-LabelTheme -Label $reduceUnitLabel

    $karaokeCheck = New-Object System.Windows.Forms.CheckBox
    $karaokeCheck.Text = 'コーラスを残してボーカルカット（リードボーカルだけ除く）'
    $karaokeCheck.Location = New-Object System.Drawing.Point(88, 104)
    $karaokeCheck.Size = New-Object System.Drawing.Size(420, 24)
    $karaokeCheck.TabIndex = 3
    Set-CheckBoxTheme -CheckBox $karaokeCheck

    $twoStageCheck = New-Object System.Windows.Forms.CheckBox
    $twoStageCheck.Text = 'ボーカルだけを取り出してからリードを除く（2 段方式・おすすめ）'
    $twoStageCheck.Location = New-Object System.Drawing.Point(108, 130)
    $twoStageCheck.Size = New-Object System.Drawing.Size(400, 24)
    $twoStageCheck.Checked = [bool]$saved.TwoStage
    $twoStageCheck.TabIndex = 4
    Set-CheckBoxTheme -CheckBox $twoStageCheck

    $vocalsCheck = New-Object System.Windows.Forms.CheckBox
    $vocalsCheck.Text = 'ボーカルのみ（分離したボーカル）'
    $vocalsCheck.Location = New-Object System.Drawing.Point(88, 158)
    $vocalsCheck.Size = New-Object System.Drawing.Size(420, 24)
    $vocalsCheck.TabIndex = 5
    Set-CheckBoxTheme -CheckBox $vocalsCheck

    $modelLabel = New-Object System.Windows.Forms.Label
    $modelLabel.Text = 'モデル'
    $modelLabel.Location = New-Object System.Drawing.Point(12, 197)
    $modelLabel.Size = New-Object System.Drawing.Size(70, 22)
    Set-LabelTheme -Label $modelLabel -Muted

    $vocalModelLabel = New-Object System.Windows.Forms.Label
    $vocalModelLabel.Text = 'ボーカル'
    $vocalModelLabel.Location = New-Object System.Drawing.Point(88, 197)
    $vocalModelLabel.Size = New-Object System.Drawing.Size(124, 22)
    Set-LabelTheme -Label $vocalModelLabel

    $vocalModelCombo = New-Object System.Windows.Forms.ComboBox
    $vocalModelCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $vocalModelCombo.Location = New-Object System.Drawing.Point(216, 194)
    $vocalModelCombo.Size = New-Object System.Drawing.Size(292, 22)
    $vocalModelCombo.TabIndex = 6
    Set-ComboBoxTheme -ComboBox $vocalModelCombo
    $modelState.VocalKeys = @(Set-SeparationModelComboItems -ComboBox $vocalModelCombo -Models $modelState.Models -Role 'vocals' -SelectedKey ([string]$saved.VocalModel))

    $leadModelLabel = New-Object System.Windows.Forms.Label
    $leadModelLabel.Text = 'リードボーカル'
    $leadModelLabel.Location = New-Object System.Drawing.Point(88, 227)
    $leadModelLabel.Size = New-Object System.Drawing.Size(124, 22)
    Set-LabelTheme -Label $leadModelLabel

    $leadModelCombo = New-Object System.Windows.Forms.ComboBox
    $leadModelCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $leadModelCombo.Location = New-Object System.Drawing.Point(216, 224)
    $leadModelCombo.Size = New-Object System.Drawing.Size(292, 22)
    $leadModelCombo.TabIndex = 7
    Set-ComboBoxTheme -ComboBox $leadModelCombo
    $modelState.LeadKeys = @(Set-SeparationModelComboItems -ComboBox $leadModelCombo -Models $modelState.Models -Role 'lead' -SelectedKey ([string]$saved.LeadModel))

    $allCandidatesCheck = New-Object System.Windows.Forms.CheckBox
    $allCandidatesCheck.Text = '全モデルで候補を作る'
    $allCandidatesCheck.Location = New-Object System.Drawing.Point(88, 254)
    $allCandidatesCheck.Size = New-Object System.Drawing.Size(256, 24)
    $allCandidatesCheck.TabIndex = 8
    Set-CheckBoxTheme -CheckBox $allCandidatesCheck

    $openModelsButton = New-Object System.Windows.Forms.Button
    $openModelsButton.Text = 'モデルフォルダーを開く'
    $openModelsButton.Location = New-Object System.Drawing.Point(348, 252)
    $openModelsButton.Size = New-Object System.Drawing.Size(160, 28)
    $openModelsButton.TabIndex = 12
    Set-ButtonTheme -Button $openModelsButton
    $dialogToolTip = New-Object System.Windows.Forms.ToolTip
    $dialogToolTip.SetToolTip($allCandidatesCheck, 'ファイルのある全モデルでボーカルカットとコーラス残しを 1 トラックずつ作ります（トラック名にモデル名が付きます）')
    $dialogToolTip.SetToolTip($openModelsButton, "モデル（.gguf）を置くフォルダーを開きます。`r`n同名の .json に {`"label`": `"表示名`", `"role`": `"vocals または lead`"} を書くと、名前と用途を指定できます。")

    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = "できたトラックは次の画面で聴いてから、採用するものだけを追加します。`r`n出力は元のファイルと同じフォルダーに m4a で保存します。`r`nGPU がない PC では 1 モデルで数分〜十数分かかります。"
    $noteLabel.Location = New-Object System.Drawing.Point(88, 284)
    $noteLabel.Size = New-Object System.Drawing.Size(420, 58)
    Set-LabelTheme -Label $noteLabel -Muted

    $settingsPanel.Controls.AddRange(@(
        $sourceLabel, $sourceValue,
        $kindLabel, $cutCheck, $reduceCheck, $reduceUpDown, $reduceUnitLabel, $karaokeCheck, $twoStageCheck, $vocalsCheck,
        $modelLabel, $vocalModelLabel, $vocalModelCombo, $leadModelLabel, $leadModelCombo, $allCandidatesCheck, $openModelsButton,
        $noteLabel
    ))

    # ---- 結果の面 ----
    $resultPanel = New-Object System.Windows.Forms.Panel
    $resultPanel.Location = New-Object System.Drawing.Point(0, 0)
    $resultPanel.Size = New-Object System.Drawing.Size(520, 344)
    $resultPanel.BackColor = Get-UiColor 'Background'
    $resultPanel.Visible = $false

    $resultLabel = New-Object System.Windows.Forms.Label
    $resultLabel.Text = 'できたトラック（行を選んで再生。トラック名はクリックで候補から選べ、入力もできます）'
    $resultLabel.Location = New-Object System.Drawing.Point(12, 10)
    $resultLabel.Size = New-Object System.Drawing.Size(496, 22)
    Set-LabelTheme -Label $resultLabel -Muted

    $resultGrid = New-Object System.Windows.Forms.DataGridView
    $resultGrid.Location = New-Object System.Drawing.Point(12, 34)
    $resultGrid.Size = New-Object System.Drawing.Size(496, 156)
    $resultGrid.AllowUserToAddRows = $false
    $resultGrid.AllowUserToDeleteRows = $false
    $resultGrid.AllowUserToResizeRows = $false
    $resultGrid.RowHeadersVisible = $false
    $resultGrid.AutoSizeColumnsMode = 'Fill'
    $resultGrid.SelectionMode = 'FullRowSelect'
    $resultGrid.MultiSelect = $false
    $resultGrid.TabIndex = 0
    Set-GridTheme -Grid $resultGrid

    $adoptColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $adoptColumn.HeaderText = '採用'
    $adoptColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
    $adoptColumn.Width = 48
    $resultGrid.Columns.Add($adoptColumn) | Out-Null

    $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $nameColumn.HeaderText = 'トラック名'
    $nameColumn.FillWeight = 50
    $resultGrid.Columns.Add($nameColumn) | Out-Null

    $fileColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $fileColumn.HeaderText = 'ファイル'
    $fileColumn.FillWeight = 50
    $fileColumn.ReadOnly = $true
    $resultGrid.Columns.Add($fileColumn) | Out-Null

    # リデュースの行を選んでいるときだけ出す「ボーカル量」のスライダー
    $levelLabel = New-Object System.Windows.Forms.Label
    $levelLabel.Text = 'ボーカル量'
    $levelLabel.Location = New-Object System.Drawing.Point(12, 198)
    $levelLabel.Size = New-Object System.Drawing.Size(76, 22)
    $levelLabel.Visible = $false
    Set-LabelTheme -Label $levelLabel -Muted

    $levelBar = New-Object System.Windows.Forms.TrackBar
    $levelBar.AutoSize = $false
    $levelBar.Location = New-Object System.Drawing.Point(88, 194)
    $levelBar.Size = New-Object System.Drawing.Size(180, 30)
    $levelBar.Minimum = -20
    $levelBar.Maximum = 40
    $levelBar.TickFrequency = 10
    $levelBar.SmallChange = 1
    $levelBar.LargeChange = 3
    $levelBar.Visible = $false
    $levelBar.TabIndex = 1

    $levelValue = New-Object System.Windows.Forms.Label
    $levelValue.Text = ''
    $levelValue.Location = New-Object System.Drawing.Point(272, 198)
    $levelValue.Size = New-Object System.Drawing.Size(236, 22)
    $levelValue.Visible = $false
    Set-LabelTheme -Label $levelValue

    $playButton = New-Object System.Windows.Forms.Button
    $playButton.Text = '▶ 再生'
    $playButton.Location = New-Object System.Drawing.Point(12, 232)
    $playButton.Size = New-Object System.Drawing.Size(84, 28)
    $playButton.TabIndex = 2
    Set-ButtonTheme -Button $playButton

    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = '■ 停止'
    $stopButton.Location = New-Object System.Drawing.Point(100, 232)
    $stopButton.Size = New-Object System.Drawing.Size(84, 28)
    $stopButton.TabIndex = 3
    Set-ButtonTheme -Button $stopButton

    $positionBar = New-Object System.Windows.Forms.TrackBar
    $positionBar.AutoSize = $false
    $positionBar.Location = New-Object System.Drawing.Point(190, 231)
    $positionBar.Size = New-Object System.Drawing.Size(160, 30)
    $positionBar.Minimum = 0
    $positionBar.Maximum = 100
    $positionBar.TickStyle = [System.Windows.Forms.TickStyle]::None
    $positionBar.TabIndex = 4

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = '0:00 / 0:00'
    $timeLabel.Location = New-Object System.Drawing.Point(352, 235)
    $timeLabel.Size = New-Object System.Drawing.Size(76, 22)
    $timeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    Set-LabelTheme -Label $timeLabel

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存...'
    $saveButton.Location = New-Object System.Drawing.Point(432, 232)
    $saveButton.Size = New-Object System.Drawing.Size(76, 28)
    $saveButton.TabIndex = 5
    Set-ButtonTheme -Button $saveButton

    $resultHint = New-Object System.Windows.Forms.Label
    $resultHint.Text = "再生中に別の行を選ぶと、同じ位置のままそのトラックに切り替わります（聴き比べ用）。`r`n採用したトラックは元のファイルと同じフォルダーに保存して一覧に追加します。`r`n採用しないトラックは「保存...」で残せます。残りはこの画面を閉じるときに消えます。"
    $resultHint.Location = New-Object System.Drawing.Point(12, 268)
    $resultHint.Size = New-Object System.Drawing.Size(496, 58)
    Set-LabelTheme -Label $resultHint -Muted

    $resultPanel.Controls.AddRange(@($resultLabel, $resultGrid, $levelLabel, $levelBar, $levelValue, $playButton, $stopButton, $positionBar, $timeLabel, $saveButton, $resultHint))

    # ---- 共通の下部 ----
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(12, 348)
    $progressBar.Size = New-Object System.Drawing.Size(496, 18)
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous

    $statusText = New-Object System.Windows.Forms.Label
    $statusText.Text = ''
    $statusText.Location = New-Object System.Drawing.Point(12, 372)
    $statusText.Size = New-Object System.Drawing.Size(496, 22)
    $statusText.AutoEllipsis = $true
    Set-LabelTheme -Label $statusText -Muted

    $backButton = New-Object System.Windows.Forms.Button
    $backButton.Text = '← やり直す'
    $backButton.Location = New-Object System.Drawing.Point(12, 410)
    $backButton.Size = New-Object System.Drawing.Size(110, 30)
    $backButton.TabIndex = 11
    $backButton.Visible = $false
    Set-ButtonTheme -Button $backButton

    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Text = '実行'
    $runButton.Location = New-Object System.Drawing.Point(254, 410)
    $runButton.Size = New-Object System.Drawing.Size(162, 30)
    $runButton.TabIndex = 9
    Set-ButtonTheme -Button $runButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(416, 410)
    $cancelButton.Size = New-Object System.Drawing.Size(92, 30)
    $cancelButton.TabIndex = 10
    Set-ButtonTheme -Button $cancelButton

    $inputControls = @($cutCheck, $reduceCheck, $reduceUpDown, $karaokeCheck, $twoStageCheck, $vocalsCheck, $vocalModelCombo, $leadModelCombo, $allCandidatesCheck, $runButton)
    $setInputsEnabled = {
        param([bool]$enabled)

        foreach ($control in $inputControls) {
            $control.Enabled = $enabled
        }
        if ($enabled) {
            $twoStageCheck.Enabled = $karaokeCheck.Checked
        }
    }
    $onProgress = {
        param(
            [int]$percent,
            [string]$text
        )

        $progressBar.Value = [math]::Max(0, [math]::Min(100, $percent))
        $statusText.Text = $text
        [System.Windows.Forms.Application]::DoEvents()
    }
    $getSelectedKey = {
        param(
            [System.Windows.Forms.ComboBox]$combo,
            [string[]]$keys
        )

        if ($combo.SelectedIndex -lt 0 -or $combo.SelectedIndex -ge $keys.Count) {
            return ''
        }
        return $keys[$combo.SelectedIndex]
    }

    # ---- プレビュー再生（.NET の MediaPlayer。AAC/m4a も再生できる） ----
    $formatTime = {
        param([double]$seconds)

        $total = [int][math]::Floor([math]::Max(0, $seconds))
        return '{0}:{1:00}' -f [int][math]::Floor($total / 60), ($total % 60)
    }
    $ensurePlayer = {
        if ($null -ne $playback.Player -or -not [string]::IsNullOrEmpty($playback.Error)) {
            return
        }
        try {
            Add-Type -AssemblyName PresentationCore
            $playback.Player = New-Object System.Windows.Media.MediaPlayer
            $playback.Player.Volume = 0.8
        }
        catch {
            $playback.Error = $_.Exception.GetBaseException().Message
        }
    }
    $getSelectedTag = {
        if ($null -eq $resultGrid.CurrentRow) {
            return $null
        }
        return $resultGrid.CurrentRow.Tag
    }
    # リデュースのプレビューは伴奏と ボーカルを別々に鳴らす。伴奏 = 元音源 − ボーカル なので、
    # 書き出しの係数（MixGain, StemGain）から 伴奏の音量 = MixGain、ボーカルの音量 = MixGain + StemGain になる
    $reduceGains = {
        param([int]$db)

        $gains = Get-SeparationReduceGains -Db $db
        return @([double]$gains[0], ([double]$gains[0] + [double]$gains[1]))
    }
    $applyVolumes = {
        if ($null -eq $playback.Player) {
            return
        }
        if ($playback.Dual -and $null -ne $playback.Tag -and $null -ne $playback.Player2) {
            $gains = & $reduceGains ([int]$playback.Tag.Db)
            $playback.Player.Volume = 0.8 * $gains[0]
            $playback.Player2.Volume = 0.8 * $gains[1]
        }
        else {
            $playback.Player.Volume = 0.8
        }
    }
    $startPlayback = {
        param(
            [object]$tag,
            [double]$positionSeconds
        )

        & $ensurePlayer
        if ($null -eq $playback.Player) {
            $statusText.Text = 'プレビューを再生できません: ' + $playback.Error
            return
        }
        $dual = ($tag.Kind -eq 'reduce' -and -not [string]::IsNullOrEmpty([string]$tag.InstPath) -and -not [string]::IsNullOrEmpty([string]$tag.VocalsPath))
        $playback.Tag = $tag
        $playback.Dual = $dual
        $playback.Pending = $positionSeconds
        $playback.Playing = $true
        if ($dual) {
            if ($null -eq $playback.Player2) {
                $playback.Player2 = New-Object System.Windows.Media.MediaPlayer
            }
            & $applyVolumes
            $playback.Player.Open((New-Object System.Uri -ArgumentList ([string]$tag.InstPath)))
            $playback.Player2.Open((New-Object System.Uri -ArgumentList ([string]$tag.VocalsPath)))
        }
        else {
            if ($null -ne $playback.Player2) {
                $playback.Player2.Close()
            }
            & $applyVolumes
            $playback.Player.Open((New-Object System.Uri -ArgumentList ([string]$tag.Path)))
        }
        $playButton.Text = '❚❚ 一時停止'
    }
    $stopPlayback = {
        param([bool]$resetPosition)

        $playback.Playing = $false
        $playback.Pending = $null
        foreach ($player in @($playback.Player, $playback.Player2)) {
            if ($null -eq $player) {
                continue
            }
            if ($resetPosition) {
                $player.Stop()
            }
            else {
                $player.Pause()
            }
        }
        $playButton.Text = '▶ 再生'
        if ($resetPosition) {
            $playback.Updating = $true
            $positionBar.Value = 0
            $playback.Updating = $false
        }
    }
    $closePlayer = {
        foreach ($name in 'Player', 'Player2') {
            $player = $playback.$name
            if ($null -ne $player) {
                try {
                    $player.Stop()
                    $player.Close()
                }
                catch {
                }
                $playback.$name = $null
            }
        }
        $playback.Tag = $null
        $playback.Dual = $false
    }

    $playbackTimer = New-Object System.Windows.Forms.Timer
    $playbackTimer.Interval = 250
    $playbackTimer.Add_Tick({
        if ($null -eq $playback.Player) {
            return
        }
        $player = $playback.Player
        if (-not $player.NaturalDuration.HasTimeSpan) {
            return
        }
        if ($playback.Dual -and ($null -eq $playback.Player2 -or -not $playback.Player2.NaturalDuration.HasTimeSpan)) {
            return
        }
        $duration = $player.NaturalDuration.TimeSpan.TotalSeconds
        if ($null -ne $playback.Pending) {
            # 読み込みが終わったので、指定の位置に移動してから再生する（2 本のときは同じ位置に揃える）
            $target = [TimeSpan]::FromSeconds([math]::Min($playback.Pending, [math]::Max(0, $duration - 0.5)))
            $player.Position = $target
            if ($playback.Dual) {
                $playback.Player2.Position = $target
            }
            $playback.Pending = $null
            if ($playback.Playing) {
                if ($playback.Dual) {
                    $playback.Player2.Play()
                }
                $player.Play()
            }
        }
        $position = $player.Position.TotalSeconds
        $playback.Updating = $true
        $positionBar.Maximum = [math]::Max(1, [int][math]::Ceiling($duration))
        $positionBar.Value = [math]::Max(0, [math]::Min($positionBar.Maximum, [int]$position))
        $playback.Updating = $false
        $timeLabel.Text = (& $formatTime $position) + ' / ' + (& $formatTime $duration)
        if ($playback.Playing -and $position -ge $duration - 0.3) {
            & $stopPlayback $true
        }
    })

    $playButton.Add_Click({
        $tag = & $getSelectedTag
        if ($null -eq $tag) {
            return
        }
        if ($playback.Playing) {
            & $stopPlayback $false
            return
        }
        if ($tag -eq $playback.Tag -and $null -ne $playback.Player -and $playback.Player.NaturalDuration.HasTimeSpan) {
            # 一時停止からの再開
            $playback.Playing = $true
            if ($playback.Dual -and $null -ne $playback.Player2) {
                $playback.Player2.Play()
            }
            $playback.Player.Play()
            $playButton.Text = '❚❚ 一時停止'
            return
        }
        & $startPlayback $tag ([double]$positionBar.Value)
    })

    $stopButton.Add_Click({
        & $stopPlayback $true
    })

    $positionBar.Add_Scroll({
        if ($playback.Updating -or $null -eq $playback.Player -or -not $playback.Player.NaturalDuration.HasTimeSpan) {
            return
        }
        $target = [TimeSpan]::FromSeconds($positionBar.Value)
        $playback.Player.Position = $target
        if ($playback.Dual -and $null -ne $playback.Player2) {
            $playback.Player2.Position = $target
        }
        $timeLabel.Text = (& $formatTime $positionBar.Value) + ' / ' + (& $formatTime $playback.Player.NaturalDuration.TimeSpan.TotalSeconds)
    })

    $updateLevelControls = {
        param([object]$tag)

        $isReduce = ($null -ne $tag -and $tag.Kind -eq 'reduce')
        $levelLabel.Visible = $isReduce
        $levelBar.Visible = $isReduce
        $levelValue.Visible = $isReduce
        if ($isReduce) {
            $playback.LevelUpdating = $true
            $levelBar.Value = [math]::Max($levelBar.Minimum, [math]::Min($levelBar.Maximum, [int]$tag.Db))
            $playback.LevelUpdating = $false
            $levelValue.Text = (Format-SeparationReduceTitle -Db ([int]$tag.Db)) + (Format-SeparationLevelNote -Db ([int]$tag.Db))
        }
    }

    $levelBar.Add_Scroll({
        if ($playback.LevelUpdating -or $null -eq $resultGrid.CurrentRow) {
            return
        }
        $tag = $resultGrid.CurrentRow.Tag
        if ($null -eq $tag -or $tag.Kind -ne 'reduce') {
            return
        }
        $tag.Db = [int]$levelBar.Value
        $levelValue.Text = (Format-SeparationReduceTitle -Db ([int]$tag.Db)) + (Format-SeparationLevelNote -Db ([int]$tag.Db))
        # トラック名を自分で変えていなければ、新しい量に合わせて付け直す
        if ([string]$resultGrid.CurrentRow.Cells[1].Value -eq [string]$tag.AutoTitle) {
            $tag.AutoTitle = Expand-SeparationTitleTemplate -Template ([string]$tag.Template) -ModelShort ([string]$tag.ModelShort) -Db ([int]$tag.Db) -IncludeModel ([bool]$tag.IncludeModel) -ExtraNotes @($tag.ExtraNotes)
            $resultGrid.CurrentRow.Cells[1].Value = $tag.AutoTitle
        }
        if ($playback.Dual -and $tag -eq $playback.Tag) {
            & $applyVolumes
        }
    })

    $resultGrid.Add_SelectionChanged({
        if ($playback.Loading) {
            return
        }
        $tag = & $getSelectedTag
        $saveButton.Enabled = ($null -ne $tag -and [bool]$tag.Generated)
        & $updateLevelControls $tag
        if ($null -eq $tag -or $tag -eq $playback.Tag) {
            return
        }
        if ($playback.Playing -and $null -ne $playback.Player) {
            # 同じ位置のまま別のトラックに切り替える
            $current = $playback.Player.Position.TotalSeconds
            & $startPlayback $tag $current
        }
        elseif ($null -ne $playback.Player) {
            # 停止中は次の再生がこの行から始まるようにする
            & $closePlayer
        }
    })

    $resultGrid.Add_CurrentCellDirtyStateChanged({
        if ($resultGrid.IsCurrentCellDirty) {
            $resultGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    # トラック名の候補: 設定のトラック名候補 + 今回の初期名 + 入力済みの名前
    $getNameCandidates = {
        $list = New-Object System.Collections.ArrayList
        foreach ($candidate in @(Get-TrackNameCandidates -Settings $Settings)) {
            Add-UniqueStringValue -List $list -Value $candidate
        }
        foreach ($row in $resultGrid.Rows) {
            if ($null -ne $row.Tag -and [bool]$row.Tag.Generated) {
                Add-UniqueStringValue -List $list -Value ([string]$row.Tag.AutoTitle)
                Add-UniqueStringValue -List $list -Value ([string]$row.Cells[1].Value)
            }
        }
        return @($list.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    # メイン画面と同じく、トラック名のセルをクリックすると候補のメニューを出す（直接入力もできる）
    $resultGrid.Add_CellClick({
        param($sender, $cellEvent)

        if ($cellEvent.ColumnIndex -ne 1 -or $cellEvent.RowIndex -lt 0 -or $cellEvent.RowIndex -ge $resultGrid.Rows.Count) {
            return
        }
        $row = $resultGrid.Rows[$cellEvent.RowIndex]
        if ($null -eq $row.Tag -or -not [bool]$row.Tag.Generated) {
            return
        }
        $candidates = @(& $getNameCandidates)
        if ($candidates.Count -eq 0) {
            return
        }
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.ShowImageMargin = $false
        $currentValue = [string]$row.Cells[1].Value
        foreach ($candidate in $candidates) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem
            $item.Text = [string]$candidate
            $item.Tag = [PSCustomObject]@{ RowIndex = $cellEvent.RowIndex; Name = [string]$candidate }
            if ([string]$candidate -eq $currentValue) {
                $item.Checked = $true
            }
            $item.Add_Click({
                param($menuSender, $menuEvent)

                $data = $menuSender.Tag
                $resultGrid.Rows[[int]$data.RowIndex].Cells[1].Value = [string]$data.Name
            })
            [void]$menu.Items.Add($item)
        }
        $cellRect = $resultGrid.GetCellDisplayRectangle(1, $cellEvent.RowIndex, $true)
        $menu.Show($resultGrid, $cellRect.Left, $cellRect.Bottom)
    })

    $resultGrid.Add_EditingControlShowing({
        if ($null -eq $resultGrid.CurrentCell -or $resultGrid.CurrentCell.ColumnIndex -ne 1) {
            return
        }
        $textBox = $_.Control -as [System.Windows.Forms.TextBox]
        if ($null -eq $textBox) {
            return
        }
        $source = New-Object System.Windows.Forms.AutoCompleteStringCollection
        $values = [string[]]@(& $getNameCandidates)
        if ($values.Count -gt 0) {
            $source.AddRange($values)
        }
        $textBox.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::Suggest
        $textBox.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::CustomSource
        $textBox.AutoCompleteCustomSource = $source
    })

    $showResults = {
        param([object[]]$outputs)

        $playback.Loading = $true
        $resultGrid.Rows.Clear()
        $sourceRow = $resultGrid.Rows.Add($false, '（元の音源）', (Split-Path -Leaf $SourceFile))
        $resultGrid.Rows[$sourceRow].Tag = [PSCustomObject]@{ Path = $SourceFile; Generated = $false; Kind = 'source'; Db = 0 }
        $resultGrid.Rows[$sourceRow].Cells[0].ReadOnly = $true
        $resultGrid.Rows[$sourceRow].Cells[1].ReadOnly = $true
        $resultGrid.Rows[$sourceRow].DefaultCellStyle.ForeColor = Get-UiColor 'MutedText'
        foreach ($output in $outputs) {
            if ([bool]$output.Hidden) {
                continue
            }
            $rowIndex = $resultGrid.Rows.Add($true, [string]$output.Title, (Split-Path -Leaf ([string]$output.Path)))
            # リデュースの行は、同じモデルの伴奏とボーカルを同時に鳴らしてプレビューする
            $instPath = ''
            $vocalsPath = ''
            if ($output.Kind -eq 'reduce') {
                $inst = @($outputs | Where-Object { $_.Kind -eq 'cut' -and $_.VocalModel -eq $output.VocalModel }) | Select-Object -First 1
                $vocals = @($outputs | Where-Object { $_.Kind -eq 'vocals' -and $_.VocalModel -eq $output.VocalModel }) | Select-Object -First 1
                if ($null -ne $inst -and $null -ne $vocals) {
                    $instPath = [string]$inst.Path
                    $vocalsPath = [string]$vocals.Path
                }
            }
            $resultGrid.Rows[$rowIndex].Tag = [PSCustomObject]@{
                Path = [string]$output.Path; Generated = $true; Kind = [string]$output.Kind
                VocalModel = [string]$output.VocalModel; Db = $output.Db; GeneratedDb = $output.Db
                Template = [string]$output.Template; ModelShort = [string]$output.ModelShort; IncludeModel = [bool]$output.IncludeModel; ExtraNotes = @($output.ExtraNotes)
                AutoTitle = [string]$output.Title
                MixWav = [string]$output.MixWav; StemWav = [string]$output.StemWav
                InstPath = $instPath; VocalsPath = $vocalsPath
            }
        }
        $playback.Loading = $false
        if ($resultGrid.Rows.Count -gt 1) {
            $resultGrid.CurrentCell = $resultGrid.Rows[1].Cells[1]
        }
        & $updateLevelControls (& $getSelectedTag)

        $state.Generated = @($outputs)
        $state.Phase = 'results'
        $settingsPanel.Visible = $false
        $resultPanel.Visible = $true
        $backButton.Visible = $true
        $runButton.Text = '採用したトラックを追加'
        $cancelButton.Text = '閉じる'
        $dialog.AcceptButton = $null
        $visibleCount = @($outputs | Where-Object { -not [bool]$_.Hidden }).Count
        $statusText.Text = '{0} 件できました。聴いてから、採用するトラックを選んで「追加」を押してください。' -f $visibleCount
        $playbackTimer.Start()
    }
    $showSettings = {
        & $stopPlayback $true
        & $closePlayer
        $playbackTimer.Stop()
        $state.Phase = 'settings'
        $resultPanel.Visible = $false
        $settingsPanel.Visible = $true
        $backButton.Visible = $false
        $runButton.Text = '実行'
        $cancelButton.Text = 'キャンセル'
        $dialog.AcceptButton = $runButton
        $statusText.Text = ''
    }
    # プレビューで開いているファイルは操作できないことがあるので、閉じてから数回試す
    $invokeFileAction = {
        param([scriptblock]$action)

        $lastError = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                & $action
                return
            }
            catch {
                $lastError = $_
                & $closePlayer
                Start-Sleep -Milliseconds 200
            }
        }
        throw $lastError
    }
    $removeResultsDir = {
        & $closePlayer
        if (Test-Path -LiteralPath $resultsDir) {
            Remove-Item -LiteralPath $resultsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # リデュースの量を変えた行は、その量で正確に計算したファイルを作り直してから使う
    $ensureRowFile = {
        param([object]$row)

        $tag = $row.Tag
        if ($tag.Kind -ne 'reduce' -or [int]$tag.Db -eq [int]$tag.GeneratedDb) {
            return [string]$tag.Path
        }
        if ([string]::IsNullOrEmpty([string]$tag.MixWav) -or -not (Test-Path -LiteralPath $tag.MixWav -PathType Leaf) -or -not (Test-Path -LiteralPath $tag.StemWav -PathType Leaf)) {
            throw 'ボーカル量を変えて作り直すための作業ファイルが見つかりません。設定に戻ってやり直してください。'
        }
        $ffmpegPath = Get-SupportFilePath -FileName 'ffmpeg.exe'
        $suffix = Format-SeparationReduceSuffix -Db ([int]$tag.Db) -ModelKey ([string]$tag.VocalModel)
        $newPath = Join-Path $resultsDir (Split-Path -Leaf (Get-SeparationOutputPath -SourceFile $SourceFile -Suffix $suffix))
        $gains = Get-SeparationReduceGains -Db ([int]$tag.Db)
        & $closePlayer
        $statusText.Text = 'ボーカル量を変えて書き出しています: ' + (Format-SeparationReduceTitle -Db ([int]$tag.Db))
        [System.Windows.Forms.Application]::DoEvents()
        New-SeparationDerivedTrack -FfmpegPath $ffmpegPath -MixWav $tag.MixWav -StemWav $tag.StemWav -MixGain ([double]$gains[0]) -StemGain ([double]$gains[1]) -OutputPath $newPath -Bitrate $state.Bitrate -LogPath $logPath -State $null
        $tag.Path = $newPath
        $tag.GeneratedDb = [int]$tag.Db
        $row.Cells[2].Value = Split-Path -Leaf $newPath
        return $newPath
    }

    # 書き出しやファイル操作の間（DoEvents で画面は動く）に他のボタンが押されても二重に動かないようにする
    $setResultBusy = {
        param([bool]$busy)

        $state.Running = $busy
        foreach ($control in @($runButton, $backButton, $saveButton, $playButton, $stopButton, $resultGrid, $levelBar, $positionBar)) {
            $control.Enabled = -not $busy
        }
        $dialog.UseWaitCursor = $busy
        if (-not $busy) {
            $tag = & $getSelectedTag
            $saveButton.Enabled = ($null -ne $tag -and [bool]$tag.Generated)
        }
    }

    # 選択中のトラックを好きな場所にコピーして残す（採用しなくてもよい）
    $saveButton.Add_Click({
        if ($state.Running -or $null -eq $resultGrid.CurrentRow -or $null -eq $resultGrid.CurrentRow.Tag -or -not [bool]$resultGrid.CurrentRow.Tag.Generated) {
            return
        }
        $row = $resultGrid.CurrentRow
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Title = 'トラックを保存'
        $saveDialog.Filter = 'M4A (*.m4a)|*.m4a|All files (*.*)|*.*'
        $suggested = [string]$row.Tag.Path
        if ($row.Tag.Kind -eq 'reduce') {
            $suggested = Get-SeparationOutputPath -SourceFile $SourceFile -Suffix (Format-SeparationReduceSuffix -Db ([int]$row.Tag.Db) -ModelKey ([string]$row.Tag.VocalModel))
        }
        $saveDialog.FileName = Split-Path -Leaf $suggested
        $saveDialog.InitialDirectory = $sourceDir
        $saveDialog.OverwritePrompt = $true
        if ($saveDialog.ShowDialog($dialog) -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }
        & $setResultBusy $true
        try {
            $destination = $saveDialog.FileName
            $path = & $ensureRowFile $row
            & $invokeFileAction { Copy-Item -LiteralPath $path -Destination $destination -Force -ErrorAction Stop }
            $statusText.Text = '保存しました: ' + $destination
        }
        catch {
            Show-ErrorMessage ("保存できませんでした。`r`n" + $_.Exception.GetBaseException().Message)
        }
        finally {
            & $setResultBusy $false
        }
    })

    $twoStageCheck.Enabled = $karaokeCheck.Checked
    $karaokeCheck.Add_CheckedChanged({
        $twoStageCheck.Enabled = $karaokeCheck.Checked
    })

    # モデルフォルダーを読み直してコンボボックスを作り直す（選択はできるだけ保つ）
    $refreshModels = {
        $currentVocal = & $getSelectedKey $vocalModelCombo $modelState.VocalKeys
        $currentLead = & $getSelectedKey $leadModelCombo $modelState.LeadKeys
        if ([string]::IsNullOrEmpty($currentVocal)) { $currentVocal = [string]$saved.VocalModel }
        if ([string]::IsNullOrEmpty($currentLead)) { $currentLead = [string]$saved.LeadModel }
        $modelState.Models = @(Get-SeparationModelList)
        $modelState.VocalKeys = @(Set-SeparationModelComboItems -ComboBox $vocalModelCombo -Models $modelState.Models -Role 'vocals' -SelectedKey $currentVocal)
        $modelState.LeadKeys = @(Set-SeparationModelComboItems -ComboBox $leadModelCombo -Models $modelState.Models -Role 'lead' -SelectedKey $currentLead)
    }

    $openModelsButton.Add_Click({
        # Store 版で書き込みが振り替えられているときは、エクスプローラーにその実パスを渡す（フォルダーもそこで作られる）
        $openDir = Get-SeparationModelsRealDir
        try {
            if (-not (Test-Path -LiteralPath $openDir -PathType Container)) {
                New-Item -ItemType Directory -Path $openDir -Force | Out-Null
            }
            Start-Process -FilePath 'explorer.exe' -ArgumentList (ConvertTo-CommandLineArgument $openDir)
        }
        catch {
            Show-ErrorMessage ("フォルダーを開けませんでした。`r`n" + $openDir + "`r`n" + $_.Exception.GetBaseException().Message)
        }
    })

    # エクスプローラーでモデルを置いて戻ってきたときに一覧を読み直す
    $dialog.Add_Activated({
        if (-not $state.Running -and $state.Phase -eq 'settings') {
            & $refreshModels
        }
    })

    $runSeparation = {
        if (-not ($cutCheck.Checked -or $reduceCheck.Checked -or $karaokeCheck.Checked -or $vocalsCheck.Checked)) {
            Show-ErrorMessage '作るトラックを選んでください。'
            return
        }

        $vocalModel = & $getSelectedKey $vocalModelCombo $modelState.VocalKeys
        $leadModel = & $getSelectedKey $leadModelCombo $modelState.LeadKeys
        $needsVocal = $cutCheck.Checked -or $reduceCheck.Checked -or $vocalsCheck.Checked -or ($karaokeCheck.Checked -and $twoStageCheck.Checked)
        if ($needsVocal -and [string]::IsNullOrEmpty($vocalModel)) {
            Show-ErrorMessage "ボーカルのモデルがありません。`r`n$(Get-SeparationModelsRealDir) に GGUF ファイルを置いてください。"
            return
        }
        if ($karaokeCheck.Checked -and [string]::IsNullOrEmpty($leadModel)) {
            Show-ErrorMessage "リードボーカルのモデルがありません。`r`n$(Get-SeparationModelsRealDir) に GGUF ファイルを置いてください。"
            return
        }

        $ffmpegPath = Request-Ffmpeg
        if (-not (Test-Path -LiteralPath $ffmpegPath -PathType Leaf)) {
            Show-ErrorMessage "ffmpeg.exe が見つかりません。`r`n$ffmpegPath"
            return
        }

        $state.Running = $true
        $state.CancelRequested = $false
        & $setInputsEnabled $false
        $cancelButton.Text = '中止'
        $dialog.UseWaitCursor = $true
        try {
            $cliPath = Request-BsRoformer -Owner $dialog -OnProgress $onProgress -State $state
            if ($null -eq $cliPath) {
                $statusText.Text = ''
                return
            }

            # 使うモデルがなければ初回にダウンロードする（候補一括のときはファイルのあるものだけ使うので対象外）
            $neededKeys = @()
            if ($needsVocal) { $neededKeys += $vocalModel }
            if ($karaokeCheck.Checked) { $neededKeys += $leadModel }
            foreach ($neededKey in @($neededKeys | Select-Object -Unique)) {
                $neededModel = Get-SeparationModel -Models $modelState.Models -Key $neededKey
                if (-not (Request-SeparationModel -Model $neededModel -Owner $dialog -OnProgress $onProgress -State $state)) {
                    $statusText.Text = ''
                    return
                }
            }
            & $refreshModels

            $request = [PSCustomObject]@{
                SourceFile    = $SourceFile
                VocalCut      = $cutCheck.Checked
                VocalReduce   = $reduceCheck.Checked
                ReduceDb      = [int]$reduceUpDown.Value
                Karaoke       = $karaokeCheck.Checked
                TwoStage      = $twoStageCheck.Checked
                VocalsOnly    = $vocalsCheck.Checked
                VocalModel    = $vocalModel
                LeadModel     = $leadModel
                AllCandidates = $allCandidatesCheck.Checked
                TrackNames    = $saved.TrackNames
                Bitrate       = ConvertTo-ReencodeBitrate $Settings.ReencodeBitrate
            }
            $state.Bitrate = [string]$request.Bitrate
            New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
            $outputs = @(Invoke-Separation -Request $request -FfmpegPath $ffmpegPath -CliPath $cliPath -OnProgress $onProgress -State $state -OutputDir $resultsDir)

            # 次回のために選んだモデルなどを覚える
            $Settings | Add-Member -NotePropertyName 'Separation' -NotePropertyValue (ConvertTo-SeparationSettings $request) -Force
            try {
                Save-Settings -Settings $Settings
            }
            catch {
            }

            $state.Running = $false
            & $showResults $outputs
        }
        catch {
            if ($state.CancelRequested) {
                $statusText.Text = '中止しました。'
            }
            else {
                $statusText.Text = ''
                Show-ErrorMessage $_.Exception.GetBaseException().Message
            }
        }
        finally {
            $state.Running = $false
            $state.CancelRequested = $false
            $dialog.UseWaitCursor = $false
            $progressBar.Value = 0
            if ($state.Phase -eq 'settings') {
                $cancelButton.Text = 'キャンセル'
            }
            & $setInputsEnabled $true
        }
    }

    # 採用したトラックのファイルを元のファイルと同じフォルダーへ移してから返す
    $adoptTracks = {
        $resultGrid.EndEdit() | Out-Null
        $adoptedRows = @()
        foreach ($row in $resultGrid.Rows) {
            if ($null -ne $row.Tag -and [bool]$row.Tag.Generated -and [bool]$row.Cells[0].Value) {
                $adoptedRows += $row
            }
        }
        if ($adoptedRows.Count -eq 0) {
            Show-ErrorMessage '採用するトラックにチェックを付けてください。'
            return
        }

        & $stopPlayback $true
        $playbackTimer.Stop()
        & $setResultBusy $true
        $moved = @()
        try {
            foreach ($row in $adoptedRows) {
                $title = ([string]$row.Cells[1].Value).Trim()
                $source = & $ensureRowFile $row
                if ([string]::IsNullOrWhiteSpace($title)) {
                    $title = [System.IO.Path]::GetFileNameWithoutExtension($source)
                }
                $destination = Join-Path $sourceDir (Split-Path -Leaf $source)
                & $invokeFileAction { Move-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop }
                $moved += [PSCustomObject]@{ Path = $destination; Title = $title }
            }
        }
        catch {
            Show-ErrorMessage ("ファイルを用意できませんでした。`r`n" + $_.Exception.GetBaseException().Message)
            & $setResultBusy $false
            $playbackTimer.Start()
            return
        }
        & $setResultBusy $false
        $state.Result = $moved
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }

    $runButton.Add_Click({
        if ($state.Running) {
            return
        }
        if ($state.Phase -eq 'results') {
            & $adoptTracks
        }
        else {
            & $runSeparation
        }
    })

    $backButton.Add_Click({
        if ($state.Running) {
            return
        }
        & $showSettings
    })

    $cancelButton.Add_Click({
        if ($state.Running) {
            # 結果の面でのファイル操作は短いので待ってもらう。分離の実行中なら中止の指示
            if ($state.Phase -eq 'results') {
                return
            }
            $state.CancelRequested = $true
            $statusText.Text = '中止しています...'
            return
        }
        if ($state.Phase -eq 'results') {
            & $stopPlayback $true
            $playbackTimer.Stop()
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    })

    $dialog.Add_FormClosing({
        param($formSender, $closingEvent)

        # 処理中に閉じようとしたら、中止の指示として扱う
        if ($state.Running) {
            $closingEvent.Cancel = $true
            $state.CancelRequested = $true
            $statusText.Text = '中止しています...'
        }
    })

    $dialog.AcceptButton = $runButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@($settingsPanel, $resultPanel, $progressBar, $statusText, $backButton, $runButton, $cancelButton))

    $dialogResult = $dialog.ShowDialog($Owner)
    $playbackTimer.Stop()
    $playbackTimer.Dispose()
    & $removeResultsDir
    $dialog.Dispose()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $state.Result
    }
    return $null
}

# ライセンスの表示。Store 版は dev\build_msix.ps1 が入れる licenses\README.txt を見せる
function Show-LicenseDialog {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $licenseDir = Join-Path $Script:RootDir 'licenses'
    $readmePath = Join-Path $licenseDir 'README.txt'
    if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
        $text = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
        $folder = $licenseDir
    }
    else {
        $text = "ぴたトラックは Apache License 2.0 で提供しています。`r`n" +
            (Join-Path $Script:RootDir 'LICENSE') + "`r`n`r`n" +
            "動画と音声をまとめるのに使う ffmpeg.exe は、FFmpeg プロジェクト（https://ffmpeg.org/）のソフトウェアです。`r`n" +
            "ぴたトラックの作者は FFmpeg の著作権を持っていません。"
        $folder = $Script:RootDir
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'ライセンス'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(640, 480)
    $dialog.MinimumSize = New-Object System.Drawing.Size(480, 320)
    Set-FormTheme -Form $dialog

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textBox.Location = New-Object System.Drawing.Point(12, 12)
    $textBox.Size = New-Object System.Drawing.Size(600, 380)
    $textBox.Anchor = 'Left,Right,Top,Bottom'
    $textBox.Text = ($text -replace "`r?`n", "`r`n")
    Set-TextBoxTheme -TextBox $textBox

    $folderButton = New-Object System.Windows.Forms.Button
    $folderButton.Text = 'フォルダーを開く'
    $folderButton.Location = New-Object System.Drawing.Point(12, 402)
    $folderButton.Size = New-Object System.Drawing.Size(130, 30)
    $folderButton.Anchor = 'Left,Bottom'
    Set-ButtonTheme -Button $folderButton
    $folderButton.Add_Click({
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList (ConvertTo-CommandLineArgument $folder)
    })

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '閉じる'
    $closeButton.Location = New-Object System.Drawing.Point(528, 402)
    $closeButton.Size = New-Object System.Drawing.Size(84, 30)
    $closeButton.Anchor = 'Right,Bottom'
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $closeButton -Kind Primary

    $dialog.AcceptButton = $closeButton
    $dialog.CancelButton = $closeButton
    $dialog.Controls.AddRange(@($textBox, $folderButton, $closeButton))
    $dialog.Add_Shown({ $closeButton.Focus() | Out-Null })
    [void]$dialog.ShowDialog($Owner)
}

function Show-SettingsDialog {
    param([object]$CurrentSettings)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '設定'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(560, 822)
    $dialog.MinimumSize = New-Object System.Drawing.Size(520, 742)
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

    $separationSaved = ConvertTo-SeparationSettings $CurrentSettings.Separation

    $sepNameLabel = New-Object System.Windows.Forms.Label
    $sepNameLabel.Text = 'ボーカル分離で作るトラックの初期名（{model} はモデル名、{db} はリデュース量に置き換わります）'
    $sepNameLabel.Location = New-Object System.Drawing.Point(12, 534)
    $sepNameLabel.Size = New-Object System.Drawing.Size(520, 22)
    $sepNameLabel.Anchor = 'Left,Right,Bottom'
    Set-LabelTheme -Label $sepNameLabel -Muted

    $sepCutLabel = New-Object System.Windows.Forms.Label
    $sepCutLabel.Text = 'ボーカルカット'
    $sepCutLabel.Location = New-Object System.Drawing.Point(12, 562)
    $sepCutLabel.Size = New-Object System.Drawing.Size(140, 22)
    $sepCutLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $sepCutLabel

    $sepCutText = New-Object System.Windows.Forms.TextBox
    $sepCutText.Text = [string]$separationSaved.TrackNames.Cut
    $sepCutText.Location = New-Object System.Drawing.Point(158, 559)
    $sepCutText.Size = New-Object System.Drawing.Size(374, 22)
    $sepCutText.Anchor = 'Left,Right,Bottom'
    $sepCutText.TabIndex = 12
    Set-TextBoxTheme -TextBox $sepCutText

    $sepReduceLabel = New-Object System.Windows.Forms.Label
    $sepReduceLabel.Text = 'ボーカルリデュース'
    $sepReduceLabel.Location = New-Object System.Drawing.Point(12, 594)
    $sepReduceLabel.Size = New-Object System.Drawing.Size(140, 22)
    $sepReduceLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $sepReduceLabel

    $sepReduceText = New-Object System.Windows.Forms.TextBox
    $sepReduceText.Text = [string]$separationSaved.TrackNames.Reduce
    $sepReduceText.Location = New-Object System.Drawing.Point(158, 591)
    $sepReduceText.Size = New-Object System.Drawing.Size(374, 22)
    $sepReduceText.Anchor = 'Left,Right,Bottom'
    $sepReduceText.TabIndex = 13
    Set-TextBoxTheme -TextBox $sepReduceText

    $sepKaraokeLabel = New-Object System.Windows.Forms.Label
    $sepKaraokeLabel.Text = 'コーラス残し'
    $sepKaraokeLabel.Location = New-Object System.Drawing.Point(12, 626)
    $sepKaraokeLabel.Size = New-Object System.Drawing.Size(140, 22)
    $sepKaraokeLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $sepKaraokeLabel

    $sepKaraokeText = New-Object System.Windows.Forms.TextBox
    $sepKaraokeText.Text = [string]$separationSaved.TrackNames.Karaoke
    $sepKaraokeText.Location = New-Object System.Drawing.Point(158, 623)
    $sepKaraokeText.Size = New-Object System.Drawing.Size(374, 22)
    $sepKaraokeText.Anchor = 'Left,Right,Bottom'
    $sepKaraokeText.TabIndex = 14
    Set-TextBoxTheme -TextBox $sepKaraokeText

    $sepVocalsLabel = New-Object System.Windows.Forms.Label
    $sepVocalsLabel.Text = 'ボーカルのみ'
    $sepVocalsLabel.Location = New-Object System.Drawing.Point(12, 658)
    $sepVocalsLabel.Size = New-Object System.Drawing.Size(140, 22)
    $sepVocalsLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $sepVocalsLabel

    $sepVocalsText = New-Object System.Windows.Forms.TextBox
    $sepVocalsText.Text = [string]$separationSaved.TrackNames.Vocals
    $sepVocalsText.Location = New-Object System.Drawing.Point(158, 655)
    $sepVocalsText.Size = New-Object System.Drawing.Size(374, 22)
    $sepVocalsText.Anchor = 'Left,Right,Bottom'
    $sepVocalsText.TabIndex = 15
    Set-TextBoxTheme -TextBox $sepVocalsText

    $sepNameHint = New-Object System.Windows.Forms.Label
    $sepNameHint.Text = '例: ボーカル {db}dB → 「ボーカル -8dB」。全モデルで候補を作るときは、{model} がなければ名前の後ろに（モデル名）が付きます。'
    $sepNameHint.Location = New-Object System.Drawing.Point(12, 684)
    $sepNameHint.Size = New-Object System.Drawing.Size(520, 36)
    $sepNameHint.Anchor = 'Left,Right,Bottom'
    Set-LabelTheme -Label $sepNameHint -Muted

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '保存'
    $okButton.Location = New-Object System.Drawing.Point(356, 736)
    $okButton.Size = New-Object System.Drawing.Size(84, 30)
    $okButton.Anchor = 'Right,Bottom'
    $okButton.TabIndex = 16
    Set-ButtonTheme -Button $okButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(448, 736)
    $cancelButton.Size = New-Object System.Drawing.Size(84, 30)
    $cancelButton.Anchor = 'Right,Bottom'
    $cancelButton.TabIndex = 17
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $cancelButton

    $licenseButton = New-Object System.Windows.Forms.Button
    $licenseButton.Text = 'ライセンス'
    $licenseButton.Location = New-Object System.Drawing.Point(12, 736)
    $licenseButton.Size = New-Object System.Drawing.Size(100, 30)
    $licenseButton.Anchor = 'Left,Bottom'
    $licenseButton.TabIndex = 18
    Set-ButtonTheme -Button $licenseButton
    $licenseButton.Add_Click({ Show-LicenseDialog -Owner $dialog })

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
        # ボーカル分離の設定は、ここで変えられる初期名だけ差し替える（空欄は既定に戻る）
        $separationSettings = ConvertTo-SeparationSettings $CurrentSettings.Separation
        $separationSettings.TrackNames = [PSCustomObject]@{
            Cut     = $sepCutText.Text
            Reduce  = $sepReduceText.Text
            Karaoke = $sepKaraokeText.Text
            Vocals  = $sepVocalsText.Text
        }
        $newSettings = ConvertTo-SavedSettings -TrackNames $trackNames -LaterName $later -OutputSuffix $suffix -TrackNameCandidates $candidates -DelayMode $delayMode -ReencodeBitrate $bitrate -OffsetStepMs $offsetStepMs -AutoOffsetAlways $autoOffsetCheck.Checked -TrackCountProfiles $profiles -Separation $separationSettings
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
        $offsetStepLabel, $offsetStepText, $autoOffsetCheck,
        $sepNameLabel, $sepCutLabel, $sepCutText, $sepReduceLabel, $sepReduceText, $sepKaraokeLabel, $sepKaraokeText, $sepVocalsLabel, $sepVocalsText, $sepNameHint,
        $okButton, $cancelButton, $licenseButton
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
    $form.Text = 'ぴたトラック'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(880, 580)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 480)
    Set-FormTheme -Form $form
    $iconPath = Join-Path $Script:ToolDir 'pitatrack.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $form.Icon = New-Object System.Drawing.Icon -ArgumentList $iconPath
    }

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

    $separateButton = New-Object System.Windows.Forms.Button
    $separateButton.Text = 'ボーカル分離'
    $separateButton.Location = New-Object System.Drawing.Point(754, 312)
    $separateButton.Size = New-Object System.Drawing.Size(94, 30)
    $separateButton.Anchor = 'Top,Right'
    $separateButton.TabIndex = 8
    Set-ButtonTheme -Button $separateButton
    $offsetToolTip.SetToolTip($separateButton, '選択中のトラックからオフボーカルやコーラス残しのトラックを作り、その下に追加します')

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

        $ffmpegPath = if ($Automatic) { Get-SupportFilePath -FileName 'ffmpeg.exe' } else { Request-Ffmpeg }
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

    $separateButton.Add_Click({
        Complete-TrackNameEdit -Grid $grid -TrackNameColumnIndex $trackNameColumnIndex
        if ($null -eq $grid.CurrentCell) {
            Show-ErrorMessage '分離するトラックを選択してください。'
            return
        }

        $rowIndex = $grid.CurrentCell.RowIndex
        if ($rowIndex -lt 0 -or $rowIndex -ge $grid.Rows.Count) {
            return
        }

        $row = $grid.Rows[$rowIndex]
        $tag = $row.Tag
        if ($null -eq $tag) {
            Show-ErrorMessage '分離するトラックを選択してください。'
            return
        }

        $sourceFile = if ([bool]$tag.IsVideoAudio) { [string]$Script:VideoFile } else { [string]$tag.SourceFile }
        if ([string]::IsNullOrWhiteSpace($sourceFile) -or -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            Show-ErrorMessage "元のファイルが見つかりません。`r`n$sourceFile"
            return
        }

        # 分離したトラックは元のトラックと同じだけずらす
        $offsetMs = ConvertTo-OffsetMs $row.Cells[$offsetColumnIndex].Value
        if ($null -eq $offsetMs) {
            $offsetMs = [int]$tag.OffsetMs
        }
        $sourceText = '{0}. {1}（{2}）' -f ($rowIndex + 1), [string]$row.Cells[$trackNameColumnIndex].Value, (Get-TrackSourceText $tag)

        $separated = Show-SeparationDialog -Owner $form -SourceFile $sourceFile -SourceText $sourceText -Settings $Script:Settings
        if ($null -eq $separated -or @($separated).Count -eq 0) {
            return
        }

        $addedCount = Add-SeparatedTracksToGrid -Grid $grid -Tracks @($separated) -InsertIndex ($rowIndex + 1) -OffsetMs $offsetMs
        if ($addedCount -gt 0) {
            $statusLabel.Text = '分離したトラックを{0}件追加しました' -f $addedCount
        }
        else {
            $statusLabel.Text = '分離したトラックはすでに一覧にあります（ファイルは作り直しました）'
        }
        Update-DefaultOutputPath
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
            'ぴたトラック',
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
                    'ぴたトラック',
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
        $upButton, $downButton, $addTrackButton, $deleteTrackButton, $swapVideoButton, $separateButton,
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

# mixtrack_ffmpeg_gui.bat から開いたときは、見えないウインドウで開き直す（コンソールを残さない）
if ($Detach) {
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (ConvertTo-CommandLineArgument $PSCommandPath))
    foreach ($file in $Files) {
        $arguments += ConvertTo-CommandLineArgument $file
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Store 版（MSIX）のパッケージ ファミリー名を取る。設定やモデルの振り替え先（LocalCache）のフォルダー名に使う
public static class PitaTrackPackage
{
    const int ERROR_INSUFFICIENT_BUFFER = 122;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetCurrentPackageFamilyName(ref int packageFamilyNameLength, StringBuilder packageFamilyName);

    // パッケージの中で動いていなければ null
    public static string GetFamilyName()
    {
        int length = 0;
        if (GetCurrentPackageFamilyName(ref length, null) != ERROR_INSUFFICIENT_BUFFER || length <= 0)
        {
            return null;
        }
        StringBuilder name = new StringBuilder(length);
        if (GetCurrentPackageFamilyName(ref length, name) != 0)
        {
            return null;
        }
        return name.ToString();
    }
}

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

        int searchStart = Math.Max(-maxLag, minOverlap - reference.OnsetLow.Length) + maxLag;
        int searchEnd = Math.Min(maxLag, track.OnsetLow.Length - minOverlap) + maxLag + 1;
        int exclusion = (int)(500.0 / FrameMs);
        int refineRadius = (int)(60.0 / FrameMs);
        List<int> peaks = TopPeaks(combined, searchStart, searchEnd, 3, exclusion);
        AudioOffsetResult result = new AudioOffsetResult();
        int chosenPeak = peaks[0];
        double chosenLagMs = 0;
        double bestSharpness = 0;
        double secondSharpness = 0;
        for (int p = 0; p < peaks.Count; p++)
        {
            int peak = peaks[p];
            int refined = ArgMax(onset, Math.Max(searchStart, peak - refineRadius), Math.Min(searchEnd, peak + refineRadius + 1));
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

    static List<int> TopPeaks(double[] values, int start, int end, int count, int separation)
    {
        List<int> candidates = new List<int>();
        for (int i = start; i < end; i++)
        {
            double left = i > start ? values[i - 1] : double.MinValue;
            double right = i < end - 1 ? values[i + 1] : double.MinValue;
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
            peaks.Add(ArgMax(values, start, end));
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
        int lowestLag = Math.Max(-maxLag, 1 - lengthA);
        int highestLag = Math.Min(maxLag, lengthB - 1);

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
            for (int lag = lowestLag; lag <= highestLag; lag++)
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
Request-Ffmpeg | Out-Null
Show-MainForm
