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
RANDOM_SEQ=0

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

# A cargo shim that writes the binary the installer expects to install,
# honouring CARGO_TARGET_DIR the way cargo does.
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
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    case "$CARGO_TARGET_DIR" in
    /*) root="$CARGO_TARGET_DIR" ;;
    *) root="$(pwd)/$CARGO_TARGET_DIR" ;;
    esac
else
    root="$(cd "$(dirname "$manifest")" && pwd)/target"
fi
case "$pkg" in
cua-cli)
    out="$root/release/cua"
    mkdir -p "$(dirname "$out")"
    cat >"$out" <<'CUA'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo "cua 0.0.0-source"; exit 0; fi
case "$*" in
"host setup --help")
    echo "Usage: cua host setup [OPTIONS]"
    [ -n "${CUA_FAKE_NO_PAIR:-}" ] || echo "      --pair <CODE>  add this machine with a code"
    [ -n "${CUA_FAKE_HAS_NO_DESKTOP:-}" ] || echo "      --no-desktop   keep the screen private"
    exit 0
    ;;
"host status --json")
    [ -n "${CUA_FAKE_CONFIGURED:-}" ] && echo '{"configured":true}'
    exit 0
    ;;
"runtime doctor")
    echo 'runtime doctor diagnostic'
    exit "${CUA_FAKE_DOCTOR_STATUS:-0}"
    ;;
"runtime setup qemu")
    echo "$*" >>"${CUA_FAKE_LOG:-/dev/null}"
    if [ -n "${CUA_FAKE_QEMU_DIR:-}" ]; then
        for t in qemu-img "qemu-system-$(uname -m)"; do
            printf '#!/bin/sh\n' >"$CUA_FAKE_QEMU_DIR/$t" && chmod +x "$CUA_FAKE_QEMU_DIR/$t"
        done
    fi
    exit "${CUA_FAKE_RUNTIME_STATUS:-0}"
    ;;
"daemon status")
    [ -n "${CUA_FAKE_DAEMON_VERSION:-}" ] && echo "cua daemon $CUA_FAKE_DAEMON_VERSION (pid 4242) socket=/x"
    echo "$*" >>"${CUA_FAKE_LOG:-/dev/null}"
    exit 0
    ;;
esac
echo "$*" >>"${CUA_FAKE_LOG:-/dev/null}"
CUA
    chmod +x "$out"
    ;;
cua-spacesd)
    out="$root/release/cua-spacesd"
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

# A cua-driver installer that logs its flags and installs cua-driver-local plus
# the cua-driver symlink, as install-local does.
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

# The Cua Spaces app build, as apps/cua-spaces-macos/scripts/build-release.sh.
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

mkdir -p "$work/fakebin-macos26" "$work/fakebin-macos14"
printf '#!/bin/sh\necho 26.0\n' >"$work/fakebin-macos26/sw_vers"
printf '#!/bin/sh\necho 14.8\n' >"$work/fakebin-macos14/sw_vers"
chmod +x "$work/fakebin-macos26/sw_vers" "$work/fakebin-macos14/sw_vers"

# A VM runtime, so a plain Linux install needs no QEMU setup.
mkdir -p "$work/qemu" "$work/host-bin"
for f in $(printf '%s' "$PATH" | tr ':' '\n' | sed 's#$#/*#'); do
    case "${f##*/}" in qemu* | docker) continue ;; esac
    [ -x "$f" ] && [ ! -e "$work/host-bin/${f##*/}" ] && ln -s "$f" "$work/host-bin/${f##*/}"
