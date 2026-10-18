# `cua-driver update --apply` must refuse to install release builds (#2803, #4388).
#
# Release updates are repository-backed: the driver reports that a newer
# release exists, and the user pulls the repository and rebuilds. This smoke
# proves the refusal is explicit, uses exit code 2, and names the local
# installer. It runs only on a disposable machine because the preceding
# workflow step installs a release build.

[CmdletBinding()]
param(
    [string]$EvidenceDir = [System.IO.Path]::GetTempPath()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$driver = Get-Command cua-driver -ErrorAction Stop
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = & $driver.Source update --apply 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previous
}

Assert-True ($exitCode -eq 2) "update --apply exited $exitCode instead of 2: $output"
Assert-True ($output -match 'Installing cua-driver release builds is disabled') "missing refusal: $output"
Assert-True ($output -match 'install-local\.ps1') "missing rebuild instruction: $output"
Assert-True ($output -notmatch 'cua\.ai/driver/install\.ps1') "refusal still points at the remote installer: $output"

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$evidence = Join-Path $EvidenceDir 'cua-driver-update-apply-refusal.txt'
@(
    "binary: $($driver.Source)",
    "exit_code: $exitCode",
    $output.Trim()
) | Set-Content -LiteralPath $evidence -Encoding utf8

Write-Host "cua-driver update --apply refused release installation and named the local rebuild."
Write-Host "Evidence: $evidence"
