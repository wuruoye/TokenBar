#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$sourceHelper = Join-Path $repositoryRoot 'Helper\target\release\tokenbar-helper.exe'
$installedHelper = Join-Path $syncDirectory 'target\release\tokenbar-helper.exe'
$releaseLicense = Join-Path $syncDirectory 'target\release\LICENSE.txt'
$releaseNotices = Join-Path $syncDirectory 'target\release\ThirdPartyLicenses.html'
Copy-Item -LiteralPath $sourceHelper -Destination $installedHelper -Force
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $releaseLicense -Force
Copy-Item -LiteralPath (Join-Path $syncDirectory 'ThirdPartyLicenses.html') -Destination $releaseNotices -Force

[pscustomobject]@{
    SyncBinary = $syncBinary
    SyncBytes = (Get-Item -LiteralPath $syncBinary).Length
    SyncSHA256 = (Get-FileHash -LiteralPath $syncBinary -Algorithm SHA256).Hash
    HelperBinary = $installedHelper
    HelperBytes = (Get-Item -LiteralPath $installedHelper).Length
    HelperSHA256 = (Get-FileHash -LiteralPath $installedHelper -Algorithm SHA256).Hash
    License = $releaseLicense
    ThirdPartyLicenses = $releaseNotices
}
