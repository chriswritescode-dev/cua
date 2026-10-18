#!/bin/sh
# Plain-sh tests for install.sh against a fake checkout and a fake cargo.
# Hermetic: fake HOME, fake cargo/git shims, --prefix temp dirs.
# Nothing touches the real home directory, /Applications or PATH.
#
#   scripts/install/tests/run.sh            # all tests
#   CUA_INSTALL_TEST_SHELL=dash run.sh      # run install.sh under another sh
#
# Needs bash (the driver script) and a POSIX sh.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
installer="$here/../install.sh"
sh_bin="${CUA_INSTALL_TEST_SHELL:-sh}"
work="$(mktemp -d 2>/dev/null || mktemp -d -t cua-install-tests)"
pass=0
fail=0

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
not_ok() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1"
    [ -f "$work/out" ] && sed 's/^/     | /' "$work/out"
}
check() { # name command...
    name="$1"
    shift
    if "$@"; then ok "$name"; else not_ok "$name"; fi
}

# ------------------------------------------------------------ fake checkout

repo="$work/repo"
mkdir -p "$repo/scripts/install" "$repo/libs/cua/target" "$repo/libs/cua-spacesd/target" \
    "$repo/libs/cua-driver/scripts" "$repo/apps/cua-spaces-macos/scripts" "$work/bin"
cp "$installer" "$repo/scripts/install/install.sh"
: >"$repo/libs/cua/Cargo.toml"
: >"$repo/libs/cua-spacesd/Cargo.toml"

cat >"$work/bin/cargo" <<'EOF'
#!/bin/sh
pkg=""
manifest=""
while [ $# -gt 0 ]; do
    case "$1" in
    -p)
        pkg="$2"
        shift
        ;;
    --manifest-path)
        manifest="$2"
        shift
        ;;
    esac
    shift
done
[ -n "$pkg" ] && [ -n "$manifest" ] || {
    echo "cargo shim: missing -p or --manifest-path" >&2
    exit 1
}
dir="$(cd "$(dirname "$manifest")" && pwd)"
case "$pkg" in
cua-cli)
    out="$dir/target/release/cua"
    mkdir -p "$(dirname "$out")"
    cat >"$out" <<'CUA'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo "cua 0.0.0-source"; exit 0; fi
if [ "${1:-} ${2:-} ${3:-}" = "host setup --help" ]; then
    echo "Usage: cua host setup [OPTIONS]"
    [ -n "${CUA_FAKE_NO_PAIR:-}" ] || echo "      --pair <CODE>  add this machine with a code"
    exit 0
fi
echo "$*" >>"${CUA_FAKE_LOG:-/dev/null}"
CUA
    chmod +x "$out"
    ;;
cua-spacesd)
    out="$dir/target/release/cua-spacesd"
    mkdir -p "$(dirname "$out")"
    printf '#!/bin/sh\necho cua-spacesd 0.0.0-source\n' >"$out"
    chmod +x "$out"
    ;;
*)
    echo "cargo shim: unexpected package $pkg" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$work/bin/cargo"

cat >"$repo/libs/cua-driver/scripts/install.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$HOME/driver.log"
bin="$HOME/.local/bin"
while [ $# -gt 0 ]; do
    case "$1" in
    --bin-dir=*) bin="${1#*=}" ;;
    --bin-dir)
        bin="$2"
        shift
        ;;
    esac
    shift
done
mkdir -p "$bin"
printf '#!/bin/sh\necho cua-driver\n' >"$bin/cua-driver-local"
chmod +x "$bin/cua-driver-local"
ln -sf cua-driver-local "$bin/cua-driver"
EOF
chmod +x "$repo/libs/cua-driver/scripts/install.sh"

cat >"$repo/apps/cua-spaces-macos/scripts/build-release.sh" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in
    --out) out="$2"; shift ;;
    --out=*) out="${1#*=}" ;;
    esac
    shift
