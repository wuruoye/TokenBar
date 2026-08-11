#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'TokenBarSync'),
    [string] $TaskName = 'TokenBarSync'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$binary = Join-Path $resolvedInstallRoot 'tokenbar-sync.exe'
$helper = Join-Path $resolvedInstallRoot 'tokenbar-helper.exe'
$config = Join-Path $resolvedInstallRoot 'config.json'
$marker = Join-Path $resolvedInstallRoot '.tokenbar-sync-install'

$token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Process')
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'User')
}
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Machine')
}
$tokenConfigured = -not [string]::IsNullOrWhiteSpace($token)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = if ($null -ne $task) {
    Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
} else {
    $null
}

$clientStatus = $null
if ((Test-Path -LiteralPath $binary -PathType Leaf) -and
    (Test-Path -LiteralPath $config -PathType Leaf)) {
    if ($tokenConfigured) {
        $env:TOKENBAR_SYNC_TOKEN = $token
    }
    $statusJson = & $binary --config $config --state-dir $resolvedInstallRoot status 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($statusJson -join ''))) {
        $clientStatus = ($statusJson -join [Environment]::NewLine) | ConvertFrom-Json
    }
}
$token = $null

[pscustomobject]@{
    Installed = (Test-Path -LiteralPath $marker -PathType Leaf)
    InstallRoot = $resolvedInstallRoot
    BinaryPresent = (Test-Path -LiteralPath $binary -PathType Leaf)
    HelperPresent = (Test-Path -LiteralPath $helper -PathType Leaf)
    ConfigPresent = (Test-Path -LiteralPath $config -PathType Leaf)
    TokenConfigured = $tokenConfigured
    TaskPresent = ($null -ne $task)
    TaskState = if ($null -ne $task) { [string] $task.State } else { $null }
    LastRunTime = if ($null -ne $taskInfo) { $taskInfo.LastRunTime } else { $null }
    LastTaskResult = if ($null -ne $taskInfo) { $taskInfo.LastTaskResult } else { $null }
    NextRunTime = if ($null -ne $taskInfo) { $taskInfo.NextRunTime } else { $null }
    Client = $clientStatus
}
