#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-GuiSubsystemCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Release binary is not a valid PE image: $Source"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 96 -gt $bytes.Length -or
        [Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne "PE`0`0") {
        throw "Release binary has an invalid PE header: $Source"
    }
    $optionalHeaderOffset = $peOffset + 24
    $magic = [BitConverter]::ToUInt16($bytes, $optionalHeaderOffset)
    if ($magic -ne 0x10B -and $magic -ne 0x20B) {
        throw "Release binary has an unsupported PE optional header: $Source"
    }
    $subsystemOffset = $optionalHeaderOffset + 68
    $subsystem = [BitConverter]::ToUInt16($bytes, $subsystemOffset)
    if ($subsystem -ne 3) {
        throw "Expected a Windows console release binary before conversion: $Source"
    }

    [BitConverter]::GetBytes([UInt16] 2).CopyTo($bytes, $subsystemOffset)
    [Array]::Clear($bytes, $optionalHeaderOffset + 64, 4)
    [IO.File]::WriteAllBytes($Destination, $bytes)
}

$syncManifest = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Cargo.toml'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$helperManifest = Join-Path $repositoryRoot 'Helper\Cargo.toml'

& cargo build --manifest-path $helperManifest --release --locked
if ($LASTEXITCODE -ne 0) {
    throw "tokenbar-helper cargo build failed with exit code $LASTEXITCODE"
}
& cargo build --manifest-path $syncManifest --release --locked
if ($LASTEXITCODE -ne 0) {
    throw "tokenbar-sync cargo build failed with exit code $LASTEXITCODE"
}

$syncDirectory = Split-Path -Parent $syncManifest
$syncBinary = Join-Path $syncDirectory 'target\release\tokenbar-sync.exe'
$backgroundSyncBinary = Join-Path $syncDirectory 'target\release\tokenbar-sync-background.exe'
$taskRunnerBinary = Join-Path $syncDirectory 'target\release\tokenbar-sync-task.exe'
$sourceHelper = Join-Path $repositoryRoot 'Helper\target\release\tokenbar-helper.exe'
$installedHelper = Join-Path $syncDirectory 'target\release\tokenbar-helper.exe'
$backgroundHelper = Join-Path $syncDirectory 'target\release\tokenbar-helper-background.exe'
$releaseLicense = Join-Path $syncDirectory 'target\release\LICENSE.txt'
$releaseNotices = Join-Path $syncDirectory 'target\release\ThirdPartyLicenses.html'
Copy-Item -LiteralPath $sourceHelper -Destination $installedHelper -Force
New-GuiSubsystemCopy -Source $syncBinary -Destination $backgroundSyncBinary
New-GuiSubsystemCopy -Source $sourceHelper -Destination $backgroundHelper
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $releaseLicense -Force
Copy-Item -LiteralPath (Join-Path $syncDirectory 'ThirdPartyLicenses.html') -Destination $releaseNotices -Force

[pscustomobject]@{
    SyncBinary = $syncBinary
    SyncBytes = (Get-Item -LiteralPath $syncBinary).Length
    SyncSHA256 = (Get-FileHash -LiteralPath $syncBinary -Algorithm SHA256).Hash
    BackgroundSyncBinary = $backgroundSyncBinary
    BackgroundSyncBytes = (Get-Item -LiteralPath $backgroundSyncBinary).Length
    BackgroundSyncSHA256 = (Get-FileHash -LiteralPath $backgroundSyncBinary -Algorithm SHA256).Hash
    TaskRunnerBinary = $taskRunnerBinary
    TaskRunnerBytes = (Get-Item -LiteralPath $taskRunnerBinary).Length
    TaskRunnerSHA256 = (Get-FileHash -LiteralPath $taskRunnerBinary -Algorithm SHA256).Hash
    HelperBinary = $installedHelper
    HelperBytes = (Get-Item -LiteralPath $installedHelper).Length
    HelperSHA256 = (Get-FileHash -LiteralPath $installedHelper -Algorithm SHA256).Hash
    BackgroundHelperBinary = $backgroundHelper
    BackgroundHelperBytes = (Get-Item -LiteralPath $backgroundHelper).Length
    BackgroundHelperSHA256 = (Get-FileHash -LiteralPath $backgroundHelper -Algorithm SHA256).Hash
    License = $releaseLicense
    ThirdPartyLicenses = $releaseNotices
}
