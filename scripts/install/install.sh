#!/bin/sh
# Cua source installer: build and install the `cua` CLI, cua-spacesd and agent
# extras from this repository checkout.
#
# Run it from a checkout of the fork:
#
#   git clone https://github.com/chriswritescode-dev/cua.git
#   cd cua
#   git checkout local-build
#   scripts/install/install.sh
#   scripts/install/install.sh --select cua-driver
#   scripts/install/install.sh --cli-only --yes
#   scripts/install/install.sh --pair K7QM-4XPB-2RHD
#
# In a terminal it shows a checklist of what to install. Items:
#   cli         the cua CLI and cua-spacesd (always, except with --app-only)
#   spaces      the Cua Spaces app (macOS only; default on there)
#   cua-driver  cua-driver MCP and skill for your agents (default off)
#   host        host this machine: `cua host setup` (default off)
#
# Options:
#   --select LIST       preselect items (comma list, e.g. cua-driver,host)
#   --only LIST         install exactly LIST plus the CLI, no checklist
#   --cli-only          install only the `cua` CLI (same as --only cli)
#   --app-only          install only the Cua Spaces app (no CLI)
#   --mode host|client  preselect the app's first-run choice (implies spaces)
#   --pair CODE         add this machine to your account with a one-time code
#                       from the Cua Spaces app (Add a machine): installs and
#                       runs `cua host setup --pair CODE`, no sign-in, no checklist
#   --relay URL         relay for --pair (default https://relay.cua.ai)
#                       A computer that already has a cua with `host setup --pair`
#                       (and the app) uses them instead of building again;
#                       --prefix or CUA_INSTALL_REINSTALL=1 builds anyway
#   --prefix DIR        install under DIR (DIR/bin, DIR/Applications)
#   --modify-path       add the bin dir to your shell profile without asking
#   --no-modify-path    never edit your shell profile (print the one-line command)
#   --no-onboarding     do not run `cua auth login` afterwards
#   --dry-run           print what would happen, change nothing
#   -y, --yes           accept the selection and every prompt (non-interactive)
#   -h, --help          show this help
#
# Environment:
#   CUA_INSTALL_NONINTERACTIVE=1  never prompt (defaults plus --select)
#   CUA_INSTALL_REINSTALL=1       with --pair, build and install even if present
#   CUA_INSTALL_OS, CUA_INSTALL_ARCH  override platform detection
#   CUA_HOME                      cua state dir (default ~/.cua)
#   CARGO_TARGET_DIR              cargo target directory (as cargo itself)
set -eu

CUA_REPO_URL="${CUA_REPO_URL:-https://github.com/chriswritescode-dev/cua.git}"

want_cli=1
cli_only=0
app_only=0
select_list=""
only_list=""
only_set=0
sel_spaces=0
sel_driver=0
sel_host=0
picked=0
tty_saved=""
mode=""
pair_code=""
relay_url=""
prefix=""
modify_path=0
no_modify_path=0
onboarding=1
dry_run=0
assume_yes=0
tmp=""
existing_cua=""
repo_root=""

say() { printf '%s\n' "$*"; }
info() { printf 'cua-install: %s\n' "$*"; }
warn() { printf 'cua-install: warning: %s\n' "$*" >&2; }
die() {
    printf 'cua-install: error: %s\n' "$*" >&2
    exit 1
}

clone_hint() {
    say "Cua is installed from a source checkout now. Build it locally:"
    say ""
    say "  git clone $CUA_REPO_URL"
    say "  cd cua"
    say "  git checkout local-build"
    say "  scripts/install/install.sh"
    say ""
}

usage() {
    sed -n '2,/^set -eu/p' "$0" 2>/dev/null | sed -e '$d' -e 's/^# \{0,1\}//' || true
}

