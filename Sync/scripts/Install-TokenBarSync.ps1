#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $Endpoint,

    [ValidateRange(1, 1440)]
    [int] $IntervalMinutes = 15,

    [ValidateRange(1, 3660)]
    [int] $Days = 30,

    [ValidateLength(1, 80)]
    [string] $DeviceName = $env:COMPUTERNAME,

    [ValidateSet('utc', 'local')]
    [string] $StatisticsTimezone = 'utc',

    [string] $CodexHome = (Join-Path $env:USERPROFILE '.codex'),

    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'TokenBarSync'),

    [string] $TaskName = 'TokenBarSync',

    [string] $BinaryPath,

    [string] $HelperBinaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
    $BinaryPath = Join-Path $PSScriptRoot '..\target\release\tokenbar-sync.exe'
}
if ([string]::IsNullOrWhiteSpace($HelperBinaryPath)) {
    $HelperBinaryPath = Join-Path $PSScriptRoot '..\target\release\tokenbar-helper.exe'
}

function Get-ConfiguredSyncToken {
    $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'User')
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Machine')
    }
    return $token
}

$endpointUri = $null
if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref] $endpointUri)) {
    throw 'Endpoint must be an absolute HTTPS origin URL.'
}
if ($endpointUri.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($endpointUri.UserInfo) -or
    ($endpointUri.AbsolutePath -ne '/') -or
    -not [string]::IsNullOrEmpty($endpointUri.Query) -or
    -not [string]::IsNullOrEmpty($endpointUri.Fragment)) {
    throw 'Endpoint must be an HTTPS origin without credentials, path, query, or fragment.'
}

$token = Get-ConfiguredSyncToken
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'TOKENBAR_SYNC_TOKEN is not configured in the process, user, or machine environment. The installer never accepts or prints the token as an argument.'
}
$token = $null

$sourceBinary = [IO.Path]::GetFullPath($BinaryPath)
if (-not (Test-Path -LiteralPath $sourceBinary -PathType Leaf)) {
    throw "Release binary not found: $sourceBinary. Run Build-TokenBarSync.ps1 first."
}
$sourceHelper = [IO.Path]::GetFullPath($HelperBinaryPath)
if (-not (Test-Path -LiteralPath $sourceHelper -PathType Leaf)) {
    throw "Helper binary not found: $sourceHelper. Run Build-TokenBarSync.ps1 first."
}

$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$resolvedCodexHome = [IO.Path]::GetFullPath($CodexHome)
if ($resolvedInstallRoot.Contains('"')) {
    throw 'InstallRoot must not contain a quote character.'
}
if (-not (Test-Path -LiteralPath $resolvedCodexHome -PathType Container)) {
    throw "Codex data root not found: $resolvedCodexHome"
}

if (-not $PSCmdlet.ShouldProcess($resolvedInstallRoot, "Install TokenBar Sync and register task $TaskName")) {
    return
}

New-Item -ItemType Directory -Path $resolvedInstallRoot -Force | Out-Null
$installedBinary = Join-Path $resolvedInstallRoot 'tokenbar-sync.exe'
$installedHelper = Join-Path $resolvedInstallRoot 'tokenbar-helper.exe'
$invokeScript = Join-Path $resolvedInstallRoot 'Invoke-TokenBarSync.ps1'
$statusScript = Join-Path $resolvedInstallRoot 'Get-TokenBarSyncStatus.ps1'
$uninstallScript = Join-Path $resolvedInstallRoot 'Uninstall-TokenBarSync.ps1'
$configPath = Join-Path $resolvedInstallRoot 'config.json'
$markerPath = Join-Path $resolvedInstallRoot '.tokenbar-sync-install'

Copy-Item -LiteralPath $sourceBinary -Destination $installedBinary -Force
Copy-Item -LiteralPath $sourceHelper -Destination $installedHelper -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-TokenBarSync.ps1') -Destination $invokeScript -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-TokenBarSyncStatus.ps1') -Destination $statusScript -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-TokenBarSync.ps1') -Destination $uninstallScript -Force

$config = [ordered]@{
    endpoint = $Endpoint.TrimEnd('/')
    deviceName = $DeviceName
    days = $Days
    codexHome = $resolvedCodexHome
    helperPath = $installedHelper
    statisticsTimezone = $StatisticsTimezone
    stateDir = $resolvedInstallRoot
}
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 4), $utf8NoBom)
[IO.File]::WriteAllText($markerPath, "TokenBarSync`n", $utf8NoBom)

& $installedBinary --config $configPath --state-dir $resolvedInstallRoot device | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "TokenBar Sync could not initialize its stable device identity (exit $LASTEXITCODE)."
}

$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$taskArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}"' -f $invokeScript, $resolvedInstallRoot
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $taskArguments
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Uploads sanitized TokenBar ActivitySnapshot protocol-v1 envelopes.' `
    -Force | Out-Null

[pscustomobject]@{
    Installed = $true
    InstallRoot = $resolvedInstallRoot
    TaskName = $TaskName
    IntervalMinutes = $IntervalMinutes
    StatisticsTimezone = $StatisticsTimezone
    DeviceName = $DeviceName
    TokenConfigured = $true
}
