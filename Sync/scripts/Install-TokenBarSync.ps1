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

    [string] $BinaryPath,

    [string] $HelperBinaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TokenBarSync'))
$TaskName = 'TokenBarSync'
$MarkerName = '.tokenbar-sync-install.json'
$TaskDescription = 'TokenBar managed protocol-v1 activity snapshot upload.'
$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentUserSid = $CurrentIdentity.User.Value
$CurrentUserName = $CurrentIdentity.Name
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$InvokeScript = Join-Path $InstallRoot 'Invoke-TokenBarSync.ps1'
$TaskArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $InvokeScript
$MarkerPath = Join-Path $InstallRoot $MarkerName
$TokenPath = Join-Path $InstallRoot 'token.protected'

function Read-OwnedMarker {
    param([string] $Path)

    try {
        $marker = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "TokenBar Sync install marker is invalid: $Path"
    }
    $parsedInstallId = [Guid]::Empty
    if ([int] $marker.schemaVersion -ne 1 -or
        -not [Guid]::TryParse([string] $marker.installId, [ref] $parsedInstallId) -or
        [string] $marker.userSid -ne $CurrentUserSid -or
        [IO.Path]::GetFullPath([string] $marker.installRoot) -ne $InstallRoot -or
        [string] $marker.taskName -ne $TaskName -or
        [IO.Path]::GetFullPath([string] $marker.powerShellExe) -ne $PowerShellExe -or
        [string] $marker.taskArguments -ne $TaskArguments) {
        throw 'TokenBar Sync install marker does not belong to this user, path, and task.'
    }
    return $marker
}

function Assert-OwnedTask {
    param($Task)

    if ($Task.Actions.Count -ne 1 -or
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(
            [string] $Task.Actions[0].Execute)) -ne $PowerShellExe -or
        [string] $Task.Actions[0].Arguments -ne $TaskArguments -or
        ([string] $Task.Principal.UserId -ne $CurrentUserSid -and
            [string] $Task.Principal.UserId -ne $CurrentUserName) -or
        [string] $Task.Description -ne $TaskDescription) {
        throw "Scheduled Task '$TaskName' exists but is not owned by this TokenBar Sync install."
    }
}

if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    throw "Windows PowerShell 5.1 was not found at $PowerShellExe"
}

if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
    $BinaryPath = Join-Path $PSScriptRoot '..\target\release\tokenbar-sync.exe'
}
if ([string]::IsNullOrWhiteSpace($HelperBinaryPath)) {
    $HelperBinaryPath = Join-Path $PSScriptRoot '..\target\release\tokenbar-helper.exe'
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

$token = [Environment]::GetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', 'Process')
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Set TOKENBAR_SYNC_TOKEN in this PowerShell process before installation. It is used once and persisted with DPAPI CurrentUser protection.'
}
$token = $token.Trim()
$invalidTokenCharacter = $token.ToCharArray() | Where-Object {
    [int] $_ -lt 33 -or [int] $_ -gt 126
} | Select-Object -First 1
if ($token.Length -lt 32 -or $token.Length -gt 512 -or $null -ne $invalidTokenCharacter) {
    throw 'TOKENBAR_SYNC_TOKEN must contain 32..512 non-whitespace ASCII characters.'
}

$sourceBinary = [IO.Path]::GetFullPath($BinaryPath)
if (-not (Test-Path -LiteralPath $sourceBinary -PathType Leaf)) {
    throw "Release binary not found: $sourceBinary. Run Build-TokenBarSync.ps1 first."
}
$sourceHelper = [IO.Path]::GetFullPath($HelperBinaryPath)
if (-not (Test-Path -LiteralPath $sourceHelper -PathType Leaf)) {
    throw "Helper binary not found: $sourceHelper. Run Build-TokenBarSync.ps1 first."
}
$sourceLicense = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\target\release\LICENSE.txt'))
$sourceNotices = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\target\release\ThirdPartyLicenses.html'))
if (-not (Test-Path -LiteralPath $sourceLicense -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceNotices -PathType Leaf)) {
    throw 'Release license files are missing. Run Build-TokenBarSync.ps1 first.'
}
$resolvedCodexHome = [IO.Path]::GetFullPath($CodexHome)
if (-not (Test-Path -LiteralPath $resolvedCodexHome -PathType Container)) {
    throw "Codex data root not found: $resolvedCodexHome"
}
if ([IO.Path]::GetFileName($resolvedCodexHome) -ine '.codex') {
    throw 'CodexHome must be a data root directory named .codex.'
}

