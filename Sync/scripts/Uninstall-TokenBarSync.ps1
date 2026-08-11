#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'TokenBarSync'),
    [string] $TaskName = 'TokenBarSync'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$root = [IO.Path]::GetPathRoot($resolvedInstallRoot)
if ($resolvedInstallRoot -eq $root -or
    $resolvedInstallRoot -eq [IO.Path]::GetFullPath($env:USERPROFILE) -or
    $resolvedInstallRoot -eq [IO.Path]::GetFullPath($env:LOCALAPPDATA)) {
    throw 'Refusing to uninstall from a broad system or user directory.'
}

$marker = Join-Path $resolvedInstallRoot '.tokenbar-sync-install'
if ((Test-Path -LiteralPath $resolvedInstallRoot) -and
    -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Refusing to remove an unmarked directory: $resolvedInstallRoot"
}

if (-not $PSCmdlet.ShouldProcess($resolvedInstallRoot, "Unregister task $TaskName and remove TokenBar Sync")) {
    return
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
if (Test-Path -LiteralPath $resolvedInstallRoot) {
    Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
}

[pscustomobject]@{
    Uninstalled = $true
    RemovedInstallRoot = $resolvedInstallRoot
    RemovedTask = ($null -ne $task)
    TokenEnvironmentVariablePreserved = $true
}
