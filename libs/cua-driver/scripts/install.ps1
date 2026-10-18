# cua-driver installer (Windows) — build and install cua-driver from this
# checkout.
#
# Run it from a checkout of the fork:
#
#   git clone https://github.com/chriswritescode-dev/cua.git
#   cd cua
#   git checkout local-build
#   powershell -ExecutionPolicy Bypass -File libs\cua-driver\scripts\install.ps1
#
# This installer builds the Rust implementation with cargo and installs it as
# `cua-driver-local` through install-local.ps1 (the single source of truth for
# the local build). There is no release download.
#
# Params (forwarded to install-local.ps1):
#   -BinDir <path>          install the visible binary to <path> instead of
#                           %LOCALAPPDATA%\Programs\Cua\cua-driver-local\bin
#   -AutoStart              register the cua-driver-local-serve Scheduled Task
#   -NoAutoStart            do not register it (default)
#   -NoPathUpdate           do not add the bin directory to the user PATH

[CmdletBinding()]
param(
    [string]$BinDir = '',
    [switch]$AutoStart,
    [switch]$NoAutoStart,
    [switch]$NoPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-CloneHint {
    Write-Host 'cua-driver is installed from a source checkout now. Build it locally:'
    Write-Host ''
    Write-Host '  git clone https://github.com/chriswritescode-dev/cua.git'
    Write-Host '  cd cua'
    Write-Host '  git checkout local-build'
    Write-Host '  powershell -ExecutionPolicy Bypass -File libs\cua-driver\scripts\install.ps1'
    Write-Host ''
}

function Stop-Install([string]$Message) { throw "cua-driver install: error: $Message" }

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    Write-CloneHint
    Stop-Install 'run libs\cua-driver\scripts\install.ps1 from a cloned repository; it cannot run from a pipe'
}
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..\..')).Path
$InstallLocal = Join-Path $ScriptDir 'install-local.ps1'
$CargoManifest = Join-Path $RepoRoot 'libs\cua-driver\rust\Cargo.toml'

if (-not (Test-Path -LiteralPath $CargoManifest) -or -not (Test-Path -LiteralPath $InstallLocal)) {
    Write-CloneHint
    Stop-Install "$ScriptDir is not a cua-driver checkout"
}

if ($NoAutoStart) { $AutoStart = $false }

function Get-PowerShellExe {
    $p = (Get-Process -Id $PID).Path
    if ($p -and (Split-Path -Leaf $p) -match '^(pwsh|powershell)(\.exe)?$') { return $p }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return 'pwsh' }
    return 'powershell'
}

$installArgs = @()
if ($AutoStart) { $installArgs += '-AutoStart' } else { $installArgs += '-NoAutoStart' }
if ($NoPathUpdate) { $installArgs += '-NoPathUpdate' }

$savedBin = $env:CUA_DRIVER_LOCAL_INSTALL_DIR
if ($BinDir) { $env:CUA_DRIVER_LOCAL_INSTALL_DIR = $BinDir }
$installedDir = if ($BinDir) { $BinDir } elseif ($savedBin) { $savedBin } else {
    Join-Path $env:LOCALAPPDATA "Programs\Cua\cua-driver-local\bin"
}
try {
    & (Get-PowerShellExe) -NoProfile -ExecutionPolicy Bypass -File $InstallLocal @installArgs
    if ($LASTEXITCODE -ne 0) { Stop-Install "install-local.ps1 failed (exit $LASTEXITCODE)" }
}
finally {
    $env:CUA_DRIVER_LOCAL_INSTALL_DIR = $savedBin
}

Copy-Item -LiteralPath (Join-Path $installedDir 'cua-driver-local.exe') `
    -Destination (Join-Path $installedDir 'cua-driver.exe') -Force
Write-Host "installed $(Join-Path $installedDir 'cua-driver.exe')"
