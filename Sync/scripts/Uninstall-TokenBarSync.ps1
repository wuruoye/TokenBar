#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TokenBarSync'))
$TaskName = 'TokenBarSync'
$MarkerPath = Join-Path $InstallRoot '.tokenbar-sync-install.json'
$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentUserSid = $CurrentIdentity.User.Value
$CurrentUserName = $CurrentIdentity.Name

function Test-CurrentUserPrincipal {
    param([string] $UserId)

    if ($UserId -eq $CurrentUserSid -or $UserId -eq $CurrentUserName) {
        return $true
    }
    try {
        $resolvedSid = ([Security.Principal.NTAccount]::new($UserId)).Translate(
            [Security.Principal.SecurityIdentifier]).Value
        return $resolvedSid -eq $CurrentUserSid
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw 'TokenBar Sync is not installed for this user.'
}
$directory = Get-Item -LiteralPath $InstallRoot -Force
if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to uninstall from a reparse point: $InstallRoot"
}
if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
    throw "Refusing to modify an unmarked directory: $InstallRoot"
}

try {
    $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
} catch {
    throw 'TokenBar Sync install marker is invalid.'
}
$parsedInstallId = [Guid]::Empty
if ([int] $marker.schemaVersion -ne 1 -or
    -not [Guid]::TryParse([string] $marker.installId, [ref] $parsedInstallId) -or
    [string] $marker.userSid -ne $CurrentUserSid -or
    [IO.Path]::GetFullPath([string] $marker.installRoot) -ne $InstallRoot -or
    [string] $marker.taskName -ne $TaskName) {
    throw 'TokenBar Sync install marker does not belong to this user, path, and task.'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.Actions.Count -ne 1 -or
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(
            [string] $task.Actions[0].Execute)) -ne
            [IO.Path]::GetFullPath([string] $marker.powerShellExe) -or
        [string] $task.Actions[0].Arguments -ne [string] $marker.taskArguments -or
        -not (Test-CurrentUserPrincipal ([string] $task.Principal.UserId))) {
        throw "Scheduled Task '$TaskName' is not owned by this TokenBar Sync install."
    }
}

if (-not $PSCmdlet.ShouldProcess($InstallRoot, "Unregister task $TaskName and remove only TokenBar Sync-owned files")) {
    return
}

if ($null -ne $task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$ownedFiles = @(
    'tokenbar-sync.exe',
    'tokenbar-helper.exe',
    'LICENSE.txt',
    'ThirdPartyLicenses.html',
    'Invoke-TokenBarSync.ps1',
    'Get-TokenBarSyncStatus.ps1',
    'Uninstall-TokenBarSync.ps1',
    'config.json',
    'device.json',
    'last-run.json',
    'snapshot.json',
    'remote-snapshots.json',
    'token.protected',
    '.token.protected.tmp',
    '.tokenbar-sync-install.tmp',
    '.tokenbar-sync-install.json'
)
foreach ($name in $ownedFiles) {
    $path = Join-Path $InstallRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

$remaining = @(Get-ChildItem -LiteralPath $InstallRoot -Force)
$removedRoot = $false
if ($remaining.Count -eq 0) {
    Remove-Item -LiteralPath $InstallRoot -Force
    $removedRoot = $true
}

[pscustomobject]@{
    Uninstalled = $true
    RemovedTask = ($null -ne $task)
    RemovedInstallRoot = $removedRoot
    PreservedEntryNames = @($remaining | ForEach-Object { $_.Name })
    RemovedProtectedToken = $true
}