cleanup() {
    if [ -n "$tty_saved" ]; then
        stty "$tty_saved" </dev/tty 2>/dev/null || true
        tty_saved=""
    fi
    if [ -n "$tmp" ] && [ -d "$tmp" ]; then
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- arguments

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --cli-only) cli_only=1 ;;
        --app-only) app_only=1 ;;
        --select)
            [ $# -ge 2 ] || die "--select needs a list of items"
            select_list="$select_list,$2"
            shift
            ;;
        --select=*) select_list="$select_list,${1#--select=}" ;;
        --only)
            [ $# -ge 2 ] || die "--only needs a list of items"
            only_list="$only_list,$2"
            only_set=1
            shift
            ;;
        --only=*)
            only_list="$only_list,${1#--only=}"
            only_set=1
            ;;
        --mode)
            [ $# -ge 2 ] || die "--mode needs host or client"
            mode="$2"
            shift
            ;;
        --mode=*) mode="${1#--mode=}" ;;
        --pair)
            [ $# -ge 2 ] || die "--pair needs the code from the Cua Spaces app"
            pair_code="$2"
            shift
            ;;
        --pair=*) pair_code="${1#--pair=}" ;;
        --relay)
            [ $# -ge 2 ] || die "--relay needs a URL"
            relay_url="$2"
            shift
            ;;
        --relay=*) relay_url="${1#--relay=}" ;;
        --prefix)
            [ $# -ge 2 ] || die "--prefix needs a directory"
            prefix="$2"
            shift
            ;;
        --prefix=*) prefix="${1#--prefix=}" ;;
        --modify-path) modify_path=1 ;;
        --no-modify-path) no_modify_path=1 ;;
        --no-onboarding) onboarding=0 ;;
        --dry-run) dry_run=1 ;;
        -y | --yes) assume_yes=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    if [ "$cli_only" = 1 ] && [ "$app_only" = 1 ]; then
        die "--cli-only and --app-only are mutually exclusive"
    fi
    if [ "$only_set" = 1 ] && [ -n "$select_list" ]; then
        die "--only and --select are mutually exclusive"
    fi
    extra="$(items_in "$select_list$only_list")"
    if [ "$cli_only" = 1 ] && [ -n "$extra" ] && [ -z "$pair_code" ]; then
        die "--cli-only installs only the CLI; use --only $extra instead"
    fi
    if [ "$app_only" = 1 ]; then
        case " $extra " in
        *" cua-driver "* | *" host "*) die "--app-only skips the CLI, which cua-driver and host need" ;;
        esac
        want_cli=0
    fi
    if [ -n "$pair_code" ]; then
        # Letters, digits and dashes only: it ends up on a command line.
        case "$pair_code" in
        *[!A-Za-z0-9-]*) die "--pair: '$pair_code' is not a pairing code (like K7QM-4XPB-2RHD)" ;;
        esac
        [ "$app_only" = 0 ] || die "--pair needs the CLI; drop --app-only"
        [ "$cli_only" = 0 ] || only_list="$only_list,host"
        select_list="$select_list,host"
        if [ "$only_set" = 1 ]; then only_list="$only_list,host"; fi
        # The code stands in for the account: no sign-in here.
        onboarding=0
    fi
    if [ -n "$relay_url" ]; then
        [ -n "$pair_code" ] || die "--relay goes with --pair"
        case "$relay_url" in
        *[!A-Za-z0-9:/._%-]*) die "--relay: '$relay_url' is not a plain URL" ;;
        esac
        # https anywhere; plain http only to this machine (local relays).
        printf '%s\n' "$relay_url" | grep -Eq '^(https://[A-Za-z0-9.-]+(:[0-9]+)?|http://(localhost|127\.0\.0\.1)(:[0-9]+)?)(/[A-Za-z0-9._%/-]*)?$' ||
            die "--relay must be an https:// URL (plain http only for localhost)"
    fi
    case "$mode" in
    "" | host | client) ;;
    *) die "--mode must be host or client, not '$mode'" ;;
    esac
    case "$prefix" in
    "" | /*) ;;
    *) prefix="$(pwd)/$prefix" ;;
    esac
}

# ---------------------------------------------------------------- checkout

find_repo_root() {
    case "${0:-}" in
    "") die "this installer must run from a source checkout, not from a pipe" ;;
    -*) die "this installer must run from a source checkout, not from a pipe" ;;
    esac
    script_dir="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" ||
        die "could not resolve the directory of $0; run scripts/install/install.sh from a checkout"
    candidate="$(cd -- "$script_dir/../.." 2>/dev/null && pwd)" || candidate=""
    [ -n "$candidate" ] || die "run scripts/install/install.sh from a cloned repository"
    if [ ! -f "$candidate/libs/cua/Cargo.toml" ] || [ ! -f "$candidate/libs/cua-spacesd/Cargo.toml" ]; then
        printf 'cua-install: error: %s is not a Cua checkout\n\n' "$script_dir" >&2
        clone_hint >&2
        exit 1
    fi
    repo_root="$candidate"
}

# ---------------------------------------------------------------- helpers

has() { command -v "$1" >/dev/null 2>&1; }

# Whether a human can answer prompts.
tty_ok() {
    [ -t 1 ] || [ -t 2 ] || return 1
    (: </dev/tty) 2>/dev/null
}

confirm() {
    if [ "$assume_yes" = 1 ] || [ "$picked" = 1 ]; then
        return 0
    fi
    if ! tty_ok; then
        [ "$2" = y ]
        return
    fi
    if [ "$2" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '%s %s ' "$1" "$hint" >/dev/tty
    answer=""
    read -r answer </dev/tty || answer=""
    case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    [nN] | [nN][oO]) return 1 ;;
    *) [ "$2" = y ] ;;
    esac
}

run() {
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $*"
    else
        "$@"
    fi
}

detect_platform() {
    os="${CUA_INSTALL_OS:-$(uname -s)}"
    arch="${CUA_INSTALL_ARCH:-$(uname -m)}"
    case "$os" in
    Darwin | darwin | macos) os=darwin ;;
    Linux | linux) os=linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT | windows)
        die "on Windows, run scripts\\install\\install.ps1 from a PowerShell prompt in the checkout"
        ;;
    *) die "unsupported OS: $os" ;;
    esac
    case "$arch" in
    x86_64 | amd64 | x64) arch=x64 ;;
    arm64 | aarch64 | armv8*) arch=arm64 ;;
    *) die "unsupported CPU architecture: $arch" ;;
    esac
    # A shell under Rosetta reports x86_64 on Apple silicon.
    if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ -z "${CUA_INSTALL_ARCH:-}" ]; then
        if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
            arch=arm64
        fi
    fi
    platform="$os-$arch"
}

target_dir() {
    if [ -n "${CARGO_TARGET_DIR:-}" ]; then
        case "$CARGO_TARGET_DIR" in
        /*) printf '%s\n' "$CARGO_TARGET_DIR" ;;
        *) printf '%s/%s\n' "$(pwd)" "$CARGO_TARGET_DIR" ;;
        esac
    else
        printf '%s\n' "$1"
    fi
}

cua_binary() { printf '%s/release/cua\n' "$(target_dir "$repo_root/libs/cua/target")"; }
spacesd_binary() { printf '%s/release/cua-spacesd\n' "$(target_dir "$repo_root/libs/cua-spacesd/target")"; }

check_build_tools() {
    if [ "$want_cli" = 1 ]; then
        has cargo || die "cargo is required to build cua; install Rust from https://rustup.rs and rerun"
    fi
    if [ "$sel_driver" = 1 ]; then
        has cargo || die "cargo is required to build cua-driver; install Rust from https://rustup.rs and rerun"
        has bash || die "cua-driver: its installer needs bash; install bash and rerun"
    fi
}

# ---------------------------------------------------------------- selection

items_in() {
    out=""
    for item in $(printf '%s' "$1" | tr ',' ' '); do
        case "$item" in
        cli) ;;
        spaces | cua-driver | host)
            case " $out " in *" $item "*) ;; *) out="${out:+$out }$item" ;; esac
            ;;
        *) die "unknown item '$item' (valid: cli, spaces, cua-driver, host)" ;;
        esac
    done
    printf '%s\n' "$out"
}

item_on() {
    case "$1" in
    cli) [ "$want_cli" = 1 ] ;;
    spaces) [ "$sel_spaces" = 1 ] ;;
    cua-driver) [ "$sel_driver" = 1 ] ;;
    host) [ "$sel_host" = 1 ] ;;
    esac
}

item_set() { # id 0|1
    case "$1" in
    spaces) sel_spaces=$2 ;;
    cua-driver) sel_driver=$2 ;;
    host) sel_host=$2 ;;
    esac
}

item_toggle() {
    if item_on "$1"; then item_set "$1" 0; else item_set "$1" 1; fi
}

item_label() {
    case "$1" in
    cli) printf 'cua CLI and cua-spacesd (required)' ;;
    spaces) printf 'Cua Spaces app' ;;
    cua-driver) printf 'cua-driver MCP and skill for your agents' ;;
    host) printf 'Host this machine' ;;
    esac
}

init_selection() {
    if [ "$only_set" = 1 ] || [ "$cli_only" = 1 ]; then
        list="$only_list"
    else
        list="$select_list"
        if spaces_supported; then sel_spaces=1; fi
    fi
    for item in $(items_in "$list"); do item_set "$item" 1; done
    # Legacy: --app-only and --mode mean the app, as they always did.
    if [ "$app_only" = 1 ] || { [ -n "$mode" ] && [ "$cli_only" = 0 ]; }; then
        sel_spaces=1
    fi
    if [ "$sel_spaces" = 1 ] && ! spaces_supported; then
        if [ "$app_only" = 1 ]; then
            die "the Cua Spaces app has no source build for $os; build it from apps/cua-spaces-desktop (pnpm), or use the SDK and CLI"
        fi
        info "Cua Spaces has no source build for $os; skipping the app (build it from apps/cua-spaces-desktop)"
        sel_spaces=0
    fi
}

spaces_supported() {
    [ "$os" = darwin ]
}

# --pair on a computer that already has Cua: use the `cua` that is there
# instead of building it again. Anything else (--prefix, an old cua, nothing
# installed) builds as before.
reuse_installed() {
    [ -n "$pair_code" ] || return 0
    [ -z "$prefix" ] && [ "${CUA_INSTALL_REINSTALL:-0}" != 1 ] || return 0
    [ "$app_only" = 0 ] || return 0
    found=""
    for candidate in "$(command -v cua 2>/dev/null || true)" "$HOME/.local/bin/cua" /usr/local/bin/cua \
        "/Applications/Cua Spaces.app/Contents/MacOS/cua" "$HOME/Applications/Cua Spaces.app/Contents/MacOS/cua"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        if "$candidate" host setup --help 2>&1 </dev/null | grep -q -e '--pair'; then
            found="$candidate"
            break
        fi
    done
    [ -n "$found" ] || return 0
    info "cua is already installed at $found; using it (CUA_INSTALL_REINSTALL=1 builds it again)"
    existing_cua="$found"
    want_cli=0
    if [ -d "/Applications/Cua Spaces.app" ] || [ -d "$HOME/Applications/Cua Spaces.app" ]; then
        sel_spaces=0
        info "Cua Spaces is already installed; keeping it"
    fi
}

wants_checklist() {
    [ -z "$pair_code" ] && [ "$assume_yes" = 0 ] && [ "$only_set" = 0 ] && [ "$cli_only" = 0 ] &&
        [ "$app_only" = 0 ] && [ "${CUA_INSTALL_NONINTERACTIVE:-}" != 1 ] && tty_ok
}

row_id() { # N: the item on row N
    i=0
    for r in $rows; do
        i=$((i + 1))
        if [ "$i" = "$1" ]; then printf '%s' "$r"; fi
    done
}

draw_rows() { # cursor row, or 0 for the numbered list
    i=0
    for r in $rows; do
        i=$((i + 1))
        if item_on "$r"; then box='[x]'; else box='[ ]'; fi
        if [ "$1" = 0 ]; then
            printf '  %d %s %s\n' "$i" "$box" "$(item_label "$r")"
        else
            if [ "$i" = "$1" ]; then p='>'; else p=' '; fi
            printf '\r\033[K%s %s %s\n' "$p" "$box" "$(item_label "$r")"
        fi
    done
}

checklist() {
    rows="cli"
    if spaces_supported; then rows="$rows spaces"; fi
    rows="$rows cua-driver host"
    n=0
    for r in $rows; do n=$((n + 1)); done
    printf '\nChoose what to install:\n' >/dev/tty
    if [ "${TERM:-dumb}" = dumb ] || ! tty_saved="$(stty -g </dev/tty 2>/dev/null)"; then
        tty_saved=""
        while :; do
            draw_rows 0 >/dev/tty
            printf 'Toggle numbers (e.g. 2 3), Enter to install: ' >/dev/tty
            line=""
            read -r line </dev/tty || line=""
            [ -n "$line" ] || break
            for k in $(printf '%s' "$line" | tr ',' ' '); do
                id="$(row_id "$k")"
                [ -n "$id" ] && item_toggle "$id"
            done
        done
    else
        stty -icanon -echo min 1 time 0 </dev/tty
        esc="$(printf '\033')"
        cr="$(printf '\r')"
        cur=1
        draw_rows "$cur" >/dev/tty
        printf 'Up/down or 1-%d to move/toggle, space to toggle, Enter to install\n' "$n" >/dev/tty
        while :; do
            key="$(dd bs=1 count=1 2>/dev/null </dev/tty)" || key=""
            case "$key" in
            "" | "$cr" | "$(printf '\004')") break ;; # Enter, EOF or Ctrl-D
            "$esc")
                key="$(dd bs=1 count=2 2>/dev/null </dev/tty)" || key=""
                case "$key" in
                ?A) [ "$cur" -gt 1 ] && cur=$((cur - 1)) ;;
                ?B) [ "$cur" -lt "$n" ] && cur=$((cur + 1)) ;;
                esac
                ;;
            k) [ "$cur" -gt 1 ] && cur=$((cur - 1)) ;;
            j) [ "$cur" -lt "$n" ] && cur=$((cur + 1)) ;;
            " ") item_toggle "$(row_id "$cur")" ;;
            [1-9])
                if [ "$key" -le "$n" ]; then
                    cur=$key
                    item_toggle "$(row_id "$cur")"
                fi
                ;;
            esac
            printf '\033[%dA' "$((n + 1))" >/dev/tty
            draw_rows "$cur" >/dev/tty
            printf '\n' >/dev/tty
        done
        stty "$tty_saved" </dev/tty 2>/dev/null || true
        tty_saved=""
    fi
    printf '\n' >/dev/tty
    picked=1
}

# ---------------------------------------------------------------- the CLI

cli_bin_dir() {
    if [ -n "$prefix" ]; then
        printf '%s/bin\n' "$prefix"
    elif [ "$(id -u)" = 0 ]; then
        printf '/usr/local/bin\n'
    else
        printf '%s/.local/bin\n' "$HOME"
    fi
}

path_has() {
    case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
    esac
}

profile_file() {
    case "${SHELL:-}" in
    */zsh) printf '%s/.zshrc\n' "${ZDOTDIR:-$HOME}" ;;
    */bash)
        if [ "$os" = darwin ]; then printf '%s/.bash_profile\n' "$HOME"; else printf '%s/.bashrc\n' "$HOME"; fi
        ;;
    */fish) printf '%s/fish/config.fish\n' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    *) printf '%s/.profile\n' "$HOME" ;;
    esac
}

