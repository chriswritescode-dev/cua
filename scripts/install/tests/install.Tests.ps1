# Pester 5 tests for install.ps1. Hermetic: temp dirs, a fake checkout and a
# fake cargo; no real installs.
#   pwsh -c "Invoke-Pester scripts/install/tests -Output Detailed"

BeforeAll {
    $script:Installer = (Resolve-Path (Join-Path $PSScriptRoot '..' 'install.ps1')).Path
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("cua-ps-tests-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null

    # A checkout the installer accepts, and a cargo that writes what it would
    # have built.
    $script:Repo = Join-Path $script:Root 'repo'
    foreach ($dir in 'scripts/install', 'libs/cua', 'libs/cua-spacesd', 'libs/cua-driver/scripts') {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Repo $dir) | Out-Null
    }
    Copy-Item -LiteralPath $script:Installer -Destination (Join-Path $script:Repo 'scripts\install\install.ps1')
    Set-Content -LiteralPath (Join-Path $script:Repo 'libs\cua\Cargo.toml') -Value ''
    Set-Content -LiteralPath (Join-Path $script:Repo 'libs\cua-spacesd\Cargo.toml') -Value ''
    $script:Bin = Join-Path $script:Root 'bin'
    New-Item -ItemType Directory -Force -Path $script:Bin | Out-Null
    $cargo = Join-Path $script:Bin 'cargo'
    Set-Content -LiteralPath $cargo -Value @'
#!/bin/sh
pkg=""
manifest=""
while [ $# -gt 0 ]; do
    case "$1" in
    -p) pkg="$2"; shift ;;
    --manifest-path) manifest="$2"; shift ;;
    esac
    shift
done
root="$(cd "$(dirname "$manifest")" && pwd)/target/release"
mkdir -p "$root"
case "$pkg" in
cua-cli) printf '#!/bin/sh\necho fake cua\n' >"$root/cua.exe" ;;
cua-spacesd) printf '#!/bin/sh\necho fake spacesd\n' >"$root/cua-spacesd.exe" ;;
*) exit 1 ;;
esac
'@
    if (-not $IsWindows) { chmod +x $cargo }

    function script:Invoke-Installer([hashtable]$Params, [hashtable]$Vars = @{}) {
        $saved = @{}
        $all = @{
            PATH = "$script:Bin$([IO.Path]::PathSeparator)$env:PATH"
            CUA_HOME = (Join-Path $script:Root 'cuahome')
            CUA_INSTALL_ARCH = 'AMD64'
        }
        foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
        foreach ($k in $all.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $all[$k])
        }
        try {
            return (& (Join-Path $script:Repo 'scripts\install\install.ps1') @Params *>&1 | Out-String)
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
}

AfterAll {
    Remove-Item -Recurse -Force -LiteralPath $script:Root -ErrorAction SilentlyContinue
}