done
mkdir -p "$out/Cua Spaces.app/Contents/MacOS"
printf '#!/bin/sh\n' >"$out/Cua Spaces.app/Contents/MacOS/cua-spaces"
chmod +x "$out/Cua Spaces.app/Contents/MacOS/cua-spaces"
EOF
chmod +x "$repo/apps/cua-spaces-macos/scripts/build-release.sh"

mkdir -p "$work/fakebin-macos26"
printf '#!/bin/sh\necho 26.0\n' >"$work/fakebin-macos26/sw_vers"
chmod +x "$work/fakebin-macos26/sw_vers"

# ------------------------------------------------------------ harness

RANDOM_SEQ=0
# inst [ENV=VAL ...] -- ARGS: run install.sh with a fresh fake HOME.
inst() {
    home="$work/home.$RANDOM_SEQ"
    RANDOM_SEQ=$((RANDOM_SEQ + 1))
    mkdir -p "$home"
    envs=""
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        envs="$envs $1"
        shift
    done
    [ "${1:-}" = -- ] && shift
    # shellcheck disable=SC2086
    env -i PATH="$work/bin:$PATH" HOME="$home" SHELL=/bin/sh TERM=dumb \
        CUA_INSTALL_OS=linux CUA_INSTALL_ARCH=x86_64 CUA_FAKE_LOG="$home/cua.log" $envs \
        "$sh_bin" "$repo/scripts/install/install.sh" "$@" </dev/null >"$work/out" 2>&1
    status=$?
    return 0
}
has_out() { grep -q "$1" "$work/out"; }
exists() { [ -e "$1" ]; }
absent() { [ ! -e "$1" ]; }

# ------------------------------------------------------------ tests

inst -- --yes --no-onboarding --prefix "$work/p1"
check "linux: exits 0" [ "$status" = 0 ]
check "linux: installs cua under --prefix/bin" exists "$work/p1/bin/cua"
check "linux: installs cua-spacesd next to cua" exists "$work/p1/bin/cua-spacesd"
check "installed cua runs" sh -c "'$work/p1/bin/cua' --version | grep -q 'cua 0.0.0-source'"
check "linux: no app build" absent "$work/p1/Applications"
check "non-interactive: prints next steps, no login" sh -c "grep -q 'cua auth login' '$work/out' && [ ! -e '$home/cua.log' ]"
check "prefix bin not on PATH: prints a hint" has_out "is not on your PATH"
check "no --modify-path: profile untouched" absent "$home/.profile"
check "prints the checkout and both builds" sh -c "grep -q 'checkout $repo' '$work/out' && grep -q 'building the cua CLI' '$work/out' && grep -q 'building cua-spacesd' '$work/out'"

inst -- --yes --cli-only --modify-path --prefix "$work/p2"
check "--modify-path writes the profile" sh -c "grep -q '$work/p2/bin' '$home/.profile'"
first_home="$home"
env -i PATH="$work/bin:$PATH" HOME="$first_home" SHELL=/bin/sh CUA_INSTALL_OS=linux \
    "$sh_bin" "$repo/scripts/install/install.sh" --yes --cli-only --modify-path --prefix "$work/p2" </dev/null >"$work/out" 2>&1
check "--modify-path is idempotent" [ "$(grep -c "$work/p2/bin" "$first_home/.profile")" = 1 ]

inst SHELL=/bin/zsh -- --yes --cli-only --modify-path --prefix "$work/p3"
check "--modify-path picks .zshrc for zsh" sh -c "grep -q '$work/p3/bin' '$home/.zshrc'"

inst -- --yes --cli-only --no-modify-path --prefix "$work/p4"
check "--no-modify-path: profile untouched, hint printed" sh -c "[ $status = 0 ] && grep -q 'is not on your PATH' '$work/out' && [ ! -e '$home/.profile' ]"