$marker = $null
if (Test-Path -LiteralPath $InstallRoot) {
    $directory = Get-Item -LiteralPath $InstallRoot -Force
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to install into a reparse point: $InstallRoot"
    }
    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        $marker = Read-OwnedMarker $MarkerPath
    } elseif (@(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -ne 0) {
        throw "Refusing to install into a non-empty unowned directory: $InstallRoot"
    }
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    if ($null -eq $marker) {
        throw "Scheduled Task '$TaskName' already exists without a matching TokenBar Sync marker."
    }
    Assert-OwnedTask $existingTask
}

if (-not $PSCmdlet.ShouldProcess($InstallRoot, "Install TokenBar Sync and register task $TaskName")) {
    $token = $null
    return
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$grantUser = '*{0}:(OI)(CI)F' -f $CurrentUserSid
$grantSystem = '*S-1-5-18:(OI)(CI)F'
& (Join-Path $env:SystemRoot 'System32\icacls.exe') $InstallRoot /inheritance:r /grant:r $grantUser $grantSystem | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not restrict the install directory ACL (icacls exit $LASTEXITCODE)."
}

$installedBinary = Join-Path $InstallRoot 'tokenbar-sync.exe'
$installedHelper = Join-Path $InstallRoot 'tokenbar-helper.exe'
$installedStatus = Join-Path $InstallRoot 'Get-TokenBarSyncStatus.ps1'
$installedUninstall = Join-Path $InstallRoot 'Uninstall-TokenBarSync.ps1'
$configPath = Join-Path $InstallRoot 'config.json'

Copy-Item -LiteralPath $sourceBinary -Destination $installedBinary -Force
Copy-Item -LiteralPath $sourceHelper -Destination $installedHelper -Force
Copy-Item -LiteralPath $sourceLicense -Destination (Join-Path $InstallRoot 'LICENSE.txt') -Force
Copy-Item -LiteralPath $sourceNotices -Destination (Join-Path $InstallRoot 'ThirdPartyLicenses.html') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-TokenBarSync.ps1') -Destination $InvokeScript -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-TokenBarSyncStatus.ps1') -Destination $installedStatus -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-TokenBarSync.ps1') -Destination $installedUninstall -Force

$config = [ordered]@{
    endpoint = $Endpoint.TrimEnd('/')
    deviceName = $DeviceName
    days = $Days
    codexHome = $resolvedCodexHome
    helperPath = $installedHelper
    statisticsTimezone = $StatisticsTimezone
    stateDir = $InstallRoot
}
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 4), $utf8NoBom)

Add-Type -AssemblyName System.Security
$plainBytes = [Text.Encoding]::UTF8.GetBytes($token)
$protectedBytes = $null
try {
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $temporaryTokenPath = Join-Path $InstallRoot '.token.protected.tmp'
    [IO.File]::WriteAllBytes($temporaryTokenPath, $protectedBytes)
    Move-Item -LiteralPath $temporaryTokenPath -Destination $TokenPath -Force
} finally {
    if ($null -ne $plainBytes) {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
    if ($null -ne $protectedBytes) {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    }
    $token = $null
}

$installId = if ($null -ne $marker) { [string] $marker.installId } else { [Guid]::NewGuid().ToString() }
$markerValue = [ordered]@{
    schemaVersion = 1
    installId = $installId
    userSid = $CurrentUserSid
    installRoot = $InstallRoot
    taskName = $TaskName
    powerShellExe = $PowerShellExe
    taskArguments = $TaskArguments
}
$temporaryMarkerPath = Join-Path $InstallRoot '.tokenbar-sync-install.tmp'
[IO.File]::WriteAllText(
    $temporaryMarkerPath,
    ($markerValue | ConvertTo-Json -Depth 4),
    $utf8NoBom)
Move-Item -LiteralPath $temporaryMarkerPath -Destination $MarkerPath -Force

& $installedBinary --config $configPath --state-dir $InstallRoot device | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "TokenBar Sync could not initialize its stable device identity (exit $LASTEXITCODE)."
}

$action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $TaskArguments
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $CurrentUserSid -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $TaskDescription -Force | Out-Null

[pscustomobject]@{
    Installed = $true
    InstallRoot = $InstallRoot
    TaskName = $TaskName
    IntervalMinutes = $IntervalMinutes
    StatisticsTimezone = $StatisticsTimezone
    DeviceName = $DeviceName
    TokenProtection = 'DPAPI CurrentUser'
}