path_line() { # dir profile
    case "$2" in
    *.fish) printf 'fish_add_path "%s"\n' "$1" ;;
    *)
        # shellcheck disable=SC2016 # $PATH is expanded by the profile, not here.
        printf 'export PATH="%s:$PATH"\n' "$1"
        ;;
    esac
}

ensure_path() { # dir
    if path_has "$1"; then
        return
    fi
    profile="$(profile_file)"
    line="$(path_line "$1" "$profile")"
    if [ "$modify_path" = 0 ] && [ "$no_modify_path" = 0 ] && [ "$assume_yes" = 0 ] && [ "$dry_run" = 0 ] && [ "${CUA_INSTALL_NONINTERACTIVE:-0}" != 1 ] && tty_ok; then
        printf 'Add %s to PATH in %s so cua works in new terminals? [Y/n] ' "$1" "$profile" >/dev/tty
        answer=""
        read -r answer </dev/tty || answer=""
        case "$answer" in
        [nN] | [nN][oO]) ;;
        *) modify_path=1 ;;
        esac
    fi
    if [ "$modify_path" = 1 ] && [ "$no_modify_path" = 0 ]; then
        if [ -f "$profile" ] && grep -qF "$line" "$profile"; then
            return
        fi
        if [ "$dry_run" = 1 ]; then
            say "[dry-run] append PATH line to $profile"
            return
        fi
        mkdir -p "$(dirname "$profile")"
        printf '\n# Added by the cua installer\n%s\n' "$line" >>"$profile"
        info "added $1 to PATH in $profile (open a new terminal to pick it up)"
    else
        say ""
        say "$1 is not on your PATH. Add it with this one line, then open a new terminal:"
        say "  echo '$line' >> $profile"
        say "(or rerun the installer with --modify-path)"
    fi
}