if command -v bash >/dev/null 2>&1; then
inst -- --yes --only cua-driver --prefix "$work/d1"
check "--only cua-driver: runs the driver installer with the shared bin dir" sh -c "[ $status = 0 ] && grep -qx -- '--bin-dir $work/d1/bin' '$home/driver.log'"
check "--only cua-driver: installs cua-driver-local" exists "$work/d1/bin/cua-driver-local"
check "--only cua-driver: links cua-driver next to it" sh -c "[ -L '$work/d1/bin/cua-driver' ] && [ \"\$(readlink '$work/d1/bin/cua-driver')\" = cua-driver-local ]"
check "--only cua-driver: registers the skill and MCP server" sh -c "grep -qx -- 'agents setup --cua-driver --agents all --yes --mcp-command $work/d1/bin/cua-driver' '$home/cua.log'"
check "--only cua-driver: no host setup" sh -c "! grep -q 'host setup' '$home/cua.log'"
else
printf 'skip cua-driver install (needs bash)\n'
fi

inst CUA_INSTALL_NONINTERACTIVE=1 -- --select host --no-onboarding --prefix "$work/h1"
check "CUA_INSTALL_NONINTERACTIVE + --select host: runs 'cua host setup'" sh -c "[ $status = 0 ] && grep -qx 'host setup' '$home/cua.log'"

inst -- --yes --only host --prefix "$work/h2"
check "--only host: runs 'cua host setup'" sh -c "[ $status = 0 ] && grep -qx 'host setup' '$home/cua.log'"

inst -- --pair k7qm-4xpb-2rhd --prefix "$work/pr1"
check "--pair: runs 'cua host setup --pair', no sign-in, no checklist" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair k7qm-4xpb-2rhd' '$home/cua.log' && ! grep -q 'auth login' '$home/cua.log' && grep -q 'This machine is added' '$work/out'"

inst CUA_FAKE_NO_PAIR=1 -- --pair K7QM-4XPB-2RHD --prefix "$work/pr0"
check "--pair: a CLI without 'host setup --pair' fails early" sh -c "[ $status != 0 ] && grep -q \"no 'cua host setup --pair'\" '$work/out'"

inst -- --pair K7QM-4XPB-2RHD --relay https://relay.example.com --cli-only --prefix "$work/pr2"
check "--pair --relay --cli-only: passes the relay on" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair K7QM-4XPB-2RHD --relay https://relay.example.com' '$home/cua.log'"

inst -- --pair 'K7QM;rm -rf /' --prefix "$work/pr3"
check "--pair: refuses a code with shell characters" sh -c "[ $status != 0 ] && grep -q 'not a pairing code' '$work/out' && [ ! -e '$work/pr3/bin/cua' ]"

inst -- --pair K7QM-4XPB-2RHD --relay http://evil.example --prefix "$work/pr4"
check "--pair: refuses a plain-http relay" sh -c "[ $status != 0 ] && grep -q 'must be an https' '$work/out'"

inst -- --pair K7QM-4XPB-2RHD --relay http://127.0.0.1:8080 --prefix "$work/pr5"
check "--pair: allows a local plain-http relay" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair K7QM-4XPB-2RHD --relay http://127.0.0.1:8080' '$home/cua.log'"

seed="$work/seed/bin"
mkdir -p "$seed"
cp "$repo/libs/cua/target/release/cua" "$seed/cua"
inst PATH="$seed:$work/bin:$PATH" -- --pair K7QM-4XPB-2RHD
check "--pair with Cua installed: uses it, builds nothing" sh -c "[ $status = 0 ] && grep -q 'already installed at $seed/cua' '$work/out' && grep -qx 'host setup --pair K7QM-4XPB-2RHD' '$home/cua.log' && [ ! -e '$home/.local/bin/cua' ]"

