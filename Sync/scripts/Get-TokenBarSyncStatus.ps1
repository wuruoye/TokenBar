#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TokenBarSync'))
$TaskName = 'TokenBarSync'
$MarkerPath = Join-Path $InstallRoot '.tokenbar-sync-install.json'
$TokenPath = Join-Path $InstallRoot 'token.protected'
$Binary = Join-Path $InstallRoot 'tokenbar-sync.exe'
$BackgroundBinary = Join-Path $InstallRoot 'tokenbar-sync-background.exe'
$Helper = Join-Path $InstallRoot 'tokenbar-helper.exe'
$BackgroundHelper = Join-Path $InstallRoot 'tokenbar-helper-background.exe'
$Config = Join-Path $InstallRoot 'config.json'
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

$marker = $null
$markerOwned = $false
if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
    try {
        $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
        $schemaVersion = [int] $marker.schemaVersion
        $markerOwned = (
            ($schemaVersion -eq 1 -or $schemaVersion -eq 2) -and
            [string] $marker.userSid -eq $CurrentUserSid -and
            [IO.Path]::GetFullPath([string] $marker.installRoot) -eq $InstallRoot -and
            [string] $marker.taskName -eq $TaskName
        )
        if ($markerOwned -and $schemaVersion -eq 1) {
            $markerOwned = (
                [IO.Path]::GetFullPath([string] $marker.powerShellExe) -eq $LegacyPowerShellExe -and
                [string] $marker.taskArguments -eq $LegacyTaskArguments
            )
        } elseif ($markerOwned -and $schemaVersion -eq 2) {
            $markerOwned = (
                [IO.Path]::GetFullPath([string] $marker.taskExecutable) -eq $TaskRunner -and
                [string] $marker.taskArguments -eq ''
            )
        }
    } catch {
        $markerOwned = $false
    }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = if ($null -ne $task) {
    Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
} else {
    $null
}
$taskOwned = $false
if ($markerOwned -and $null -ne $task) {
    $principalOwned = Test-CurrentUserPrincipal ([string] $task.Principal.UserId)
    $actionCountOwned = $task.Actions.Count -eq 1
    if ($actionCountOwned) {
        $taskExecute = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(
            [string] $task.Actions[0].Execute))
        $taskArguments = [string] $task.Actions[0].Arguments
        if ([int] $marker.schemaVersion -eq 1) {
            $taskOwned = (
                $principalOwned -and
                $taskExecute -eq $LegacyPowerShellExe -and
                ($taskArguments -eq $LegacyTaskArguments -or
                 $taskArguments -eq $LegacyHiddenTaskArguments)
            )
        } else {
            $taskOwned = (
                $principalOwned -and
                $taskExecute -eq $TaskRunner -and
                $taskArguments -eq ''
            )
        }
    }
}

$tokenConfigured = $false
$clientStatus = $null
if ($markerOwned -and
    (Test-Path -LiteralPath $TokenPath -PathType Leaf) -and
    (Test-Path -LiteralPath $Binary -PathType Leaf) -and
    (Test-Path -LiteralPath $Config -PathType Leaf)) {
    $protectedBytes = [IO.File]::ReadAllBytes($TokenPath)
    $plainBytes = $null
    $token = $null
    try {
        Add-Type -AssemblyName System.Security
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token = [Text.Encoding]::UTF8.GetString($plainBytes)
        $tokenConfigured = -not [string]::IsNullOrWhiteSpace($token)
        if ($tokenConfigured) {
            $env:TOKENBAR_SYNC_TOKEN = $token
            $statusJson = & $Binary --config $Config --state-dir $InstallRoot status 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($statusJson -join ''))) {
                $clientStatus = ($statusJson -join [Environment]::NewLine) | ConvertFrom-Json
            }
        }
    } catch {
        $tokenConfigured = $false
    } finally {
        Remove-Item Env:TOKENBAR_SYNC_TOKEN -ErrorAction SilentlyContinue
        $token = $null
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
        if ($null -ne $protectedBytes) {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    }
}

[pscustomobject]@{
    Installed = $markerOwned
    InstallRoot = $InstallRoot
    BinaryPresent = (Test-Path -LiteralPath $Binary -PathType Leaf)
    BackgroundBinaryPresent = (Test-Path -LiteralPath $BackgroundBinary -PathType Leaf)
    HelperPresent = (Test-Path -LiteralPath $Helper -PathType Leaf)
    BackgroundHelperPresent = (Test-Path -LiteralPath $BackgroundHelper -PathType Leaf)
    TaskRunnerPresent = (Test-Path -LiteralPath $TaskRunner -PathType Leaf)
    ConfigPresent = (Test-Path -LiteralPath $Config -PathType Leaf)
    TokenConfigured = $tokenConfigured
    TaskPresent = ($null -ne $task)
    TaskOwned = $taskOwned
    TaskMode = if ($markerOwned -and [int] $marker.schemaVersion -eq 2) {
        'NativeNoConsole'
    } elseif ($markerOwned) {
        'LegacyPowerShell'
    } else {
        $null
    }
    TaskState = if ($null -ne $task) { [string] $task.State } else { $null }
    LastRunTime = if ($null -ne $taskInfo) { $taskInfo.LastRunTime } else { $null }
    LastTaskResult = if ($null -ne $taskInfo) { $taskInfo.LastTaskResult } else { $null }
    NextRunTime = if ($null -ne $taskInfo) { $taskInfo.NextRunTime } else { $null }
    Client = $clientStatus
}