build_cua() {
    info "building the cua CLI from $repo_root"
    run cargo build --release -p cua-cli --manifest-path "$repo_root/libs/cua/Cargo.toml"
}

build_spacesd() {
    info "building cua-spacesd from $repo_root"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] cargo build --release -p cua-spacesd --manifest-path $repo_root/libs/cua-spacesd/Cargo.toml"
        return
    fi
    if [ "$os" = darwin ]; then
        RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-Wl,-rpath,/usr/lib/swift" \
            cargo build --release -p cua-spacesd --manifest-path "$repo_root/libs/cua-spacesd/Cargo.toml"
    else
        cargo build --release -p cua-spacesd --manifest-path "$repo_root/libs/cua-spacesd/Cargo.toml"
    fi
}

put_binary() { # source destination
    cp "$1" "$2.tmp.$$" || die "could not copy $1"
    chmod 0755 "$2.tmp.$$"
    mv -f "$2.tmp.$$" "$2"
}

install_cli() {
    bindir="$(cli_bin_dir)"
    target="$bindir/cua"
    if ! confirm "Install the cua CLI to $target?" y; then
        die "cancelled; rerun with --prefix DIR to choose another location"
    fi
    build_cua
    build_spacesd
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] install $(cua_binary) -> $target"
        say "[dry-run] install $(spacesd_binary) -> $bindir/cua-spacesd"
    else
        [ -x "$(cua_binary)" ] || die "cargo did not produce $(cua_binary)"
        [ -x "$(spacesd_binary)" ] || die "cargo did not produce $(spacesd_binary)"
        mkdir -p "$bindir" || die "cannot create $bindir (try --prefix or run as root)"
        put_binary "$(cua_binary)" "$target"
        put_binary "$(spacesd_binary)" "$bindir/cua-spacesd"
        info "installed $target"
        info "installed $bindir/cua-spacesd"
    fi
    cua_bin="$target"
    ensure_path "$bindir"
}

