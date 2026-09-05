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
$LegacyPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$InvokeScript = Join-Path $InstallRoot 'Invoke-TokenBarSync.ps1'
$LegacyTaskArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $InvokeScript
$LegacyHiddenTaskArguments = '-WindowStyle Hidden {0}' -f $LegacyTaskArguments
$TaskRunner = Join-Path $InstallRoot 'tokenbar-sync-task.exe'

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
$schemaVersion = [int] $marker.schemaVersion
if (($schemaVersion -ne 1 -and $schemaVersion -ne 2) -or
    -not [Guid]::TryParse([string] $marker.installId, [ref] $parsedInstallId) -or
    [string] $marker.userSid -ne $CurrentUserSid -or
    [IO.Path]::GetFullPath([string] $marker.installRoot) -ne $InstallRoot -or
    [string] $marker.taskName -ne $TaskName) {
    throw 'TokenBar Sync install marker does not belong to this user, path, and task.'
}
if ($schemaVersion -eq 1) {
    if ([IO.Path]::GetFullPath([string] $marker.powerShellExe) -ne $LegacyPowerShellExe -or
        [string] $marker.taskArguments -ne $LegacyTaskArguments) {
        throw 'Legacy TokenBar Sync install marker is invalid.'
    }
} elseif (
    [IO.Path]::GetFullPath([string] $marker.taskExecutable) -ne $TaskRunner -or
    [string] $marker.taskArguments -ne ''
) {
    throw 'TokenBar Sync native task marker is invalid.'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.Actions.Count -ne 1 -or
        -not (Test-CurrentUserPrincipal ([string] $task.Principal.UserId))) {
        throw "Scheduled Task '$TaskName' is not owned by this TokenBar Sync install."
    }
    $taskExecute = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(
        [string] $task.Actions[0].Execute))
    $taskArguments = [string] $task.Actions[0].Arguments
    if ($schemaVersion -eq 1) {
        if ($taskExecute -ne $LegacyPowerShellExe -or
            ($taskArguments -ne $LegacyTaskArguments -and
             $taskArguments -ne $LegacyHiddenTaskArguments)) {
            throw "Scheduled Task '$TaskName' does not match its legacy TokenBar Sync marker."
        }
    } elseif ($taskExecute -ne $TaskRunner -or $taskArguments -ne '') {
        throw "Scheduled Task '$TaskName' does not match its native TokenBar Sync marker."
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
    'tokenbar-sync-background.exe',
    'tokenbar-sync-task.exe',
    'tokenbar-helper.exe',
    'tokenbar-helper-background.exe',
    'LICENSE.txt',
    'ThirdPartyLicenses.html',
    'Invoke-TokenBarSync.ps1',
    'Get-TokenBarSyncStatus.ps1',
    'Uninstall-TokenBarSync.ps1',
    'config.json',
    'device.json',
    'last-run.json',
    'incremental-upload-v2.json',
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
