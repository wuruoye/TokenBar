#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipTests, [switch]$NoInstaller)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
$logDirectory = Join-Path $repositoryRoot '.logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$logPath = Join-Path $logDirectory ('windows-build-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Start-Transcript -Path $logPath | Out-Null
try {
    Push-Location $projectRoot
    try {
        & cargo build --manifest-path ../Helper/Cargo.toml --release --locked
        if ($LASTEXITCODE -ne 0) { throw 'tokenbar-helper build failed.' }
        $hostLine = & rustc -vV | Select-String '^host: '
        $targetTriple = $hostLine.ToString().Substring(6).Trim()
        if ($targetTriple -ne 'x86_64-pc-windows-msvc') {
            throw 'This Windows package currently requires x86_64-pc-windows-msvc.'
        }
        $binaryDirectory = Join-Path $projectRoot 'src-tauri/binaries'
        New-Item -ItemType Directory -Force -Path $binaryDirectory | Out-Null
        $sourceHelper = Join-Path $repositoryRoot 'Helper/target/release/tokenbar-helper.exe'
        $bundledHelper = Join-Path $binaryDirectory "tokenbar-helper-$targetTriple.exe"
        Copy-Item -LiteralPath $sourceHelper -Destination $bundledHelper -Force
        & npm.cmd ci --no-fund --no-audit
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
        if (-not $SkipTests) {
            & npm.cmd test
            if ($LASTEXITCODE -ne 0) { throw 'Frontend tests failed.' }
            & cargo test --manifest-path src-tauri/Cargo.toml --locked
            if ($LASTEXITCODE -ne 0) { throw 'Windows backend tests failed.' }
        }
        & node scripts/licenses.mjs
        if ($LASTEXITCODE -ne 0) { throw 'Dependency license generation failed.' }
        if ($NoInstaller) { & npm.cmd run tauri -- build --no-bundle }
        else { & npm.cmd run package }
        if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed.' }
        Write-Output ('Application: ' + (Join-Path $projectRoot 'src-tauri/target/release/tokenbar-windows.exe'))
        Write-Output ('Build log: ' + $logPath)
    } finally { Pop-Location }
} finally { Stop-Transcript | Out-Null }
