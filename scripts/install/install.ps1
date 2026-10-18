<#
.SYNOPSIS
Cua source installer for Windows: build and install the `cua` CLI, cua-spacesd
and agent extras from this repository checkout.

.DESCRIPTION
Run it from a checkout:

    git clone https://github.com/chriswritescode-dev/cua.git
    cd cua
    git checkout local-build
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -Select cua-driver
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -CliOnly -Yes
    powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1 -Pair K7QM-4XPB-2RHD

At a console it first says what Cua Spaces is, then shows a numbered list of
what to add to the command-line tools (the `cua` program: always built, except
with -AppOnly). Items:
    spaces      the Cua Spaces app (no source build for Windows yet; off)
    cua-driver  Cua Driver, which lets AI agents use apps while you keep
                working: builds it and adds its skill and MCP server to
                your agents (off by default)
Signing in adds this computer to your account: after `cua auth login`
succeeds, the installer runs `cua host setup`, so your other devices can use
it through the relay (a computer set up before keeps its settings). -NoHost
signs in only. `-Select host` and `-Only host` run `cua host setup` even
without a sign-in here (kept for scripts).
Set CUA_INSTALL_NONINTERACTIVE=1 to never prompt. Add -Verbose to see every
step (checkout paths, builds, installs).

Builds with cargo from this checkout, installs `cua.exe` and `cua-spacesd.exe`
to %LOCALAPPDATA%\Programs\cua\bin (or -Prefix\bin), adds that directory to
your user PATH (-NoModifyPath skips it), then runs `cua auth login` when a user
is at the console (not with -CliOnly, -Pair or -NoOnboarding).

.PARAMETER Select
Preselect items (comma list: spaces, cua-driver, host); the list still shows.
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
(Add a computer): builds the CLI and runs `cua host setup --pair <code>`, with
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
Do not run `cua auth login` afterwards (nor add this computer).
.PARAMETER NoHost
Sign in only: do not add this computer to your account.
.PARAMETER NoProvideSpaces
Add this computer without creating Spaces for your other devices on it
(`cua host setup --no-provide-spaces`).
.PARAMETER NoSkills
With cua-driver, add only its MCP server to your agents, not its skill (by default both are added).
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
    [switch]$NoHost,
    [switch]$NoProvideSpaces,
    [switch]$NoSkills,
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
$script:DidCli = $null
$script:DidApp = $false
$script:DidDriver = $false
$script:SignedIn = $false
$script:DidHost = $false
$script:PathHint = $null

# Write-Step: one plain line per thing the installer does. Write-Info: detail
# for -Verbose (checkout paths, build commands, installs).
function Write-Step([string]$Message) { Write-Host $Message }
function Write-Info([string]$Message) { Write-Verbose "cua-install: $Message" }
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

