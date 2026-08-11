#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'TokenBarSync')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$binary = Join-Path $resolvedInstallRoot 'tokenbar-sync.exe'
$config = Join-Path $resolvedInstallRoot 'config.json'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or
    -not (Test-Path -LiteralPath $config -PathType Leaf)) {
    Write-Error 'TokenBar Sync is not completely installed.'
    exit 2
}

$token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Process')
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'User')
}
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Machine')
}
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Error 'TOKENBAR_SYNC_TOKEN is not configured.'
    exit 3
}

$env:TOKENBAR_SYNC_TOKEN = $token
$token = $null
& $binary --config $config --state-dir $resolvedInstallRoot upload
exit $LASTEXITCODE
