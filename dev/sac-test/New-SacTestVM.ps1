#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Windows 11 のインストール ISO。省略すると J:\Git\WindowsISO の一番新しい .iso
    [string]$IsoPath,
    [string]$VMName = 'PitaTrack-SAC',
    # 仮想マシンと仮想ディスクの置き場所。省略すると Hyper-V の既定の場所
    [string]$VMPath,
    [long]$MemoryBytes = 6GB,
    [int]$ProcessorCount = 4,
    [long]$DiskBytes = 80GB,
    [string]$SwitchName = 'Default Switch'
)

# スマート アプリ コントロール（SAC）を試すための Windows 11 の仮想マシンを作ります（管理者の PowerShell で実行）。
#   第 2 世代、セキュア ブート（Microsoft Windows）、仮想 TPM、ISO から起動、ゲスト サービス（Copy-VMFile 用）を有効。
#   SAC は Windows を新しくインストールした PC でしか使えないので、この仮想マシンに新しく入れます。
#   作ったあと、仮想マシン接続の画面を開きます。「起動」を押し、"Press any key to boot from CD or DVD" が出たらすぐ何かキーを押してください。

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    $iso = Get-ChildItem -Path 'J:\Git\WindowsISO' -Filter *.iso -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $iso) {
        throw 'Windows 11 の ISO が見つかりません。-IsoPath で指定してください。'
    }
    $IsoPath = $iso.FullName
}
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    throw ('ISO が見つかりません: ' + $IsoPath)
}
if ($null -ne (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    throw ('同じ名前の仮想マシンがすでにあります: ' + $VMName + '（作り直すときは Remove-VM で消してから実行してください）')
}
if ($null -eq (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw ('仮想スイッチが見つかりません: ' + $SwitchName + '（-SwitchName で指定してください）')
}

$vmHost = Get-VMHost
if ([string]::IsNullOrWhiteSpace($VMPath)) {
    $VMPath = $vmHost.VirtualMachinePath
    $vhdDirectory = $vmHost.VirtualHardDiskPath
}
else {
    $vhdDirectory = Join-Path $VMPath $VMName
}
if (-not (Test-Path -LiteralPath $vhdDirectory)) {
    New-Item -ItemType Directory -Path $vhdDirectory -Force | Out-Null
}
$vhdPath = Join-Path $vhdDirectory ($VMName + '.vhdx')
if (Test-Path -LiteralPath $vhdPath) {
    throw ('仮想ディスクがすでにあります: ' + $vhdPath)
}

Write-Host ('ISO: ' + $IsoPath)
Write-Host ('仮想マシン: ' + $VMName + '（' + $VMPath + '）')
Write-Host ('仮想ディスク: ' + $vhdPath + '（最大 ' + [int]($DiskBytes / 1GB) + 'GB、使った分だけ増える）')

New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryBytes -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskBytes -SwitchName $SwitchName -Path $VMPath | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMProcessor -VMName $VMName -Count $ProcessorCount
# 試験の前後に戻せるよう、標準チェックポイント（メモリの状態も保存）にし、自動チェックポイントは止める
Set-VM -Name $VMName -CheckpointType Standard -AutomaticCheckpointsEnabled $false

$dvd = Add-VMDvdDrive -VMName $VMName -Path $IsoPath -Passthru
Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $dvd

# Windows 11 に必要な TPM
Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
Enable-VMTPM -VMName $VMName

# ゲスト サービス（Copy-VMFile で試験スクリプトを入れるため）。名前は表示言語で変わるので ID で探す
$guestService = Get-VMIntegrationService -VMName $VMName | Where-Object { $_.Id -match '6C09BB55-D683-4DA0-8931-C9BF705F6480' -or $_.Name -match 'Guest Service|ゲスト サービス' } | Select-Object -First 1
if ($null -ne $guestService) {
    Enable-VMIntegrationService -VMName $VMName -Name $guestService.Name
}
else {
    Write-Warning 'ゲスト サービスが見つかりませんでした。試験スクリプトは拡張セッションのコピーと貼り付けで入れてください。'
}

Write-Host ''
Write-Host '作成しました。仮想マシン接続の画面を開きます。'
Write-Host '  1. 「起動」を押し、"Press any key to boot from CD or DVD" が出たらすぐ何かキーを押す'
Write-Host '  2. Windows 11 をインストールし、Windows Update まで済ませる（プロダクト キーは「持っていません」でよい）'
Write-Host '  3. 続きは dev\sac-test\README.md を見てください'
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\vmconnect.exe') -ArgumentList @('localhost', $VMName)
