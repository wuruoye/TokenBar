#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TokenBarSync'))
$MarkerPath = Join-Path $InstallRoot '.tokenbar-sync-install.json'
$TokenPath = Join-Path $InstallRoot 'token.protected'
$Binary = Join-Path $InstallRoot 'tokenbar-sync.exe'
$Config = Join-Path $InstallRoot 'config.json'
$CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $TokenPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Binary -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    Write-Error 'TokenBar Sync is not completely installed.'
    exit 2
}

try {
    $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
} catch {
    Write-Error 'TokenBar Sync install marker is invalid.'
    exit 2
}
if ([int] $marker.schemaVersion -ne 1 -or
    [string] $marker.userSid -ne $CurrentUserSid -or
    [IO.Path]::GetFullPath([string] $marker.installRoot) -ne $InstallRoot -or
    [string] $marker.taskName -ne 'TokenBarSync') {
    Write-Error 'TokenBar Sync install ownership check failed.'
    exit 2
}

$protectedBytes = [IO.File]::ReadAllBytes($TokenPath)
if ($protectedBytes.Length -eq 0 -or $protectedBytes.Length -gt 65536) {
    Write-Error 'TokenBar Sync protected token is invalid.'
    exit 3
}

Add-Type -AssemblyName System.Security
$plainBytes = $null
$token = $null
$exitCode = 1
try {
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token = [Text.Encoding]::UTF8.GetString($plainBytes)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Protected sync token is empty.'
    }
    $env:TOKENBAR_SYNC_TOKEN = $token
    & $Binary --config $Config --state-dir $InstallRoot upload
    $exitCode = $LASTEXITCODE
} catch {
    Write-Error "TokenBar Sync token or upload failed: $($_.Exception.Message)"
    $exitCode = 3
} finally {
    Remove-Item Env:TOKENBAR_SYNC_TOKEN -ErrorAction SilentlyContinue
    $token = $null
    if ($null -ne $plainBytes) {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
    [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
}

exit $exitCode
