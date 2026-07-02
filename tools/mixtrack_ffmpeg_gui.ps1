param(
    [switch]$ValidateOnly,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files
)

$ErrorActionPreference = 'Stop'
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

function New-DefaultSettings {
    [PSCustomObject]@{
        TrackNames          = [PSCustomObject]@{
            '1' = 'オンボーカル'
            '2' = 'オフボーカル'
        }
        LaterName           = 'トラック'
        OutputSuffix        = '_mixed'
        TrackNameCandidates = @('オンボーカル', 'オフボーカル', 'トラック')
    }
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
    $batchPath = Join-Path $Script:RootDir 'mixtrack_ffmpeg.bat'

    if (-not (Test-Path -LiteralPath $batchPath)) {
        return $settings
    }

    foreach ($line in (Get-Content -LiteralPath $batchPath -Encoding Default)) {
        if ($line -match '^\s*set\s+"?TRACKNAME_(\d+)=(.*?)"?\s*$') {
            $map[$Matches[1]] = $Matches[2]
            continue
        }
        if ($line -match '^\s*set\s+"?TRACKNAME_LATER=(.*?)"?\s*$') {
            $laterName = $Matches[1]
            continue
        }
        if ($line -match '^\s*(?:if\s+.*?\s+)?set\s+"?OUTPUT_SUFFIX=(.*?)"?\s*$') {
            $suffix = $Matches[1]
            continue
        }
    }

    ConvertTo-SavedSettings -TrackNames $map -LaterName $laterName -OutputSuffix $suffix
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
    }

    return @($list.ToArray())
}

