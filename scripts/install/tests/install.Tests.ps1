# Pester 5 tests for install.ps1. Hermetic: no real installs.
#   pwsh -c "Invoke-Pester scripts/install/tests -Output Detailed"

BeforeAll {
    $script:Installer = (Resolve-Path (Join-Path $PSScriptRoot '..' 'install.ps1')).Path
    $env:CUA_INSTALL_NO_RUN = '1'
    . $script:Installer
    $env:CUA_INSTALL_NO_RUN = $null
}

Describe 'install.ps1' {
    It 'has no release download path' {
        $source = Get-Content -Raw -LiteralPath $script:Installer
        $source | Should -Not -Match 'releases/download'
        $source | Should -Not -Match 'cua\.ai/install'
        $source | Should -Not -Match 'Invoke-WebRequest'
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
    }

    It 'skips the app when there is no Windows source build' {
        $sel = Get-CuaSelection -SelectList 'spaces'
        $sel.spaces | Should -Be $false
        { Get-CuaSelection -App $true } | Should -Throw '*no source build for Windows*'
    }

    It 'adds host setup for a pairing code' {
        $saved = $script:Pair
        try {
            $script:Pair = 'K7QM-4XPB-2RHD'
            (Get-CuaSelection).host | Should -Be $true
        } finally {
            $script:Pair = $saved
        }
    }

    It 'installs under -Prefix\bin' {
        $saved = $script:Prefix
        try {
            $script:Prefix = 'C:\cua'
            Get-CliBinDir | Should -Be 'C:\cua\bin'
        } finally {
            $script:Prefix = $saved
        }
    }

    It 'fails outside a checkout with the clone instructions' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("cua-ps-alone-" + [Guid]::NewGuid().ToString('N'))
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