done
for t in qemu-img "qemu-system-$(uname -m)"; do printf '#!/bin/sh\n' >"$work/qemu/$t"; done
chmod +x "$work/qemu"/*
run_path="$work/bin:$work/qemu:$PATH"

# ------------------------------------------------------------ harness

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
    env -i PATH="$run_path" HOME="$home" SHELL=/bin/sh TERM=dumb CUA_HOME="$home/.cua" \
        CUA_INSTALL_OS=linux CUA_INSTALL_ARCH=x86_64 \
        CUA_FAKE_LOG="$home/cua.log" $envs \
        "$sh_bin" "$repo/scripts/install/install.sh" "$@" </dev/null >"$work/out" 2>&1
    status=$?
    return 0
}
has_out() { grep -q "$1" "$work/out"; }
exists() { [ -e "$1" ]; }
absent() { [ ! -e "$1" ]; }

# ------------------------------------------------------------ install

inst -- --yes --no-onboarding --verbose --prefix "$work/p1"
check "linux: exits 0" [ "$status" = 0 ]
check "linux: installs cua under --prefix/bin" exists "$work/p1/bin/cua"
check "linux: installs cua-spacesd next to cua" exists "$work/p1/bin/cua-spacesd"
check "installed cua runs" sh -c "'$work/p1/bin/cua' --version | grep -q 'cua 0.0.0-source'"
check "linux: no app build" absent "$work/p1/Applications"
check "builds both the CLI and cua-spacesd" sh -c "grep -q 'Building the cua CLI' '$work/out' && grep -q 'Building cua-spacesd' '$work/out'"
check "--verbose shows the checkout" sh -c "grep -q 'checkout $repo' '$work/out'"
check "non-interactive: prints next steps, no login" sh -c "grep -q 'cua auth login' '$work/out' && [ ! -e '$home/cua.log' ] || ! grep -q 'auth login' '$home/cua.log'"
check "prefix bin not on PATH: prints a hint" has_out "is not on your PATH"
check "no --modify-path: profile untouched" absent "$home/.profile"

inst CUA_INSTALL_VERBOSE=1 -- --yes --no-onboarding --cli-only --prefix "$work/p1v"
check "CUA_INSTALL_VERBOSE=1 is --verbose" has_out "^cua-install: platform linux-x64, checkout "

inst -- --yes --cli-only --modify-path --prefix "$work/p2"
check "--modify-path writes the profile" sh -c "grep -q '$work/p2/bin' '$home/.profile'"
first_home="$home"
env -i PATH="$run_path" HOME="$first_home" SHELL=/bin/sh CUA_HOME="$first_home/.cua" CUA_INSTALL_OS=linux \
    "$sh_bin" "$repo/scripts/install/install.sh" --yes --cli-only --modify-path --prefix "$work/p2" \
    </dev/null >"$work/out" 2>&1
check "--modify-path is idempotent" [ "$(grep -c "$work/p2/bin" "$first_home/.profile")" = 1 ]

inst SHELL=/bin/zsh -- --yes --cli-only --modify-path --prefix "$work/p3"
check "--modify-path picks .zshrc for zsh" sh -c "grep -q '$work/p3/bin' '$home/.zshrc'"

inst -- --yes --cli-only --no-modify-path --prefix "$work/p4"
check "--no-modify-path: profile untouched, hint printed" sh -c "[ $status = 0 ] && grep -q 'is not on your PATH' '$work/out' && [ ! -e '$home/.profile' ]"

# CARGO_TARGET_DIR is honoured the way cargo honours it.
inst CARGO_TARGET_DIR="$work/ctd" -- --yes --cli-only --prefix "$work/p5"
check "CARGO_TARGET_DIR: binaries come from there" sh -c "[ $status = 0 ] && [ -x '$work/ctd/release/cua' ] && [ -x '$work/p5/bin/cua' ]"

# ------------------------------------------------------------ cua-driver

if command -v bash >/dev/null 2>&1; then
    inst -- --yes --only cua-driver --prefix "$work/d1"
    check "--only cua-driver: driver installer gets the shared bin dir" sh -c "[ $status = 0 ] && grep -qx -- '--bin-dir $work/d1/bin' '$home/driver.log'"
    check "--only cua-driver: installs cua-driver-local" exists "$work/d1/bin/cua-driver-local"
    check "--only cua-driver: links cua-driver next to it" sh -c "[ -L '$work/d1/bin/cua-driver' ] && [ \"\$(readlink '$work/d1/bin/cua-driver')\" = cua-driver-local ]"
    check "--only cua-driver: registers the skill and MCP server" sh -c "grep -qx -- 'agents setup --cua-driver --agents all --yes --mcp-command $work/d1/bin/cua-driver' '$home/cua.log'"
    check "--only cua-driver: no host setup" sh -c "! grep -q 'host setup' '$home/cua.log'"
    check "--only cua-driver: no sign-in" sh -c "! grep -q 'auth login' '$home/cua.log' 2>/dev/null"

    inst -- --yes --only cua-driver --no-skills --prefix "$work/d1s"
    check "--no-skills: registers the MCP server without the skill" sh -c "grep -qx -- 'agents setup --cua-driver --agents all --yes --no-skills --mcp-command $work/d1s/bin/cua-driver' '$home/cua.log'"
else
    printf 'skip cua-driver install (needs bash)\n'
fi

# ------------------------------------------------------------ host

inst CUA_INSTALL_NONINTERACTIVE=1 -- --select host --no-onboarding --prefix "$work/h1"
check "CUA_INSTALL_NONINTERACTIVE + --select host: runs 'cua host setup'" sh -c "[ $status = 0 ] && grep -qx 'host setup' '$home/cua.log'"
check "--select host: the app's first-run choice decides how it provides Spaces" sh -c "! grep -q -- '--provide-spaces' '$home/cua.log'"

inst -- --yes --only host --prefix "$work/h2"
check "--only host: runs 'cua host setup', no app" sh -c "[ $status = 0 ] && grep -qx 'host setup' '$home/cua.log' && [ ! -e '$work/h2/bin/cua-spaces' ]"
check "--only host: says the computer is added" has_out "This computer is added to your account."

inst -- --yes --no-onboarding --only host --no-provide-spaces --prefix "$work/h3"
check "--only host --no-provide-spaces: passes it on" sh -c "[ $status = 0 ] && grep -qx 'host setup --no-provide-spaces' '$home/cua.log'"

inst -- --yes --cli-only --no-host --pair K7QM-4XPB-2RHD --prefix "$work/nh1"
check "--no-host with --pair: refused" sh -c "[ $status != 0 ] && grep -q -- '--no-host and --pair contradict' '$work/out'"
inst -- --yes --no-host --only host --prefix "$work/nh2"
check "--no-host with --only host: refused" sh -c "[ $status != 0 ] && grep -q -- '--no-host and --select host contradict' '$work/out'"
inst -- --yes --cli-only --no-host --no-provide-spaces --prefix "$work/nh3"
check "--no-provide-spaces with --no-host: refused" sh -c "[ $status != 0 ] && grep -q -- '--no-provide-spaces goes with adding this computer' '$work/out'"

# ------------------------------------------------------------ pairing

inst -- --pair k7qm-4xpb-2rhd --prefix "$work/pr1"
check "--pair: runs 'cua host setup --pair', no sign-in, no checklist" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair k7qm-4xpb-2rhd --no-desktop --provide-spaces' '$home/cua.log' && ! grep -q 'auth login' '$home/cua.log' && grep -q 'This machine is added' '$work/out'"

inst CUA_FAKE_NO_PAIR=1 -- --pair K7QM-4XPB-2RHD --prefix "$work/pr0"
check "--pair: a CLI without 'host setup --pair' fails early" sh -c "[ $status != 0 ] && grep -q \"no 'cua host setup --pair'\" '$work/out'"

inst -- --pair K7QM-4XPB-2RHD --relay https://relay.example.com --cli-only --prefix "$work/pr2"
check "--pair --relay --cli-only: passes the relay on" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair K7QM-4XPB-2RHD --relay https://relay.example.com --no-desktop --provide-spaces' '$home/cua.log'"

inst -- --pair 'K7QM;rm -rf /' --prefix "$work/pr3"
check "--pair: refuses a code with shell characters" sh -c "[ $status != 0 ] && grep -q 'not a pairing code' '$work/out' && [ ! -e '$work/pr3/bin/cua' ]"

inst -- --pair K7QM-4XPB-2RHD --relay http://evil.example --prefix "$work/pr4"
check "--pair: refuses a plain-http relay" sh -c "[ $status != 0 ] && grep -q 'must be an https' '$work/out'"

inst -- --pair K7QM-4XPB-2RHD --relay http://127.0.0.1:8080 --prefix "$work/pr5"
check "--pair: allows a local plain-http relay" sh -c "[ $status = 0 ] && grep -qx 'host setup --pair K7QM-4XPB-2RHD --relay http://127.0.0.1:8080 --no-desktop --provide-spaces' '$home/cua.log'"

seed="$work/seed/bin"
mkdir -p "$seed"
cp "$repo/libs/cua/target/release/cua" "$seed/cua"
inst PATH="$seed:$run_path" -- --pair K7QM-4XPB-2RHD
check "--pair with Cua installed: uses it, builds nothing" sh -c "[ $status = 0 ] && grep -q 'already installed at $seed/cua' '$work/out' && grep -qx 'host setup --pair K7QM-4XPB-2RHD --no-desktop --provide-spaces' '$home/cua.log' && [ ! -e '$home/.local/bin/cua' ]"

# ------------------------------------------------------------ arguments

inst -- --yes --select bogus
check "unknown item is an error listing the ids" sh -c "[ $status != 0 ] && grep -q \"unknown item 'bogus' (valid: cli, spaces, cua-driver, host)\" '$work/out'"
inst -- --yes --only host --select cua-driver
check "--only with --select is an error" sh -c "[ $status != 0 ] && grep -q 'mutually exclusive' '$work/out'"
inst -- --yes --cli-only --select spaces
check "--cli-only with --select spaces is an error" sh -c "[ $status != 0 ] && grep -q 'use --only spaces' '$work/out'"
inst -- --yes --app-only --only cua-driver
check "--app-only with cua-driver is an error" sh -c "[ $status != 0 ] && grep -q 'cua-driver and host need' '$work/out'"
inst -- --cli-only --app-only
check "--cli-only with --app-only is an error" sh -c "[ $status != 0 ] && grep -q 'mutually exclusive' '$work/out'"
inst -- --yes --mode server
check "--mode rejects other values" sh -c "[ $status != 0 ] && grep -q 'host or client' '$work/out'"
inst -- --select
check "--select needs a value" sh -c "[ $status != 0 ] && grep -q 'needs a list' '$work/out'"
inst -- --bogus
check "unknown option is an error" sh -c "[ $status != 0 ] && grep -q 'unknown option' '$work/out'"
inst -- --yes --version 1.2.3
check "--version is gone (no release downloads)" sh -c "[ $status != 0 ] && grep -q 'unknown option' '$work/out'"
inst CUA_INSTALL_ARCH=mips -- --yes
check "unsupported arch fails" sh -c "[ $status != 0 ] && grep -q 'unsupported CPU architecture' '$work/out'"
inst CUA_INSTALL_OS=MINGW64_NT-10.0 -- --yes
check "Windows shells point at install.ps1" sh -c "[ $status != 0 ] && grep -q install.ps1 '$work/out'"

inst -- --yes --app-only --prefix "$work/a1"
check "--app-only on Linux: fails with the app build guidance" sh -c "[ $status != 0 ] && grep -q 'no source build for linux' '$work/out'"

# ------------------------------------------------------------ dry run

inst -- --dry-run --yes --cli-only --prefix "$work/dr"
check "--dry-run prints both builds and nothing else" sh -c "[ $status = 0 ] && grep -q -- 'dry-run. cargo build --release -p cua-cli' '$work/out' && grep -q -- 'dry-run. cargo build --release -p cua-spacesd' '$work/out' && [ ! -e '$work/dr' ] && [ ! -e '$home/cua.log' ]"
inst -- --dry-run --yes --select cua-driver,host --prefix "$work/drd"
check "--dry-run lists the planned items and steps" sh -c "grep -q 'dry-run. would install: the cua command-line tools, Cua Driver' '$work/out' && grep -q 'dry-run. bash .*libs/cua-driver/scripts/install.sh --bin-dir' '$work/out' && grep -q 'dry-run. .* host setup' '$work/out' && [ ! -e '$home/driver.log' ]"

# ------------------------------------------------------------ runtime (Linux)

mkdir -p "$work/qemu-r1" "$work/qemu-r2" "$work/qemu-r3"
inst PATH="$work/bin:$work/qemu-r1:$work/host-bin" CUA_FAKE_QEMU_DIR="$work/qemu-r1" -- --yes --no-onboarding --prefix "$work/r1"
check "no VM runtime: installs QEMU and finishes" sh -c "[ $status = 0 ] && grep -qx 'runtime setup qemu' '$home/cua.log' && grep -q 'runtime doctor diagnostic' '$work/out' && [ -x '$work/r1/bin/cua' ]"
inst PATH="$work/bin:$work/qemu-r2:$work/host-bin" CUA_FAKE_QEMU_DIR="$work/qemu-r2" CUA_FAKE_RUNTIME_STATUS=1 -- --yes --no-onboarding --prefix "$work/r2"
check "VM runtime setup fails: says how to fix it and exits 1" sh -c "[ $status = 1 ] && grep -q 'needs QEMU or Docker; install QEMU with: sudo .* install -y qemu' '$work/out' && [ -x '$work/r2/bin/cua' ]"
inst PATH="$work/bin:$work/qemu-r3:$work/host-bin" -- --dry-run --no-onboarding --prefix "$work/r3"
check "VM runtime missing, --dry-run: prints the setup only" sh -c "[ $status = 0 ] && grep -q 'dry-run. $work/r3/bin/cua runtime setup qemu' '$work/out' && [ ! -e '$work/r3' ]"
inst CUA_FAKE_DOCTOR_STATUS=1 -- --yes --no-onboarding --prefix "$work/r4"
check "doctor-only failure finishes the installation" sh -c "[ $status = 1 ] && grep -q 'runtime doctor diagnostic' '$work/out' && grep -q '^Next:' '$work/out' && [ -x '$work/r4/bin/cua' ]"

# ------------------------------------------------------------ daemon restart

mkdir -p "$work/up/bin"
cat >"$work/up/bin/cua" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo "cua 0.0.9 (old)"; exit 0; fi
if [ "${1:-} ${2:-}" = "daemon status" ]; then echo "cua daemon 0.0.9 (pid 4242) socket=/x"; exit 0; fi
exit 0
EOF
chmod +x "$work/up/bin/cua"
inst -- --yes --no-onboarding --cli-only --prefix "$work/up"
check "upgrade over a running older daemon: stops it with the new cua, then starts it" sh -c "[ $status = 0 ] && grep -qx 'daemon stop' '$home/cua.log' && grep -qx 'daemon start' '$home/cua.log' && grep -q 'restarted the cua daemon (0.0.9 -> 0.0.0-source)' '$work/out'"
inst -- --yes --no-onboarding --cli-only --prefix "$work/fresh"
check "fresh install (no daemon): no daemon stop or start" sh -c "[ $status = 0 ] && ! grep -q 'daemon' '$home/cua.log' 2>/dev/null"

# ------------------------------------------------------------ macOS

inst CUA_INSTALL_OS=Darwin -- --dry-run --yes --prefix "$work/m1"
check "macOS dry run: plans the CLI, spacesd and the app" sh -c "[ $status = 0 ] && grep -q -- 'build-release.sh --out' '$work/out' && grep -q 'Cua Spaces.app' '$work/out'"
if command -v bash >/dev/null 2>&1; then
    inst CUA_INSTALL_OS=Darwin -- --yes --no-onboarding --prefix "$work/m2"
    check "macOS: builds and installs Cua Spaces.app" sh -c "[ $status = 0 ] && [ -x '$work/m2/Applications/Cua Spaces.app/Contents/MacOS/cua-spaces' ] && [ -e '$work/m2/bin/cua-spacesd' ]"
    inst CUA_INSTALL_OS=Darwin -- --yes --mode client --prefix "$work/m3"
    check "macOS: --mode writes the install-mode file" sh -c "[ $status = 0 ] && grep -q client '$home/.cua/spaces-install-mode'"
else
    printf 'skip the Cua Spaces app build (needs bash)\n'
fi

# ------------------------------------------------------------ quiet output

inst -- --yes --no-onboarding --cli-only --prefix "$work/q1"
check "quiet default: no cua-install: lines" sh -c "[ $status = 0 ] && ! grep -q '^cua-install:' '$work/out'"
check "quiet default: closes with what was installed" has_out "^Installed the command-line tools (built from source)\.\$"
check "quiet default: says what to do next" sh -c "grep -q '^Next: run \"cua auth login\" to sign in, then \"cua agents setup\"' '$work/out' && grep -q 'To add this computer to your account, run \"cua host setup\" after signing in.' '$work/out'"
check "quiet default: the PATH hint comes last" sh -c "tail -4 '$work/out' | grep -q 'is not on your PATH'"
check "quiet default: no release jargon" sh -c "! grep -qi 'cosign\|minisign\|sha256\|checksum\|manifest\|downloading' '$work/out'"
check "quiet default: no install telemetry" sh -c "! grep -qi 'anonymous data\|telemetry' '$work/out'"

# ------------------------------------------------------------ outside a checkout

mkdir -p "$work/alone"
cp "$installer" "$work/alone/install.sh"
env -i PATH="$run_path" HOME="$work/home-elsewhere" SHELL=/bin/sh \
    "$sh_bin" "$work/alone/install.sh" --yes </dev/null >"$work/out" 2>&1
status=$?
check "outside a checkout: fails with the clone instructions" sh -c "[ $status != 0 ] && grep -q 'chriswritescode-dev/cua.git' '$work/out' && grep -q 'git checkout local-build' '$work/out'"

env -i PATH="$run_path" HOME="$work/home-piped" SHELL=/bin/sh \
    "$sh_bin" -s -- --yes <"$installer" >"$work/out" 2>&1
status=$?
check "piped install: fails with the clone instructions" sh -c "[ $status != 0 ] && grep -q 'source checkout' '$work/out'"

inst -- --help
check "--help prints usage" sh -c "[ $status = 0 ] && grep -q -- '--cli-only' '$work/out' && grep -q 'git clone https://github.com/chriswritescode-dev/cua.git' '$work/out'"

# ------------------------------------------------------------ interactive

if script --version 2>/dev/null | grep -q util-linux && command -v timeout >/dev/null 2>&1; then
    pty_inst() { # KEYS ARGS...
        keys="$1"
        shift
        home="$work/home.tty.$RANDOM_SEQ"
        RANDOM_SEQ=$((RANDOM_SEQ + 1))
        mkdir -p "$home"
        (
            sleep 2
            printf '%b' "$keys"
            sleep 3
        ) | env -i PATH="$run_path" HOME="$home" SHELL=/bin/sh TERM="${tty_term:-xterm}" \
            CUA_HOME="$home/.cua" CUA_INSTALL_OS=linux CUA_INSTALL_ARCH=x86_64 \
            CUA_FAKE_LOG="$home/cua.log" \
            timeout 60 script -qec "$sh_bin '$repo/scripts/install/install.sh' --no-onboarding --no-modify-path $*" /dev/null \
            >"$work/out" 2>&1
        status=$?
    }
    tty_term=xterm
    pty_inst '\r' --prefix "$work/t1"
    check "checklist: says what Cua Spaces is and what is always installed" sh -c "grep -q 'Cua Spaces lets your AI agents use computers' '$work/out' && grep -q 'Needed, so always installed:' '$work/out'"
    check "checklist: Enter accepts the defaults (CLI only on Linux)" sh -c "[ $status = 0 ] && [ -e '$work/t1/bin/cua' ] && [ ! -e '$work/t1/bin/cua-driver' ] && ! grep -q 'host setup' '$home/cua.log' 2>/dev/null"
    pty_inst '1\r' --prefix "$work/t2"
    check "checklist: number key toggles cua-driver on" sh -c "[ $status = 0 ] && [ -e '$work/t2/bin/cua-driver' ] && grep -q 'agents setup --cua-driver' '$home/cua.log'"
    pty_inst '\r' --yes --select host --prefix "$work/t3"
    check "checklist: --yes skips it" sh -c "[ $status = 0 ] && ! grep -q 'Choose what else to add' '$work/out' && grep -qx 'host setup' '$home/cua.log'"
else
    printf 'skip interactive checklist (needs util-linux script and timeout)\n'
fi

if [ "$(uname -s)" = Darwin ]; then
    inst PATH="$work/fakebin-macos26:$run_path" CUA_INSTALL_OS= -- --yes --app-only --prefix "$work/p15"
    check "macOS 26: builds the app into --prefix/Applications" exists "$work/p15/Applications/Cua Spaces.app/Contents/MacOS/cua-spaces"
    inst PATH="$work/fakebin-macos14:$run_path" CUA_INSTALL_OS= -- --yes --app-only --prefix "$work/p14"
    check "macOS 14: skips the app (needs macOS 26)" sh -c "[ $status = 0 ] && grep -q 'needs macOS 26 or later' '$work/out' && [ ! -e '$work/p14/Applications/Cua Spaces.app' ]"
else
    printf 'skip macOS version check (not macOS)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