# ---------------------------------------------------------------- the app

install_app_darwin() {
    if [ -z "${CUA_INSTALL_OS:-}" ] && has sw_vers; then
        macos="$(sw_vers -productVersion 2>/dev/null || true)"
        case "${macos%%.*}" in
        '' | *[!0-9]*) ;;
        *)
            if [ "${macos%%.*}" -lt 26 ]; then
                warn "Cua Spaces for macOS needs macOS 26 or later (this Mac runs $macos); skipping the app"
                return
            fi
            ;;
        esac
    fi
    script="$repo_root/apps/cua-spaces-macos/scripts/build-release.sh"
    [ -f "$script" ] || die "missing $script"
    if [ -n "$prefix" ]; then
        appdir="$prefix/Applications"
    elif [ -w /Applications ]; then
        appdir="/Applications"
    else
        appdir="$HOME/Applications"
    fi
    if ! confirm "Build and install Cua Spaces to $appdir?" y; then
        if [ "$appdir" = /Applications ] && confirm "Install to $HOME/Applications instead?" y; then
            appdir="$HOME/Applications"
        else
            info "skipping the Cua Spaces app"
            return
        fi
    fi
    app_path="$appdir/Cua Spaces.app"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] bash $script --out $tmp/app"
        say "[dry-run] copy $tmp/app/Cua Spaces.app -> $app_path"
        return
    fi
    info "building Cua Spaces from $repo_root"
    bash "$script" --out "$tmp/app" || die "the Cua Spaces build failed"
    src="$tmp/app/Cua Spaces.app"
    [ -d "$src" ] || die "the Cua Spaces build produced no app bundle"
    mkdir -p "$appdir"
    rm -rf "$app_path.cua-new"
    ditto "$src" "$app_path.cua-new" 2>/dev/null || cp -R "$src" "$app_path.cua-new"
    rm -rf "$app_path"
    mv "$app_path.cua-new" "$app_path"
    info "installed $app_path"
}