Describe 'install.ps1' {
    BeforeAll {
        $env:CUA_INSTALL_NO_RUN = '1'
        . $script:Installer
        $env:CUA_INSTALL_NO_RUN = $null
    }

    It 'has no release download path' {
        $source = Get-Content -Raw -LiteralPath $script:Installer
        $source | Should -Not -Match 'releases/download'
        $source | Should -Not -Match 'cua\.ai/install'
        $source | Should -Not -Match 'cua\.ai/driver'
        $source | Should -Not -Match 'Invoke-WebRequest'
        $source | Should -Not -Match 'release-artifacts'
    }

    It 'sends no install telemetry' {
        $source = Get-Content -Raw -LiteralPath $script:Installer
        $source | Should -Not -Match 'telemetry'
        $source | Should -Not -Match 'posthog'
        $source | Should -Not -Match 'DO_NOT_TRACK'
        $source | Should -Not -Match 'installer_started|installer_completed|installer_failed'
    }

    It 'maps architectures' {
        Get-CuaPlatform -Arch 'AMD64' | Should -Be 'windows-x64'
        Get-CuaPlatform -Arch 'ARM64' | Should -Be 'windows-arm64'
        { Get-CuaPlatform -Arch 'x86' } | Should -Throw '*unsupported CPU architecture*'
    }

    It 'parses the item list, dropping cli and duplicates' {
        ConvertTo-CuaItems 'cli,host,host' | Should -Be @('host')
        ConvertTo-CuaItems '' | Should -Be @()
        { ConvertTo-CuaItems 'bogus' } | Should -Throw "*unknown item 'bogus'*"
    }

    It 'requires the CLI for cua-driver and host' {
        (Get-CuaSelection).cli | Should -Be $true
        { Get-CuaSelection -Cli $true -SelectList 'cua-driver' } | Should -Throw '*use -Only cua-driver*'
        { Get-CuaSelection -OnlyList 'host' -SelectList 'cua-driver' } | Should -Throw '*mutually exclusive*'
        { Get-CuaSelection -App $true -OnlyList 'cua-driver' } | Should -Throw '*cua-driver and host need*'
        { Get-CuaSelection -Cli $true -App $true } | Should -Throw '*mutually exclusive*'
    }

    It 'skips the app when there is no Windows source build' {
        (Get-CuaSelection).spaces | Should -BeFalse
        { Get-CuaSelection -App $true } | Should -Throw '*no source build for Windows*'
    }

    It 'adds host setup for a pairing code' {
        $Pair = 'K7QM-4XPB-2RHD'
        try {
            (Get-CuaSelection).host | Should -Be $true
        } finally {
            $Pair = ''
        }
    }

    It 'refuses -NoHost with what adds this computer' {
        $NoHost = $true
        try {
            $Pair = 'K7QM-4XPB-2RHD'
            try { { Get-CuaSelection } | Should -Throw '*-NoHost and -Pair contradict*' } finally { $Pair = '' }
            { Get-CuaSelection -SelectList 'host' } | Should -Throw '*-NoHost and -Select host contradict*'
            $NoProvideSpaces = $true
            try { { Get-CuaSelection } | Should -Throw '*-NoProvideSpaces goes with adding this computer*' } finally { $NoProvideSpaces = $false }
        } finally { $NoHost = $false }
    }

    It 'installs under -Prefix\bin' {
        $Prefix = Join-Path $script:Root 'prefixed'
        try {
            Get-CliBinDir | Should -Be (Join-Path $Prefix 'bin')
        } finally {
            $Prefix = ''
        }
    }

    It 'shows only the Cua Driver row, and says a scripted -Select host is on' {
        $script:answers = [Collections.Generic.Queue[string]]::new([string[]]@(''))
        $sel = Get-CuaSelection -SelectList 'host' -OnlyList '' -Cli $false -App $false -InstallMode ''
        $shown = @(& { $null = Read-CuaSelection $sel { $script:answers.Dequeue() } } 6>&1 | ForEach-Object { "$($_.MessageData)" })
        $text = $shown -join "`n"
        $text | Should -Match 'Cua Spaces lets your AI agents use computers'
        $text | Should -Match 'Needed, so always installed:'
        $text | Should -Match 'Also: your other devices will be able to use this computer'
        $text | Should -Match '1 \[ \] Cua Driver: lets AI agents use your apps while you keep working'
        $text | Should -Not -Match 'Host this machine'
        $text | Should -Not -Match 'Cua Spaces app:'
        $script:Picked = $false
    }

    It 'counts the Cua Driver row' {
        $script:answers = [Collections.Generic.Queue[string]]::new([string[]]@('1', ''))
        $sel = Get-CuaSelection -SelectList '' -OnlyList '' -Cli $false -App $false -InstallMode ''
        $sel = Read-CuaSelection $sel { $script:answers.Dequeue() } 6>$null
        $sel['cua-driver'] | Should -BeTrue
        $script:Picked = $false
    }

    It 'runs the cua-driver installer, then registers the skill and MCP server' -Skip:($IsWindows) {
        $root = Join-Path $script:Root 'drv'
        $prefix = Join-Path $root 'prefix'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $log = Join-Path $root 'driver.log'
        $cuaLog = Join-Path $root 'cua.log'
        $fakeDriver = Join-Path $script:Repo 'libs/cua-driver/scripts/install.ps1'
        Set-Content -LiteralPath $fakeDriver -Value @"
param([string]`$BinDir, [switch]`$AutoStart, [switch]`$NoAutoStart, [switch]`$NoPathUpdate)
"BinDir=`$BinDir NoAutoStart=`$NoAutoStart NoPathUpdate=`$NoPathUpdate" | Set-Content '$log'
New-Item -ItemType Directory -Force -Path `$BinDir | Out-Null
Set-Content (Join-Path `$BinDir 'cua-driver.exe') 'fake'
"@
        $fakeCua = Join-Path $root 'cua'
        Set-Content -LiteralPath $fakeCua -Value "#!/bin/sh`necho `"`$*`" >>'$cuaLog'"
        chmod +x $fakeCua
        $savedEnv = $env:CUA_DRIVER_LOCAL_INSTALL_DIR
        $env:CUA_DRIVER_LOCAL_INSTALL_DIR = $null
        $Prefix = $prefix; $DryRun = $false; $NoSkills = $false
        try {
            Install-CuaDriver $fakeCua $script:Repo 6>$null
        } finally {
            $env:CUA_DRIVER_LOCAL_INSTALL_DIR = $savedEnv
        }
        $bin = Get-DriverBinDir
        (Get-Content $log -Raw).Trim() | Should -Be "BinDir=$bin NoAutoStart=True NoPathUpdate=True"
        (Get-Content $cuaLog -Raw).Trim() | Should -Be "agents setup --cua-driver --agents all --yes --mcp-command $(Join-Path $bin 'cua-driver.exe')"
    }

    It 'adds the MCP server without the skill with -NoSkills' -Skip:($IsWindows) {
        $root = Join-Path $script:Root 'noskills'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $cuaLog = Join-Path $root 'cua.log'
        $fakeDriver = Join-Path $script:Repo 'libs/cua-driver/scripts/install.ps1'
        Set-Content -LiteralPath $fakeDriver -Value @"
param([string]`$BinDir, [switch]`$AutoStart, [switch]`$NoAutoStart, [switch]`$NoPathUpdate)
New-Item -ItemType Directory -Force -Path `$BinDir | Out-Null
Set-Content (Join-Path `$BinDir 'cua-driver.exe') 'fake'
"@
        $fakeCua = Join-Path $root 'cua'
        Set-Content -LiteralPath $fakeCua -Value "#!/bin/sh`necho `"`$*`" >>'$cuaLog'"
        chmod +x $fakeCua
        $savedEnv = $env:CUA_DRIVER_LOCAL_INSTALL_DIR
        $env:CUA_DRIVER_LOCAL_INSTALL_DIR = (Join-Path $root 'bin')
        $Prefix = ''; $DryRun = $false; $NoSkills = $true
        try {
            Install-CuaDriver $fakeCua $script:Repo 6>$null
        } finally {
            $env:CUA_DRIVER_LOCAL_INSTALL_DIR = $savedEnv; $NoSkills = $false
        }
        (Get-Content $cuaLog -Raw) | Should -Match 'agents setup --cua-driver --agents all --yes --no-skills --mcp-command '
    }

    It 'plans host setup from the selection and -NoProvideSpaces' {
        $Cua = Join-Path $script:Root 'cua-plan'
        $DryRun = $true
        $Pair = ''
        $NoProvideSpaces = $false
        $out = (& { Invoke-HostSetup $Cua @{ host = $true } } *>&1 | Out-String)
        $out | Should -Match 'host setup$'
        $out = (& { Invoke-HostSetup $Cua @{ host = $false } } *>&1 | Out-String)
        $out | Should -Match 'host setup --no-desktop --provide-spaces'
        $NoProvideSpaces = $true
        try {
            $out = (& { Invoke-HostSetup $Cua @{ host = $true } } *>&1 | Out-String)
            $out | Should -Match 'host setup --no-provide-spaces'
        } finally { $NoProvideSpaces = $false }
    }

    It 'fails outside a checkout with the clone instructions' {
        $root = Join-Path $script:Root 'alone'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            $copy = Join-Path $root 'install.ps1'
            Copy-Item -LiteralPath $script:Installer -Destination $copy
            { & $copy -CliOnly -Yes } | Should -Throw '*not a Cua checkout*'
        } finally {
            Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
        }
    }
}