inst -- --yes --select bogus
check "unknown item is an error listing the ids" sh -c "[ $status != 0 ] && grep -q \"unknown item 'bogus' (valid: cli, spaces, cua-driver, host)\" '$work/out'"
inst -- --yes --only host --select cua-driver
check "--only with --select is an error" sh -c "[ $status != 0 ] && grep -q 'mutually exclusive' '$work/out'"
inst -- --yes --cli-only --select spaces
check "--cli-only with --select spaces is an error" sh -c "[ $status != 0 ] && grep -q 'use --only spaces' '$work/out'"
inst -- --yes --app-only --only cua-driver
check "--app-only with cua-driver is an error" sh -c "[ $status != 0 ] && grep -q 'cua-driver and host need' '$work/out'"
inst -- --select
check "--select needs a value" sh -c "[ $status != 0 ] && grep -q 'needs a list' '$work/out'"
inst -- --bogus
check "unknown option is an error" sh -c "[ $status != 0 ] && grep -q 'unknown option' '$work/out'"

inst -- --yes --app-only --prefix "$work/a1"
check "--app-only on Linux: fails with the app build guidance" sh -c "[ $status != 0 ] && grep -q 'no source build for linux' '$work/out'"

inst -- --dry-run --yes --cli-only --prefix "$work/dr"
check "--dry-run prints both builds and nothing else" sh -c "[ $status = 0 ] && grep -q -- 'dry-run. cargo build --release -p cua-cli' '$work/out' && grep -q -- 'dry-run. cargo build --release -p cua-spacesd' '$work/out' && [ ! -e '$work/dr' ] && [ ! -e '$home/cua.log' ]"

inst CUA_INSTALL_OS=Darwin PATH="$work/fakebin-macos26:$work/bin:$PATH" -- --dry-run --yes --prefix "$work/m1"
check "macOS dry run: plans the CLI, spacesd and the app" sh -c "[ $status = 0 ] && grep -q -- 'build-release.sh --out' '$work/out' && grep -q 'Cua Spaces.app' '$work/out'"

inst CUA_INSTALL_OS=Darwin PATH="$work/fakebin-macos26:$work/bin:$PATH" -- --yes --no-onboarding --prefix "$work/m2"
check "macOS: builds and installs Cua Spaces.app" sh -c "[ $status = 0 ] && [ -x '$work/m2/Applications/Cua Spaces.app/Contents/MacOS/cua-spaces' ] && [ -e '$work/m2/bin/cua-spacesd' ]"

inst CUA_INSTALL_OS=Darwin -- --yes --mode client --prefix "$work/m3"
check "macOS: --mode writes the install-mode file" sh -c "[ $status = 0 ] && grep -q client '$home/.cua/spaces-install-mode'"

inst -- --yes --mode server
check "--mode rejects other values" sh -c "[ $status != 0 ] && grep -q 'host or client' '$work/out'"

inst -- --cli-only --app-only
check "--cli-only with --app-only is an error" sh -c "[ $status != 0 ] && grep -q 'mutually exclusive' '$work/out'"

# Not a checkout: the script alone in a temp dir.
mkdir -p "$work/alone"
cp "$installer" "$work/alone/install.sh"
env -i PATH="$work/bin:$PATH" HOME="$work/home-elsewhere" SHELL=/bin/sh "$sh_bin" "$work/alone/install.sh" --yes </dev/null >"$work/out" 2>&1
status=$?
check "outside a checkout: fails with the clone instructions" sh -c "[ $status != 0 ] && grep -q 'chriswritescode-dev/cua.git' '$work/out' && grep -q 'git checkout local-build' '$work/out'"

# Piped from a shell's stdin: no checkout path to resolve.
env -i PATH="$work/bin:$PATH" HOME="$work/home-piped" SHELL=/bin/sh "$sh_bin" -s -- --yes <"$installer" >"$work/out" 2>&1
status=$?
check "piped install: fails with the clone instructions" sh -c "[ $status != 0 ] && grep -q 'source checkout' '$work/out'"

inst -- --help
check "--help prints usage" sh -c "[ $status = 0 ] && grep -q -- '--cli-only' '$work/out' && grep -q 'git clone https://github.com/chriswritescode-dev/cua.git' '$work/out'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