# The installer only works from a clone, and every component is built from it.
function Get-RepoRoot {
    if (-not $PSScriptRoot) {
        Write-CloneHint
        Stop-Install 'run scripts\install\install.ps1 from a cloned repository; it cannot run from a pipe'
    }
    $candidate = $null
    try { $candidate = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..') -ErrorAction Stop).Path } catch { $candidate = $null }
    if (-not $candidate) {
        Write-CloneHint
        Stop-Install "$PSScriptRoot is not a Cua checkout"
    }
    $cli = Join-Path $candidate 'libs' 'cua' 'Cargo.toml'
    $spacesd = Join-Path $candidate 'libs' 'cua-spacesd' 'Cargo.toml'
    if (-not (Test-Path -LiteralPath $cli) -or -not (Test-Path -LiteralPath $spacesd)) {
        Write-CloneHint
        Stop-Install "$PSScriptRoot is not a Cua checkout"
    }
    return $candidate
}

# Where cargo puts release builds, honouring CARGO_TARGET_DIR as cargo does.
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

# The item ids in a comma list (cli dropped), or an error.
function ConvertTo-CuaItems([string]$List) {
    $out = @()
    foreach ($item in @($List -split '[,\s]+' | Where-Object { $_ })) {
        if ($item -eq 'cli') { continue }
        if ($CuaItems -notcontains $item) { Stop-Install "unknown item '$item' (valid: cli, spaces, cua-driver, host)" }
        if ($out -notcontains $item) { $out += $item }
    }
    return $out
}

# The selection before the checklist: defaults, legacy switches, -Select/-Only.
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
    if (-not ($OnlyList -or $Cli -or $Pair -or "$SelectList".Trim(' ', ',', "`t")) -and $script:SpacesSupported) { $sel.spaces = $true }
    foreach ($item in @(ConvertTo-CuaItems $list)) { $sel[$item] = $true }
    # A pairing code adds this machine: the CLI and host setup.
    if ($Pair) {
        if ($App) { Stop-Install '-Pair needs the CLI; drop -AppOnly' }
        $sel.host = $true
    }
    if ($NoHost) {
        if ($Pair) { Stop-Install '-NoHost and -Pair contradict each other: -Pair adds this computer' }
        if ($sel.host) { Stop-Install '-NoHost and -Select host contradict each other' }
        if ($NoProvideSpaces) { Stop-Install '-NoProvideSpaces goes with adding this computer; drop -NoHost' }
    }
    # Legacy: -AppOnly and -Mode mean the app, as they always did.
    if ($App -or ($InstallMode -and -not $Cli)) { $sel.spaces = $true }
    if ($sel.spaces -and -not $script:SpacesSupported) {
        if ($App) { Stop-Install 'the Cua Spaces app has no source build for Windows yet; use the SDK and CLI' }
        Write-Step 'Cua Spaces has no source build for Windows; skipping the app'
        $sel.spaces = $false
    }
    return $sel
}

function Test-WantsChecklist {
    return (-not $Pair -and -not $Yes -and -not $Only -and -not $CliOnly -and -not $AppOnly -and
        $env:CUA_INSTALL_NONINTERACTIVE -ne '1' -and (Test-Interactive))
}