write_mode() {
    [ -n "$mode" ] || return 0
    home="${CUA_HOME:-$HOME/.cua}"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] write $home/spaces-install-mode ($mode)"
        return
    fi
    mkdir -p "$home"
    printf '%s\n' "$mode" >"$home/spaces-install-mode"
}

# ---------------------------------------------------------------- cua-driver

install_driver() {
    script="$repo_root/libs/cua-driver/scripts/install.sh"
    [ -f "$script" ] || die "missing $script"
    bindir="$(cli_bin_dir)"
    driver_bin="$bindir/cua-driver"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] bash $script --bin-dir $bindir"
    else
        info "building and installing cua-driver (libs/cua-driver/scripts/install.sh)"
        bash "$script" --bin-dir "$bindir" </dev/null || die "the cua-driver installer failed"
        info "installed $driver_bin"
    fi
    info "adding the cua-driver skill and MCP server to your agents"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $cua_bin agents setup --cua-driver --agents all --yes --mcp-command $driver_bin"
    elif ! "$cua_bin" agents setup --cua-driver --agents all --yes --mcp-command "$driver_bin" </dev/null; then
        warn "agent setup for cua-driver did not finish; rerun: cua agents setup --cua-driver"
    fi
}

# Host this machine: joins the relay as the signed-in account.
host_setup() {
    if [ -n "$pair_code" ]; then
        host_pair
        return
    fi
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $cua_bin host setup"
        return
    fi
    info "setting up this machine as a host (cua host setup)"
    if tty_ok; then
        if "$cua_bin" host setup </dev/tty; then
            say "  cua runtime setup lume  # also needed to provide macOS VM Spaces (cua host setup --profile spare --provide-spaces)"
            return
        fi
    else
        if "$cua_bin" host setup </dev/null; then
            say "  cua runtime setup lume  # also needed to provide macOS VM Spaces (cua host setup --profile spare --provide-spaces)"
            return
        fi
    fi
    warn "host setup did not finish; run 'cua auth login --remote' (over ssh) or 'cua auth login', then 'cua host setup' again"
}

