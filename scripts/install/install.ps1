<#
.SYNOPSIS
Cua source installer for Windows: build and install the `cua` CLI, cua-spacesd
and agent extras from this repository checkout.

.DESCRIPTION
Run it from a checkout of the fork:

    git clone https://github.com/chriswritescode-dev/cua.git
    cd cua
    git checkout local-build
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -Select cua-driver
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -CliOnly -Yes
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -Pair K7QM-4XPB-2RHD

At a console it first shows a numbered checklist of what to install. Items:
    cli         the cua CLI and cua-spacesd (always, except with -AppOnly)
    spaces      the Cua Spaces app (no source build for Windows yet; off)
    cua-driver  cua-driver MCP and skill for your agents (off by default)
    host        host this machine: `cua host setup` (off by default)
Set CUA_INSTALL_NONINTERACTIVE=1 to never prompt.

Builds with cargo from this checkout, installs `cua.exe` and `cua-spacesd.exe`
to %LOCALAPPDATA%\Programs\cua\bin (or -Prefix\bin), adds that directory to
your user PATH (-NoModifyPath skips it), then runs `cua auth login` when a user
is at the console (not with -CliOnly, -Pair or -NoOnboarding).

.PARAMETER Select
Preselect items (comma list: spaces, cua-driver, host); the checklist still shows.
.PARAMETER Only
Install exactly these items plus the CLI, without the checklist.
.PARAMETER CliOnly
Install only the `cua` CLI (same as -Only cli), without prompts or sign-in.
.PARAMETER AppOnly
Install only the Cua Spaces app (no CLI).
.PARAMETER Mode
Preselect the app's first-run choice: host or client (implies spaces).
.PARAMETER Pair
Add this machine to your account with a one-time code from the Cua Spaces app
(Add a machine): installs the CLI and runs `cua host setup --pair <code>`, with
no sign-in and no checklist. A computer that already has a cua with
`host setup --pair` uses it instead of building again; -Prefix or
CUA_INSTALL_REINSTALL=1 build anyway.
.PARAMETER Relay
Relay for -Pair (default https://relay.cua.ai).
.PARAMETER Prefix
Install the CLI under Prefix\bin.
.PARAMETER ModifyPath
Kept for older commands: the CLI directory is added to the user PATH by default.
.PARAMETER NoModifyPath
Do not add the CLI directory to the user PATH.
.PARAMETER NoOnboarding
Do not run `cua auth login` afterwards.
.PARAMETER DryRun
Print what would happen; change nothing.
.PARAMETER Yes
Accept the selection and every prompt.
#>
[CmdletBinding()]
param(
    [string]$Select = '',
    [string]$Only = '',
    [switch]$CliOnly,
    [switch]$AppOnly,
    [ValidateSet('host', 'client', '')][string]$Mode = '',
    [string]$Pair = '',
    [string]$Relay = '',
    [string]$Prefix = '',
    [switch]$ModifyPath,
    [switch]$NoModifyPath,
    [switch]$NoOnboarding,
    [switch]$DryRun,
    [switch]$Yes
)

# Windows PowerShell 5.1 started from PowerShell 7 inherits pwsh's
# PSModulePath; put this edition's own modules first before using them.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $desktopModules = Join-Path $PSHOME 'Modules'
    $modulePaths = @($desktopModules) + @(($env:PSModulePath -split ';') | Where-Object {
            $_ -and ($_ -notmatch '\\PowerShell\\') -and ($_.TrimEnd('\') -ne $desktopModules.TrimEnd('\'))
        })
    $env:PSModulePath = $modulePaths -join ';'
}

$RepoUrl = if ($env:CUA_REPO_URL) { $env:CUA_REPO_URL } else { 'https://github.com/chriswritescode-dev/cua.git' }
$CuaItems = @('spaces', 'cua-driver', 'host')
$script:Picked = $false
$script:SpacesSupported = $false

function Write-Info([string]$Message) { Write-Host "cua-install: $Message" }
function Stop-Install([string]$Message) { throw "cua-install: error: $Message" }

function Write-CloneHint {
    Write-Host 'Cua is installed from a source checkout now. Build it locally:'
    Write-Host ''
    Write-Host "  git clone $RepoUrl"
    Write-Host '  cd cua'
    Write-Host '  git checkout local-build'
    Write-Host '  powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1'
    Write-Host ''
}

function Get-RepoRoot {
    if (-not $PSScriptRoot) {
        Write-CloneHint
        Stop-Install 'run scripts\install\install.ps1 from a cloned repository; it cannot run from a pipe'
    }
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $cli = Join-Path $root 'libs\cua\Cargo.toml'
    $spacesd = Join-Path $root 'libs\cua-spacesd\Cargo.toml'
    if (-not (Test-Path -LiteralPath $cli) -or -not (Test-Path -LiteralPath $spacesd)) {
        Write-CloneHint
        Stop-Install "$PSScriptRoot is not a Cua checkout"
    }
    return $root
}

function Get-TargetDir([string]$Default) {
    if ($env:CARGO_TARGET_DIR) {
        if ([IO.Path]::IsPathRooted($env:CARGO_TARGET_DIR)) { return $env:CARGO_TARGET_DIR }
        return (Join-Path (Get-Location).Path $env:CARGO_TARGET_DIR)
    }
    return $Default
}

function Get-CuaPlatform {
    param([string]$Arch = $env:CUA_INSTALL_ARCH)
    if (-not $Arch) {
        $Arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        if (-not $Arch) { $Arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    }
    switch -Regex ($Arch) {
        '^(AMD64|x64|x86_64)$' { return 'windows-x64' }
        '^(ARM64|Arm64|aarch64)$' { return 'windows-arm64' }
        default { Stop-Install "unsupported CPU architecture: $Arch" }
    }
}

function Test-Interactive {
    try { return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { return $false }
}

function Confirm-Step([string]$Question, [bool]$Default = $true) {
    if ($Yes -or $script:Picked -or -not (Test-Interactive)) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $hint"
    if ($answer -match '^(y|yes)$') { return $true }
    if ($answer -match '^(n|no)$') { return $false }
    return $Default
}

function ConvertTo-CuaItems([string]$List) {
    $out = @()
    foreach ($item in @($List -split '[,\s]+' | Where-Object { $_ })) {
        if ($item -eq 'cli') { continue }
        if ($CuaItems -notcontains $item) { Stop-Install "unknown item '$item' (valid: cli, spaces, cua-driver, host)" }
        if ($out -notcontains $item) { $out += $item }
    }
    return $out
}

function Get-CuaSelection {
    param([string]$SelectList = $Select, [string]$OnlyList = $Only, [bool]$Cli = [bool]$CliOnly,
        [bool]$App = [bool]$AppOnly, [string]$InstallMode = $Mode)
    if ($Cli -and $App) { Stop-Install '-CliOnly and -AppOnly are mutually exclusive' }
    if ($OnlyList -and $SelectList) { Stop-Install '-Only and -Select are mutually exclusive' }
    $extra = @(ConvertTo-CuaItems "$SelectList,$OnlyList")
    if ($Cli -and $extra.Count -and -not $Pair) { Stop-Install "-CliOnly installs only the CLI; use -Only $($extra -join ',') instead" }
    if ($App -and ($extra -contains 'cua-driver' -or $extra -contains 'host')) { Stop-Install '-AppOnly skips the CLI, which cua-driver and host need' }
    $sel = [ordered]@{ cli = -not $App; spaces = $false; 'cua-driver' = $false; host = $false }
    $list = if ($OnlyList -or $Cli) { $OnlyList } else { $SelectList }
    if (-not ($OnlyList -or $Cli -or $Pair) -and $script:SpacesSupported) { $sel.spaces = $true }
    foreach ($item in @(ConvertTo-CuaItems $list)) { $sel[$item] = $true }
    if ($Pair) {
        if ($App) { Stop-Install '-Pair needs the CLI; drop -AppOnly' }
        $sel.host = $true
    }
    if ($App -or ($InstallMode -and -not $Cli)) { $sel.spaces = $true }
    if ($sel.spaces -and -not $script:SpacesSupported) {
        if ($App) { Stop-Install 'the Cua Spaces app has no source build for Windows yet; use the SDK and CLI' }
        Write-Info 'the Cua Spaces app has no source build for Windows yet; skipping the app'
        $sel.spaces = $false
    }
    return $sel
}

function Test-WantsChecklist {
    return (-not $Pair -and -not $Yes -and -not $Only -and -not $CliOnly -and -not $AppOnly -and
        $env:CUA_INSTALL_NONINTERACTIVE -ne '1' -and (Test-Interactive))
}

function Read-CuaSelection($Sel, [scriptblock]$Reader = { Read-Host 'Toggle numbers (e.g. 2 3), Enter to install' }) {
    $rows = @('cli')
    if ($script:SpacesSupported) { $rows += 'spaces' }
    $rows += 'cua-driver', 'host'
    $labels = @{ cli = 'cua CLI and cua-spacesd (required)'; spaces = 'Cua Spaces app'; 'cua-driver' = 'cua-driver MCP and skill for your agents'; host = 'Host this machine' }
    Write-Host ''
    Write-Host 'Choose what to install:'
    while ($true) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $box = if ($Sel[$rows[$i]]) { '[x]' } else { '[ ]' }
            Write-Host "  $($i + 1) $box $($labels[$rows[$i]])"
        }
        $line = & $Reader
        if (-not $line) { break }
        foreach ($tok in @($line -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($tok, [ref]$n) -and $n -ge 2 -and $n -le $rows.Count) {
                $id = $rows[$n - 1]
                $Sel[$id] = -not $Sel[$id]
            }
        }
    }
    $script:Picked = $true
    return $Sel
}

function Get-CliBinDir {
    if ($Prefix) { return (Join-Path $Prefix 'bin') }
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
    return (Join-Path $base 'Programs\cua\bin')
}

function Test-OnPath([string]$Dir) {
    return @($env:Path -split ';' | Where-Object { $_ }) -contains $Dir
}

function Add-UserPath([string]$Dir) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @(if ($current) { $current -split ';' | Where-Object { $_ } })
    if ($DryRun) { Write-Host "[dry-run] add $Dir to the user PATH"; return }
    if (-not (Test-OnPath $Dir)) { $env:Path = "$env:Path;$Dir" }
    if (@($parts | ForEach-Object { $_.TrimEnd('\') }) -contains $Dir.TrimEnd('\')) { return }
    [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'User')
    Write-Info "added $Dir to your user PATH (new terminals pick it up)"
}

function Invoke-Cargo([string]$Manifest, [string]$Package) {
    if ($DryRun) {
        Write-Host "[dry-run] cargo build --release -p $Package --manifest-path $Manifest"
        return
    }
    & cargo build --release -p $Package --manifest-path $Manifest
    if ($LASTEXITCODE -ne 0) { Stop-Install "cargo build failed for $Package (exit $LASTEXITCODE)" }
}

function Install-Cli([string]$RepoRoot) {
    $bin = Get-CliBinDir
    $target = Join-Path $bin 'cua.exe'
    if (-not ($CliOnly -or $Only) -and -not (Confirm-Step "Install the cua CLI to ${target}?")) { Stop-Install 'cancelled; rerun with -Prefix DIR to choose another location' }
    $cuaOut = Join-Path (Get-TargetDir (Join-Path $RepoRoot 'libs\cua\target')) 'release\cua.exe'
    $spacesdOut = Join-Path (Get-TargetDir (Join-Path $RepoRoot 'libs\cua-spacesd\target')) 'release\cua-spacesd.exe'
    Invoke-Cargo (Join-Path $RepoRoot 'libs\cua\Cargo.toml') 'cua-cli'
    Invoke-Cargo (Join-Path $RepoRoot 'libs\cua-spacesd\Cargo.toml') 'cua-spacesd'
    if ($DryRun) {
        Write-Host "[dry-run] install $cuaOut -> $target"
        Write-Host "[dry-run] install $spacesdOut -> $(Join-Path $bin 'cua-spacesd.exe')"
    } else {
        foreach ($file in @($cuaOut, $spacesdOut)) {
            if (-not (Test-Path -LiteralPath $file)) { Stop-Install "cargo did not produce $file" }
        }
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Copy-Item -LiteralPath $cuaOut -Destination $target -Force
        Copy-Item -LiteralPath $spacesdOut -Destination (Join-Path $bin 'cua-spacesd.exe') -Force
        Write-Info "installed $target"
        Write-Info "installed $(Join-Path $bin 'cua-spacesd.exe')"
    }
    if (-not (Test-OnPath $bin)) {
        if (-not $NoModifyPath) { Add-UserPath $bin }
        else {
            Write-Host ""
            Write-Host "$bin is not on your PATH. Add it with:"
            Write-Host "  [Environment]::SetEnvironmentVariable('Path', `"`$([Environment]::GetEnvironmentVariable('Path','User'));$bin`", 'User')"
        }
    }
    return $target
}

function Get-DriverBinDir {
    if ($env:CUA_DRIVER_LOCAL_INSTALL_DIR) { return $env:CUA_DRIVER_LOCAL_INSTALL_DIR }
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
    return (Join-Path $base 'Programs\Cua\cua-driver-local\bin')
}

function Get-PowerShellExe {
    $p = (Get-Process -Id $PID).Path
    if ($p -and (Split-Path -Leaf $p) -match '^(pwsh|powershell)(\.exe)?$') { return $p }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return 'pwsh' }
    return 'powershell'
}

function Install-CuaDriver([string]$Cua, [string]$RepoRoot) {
    $script = Join-Path $RepoRoot 'libs\cua-driver\scripts\install.ps1'
    if (-not (Test-Path -LiteralPath $script)) { Stop-Install "missing $script" }
    $binDir = Get-DriverBinDir
    $driver = Join-Path $binDir 'cua-driver.exe'
    $exe = Get-PowerShellExe
    if ($DryRun) {
        Write-Host "[dry-run] $exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -BinDir $binDir -NoAutoStart -NoPathUpdate"
    } else {
        Write-Info 'building and installing cua-driver (libs\cua-driver\scripts\install.ps1)'
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script -BinDir $binDir -NoAutoStart -NoPathUpdate
        if ($LASTEXITCODE -ne 0) { Stop-Install "the cua-driver installer failed (exit $LASTEXITCODE)" }
        Write-Info "installed $driver"
    }
    Write-Info 'adding the cua-driver skill and MCP server to your agents'
    $setup = @('agents', 'setup', '--cua-driver', '--agents', 'all', '--yes', '--mcp-command', $driver)
    if ($DryRun) { Write-Host "[dry-run] $Cua $($setup -join ' ')"; return }
    & $Cua @setup
    if ($LASTEXITCODE -ne 0) { Write-Warning 'agent setup for cua-driver did not finish; rerun: cua agents setup --cua-driver' }
}

function Test-PairArgs {
    if ($Pair -and $Pair -notmatch '^[A-Za-z0-9-]+$') { Stop-Install "-Pair: '$Pair' is not a pairing code (like K7QM-4XPB-2RHD)" }
    if ($Relay) {
        if (-not $Pair) { Stop-Install '-Relay goes with -Pair' }
        if ($Relay -notmatch '^(https://[A-Za-z0-9.-]+(:[0-9]+)?|http://(localhost|127\.0\.0\.1)(:[0-9]+)?)(/[A-Za-z0-9._%/-]*)?$') { Stop-Install '-Relay must be a plain https:// URL (plain http only for localhost)' }
    }
}

function Invoke-HostPair([string]$Cua) {
    $pairArgs = @('host', 'setup', '--pair', $Pair)
    if ($Relay) { $pairArgs += @('--relay', $Relay) }
    if ($DryRun) { Write-Host "[dry-run] $Cua $($pairArgs -join ' ')"; return }
    $setupHelp = (& $Cua host setup --help 2>&1 | Out-String)
    if ($setupHelp -notmatch '--pair') {
        $have = (& $Cua --version 2>&1 | Out-String).Trim()
        Stop-Install "the installed cua CLI ($have) cannot add a machine with a code (no 'cua host setup --pair'); build a newer checkout (git pull; scripts\install\install.ps1) or sign in instead: cua auth login; cua host setup"
    }
    Write-Info 'adding this machine to your account (cua host setup --pair)'
    $null | & $Cua @pairArgs
    if ($LASTEXITCODE -ne 0) { Stop-Install 'adding this machine did not finish; if the code expired or was used, make a new one in Cua Spaces (Add a machine) and run: cua host setup --pair <code>' }
    Write-Host ''
    Write-Host 'This machine is added. It shows up in Cua Spaces on your other devices in a few seconds.'
}

function Invoke-HostSetup([string]$Cua) {
    if ($Pair) { Invoke-HostPair $Cua; return }
    if ($DryRun) { Write-Host "[dry-run] $Cua host setup"; return }
    Write-Info 'setting up this machine as a host (cua host setup)'
    if (Test-Interactive) { & $Cua host setup } else { $null | & $Cua host setup }
    if ($LASTEXITCODE -ne 0) { Write-Warning "host setup did not finish; run 'cua host setup' after 'cua auth login'" }
}

function Find-ExistingCua {
    if (-not $Pair -or $Prefix -or $env:CUA_INSTALL_REINSTALL -eq '1') { return $null }
    $candidates = @()
    $onPath = Get-Command cua -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\cua\bin\cua.exe') }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $help = (& $candidate host setup --help 2>&1 | Out-String)
        if ($help -match '--pair') { return $candidate }
    }
    return $null
}

function Invoke-CuaInstall {
    Set-StrictMode -Version 3
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Test-PairArgs
    $repoRoot = Get-RepoRoot
    $sel = Get-CuaSelection
    $platform = Get-CuaPlatform
    if (Test-WantsChecklist) { $sel = Read-CuaSelection $sel }
    if ($DryRun) { Write-Info 'dry run: nothing will be changed' }
    Write-Info "platform $platform, checkout $repoRoot"
    if ($sel.cli -or $sel['cua-driver']) {
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            Stop-Install 'cargo is required to build cua; install Rust from https://rustup.rs and rerun'
        }
    }
    $cua = $null
    $existing = Find-ExistingCua
    if ($existing) {
        Write-Info "cua is already installed at $existing; using it (CUA_INSTALL_REINSTALL=1 builds it again)"
        $sel.cli = $false
        $cua = $existing
    }
    if ($sel.cli) { $cua = Install-Cli $repoRoot }
    if ($Mode) {
        $cuaHome = if ($env:CUA_HOME) { $env:CUA_HOME } else { Join-Path $HOME '.cua' }
        $modeFile = Join-Path $cuaHome 'spaces-install-mode'
        if ($DryRun) { Write-Host "[dry-run] write $modeFile ($Mode)" }
        else {
            New-Item -ItemType Directory -Force -Path $cuaHome | Out-Null
            Set-Content -LiteralPath $modeFile -Value $Mode -NoNewline
        }
    }
    if ($sel['cua-driver']) { Install-CuaDriver $cua $repoRoot }
    Write-Info 'done'
    if ($cua -and -not $Pair -and -not $CliOnly -and -not $NoOnboarding -and -not $DryRun -and (Test-Interactive)) {
        Write-Info 'signing in (cua auth login)'
        & $cua auth login
        if ($LASTEXITCODE -ne 0) { Write-Warning "sign-in did not finish; run 'cua auth login' later" }
    } elseif (-not $Pair) {
        Write-Host ''
        Write-Host 'Next steps:'
        if ($sel.cli) {
            Write-Host '  cua auth login      # sign in, then set up your AI coding agents'
            Write-Host '  cua agents setup    # (re)configure cua skills and the cua MCP server'
        }
    }
    if ($sel.host) { Invoke-HostSetup $cua }
}

# Dot-sourcing with CUA_INSTALL_NO_RUN=1 loads the functions for tests.
if ($env:CUA_INSTALL_NO_RUN -ne '1') {
    Invoke-CuaInstall
}
