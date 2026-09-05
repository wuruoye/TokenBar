#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$application = [IO.Path]::GetFullPath((Join-Path $projectRoot 'src-tauri/target/release/tokenbar-windows.exe'))
if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
    throw 'Build TokenBar first with Windows/scripts/Build-TokenBar.ps1.'
}
# Only restart the executable built by this checkout.
Get-Process -Name tokenbar-windows -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $application } |
    Stop-Process
Start-Process -FilePath $application -WorkingDirectory (Split-Path -Parent $application) -WindowStyle Hidden