function ConvertTo-SavedSettings {
    param(
        [hashtable]$TrackNames,
        [string]$LaterName,
        [string]$OutputSuffix,
        [string[]]$TrackNameCandidates = $null
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
        TrackNameCandidates = @($candidates.ToArray())
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
            [System.Windows.Forms.MessageBox]::Show(
                "設定ファイルを読み込めませんでした。初期設定で起動します。`r`n`r`n$($_.Exception.Message)",
                'ffmpegMp4Mix GUI',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
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
        TrackNames   = $map
        LaterName    = $laterName
        OutputSuffix = $suffix
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

function Get-DefaultTrackName {
    param(
        [object]$Settings,
        [int]$TrackIndex
    )

    $map = Get-TrackNameMap $Settings
    $key = [string]$TrackIndex
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
        [object]$Settings
    )

    if ([string]::IsNullOrWhiteSpace($VideoFile)) {
        return ''
    }

    $directory = Split-Path -Parent $VideoFile
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile)
    $suffix = [string]$Settings.OutputSuffix
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        $suffix = '_mixed'
    }
    Join-Path $directory ($baseName + $suffix + '.mp4')
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

    $Script:DefaultOutputPath = Get-DefaultOutputPath -VideoFile $Script:VideoFile -Settings $Settings
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

function New-TrackItem {
    param(
        [string]$SourceFile,
        [bool]$IsVideoAudio,
        [string]$Title
    )

    [PSCustomObject]@{
        SourceFile   = $SourceFile
        IsVideoAudio = $IsVideoAudio
        Title        = $Title
        InputIndex   = $null
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

function Show-InfoMessage {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'ffmpegMp4Mix GUI',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
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

    if ($Item.IsVideoAudio) {
        return '元動画の音声: ' + $Item.SourceFile
    }

    return $Item.SourceFile
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
    $rowIndex = $Grid.Rows.Add('', $Item.Title, (Get-TrackSourceText $Item))
    $Grid.Rows[$rowIndex].Tag = $Item
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

        $items += New-TrackItem `
            -SourceFile ([string]$tag.SourceFile) `
            -IsVideoAudio ([bool]$tag.IsVideoAudio) `
            -Title ([string]$row.Cells[1].Value)
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

    foreach ($filePath in $FilePaths) {
        if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath($filePath)
        $Script:AudioFiles += $fullPath
        $trackIndex = $Grid.Rows.Count + 1
        $title = Get-DefaultTrackName -Settings $Settings -TrackIndex $trackIndex
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
        [string]$OutputPath
    )

    $arguments = @('-i', $Script:VideoFile)
    $nextInputIndex = 1

    foreach ($item in $TrackItems) {
        if (-not $item.IsVideoAudio) {
            $arguments += @('-i', $item.SourceFile)
            $item.InputIndex = $nextInputIndex
            $nextInputIndex++
        }
    }

    $arguments += @('-c:v', 'copy', '-c:a', 'copy', '-map', '0:v')

    for ($index = 0; $index -lt $TrackItems.Count; $index++) {
        $item = $TrackItems[$index]
        $mapValue = if ($item.IsVideoAudio) {
            '0:a:0'
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

    $arguments = @(Build-FfmpegArguments -TrackItems $TrackItems -OutputPath $OutputPath)
    if (Test-Path -LiteralPath $OutputPath) {
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
        throw "ffmpeg がエラー終了しました。ログを保存しました。`r`n`r`n$logPath"
    }

    return $true
}

function Show-SettingsDialog {
    param([object]$CurrentSettings)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '設定'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(560, 580)
    $dialog.MinimumSize = New-Object System.Drawing.Size(520, 500)
    Set-FormTheme -Form $dialog

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 12)
    $grid.Size = New-Object System.Drawing.Size(520, 180)
    $grid.Anchor = 'Top,Left,Right'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.TabIndex = 0
    Set-GridTheme -Grid $grid

    $numberColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $numberColumn.HeaderText = '番号'
    $numberColumn.FillWeight = 25
    $grid.Columns.Add($numberColumn) | Out-Null

    $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $nameColumn.HeaderText = '初期トラック名'
    $nameColumn.FillWeight = 75
    $grid.Columns.Add($nameColumn) | Out-Null

    $map = Get-TrackNameMap $CurrentSettings
    foreach ($key in (Get-SortedTrackNameKeys $map)) {
        $grid.Rows.Add($key, $map[$key]) | Out-Null
    }

    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Text = '+ 追加'
    $addButton.Location = New-Object System.Drawing.Point(12, 204)
    $addButton.Size = New-Object System.Drawing.Size(80, 28)
    $addButton.Anchor = 'Left,Top'
    $addButton.TabIndex = 1
    Set-ButtonTheme -Button $addButton

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = '- 削除'
    $deleteButton.Location = New-Object System.Drawing.Point(98, 204)
    $deleteButton.Size = New-Object System.Drawing.Size(80, 28)
    $deleteButton.Anchor = 'Left,Top'
    $deleteButton.TabIndex = 2
    Set-ButtonTheme -Button $deleteButton -Kind Danger

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
    $candidateText.TabIndex = 3
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
    $laterText.TabIndex = 4
    Set-TextBoxTheme -TextBox $laterText

    $suffixLabel = New-Object System.Windows.Forms.Label
    $suffixLabel.Text = '出力接尾語'
    $suffixLabel.Location = New-Object System.Drawing.Point(12, 406)
    $suffixLabel.Size = New-Object System.Drawing.Size(140, 22)
    $suffixLabel.Anchor = 'Left,Bottom'
    Set-LabelTheme -Label $suffixLabel -Muted

    $suffixText = New-Object System.Windows.Forms.TextBox
    $suffixText.Text = [string]$CurrentSettings.OutputSuffix
    $suffixText.Location = New-Object System.Drawing.Point(158, 403)
    $suffixText.Size = New-Object System.Drawing.Size(374, 22)
    $suffixText.Anchor = 'Left,Right,Bottom'
    $suffixText.TabIndex = 5
    Set-TextBoxTheme -TextBox $suffixText

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '保存'
    $okButton.Location = New-Object System.Drawing.Point(356, 494)
    $okButton.Size = New-Object System.Drawing.Size(84, 30)
    $okButton.Anchor = 'Right,Bottom'
    $okButton.TabIndex = 6
    Set-ButtonTheme -Button $okButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(448, 494)
    $cancelButton.Size = New-Object System.Drawing.Size(84, 30)
    $cancelButton.Anchor = 'Right,Bottom'
    $cancelButton.TabIndex = 7
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $cancelButton

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

    $okButton.Add_Click({
        $grid.EndEdit()
        $trackNames = @{}
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) {
                continue
            }

            $numberText = [string]$row.Cells[0].Value
            $nameText = [string]$row.Cells[1].Value
            $number = 0
            if (-not [int]::TryParse($numberText, [ref]$number) -or $number -le 0) {
                Show-ErrorMessage 'トラック番号には1以上の数字を入力してください。'
                return
            }
            if ([string]::IsNullOrWhiteSpace($nameText)) {
                Show-ErrorMessage '初期トラック名を入力してください。'
                return
            }
            $trackNames[[string]$number] = $nameText
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

        $suffix = [string]$suffixText.Text
        if ([string]::IsNullOrWhiteSpace($suffix)) {
            $suffix = '_mixed'
        }

        $candidates = @(ConvertTo-TrackNameCandidateList -Candidates $candidateText.Lines)
        $newSettings = ConvertTo-SavedSettings -TrackNames $trackNames -LaterName $later -OutputSuffix $suffix -TrackNameCandidates $candidates
        Save-Settings $newSettings
        $dialog.Tag = $newSettings
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@(
        $grid, $addButton, $deleteButton, $candidateLabel, $candidateText,
        $laterLabel, $laterText, $suffixLabel, $suffixText, $okButton, $cancelButton
    ))

    if ($grid.Rows.Count -gt 0) {
        $grid.CurrentCell = $grid.Rows[0].Cells[1]
    }

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

    $grid = New-Object TrackNameDataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 74)
    $grid.Size = New-Object System.Drawing.Size(730, 330)
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
    $numberColumn.FillWeight = 12
    $grid.Columns.Add($numberColumn) | Out-Null

    $titleColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $titleColumn.HeaderText = 'トラック名'
    $titleColumn.FillWeight = 28
    $grid.Columns.Add($titleColumn) | Out-Null
    Set-TrackNameCandidateColumnItems -Grid $grid -Settings $Script:Settings

    $sourceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $sourceColumn.HeaderText = '入力ファイル'
    $sourceColumn.ReadOnly = $true
    $sourceColumn.FillWeight = 60
    $grid.Columns.Add($sourceColumn) | Out-Null

    $upButton = New-Object System.Windows.Forms.Button
    $upButton.Text = '↑ 上へ'
    $upButton.Location = New-Object System.Drawing.Point(754, 74)
    $upButton.Size = New-Object System.Drawing.Size(94, 30)
    $upButton.Anchor = 'Top,Right'
    $upButton.TabIndex = 3
    Set-ButtonTheme -Button $upButton

    $downButton = New-Object System.Windows.Forms.Button
    $downButton.Text = '↓ 下へ'
    $downButton.Location = New-Object System.Drawing.Point(754, 110)
    $downButton.Size = New-Object System.Drawing.Size(94, 30)
    $downButton.Anchor = 'Top,Right'
    $downButton.TabIndex = 4
    Set-ButtonTheme -Button $downButton

    $addTrackButton = New-Object System.Windows.Forms.Button
    $addTrackButton.Text = '+ 追加'
    $addTrackButton.Location = New-Object System.Drawing.Point(754, 154)
    $addTrackButton.Size = New-Object System.Drawing.Size(94, 30)
    $addTrackButton.Anchor = 'Top,Right'
    $addTrackButton.TabIndex = 5
    Set-ButtonTheme -Button $addTrackButton

    $deleteTrackButton = New-Object System.Windows.Forms.Button
    $deleteTrackButton.Text = '- 削除'
    $deleteTrackButton.Location = New-Object System.Drawing.Point(754, 190)
    $deleteTrackButton.Size = New-Object System.Drawing.Size(94, 30)
    $deleteTrackButton.Anchor = 'Top,Right'
    $deleteTrackButton.TabIndex = 6
    Set-ButtonTheme -Button $deleteTrackButton -Kind Danger

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
    $outputText.TabIndex = 7
    Set-TextBoxTheme -TextBox $outputText

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = '参照...'
    $browseButton.Location = New-Object System.Drawing.Point(754, 414)
    $browseButton.Size = New-Object System.Drawing.Size(94, 28)
    $browseButton.Anchor = 'Right,Bottom'
    $browseButton.TabIndex = 8
    Set-ButtonTheme -Button $browseButton

    $settingsButton = New-Object System.Windows.Forms.Button
    $settingsButton.Text = '設定'
    $settingsButton.Location = New-Object System.Drawing.Point(12, 484)
    $settingsButton.Size = New-Object System.Drawing.Size(94, 30)
    $settingsButton.Anchor = 'Left,Bottom'
    $settingsButton.TabIndex = 9
    Set-ButtonTheme -Button $settingsButton

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = ''
    $statusLabel.Location = New-Object System.Drawing.Point(116, 490)
    $statusLabel.Size = New-Object System.Drawing.Size(478, 22)
    $statusLabel.Anchor = 'Left,Right,Bottom'
    Set-LabelTheme -Label $statusLabel -Muted

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(656, 484)
    $okButton.Size = New-Object System.Drawing.Size(92, 30)
    $okButton.Anchor = 'Right,Bottom'
    $okButton.TabIndex = 10
    Set-ButtonTheme -Button $okButton -Kind Primary

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(756, 484)
    $cancelButton.Size = New-Object System.Drawing.Size(92, 30)
    $cancelButton.Anchor = 'Right,Bottom'
    $cancelButton.TabIndex = 11
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-ButtonTheme -Button $cancelButton

    $suppressVideoAudioReset = $false
    $trackDragFormat = 'ffmpegMp4Mix.TrackRowIndex'
    $trackNameColumnIndex = 1
    $trackDragState = [PSCustomObject]@{
        RowIndex = -1
        Box = [System.Drawing.Rectangle]::Empty
    }

    function Reset-GridFromInputs {
        $items = @()
        $trackNumber = 1
        if ($useVideoAudio.Checked -and (Test-VideoSelected)) {
            $items += New-TrackItem -SourceFile $Script:VideoFile -IsVideoAudio $true -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex $trackNumber)
            $trackNumber++
        }

        foreach ($audioFile in $Script:AudioFiles) {
            $items += New-TrackItem -SourceFile $audioFile -IsVideoAudio $false -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex $trackNumber)
            $trackNumber++
        }
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
                $videoItem = New-TrackItem -SourceFile $Script:VideoFile -IsVideoAudio $true -Title (Get-DefaultTrackName -Settings $Script:Settings -TrackIndex 1)
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
    }

    function Update-VideoAudioRows {
        $updated = $false
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow -or $null -eq $row.Tag) {
                continue
            }

            if ([bool]$row.Tag.IsVideoAudio) {
                $row.Tag.SourceFile = $Script:VideoFile
                $row.Cells[2].Value = Get-TrackSourceText $row.Tag
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

        $oldDefault = [string]$Script:DefaultOutputPath
        $Script:VideoFile = [System.IO.Path]::GetFullPath($VideoFile)
        $videoText.Text = $Script:VideoFile
        $useVideoAudio.Enabled = $true
        $Script:DefaultOutputPath = Get-DefaultOutputPath -VideoFile $Script:VideoFile -Settings $Script:Settings

        if ([string]::IsNullOrWhiteSpace([string]$outputText.Text) -or $outputText.Text -eq $oldDefault) {
            $outputText.Text = $Script:DefaultOutputPath
        }

        Update-VideoAudioRows
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
            $row.Cells[2].Value = Get-TrackSourceText $tag
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
        if ($null -eq $grid.CurrentCell -or $grid.CurrentCell.ColumnIndex -ne $trackNameColumnIndex) {
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
        [void](Set-TrackNameCell -Grid $grid -RowIndex $hit.RowIndex -TrackNameColumnIndex $trackNameColumnIndex)

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

        if ($grid.Rows.Count -gt 0) {
            $newIndex = [Math]::Min($rowIndex, $grid.Rows.Count - 1)
            $grid.CurrentCell = $grid.Rows[$newIndex].Cells[1]
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
        $oldDefault = $Script:DefaultOutputPath
        $Script:Settings = Show-SettingsDialog -CurrentSettings $Script:Settings
        Set-TrackNameCandidateColumnItems -Grid $grid -Settings $Script:Settings
        $Script:DefaultOutputPath = Get-DefaultOutputPath -VideoFile $Script:VideoFile -Settings $Script:Settings

        if ($outputText.Text -eq $oldDefault) {
            $outputText.Text = $Script:DefaultOutputPath
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

            $statusLabel.Text = 'ffmpeg 実行中...'
            $form.UseWaitCursor = $true
            $form.Refresh()

            $ran = Invoke-Ffmpeg -OutputPath $outputPath -TrackItems $trackItems
            if ($ran) {
                $statusLabel.Text = '完了'
                Show-InfoMessage "出力が完了しました。`r`n`r`n$outputPath"
                $form.Close()
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
        $videoLabel, $videoText, $videoBrowseButton, $useVideoAudio, $grid,
        $upButton, $downButton, $addTrackButton, $deleteTrackButton,
        $outputLabel, $outputText, $browseButton, $settingsButton,
        $statusLabel, $okButton, $cancelButton
    ))

    Reset-GridFromInputs
    if ($grid.Rows.Count -gt 0) {
        $grid.CurrentCell = $grid.Rows[0].Cells[1]
    }

    $form.Add_Shown({
        if ($grid.Rows.Count -gt 0) {
            $grid.Focus() | Out-Null
            $grid.CurrentCell = $grid.Rows[0].Cells[1]
        }
    })

    [void]$form.ShowDialog()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Windows.Forms;

public class TrackTabEventArgs : EventArgs
{
    public bool Shift { get; private set; }

    public TrackTabEventArgs(bool shift)
    {
        Shift = shift;
    }
}

public class TrackNameDataGridView : DataGridView
{
    public event EventHandler<TrackTabEventArgs> TrackTabPressed;
    public event EventHandler TrackNameCandidatesPressed;

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
"@ -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:Settings = Read-Settings

if ($ValidateOnly) {
    exit 0
}

Initialize-InputFiles -InputFiles $Files -Settings $Script:Settings
Show-MainForm