host_pair() {
    set -- "$cua_bin" host setup --pair "$pair_code"
    if [ -n "$relay_url" ]; then set -- "$@" --relay "$relay_url"; fi
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $*"
        return
    fi
    if ! "$cua_bin" host setup --help 2>&1 </dev/null | grep -q -e '--pair'; then
        die "the installed cua CLI ($("$cua_bin" --version 2>/dev/null || echo unknown)) cannot add a machine with a code (no 'cua host setup --pair'); build a newer checkout (git pull && scripts/install/install.sh) or sign in instead: cua auth login && cua host setup"
    fi
    info "adding this machine to your account (cua host setup --pair)"
    if "$@" </dev/null; then
        say ""
        say "This machine is added. It shows up in Cua Spaces on your other devices in a few seconds."
        return
    fi
    die "adding this machine did not finish; if the code expired or was used, make a new one in Cua Spaces (Add a machine) and run: cua host setup --pair <code>"
}

# ---------------------------------------------------------------- onboarding

next_steps() {
    say ""
    say "Next steps:"
    if [ "$want_cli" = 1 ]; then
        say "  cua auth login      # sign in (over ssh / no browser: --remote), then set up your AI coding agents"
        say "  cua agents setup    # (re)configure cua skills and the cua MCP server"
    fi
    if [ "$sel_host" = 1 ]; then
        say "  cua host setup       # hosting Spaces needs you signed in first"
    fi
    if [ "$sel_spaces" = 1 ] && [ -n "${app_path:-}" ]; then
        say "  open \"$app_path\"  # start Cua Spaces"
    fi
}

run_onboarding() {
    [ -z "$pair_code" ] || return 0
    if [ "$want_cli" = 0 ] || [ "$onboarding" = 0 ] || [ "$dry_run" = 1 ]; then
        next_steps
        return
    fi
    if ! tty_ok; then
        say ""
        info "not signing in: no terminal to prompt on"
        say "Sign in from here with a device code (works over ssh, no browser needed):"
        say "  cua auth login --remote"
        next_steps
        return
    fi
    say ""
    info "signing in (cua auth login)"
    if ! "$cua_bin" auth login </dev/tty; then
        warn "sign-in did not finish; run 'cua auth login' later (or 'cua auth login --remote' over ssh)"
        next_steps
    fi
}

main() {
    parse_args "$@"
    detect_platform
    init_selection
    find_repo_root
    reuse_installed
    tmp="$(mktemp -d 2>/dev/null || mktemp -d -t cua-install)"
    if wants_checklist; then
        checklist
    fi
    if [ "$dry_run" = 1 ]; then
        info "dry run: nothing will be changed"
    fi
    info "platform $platform, checkout $repo_root"
    check_build_tools
    cua_bin="${existing_cua:-cua}"
    app_path=""
    if [ "$want_cli" = 1 ]; then
        install_cli
    fi
    if [ "$sel_spaces" = 1 ]; then
        install_app_darwin
        write_mode
    fi
    if [ "$sel_driver" = 1 ]; then
        install_driver
    fi
    info "done"
    run_onboarding
    if [ "$sel_host" = 1 ]; then
        host_setup
    fi
}

main "$@"
