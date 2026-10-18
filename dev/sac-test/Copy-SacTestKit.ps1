#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VMName = 'PitaTrack-SAC'
)

# SAC の試験スクリプト（Invoke-SacTest.ps1）を、仮想マシンの C:\sactest にコピーします（管理者の PowerShell で実行）。
#   仮想マシンが起動していて、Windows にサインインしていること。ゲスト サービスを使います（New-SacTestVM.ps1 で有効にしてある）。
#   ホストからのコピーなので「インターネットから来た」印（MOTW）は付きません。

$ErrorActionPreference = 'Stop'

$source = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Invoke-SacTest.ps1'
$vm = Get-VM -Name $VMName
if ($vm.State -ne 'Running') {
    throw ('仮想マシンが起動していません: ' + $VMName)
}

Copy-VMFile -Name $VMName -SourcePath $source -DestinationPath 'C:\sactest\Invoke-SacTest.ps1' -FileSource Host -CreateFullPath -Force
Write-Host ('コピーしました: ' + $VMName + ' の C:\sactest\Invoke-SacTest.ps1')
Write-Host '仮想マシンの中の PowerShell で、次を実行してください:'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1'