# Numbered list: what Cua Spaces is, what is always installed, then the
# optional rows. Toggle numbers, Enter to install. `host` is not a row (the
# app's first run asks how to use this computer; -Select host is for scripts).
function Read-CuaSelection($Sel, [scriptblock]$Reader = { Read-Host 'Type a number to switch an item on or off. Press Enter to install' }) {
    $rows = @()
    if ($script:SpacesSupported) { $rows += 'spaces' }
    $rows += 'cua-driver'
    $labels = @{ spaces = 'Cua Spaces app: lets your AI agents use computers'; 'cua-driver' = 'Cua Driver: lets AI agents use your apps while you keep working' }
    $help = @{
        spaces = 'Open the app to sign in, connect your AI agents and watch them work.'
        'cua-driver' = 'For advanced users. Adds it to Claude Code, Codex and other coding agents.'
    }
    Write-Host ''
    Write-Host 'Cua Spaces lets your AI agents use computers, and lets you watch them work.'
    Write-Host ''
    Write-Host 'Needed, so always installed:'
    Write-Host '  Command-line tools: the "cua" program that the app and your AI agents use.'
    if ($Sel.host) { Write-Host 'Also: your other devices will be able to use this computer (you asked for this with -Select host).' }
    Write-Host ''
    Write-Host 'Choose what else to add:'
    Write-Host ''
    while ($true) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $box = if ($Sel[$rows[$i]]) { '[x]' } else { '[ ]' }
            Write-Host "  $($i + 1) $box $($labels[$rows[$i]])"
            Write-Host "        $($help[$rows[$i]])"
        }
        $line = & $Reader
        if (-not $line) { break }
        foreach ($tok in @($line -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $rows.Count) {
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
    # This terminal too, so `cua` works right away.
    if (-not (Test-OnPath $Dir)) { $env:Path = "$env:Path;$Dir" }
    if (@($parts | ForEach-Object { $_.TrimEnd('\') }) -contains $Dir.TrimEnd('\')) { return }
    [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'User')
    Write-Step "Added $Dir to your user PATH (open a new terminal window to use cua)"
}

function Invoke-Cargo([string]$Manifest, [string]$Package) {
    if ($DryRun) {
        Write-Host "[dry-run] cargo build --release -p $Package --manifest-path $Manifest"
        return
    }
    & cargo build --release -p $Package --manifest-path $Manifest
    if ($LASTEXITCODE -ne 0) { Stop-Install "cargo build failed for $Package (exit $LASTEXITCODE)" }
}

# cua-host looks for cua-spacesd next to `cua`, so it is built and installed
# into the same bin directory.
function Install-Cli([string]$RepoRoot) {
    $bin = Get-CliBinDir
    $target = Join-Path $bin 'cua.exe'
    if (-not ($CliOnly -or $Only) -and -not (Confirm-Step "Install the command-line tools to ${target}?")) { Stop-Install 'cancelled; rerun with -Prefix DIR to choose another location' }
    $cuaOut = Join-Path (Get-TargetDir (Join-Path $RepoRoot 'libs' 'cua' 'target')) 'release' 'cua.exe'
    $spacesdOut = Join-Path (Get-TargetDir (Join-Path $RepoRoot 'libs' 'cua-spacesd' 'target')) 'release' 'cua-spacesd.exe'
    Write-Step "Building the cua CLI from $RepoRoot"
    Invoke-Cargo (Join-Path $RepoRoot 'libs' 'cua' 'Cargo.toml') 'cua-cli'
    Write-Step "Building cua-spacesd from $RepoRoot"
    Invoke-Cargo (Join-Path $RepoRoot 'libs' 'cua-spacesd' 'Cargo.toml') 'cua-spacesd'
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
        $script:DidCli = $target
    }
    if (-not (Test-OnPath $bin)) {
        if (-not $NoModifyPath) { Add-UserPath $bin }
        else {
            # Said at the end, after what was installed.
            $script:PathHint = @(
                "$bin is not on your PATH, the list of places your terminal looks for programs.",
                'To use cua, run this, then open a new terminal window:',
                "  [Environment]::SetEnvironmentVariable('Path', `"`$([Environment]::GetEnvironmentVariable('Path','User'));$bin`", 'User')"
            )
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

# cua-driver's own installer builds it from this checkout through
# install-local.ps1, then adds the skill and MCP server to your agents.
function Install-CuaDriver([string]$Cua, [string]$RepoRoot) {
    $script = Join-Path $RepoRoot 'libs' 'cua-driver' 'scripts' 'install.ps1'
    if (-not (Test-Path -LiteralPath $script)) { Stop-Install "missing $script" }
    $binDir = Get-DriverBinDir
    $driver = Join-Path $binDir 'cua-driver.exe'
    $exe = Get-PowerShellExe
    $driverArgs = @('-BinDir', $binDir, '-NoAutoStart', '-NoPathUpdate')
    if ($DryRun) {
        Write-Host "[dry-run] $exe -NoProfile -ExecutionPolicy Bypass -File $script $($driverArgs -join ' ')"
    } else {
        Write-Step "Building Cua Driver and installing it into $binDir"
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script @driverArgs
        if ($LASTEXITCODE -ne 0) { Stop-Install "the cua-driver installer failed (exit $LASTEXITCODE)" }
        Write-Info "installed $driver"
    }
    if ($NoSkills) { Write-Info 'adding the cua-driver MCP server to your agents (no skill: -NoSkills)' }
    else { Write-Info 'adding the cua-driver skill and MCP server to your agents' }
    $setup = @('agents', 'setup', '--cua-driver', '--agents', 'all', '--yes')
    if ($NoSkills) { $setup += '--no-skills' }
    $setup += @('--mcp-command', $driver)
    if ($DryRun) { Write-Host "[dry-run] $Cua $($setup -join ' ')"; return }
    & $Cua @setup
    if ($LASTEXITCODE -ne 0) { Write-Warning 'agent setup for cua-driver did not finish; rerun: cua agents setup --cua-driver' }
    $script:DidDriver = $true
}

# Checks -Pair / -Relay: they end up on a command line.
function Test-PairArgs {
    if ($Pair -and $Pair -notmatch '^[A-Za-z0-9-]+$') { Stop-Install "-Pair: '$Pair' is not a pairing code (like K7QM-4XPB-2RHD)" }
    if ($Relay) {
        if (-not $Pair) { Stop-Install '-Relay goes with -Pair' }
        if ($Relay -notmatch '^(https://[A-Za-z0-9.-]+(:[0-9]+)?|http://(localhost|127\.0\.0\.1)(:[0-9]+)?)(/[A-Za-z0-9._%/-]*)?$') { Stop-Install '-Relay must be a plain https:// URL (plain http only for localhost)' }
    }
}

# Add this machine with a pairing code: joins the account (or team) that
# made it, with no sign-in here.
function Invoke-HostPair([string]$Cua) {
    $pairArgs = @('host', 'setup', '--pair', $Pair)
    if ($Relay) { $pairArgs += @('--relay', $Relay) }
    if ($DryRun) { Write-Host "[dry-run] $Cua $($pairArgs -join ' ')"; return }
    # A CLI built before pairing exists would fail with a bare
    # "unexpected argument '--pair'"; say what to do instead.
    $setupHelp = (& $Cua host setup --help 2>&1 | Out-String)
    if ($setupHelp -notmatch '--pair') {
        $have = (& $Cua --version 2>&1 | Out-String).Trim()
        Stop-Install "the installed cua CLI ($have) cannot add a machine with a code (no 'cua host setup --pair'); build a newer checkout (git pull; scripts\install\install.ps1) or sign in instead: cua auth login; cua host setup"
    }
    # It provides Spaces and keeps its screen private, as a computer added
    # by signing in does; sharing its desktop is a choice on its page.
    if ($setupHelp -match '--no-desktop') { $pairArgs += @('--no-desktop', '--provide-spaces') }
    Write-Step 'Adding this computer to your account (cua host setup --pair)'
    $null | & $Cua @pairArgs
    if ($LASTEXITCODE -ne 0) { Stop-Install 'adding this machine did not finish; if the code expired or was used, make a new one in Cua Spaces (Add a computer) and run: cua host setup --pair <code>' }
    Write-Host ''
    Write-Host 'This machine is added. It shows up in Cua Spaces on your other devices in a few seconds.'
}

# Host this machine: joins the relay as the signed-in account.
function Invoke-HostSetup([string]$Cua, $Sel) {
    if ($Pair) { Invoke-HostPair $Cua; return }
    $setupArgs = @('host', 'setup')
    if (-not $Sel.host) {
        # Added by signing in: a computer already set up keeps its settings,
        # and a new one provides Spaces with its screen kept private (sharing
        # its desktop is a choice on its page in Cua Spaces).
        if (-not $DryRun) {
            $status = (& $Cua host status --json 2>$null | Out-String)
            if ($status -match '"configured"\s*:\s*true') { $script:DidHost = $true; return }
        }
        if (-not $NoProvideSpaces) { $setupArgs += @('--no-desktop', '--provide-spaces') }
    }
    if ($NoProvideSpaces) { $setupArgs += '--no-provide-spaces' }
    if ($DryRun) { Write-Host "[dry-run] $Cua $($setupArgs -join ' ')"; return }
    Write-Step 'Adding this computer to your account (cua host setup)'
    if (Test-Interactive) { & $Cua @setupArgs } else { $null | & $Cua @setupArgs }
    if ($LASTEXITCODE -ne 0) { Write-Warning "adding this computer did not finish; run 'cua host setup' to try again (sign in first with 'cua auth login')" }
    else { $script:DidHost = $true }
}

# -Pair on a computer that already has Cua: the `cua` that is there (it must
# know `host setup --pair`), or $null. -Prefix and CUA_INSTALL_REINSTALL=1
# build anyway.
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

# "a, b and c" from a list of phrases.
function Join-And([string[]]$Items) {
    if ($Items.Count -le 1) { return ($Items -join '') }
    if ($Items.Count -eq 2) { return "$($Items[0]) and $($Items[1])" }
    return (($Items[0..($Items.Count - 2)] -join ', ') + " and $($Items[-1])")
}

# The closing lines: what was installed, then what to do next, in plain words.
function Write-CuaSummary($Sel) {
    if ($DryRun -or $Pair) { return }
    $did = @()
    if ($script:DidCli) { $did += 'the command-line tools' }
    if ($script:DidApp) { $did += 'the Cua Spaces app' }
    if ($script:DidDriver) { $did += 'Cua Driver' }
    Write-Host ''
    if ($did.Count -gt 0) {
        $checked = if ($script:DidCli -or $script:DidApp) { ' (built from source)' } else { '' }
        Write-Host "Installed $(Join-And $did)$checked."
    }
    if ($script:DidHost) { Write-Host 'This computer is added to your account. It shows up in Cua Spaces on your other devices.' }
    if ($script:DidApp) {
        if ($script:SignedIn) { Write-Host 'Next: open Cua Spaces from the Start menu.' }
        else { Write-Host 'Next: open Cua Spaces from the Start menu. It guides you through signing in and connecting your AI agents. Signing in adds this computer to your account.' }
        if ($Sel.cli) {
            if ($script:SignedIn) { Write-Host 'To connect more AI agents later, run "cua agents setup" in a terminal.' }
            else { Write-Host 'Prefer a terminal? Run "cua auth login" to sign in, then "cua agents setup" to connect your AI agents.' }
        }
    } elseif ($Sel.cli) {
        if ($script:SignedIn) { Write-Host 'Next: run "cua agents setup" to connect your AI agents.' }
        else {
            Write-Host 'Next: run "cua auth login" to sign in, then "cua agents setup" to connect your AI agents.'
            Write-Host '(No web browser on this computer? Run "cua auth login --remote" instead.)'
        }
        if (-not $script:DidHost -and -not $NoHost) { Write-Host 'To add this computer to your account, run "cua host setup" after signing in.' }
    }
}

function Invoke-CuaInstall {
    # Function scope: `irm | iex` runs in the caller's session, so keep these local.
    Set-StrictMode -Version 3
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Test-PairArgs
    $sel = Get-CuaSelection
    Invoke-CuaInstallSteps $sel
}

function Invoke-CuaInstallSteps($sel) {
    $repoRoot = Get-RepoRoot
    $platform = Get-CuaPlatform
    if (Test-WantsChecklist) {
        $picked = Read-CuaSelection $sel
        foreach ($k in @($picked.Keys)) { $sel[$k] = $picked[$k] }
    }
    if ($DryRun) { Write-Step 'Dry run: nothing will be changed' }
    if ($sel.cli -or $sel['cua-driver']) {
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            Stop-Install 'cargo is required to build cua; install Rust from https://rustup.rs and rerun'
        }
    }
    Write-Info "platform $platform, checkout $repoRoot"
    $cua = $null
    $existing = Find-ExistingCua
    if ($existing) {
        Write-Step "cua is already installed at $existing; using it (CUA_INSTALL_REINSTALL=1 builds it again)"
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
    # Cua Driver on its own: sign-in would run the Cua Spaces agent onboarding, which was not picked.
    $driverOnly = $sel['cua-driver'] -and -not $sel.spaces -and -not $sel.host
    if ($cua -and -not $Pair -and -not $CliOnly -and -not $NoOnboarding -and -not $DryRun -and -not $driverOnly -and (Test-Interactive)) {
        Write-Host ''
        Write-Step 'Signing in to Cua'
        & $cua auth login
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Sign-in did not finish. Run "cua auth login" later (add --remote if this computer has no web browser).' } else { $script:SignedIn = $true }
    }
    # Signing in adds this computer (unless -NoHost); -Select host adds it
    # even without a sign-in here.
    if ($sel.host -or ($script:SignedIn -and -not $NoHost)) { Invoke-HostSetup $cua $sel }
    Write-CuaSummary $sel
    if ($script:PathHint) {
        Write-Host ''
        $script:PathHint | ForEach-Object { Write-Host $_ }
    }
}

# Dot-sourcing with CUA_INSTALL_NO_RUN=1 loads the functions for tests.
if ($env:CUA_INSTALL_NO_RUN -ne '1') {
    Invoke-CuaInstall
}