Describe 'install.ps1 run' {
    It 'builds the CLI and cua-spacesd from the checkout into -Prefix\bin' -Skip:($IsWindows) {
        $prefix = Join-Path $script:Root 'p1'
        $out = Invoke-Installer @{ CliOnly = $true; Yes = $true; NoOnboarding = $true; NoModifyPath = $true; Prefix = $prefix }
        Join-Path $prefix 'bin/cua.exe' | Should -Exist
        Join-Path $prefix 'bin/cua-spacesd.exe' | Should -Exist
        $out | Should -Match 'Building the cua CLI from '
        $out | Should -Match 'Building cua-spacesd from '
        $out | Should -Match 'Installed the command-line tools \(built from source\)\.'
        $out | Should -Match 'Next: run "cua auth login" to sign in, then "cua agents setup" to connect your AI agents\.'
        $out | Should -Match 'To add this computer to your account, run "cua host setup" after signing in\.'
        $out | Should -Match 'is not on your PATH'
    }

    It 'prints the checkout only with -Verbose' {
        $out = Invoke-Installer @{ CliOnly = $true; Yes = $true; NoOnboarding = $true; NoModifyPath = $true; Prefix = (Join-Path $script:Root 'p-quiet') }
        $out | Should -Not -Match 'cua-install:'
        $out | Should -Not -Match 'manifest|checksum|sha256|downloading'
        $verbose = Invoke-Installer @{ CliOnly = $true; Yes = $true; NoOnboarding = $true; NoModifyPath = $true; Prefix = (Join-Path $script:Root 'p-verbose'); Verbose = $true }
        $verbose | Should -Match 'cua-install: platform windows-x64, checkout '
    }

    It 'dry run plans both builds and changes nothing' {
        $prefix = Join-Path $script:Root 'p2'
        $out = Invoke-Installer @{ DryRun = $true; Yes = $true; CliOnly = $true; Prefix = $prefix }
        $out | Should -Match '\[dry-run\] cargo build --release -p cua-cli'
        $out | Should -Match '\[dry-run\] cargo build --release -p cua-spacesd'
        $prefix | Should -Not -Exist
    }

    It 'dry run: -Pair plans the CLI and host setup with the code, no sign-in' {
        $out = Invoke-Installer @{ DryRun = $true; Pair = 'K7QM-4XPB-2RHD'; Relay = 'https://relay.example.com' } @{ CUA_INSTALL_REINSTALL = '1' }
        $out | Should -Match 'host setup --pair K7QM-4XPB-2RHD --relay https://relay.example.com'
        $out | Should -Not -Match 'auth login'
        $out | Should -Not -Match 'Choose what else to add'
    }

    It '-Pair refuses codes and relays with shell characters' {
        { Invoke-Installer @{ DryRun = $true; Pair = 'K7QM;calc' } } | Should -Throw '*not a pairing code*'
        { Invoke-Installer @{ DryRun = $true; Pair = 'K7QM-4XPB-2RHD'; Relay = 'http://evil.example' } } | Should -Throw '*https*'
        { Invoke-Installer @{ DryRun = $true; Relay = 'https://relay.example.com' } } | Should -Throw '*goes with -Pair*'
    }

    It 'rejects unknown items and conflicting selections' {
        { Invoke-Installer @{ DryRun = $true; Select = 'bogus' } } | Should -Throw '*unknown item*'
        { Invoke-Installer @{ DryRun = $true; Select = 'host'; Only = 'host' } } | Should -Throw '*mutually exclusive*'
        { Invoke-Installer @{ DryRun = $true; CliOnly = $true; Select = 'spaces' } } | Should -Throw '*use -Only spaces*'
        { Invoke-Installer @{ DryRun = $true; NoHost = $true; Select = 'host' } } | Should -Throw '*-NoHost and -Select host contradict*'
    }
}
