#!/bin/sh
# Cua source installer: build and install the `cua` CLI, cua-spacesd, the Cua
# Spaces app and agent extras from this repository checkout.
#
# Run it from a checkout:
#
#   git clone https://github.com/chriswritescode-dev/cua.git
#   cd cua
#   git checkout local-build
#   scripts/install/install.sh
#   scripts/install/install.sh --select cua-driver
#   scripts/install/install.sh --cli-only --yes
#   scripts/install/install.sh --pair K7QM-4XPB-2RHD
#
# In a terminal it first says what Cua Spaces is, then lets you choose what to
# add to the command-line tools (the `cua` program: always built, except with
# --app-only):
#   spaces      the Cua Spaces app (macOS only; default on there)
#   cua-driver  Cua Driver, which lets AI agents use apps while you keep
#               working: builds it and adds its skill and MCP server to
#               your agents (default off)
# Signing in adds this computer to your account: after `cua auth login`
# succeeds, the installer runs `cua host setup`, so your other devices can
# use it through the relay (a computer set up before keeps its settings).
# --no-host signs in only. Without a terminal there is no sign-in here; the
# closing lines say how to finish. `--select host` / `--only host` run
# `cua host setup` even without a sign-in here (kept for scripts).
#
# Options:
#   --select LIST       install these items plus the CLI, not the app unless
#                       listed (comma list: spaces, cua-driver, host)
#   --only LIST         install exactly LIST plus the CLI, no checklist
#   --cli-only          install only the `cua` CLI (same as --only cli)
#   --app-only          install only the Cua Spaces app (no CLI)
#   --mode host|client  preselect the app's first-run choice (implies spaces)
#   --pair CODE         add this machine to your account with a one-time code
#                       from the Cua Spaces app (Add a computer): builds and
#                       runs `cua host setup --pair CODE`, no sign-in, no checklist
#   --relay URL         relay for --pair (default https://relay.cua.ai)
#   --no-host           sign in only: do not add this computer to your account
#   --no-provide-spaces add this computer without creating Spaces for your
#                       other devices on it (cua host setup --no-provide-spaces)
#                       A computer that already has a cua with `host setup --pair`
#                       (and the app) uses them instead of building again;
#                       --prefix or CUA_INSTALL_REINSTALL=1 builds anyway
#   --prefix DIR        install under DIR (DIR/bin, DIR/Applications)
#   --modify-path       add the bin dir to your shell profile without asking
#   --no-modify-path    never edit your shell profile (print the one-line command)
#   --no-onboarding     do not run `cua auth login` afterwards (nor add this computer)
#   --no-skills         with cua-driver, add only its MCP server to your agents,
#                       not its skill (by default both are added)
#   -v, --verbose       print every step (checkout paths, builds, installs)
#   --dry-run           print what would happen, change nothing
#   -y, --yes           accept the selection and every prompt (non-interactive)
#   -h, --help          show this help
#
# Environment:
#   CUA_INSTALL_NONINTERACTIVE=1      never prompt (defaults plus --select)
#   CUA_INSTALL_VERBOSE=1             same as --verbose
#   CUA_INSTALL_REINSTALL=1           with --pair, build the CLI and app even if present
#   CUA_REPO_URL                      the clone this installer points at
#   CUA_INSTALL_OS, CUA_INSTALL_ARCH  override platform detection
#   CUA_HOME                          cua state dir (default ~/.cua)
#   CARGO_TARGET_DIR                  cargo target directory (as cargo itself)
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
path_hint=""
verbose=0
no_tty_noted=0
signed_in=0
onboarding=1
no_host=0
no_provide_spaces=0
did_host=""
driver_skills=1
dry_run=0
assume_yes=0
tmp=""
existing_cua=""
repo_root=""
# What this run installed, for the closing summary.
did_cli=""
did_app=""
did_driver=""

[ "${CUA_INSTALL_VERBOSE:-}" != 1 ] || verbose=1

say() { printf '%s\n' "$*"; }
# step: one plain line per thing the installer does.
step() { printf '%s\n' "$*"; }
# info: detail for --verbose (checkout paths, build commands, installs).
info() { [ "$verbose" = 0 ] || printf 'cua-install: %s\n' "$*"; }
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
        --no-host) no_host=1 ;;
        --no-provide-spaces) no_provide_spaces=1 ;;
        --no-skills) driver_skills=0 ;;
        -v | --verbose) verbose=1 ;;
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
    if [ "$no_host" = 1 ]; then
        [ -z "$pair_code" ] || die "--no-host and --pair contradict each other: --pair adds this computer"
        case " $(items_in "$select_list$only_list") " in
        *" host "*) die "--no-host and --select host contradict each other" ;;
        esac
        [ "$no_provide_spaces" = 0 ] || die "--no-provide-spaces goes with adding this computer; drop --no-host"
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

# find_repo_root: the installer only works from a clone, and every component
# is built from it; a piped script has no checkout to resolve.
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

# ask "prompt": read one answer into $answer from the terminal itself, never
# from stdin. Returns 1 when nobody can answer: no terminal, or the terminal
# hit end of input. Running out of input is never an answer.
ask() {
    answer=""
    tty_ok || return 1
    printf '%s ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || {
        answer=""
        printf '\n' >/dev/tty
        return 1
    }
}

# Said once, the first time a question is skipped for lack of a terminal.
note_no_tty() {
    [ "$no_tty_noted" = 0 ] || return 0
    no_tty_noted=1
    [ "$assume_yes" = 1 ] || [ "${CUA_INSTALL_NONINTERACTIVE:-}" = 1 ] ||
        step "The installer can't ask you questions here, so it is using the usual choices (add --yes to hide this note)."
}

# confirm "question" default(y|n): 0 for yes. Answered once the checklist
# was confirmed. With nobody to ask, the default applies.
confirm() {
    if [ "$assume_yes" = 1 ] || [ "$picked" = 1 ]; then
        return 0
    fi
    if [ "$2" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if ! ask "$1 $hint"; then
        note_no_tty
        [ "$2" = y ]
        return
    fi
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
    if [ "$os" = linux ] && [ -z "${CUA_INSTALL_OS:-}" ] && has ldd; then
        if ldd --version 2>&1 | grep -qi musl; then
            warn "musl libc detected; the cua CLI needs glibc 2.31 or newer"
        fi
    fi
    platform="$os-$arch"
}

# target_dir DEFAULT: where cargo puts release builds, honouring
# CARGO_TARGET_DIR exactly as cargo does.
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

# check_build_tools: fail before installing anything when a build cannot run.
check_build_tools() {
    if [ "$want_cli" = 1 ]; then
        has cargo || die "cargo is required to build cua; install Rust from https://rustup.rs and rerun"
    fi
    if [ "$sel_driver" = 1 ]; then
        has cargo || die "cargo is required to build cua-driver; install Rust from https://rustup.rs and rerun"
        [ "$dry_run" = 1 ] || has bash || die "cua-driver: its installer needs bash; install bash and rerun"
    fi
}

# ---------------------------------------------------------------- selection

# items_in LIST: the item ids in a comma list (cli dropped), or an error.
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

# What a row is called, and one line on what it does (shown under the row
# the cursor is on). `host` is not a row: the app's first run asks how to
# use this computer; `--select host` stays for scripts.
item_label() {
    case "$1" in
    spaces) printf 'Cua Spaces app: lets your AI agents use computers' ;;
    cua-driver) printf 'Cua Driver: lets AI agents use your apps while you keep working' ;;
    esac
}

item_help() {
    case "$1" in
    spaces) printf 'Open the app to sign in, connect your AI agents and watch them work.' ;;
    cua-driver) printf 'For advanced users. Adds it to Claude Code, Codex and other coding agents.' ;;
    esac
}

# The selection before the checklist: defaults, legacy flags, --select/--only.
init_selection() {
    if [ "$only_set" = 1 ] || [ "$cli_only" = 1 ]; then
        list="$only_list"
    else
        list="$select_list"
        # The app is a default on macOS, until --select names what to
        # install: then only those items (and the CLI) are installed.
        # --pair adds host to the list itself; it keeps the default.
        if spaces_supported && { [ -n "$pair_code" ] || [ -z "$(printf %s "$list" | tr -d ', ')" ]; }; then sel_spaces=1; fi
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
        step "Cua Spaces has no source build for $os; skipping the app (build it from apps/cua-spaces-desktop)"
        sel_spaces=0
    fi
}

# Cua Spaces on macOS is the SwiftUI app; the Linux app has no source build
# here (apps/cua-spaces-desktop builds with pnpm).
spaces_supported() {
    [ "$os" = darwin ]
}

# --pair on a computer that already has Cua: use the `cua` that is there
# (it must know `host setup --pair`) and keep the app that is there, instead
# of building both again. Anything else (--prefix, an old cua, nothing
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
    step "cua is already installed at $found; using it (CUA_INSTALL_REINSTALL=1 builds it again)"
    existing_cua="$found"
    want_cli=0
    if [ -d "/Applications/Cua Spaces.app" ] || [ -d "$HOME/Applications/Cua Spaces.app" ]; then
        sel_spaces=0
        step "Cua Spaces is already installed; keeping it"
    fi
}

# Show the checklist only when a human can answer it.
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
            printf '        %s\n' "$(item_help "$r")"
        else
            if [ "$i" = "$1" ]; then p='>'; else p=' '; fi
            printf '\r\033[K%s %s %s\n' "$p" "$box" "$(item_label "$r")"
        fi
    done
    if [ "$1" != 0 ]; then
        printf '\r\033[K\n\r\033[K  %s\n\r\033[K\n' "$(item_help "$(row_id "$1")")"
    fi
}

# checklist: what Cua Spaces is, what is always installed, then the optional
# rows: arrows/numbers + space to toggle, Enter to install.
checklist() {
    rows=""
    # Spaces is offered only where it builds from source (macOS).
    if spaces_supported; then rows="spaces"; fi
    rows="${rows:+$rows }cua-driver"
    n=0
    for r in $rows; do n=$((n + 1)); done
    {
        printf '\nCua Spaces lets your AI agents use computers, and lets you watch them work.\n\n'
        printf 'Needed, so always installed:\n'
        printf '  Command-line tools: the "cua" program that the app and your AI agents use.\n'
        if [ "$sel_host" = 1 ]; then
            printf 'Also: your other devices will be able to use this computer (you asked for this with --select host).\n'
        fi
        printf '\nChoose what else to add:\n\n'
    } >/dev/tty
    if [ "${TERM:-dumb}" = dumb ] || ! tty_saved="$(stty -g </dev/tty 2>/dev/null)"; then
        tty_saved=""
        while :; do
            draw_rows 0 >/dev/tty
            printf 'Type a number to switch an item on or off. Press Enter to install: ' >/dev/tty
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
        printf 'Up/down to move, space to select, Enter to install\n' >/dev/tty
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
            printf '\033[%dA' "$((n + 4))" >/dev/tty
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
        # Interactive default: offer to add it (Enter = yes). No answer
        # (the terminal closed) leaves the profile alone.
        if ask "Make \"cua\" work in new Terminal windows? This adds $1 to PATH in $profile. [Y/n]"; then
            case "$answer" in
            [nN] | [nN][oO]) ;;
            *) modify_path=1 ;;
            esac
        fi
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
        step "Added $1 to PATH in $profile (open a new Terminal window to use cua)"
    else
        # Said at the end, after what was installed.
        path_hint="$1 is not on your PATH, the list of places your Terminal looks for programs.
To use cua, run this one line, then open a new Terminal window:
  echo '$line' >> $profile
(or rerun the installer with --modify-path)"
    fi
}

build_cua() {
    step "Building the cua CLI from $repo_root"
    run cargo build --release -p cua-cli --manifest-path "$repo_root/libs/cua/Cargo.toml"
}

# cua-host looks for cua-spacesd next to `cua`, so it is built and installed
# into the same bin directory.
build_spacesd() {
    step "Building cua-spacesd from $repo_root"
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

# running_daemon_version CUA: the version of the daemon this cua finds running
# (the one named by its daemon.json), or nothing. `cua daemon status` prints
# "cua daemon X.Y.Z (pid N) ..." only when one is up.
running_daemon_version() {
    [ -x "$1" ] || return 0
    "$1" daemon status 2>/dev/null </dev/null | sed -n 's/^cua daemon \([^ ]*\) (pid .*/\1/p' | head -n 1
}

# restart_old_daemon NEWCUA OLDVERSION: after the binary was replaced, stop a
# daemon of an older version gracefully with the NEW cua (it reads daemon.json
# and signals only that daemon) and start the new one. Local containers and
# VMs run on in their own processes, so they survive. Never a broad kill.
restart_old_daemon() {
    [ -n "$2" ] || return 0
    new_version="$("$1" --version 2>/dev/null </dev/null | sed -n 's/^cua \([^ ]*\).*/\1/p' | head -n 1)"
    [ -n "$new_version" ] && [ "$new_version" != "$2" ] || return 0
    if "$1" daemon stop >/dev/null 2>&1 </dev/null; then
        if "$1" daemon start >/dev/null 2>&1 </dev/null; then
            step "restarted the cua daemon ($2 -> $new_version); your Spaces keep running"
        else
            warn "stopped the old cua daemon ($2); it starts again with the next cua command"
        fi
    else
        warn "the cua daemon $2 is still running; run 'cua daemon stop' to finish updating to $new_version"
    fi
}

install_cli() {
    bindir="$(cli_bin_dir)"
    target="$bindir/cua"
    if ! confirm "Install the command-line tools to $target?" y; then
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
        # A daemon already running keeps serving the old binary after the
        # swap; note its version now, from the old cua.
        old_daemon="$(running_daemon_version "$target")"
        put_binary "$(cua_binary)" "$target"
        put_binary "$(spacesd_binary)" "$bindir/cua-spacesd"
        info "installed $target"
        info "installed $bindir/cua-spacesd"
        restart_old_daemon "$target" "$old_daemon"
        did_cli="$target"
    fi
    cua_bin="$target"
    ensure_path "$bindir"
}

# ---------------------------------------------------------------- the app

install_app_darwin() {
    # The macOS app (SwiftUI) needs macOS 26; an older Mac would get an app
    # that cannot open.
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
            step "Skipping the Cua Spaces app"
            return
        fi
    fi
    app_path="$appdir/Cua Spaces.app"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] bash $script --out $tmp/app"
        say "[dry-run] copy $tmp/app/Cua Spaces.app -> $app_path"
        return
    fi
    step "Building the Cua Spaces app into $appdir"
    bash "$script" --out "$tmp/app" || die "the Cua Spaces build failed"
    src="$tmp/app/Cua Spaces.app"
    [ -d "$src" ] || die "the Cua Spaces build produced no app bundle"
    mkdir -p "$appdir"
    rm -rf "$app_path.cua-new"
    ditto "$src" "$app_path.cua-new" 2>/dev/null || cp -R "$src" "$app_path.cua-new"
    rm -rf "$app_path"
    mv "$app_path.cua-new" "$app_path"
    info "installed $app_path"
    did_app="$app_path"
}

# The CLI runs Spaces as containers or VMs, so Linux needs a VM runtime.
runtime_ready() {
    [ -n "${DOCKER_HOST:-}" ] || { has docker && docker info >/dev/null 2>&1; } ||
        { has "qemu-system-$(uname -m)" && has qemu-img; }
}

qemu_install_command() {
    if has dnf; then
        printf 'sudo dnf install -y qemu-kvm qemu-img\n'
    elif [ "$arch" = arm64 ]; then
        printf 'sudo apt-get install -y qemu-system-arm qemu-utils\n'
    else
        printf 'sudo apt-get install -y qemu-system-x86 qemu-utils\n'
    fi
}

linux_runtime() {
    if runtime_ready; then
        info "VM runtime ok"
        return
    fi
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $cua_bin runtime setup qemu"
        return
    fi
    if confirm "Cua on Linux needs QEMU, a program that runs virtual computers. Install it now?" y; then
        step "Installing QEMU, which Cua on Linux uses to run virtual computers"
        if "$cua_bin" runtime setup qemu </dev/null && runtime_ready; then
            return
        fi
    fi
    warn "Cua on Linux needs QEMU or Docker; install QEMU with: $(qemu_install_command) (or install Docker), then rerun the installer"
    runtime_failed=1
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

# cua-driver's own installer builds it from this checkout through
# install-local and puts it next to `cua`, then the skill + MCP server.
install_driver() {
    script="$repo_root/libs/cua-driver/scripts/install.sh"
    [ -f "$script" ] || die "missing $script"
    bindir="$(cli_bin_dir)"
    driver_bin="$bindir/cua-driver"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] bash $script --bin-dir $bindir"
    else
        step "Building Cua Driver and installing it into $bindir"
        bash "$script" --bin-dir "$bindir" </dev/null || die "the cua-driver installer failed"
        info "installed $driver_bin"
    fi
    if [ "$driver_skills" = 1 ]; then
        info "adding the cua-driver skill and MCP server to your agents"
    else
        info "adding the cua-driver MCP server to your agents (no skill: --no-skills)"
    fi
    set -- "$cua_bin" agents setup --cua-driver --agents all --yes
    [ "$driver_skills" = 1 ] || set -- "$@" --no-skills
    set -- "$@" --mcp-command "$driver_bin"
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $*"
    elif ! "$@" </dev/null; then
        warn "agent setup for cua-driver did not finish; rerun: cua agents setup --cua-driver"
    fi
    did_driver=1
}

# Host this machine: joins the relay as the signed-in account. cua-spacesd is
# installed with the CLI; macOS VM Spaces also need Lume (`cua runtime setup lume`).
host_setup() {
    if [ -n "$pair_code" ]; then
        host_pair
        return
    fi
    set -- "$cua_bin" host setup
    if [ "$sel_host" = 0 ]; then
        # Added by signing in: a computer already set up keeps its settings,
        # and a new one provides Spaces with its screen kept private (sharing
        # its desktop is a choice on its page in Cua Spaces).
        if [ "$dry_run" = 0 ] && "$cua_bin" host status --json </dev/null 2>/dev/null | grep -q '"configured":true'; then
            did_host=1
            return
        fi
        if [ "$no_provide_spaces" = 0 ]; then set -- "$@" --no-desktop --provide-spaces; fi
    fi
    if [ "$no_provide_spaces" = 1 ]; then set -- "$@" --no-provide-spaces; fi
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $*"
        return
    fi
    step "Adding this computer to your account (cua host setup)"
    if tty_ok; then
        if "$@" </dev/tty; then
            did_host=1
        fi
    else
        if "$@" </dev/null; then
            did_host=1
        fi
    fi
    if [ -n "$did_host" ]; then
        say "  cua runtime setup lume  # also needed to provide macOS VM Spaces"
        return
    fi
    warn "adding this computer did not finish; run 'cua host setup' to try again (sign in first with 'cua auth login', or 'cua auth login --remote' over ssh)"
}

# Add this machine with a pairing code (Add a computer in the app): joins
# the account (or team) that made the code, with no sign-in here.
host_pair() {
    set -- "$cua_bin" host setup --pair "$pair_code"
    if [ -n "$relay_url" ]; then set -- "$@" --relay "$relay_url"; fi
    if [ "$dry_run" = 1 ]; then
        say "[dry-run] $*"
        return
    fi
    # A CLI built before pairing exists would fail with a bare
    # "unexpected argument '--pair'"; say what to do instead.
    setup_help="$("$cua_bin" host setup --help 2>&1 </dev/null)"
    if ! printf '%s\n' "$setup_help" | grep -q -e '--pair'; then
        die "the installed cua CLI ($("$cua_bin" --version 2>/dev/null || echo unknown)) cannot add a machine with a code (no 'cua host setup --pair'); build a newer checkout (git pull && scripts/install/install.sh) or sign in instead: cua auth login && cua host setup"
    fi
    # It provides Spaces and keeps its screen private, as a computer added
    # by signing in does; sharing its desktop is a choice on its page.
    if printf '%s\n' "$setup_help" | grep -q -e '--no-desktop'; then set -- "$@" --no-desktop --provide-spaces; fi
    step "Adding this computer to your account (cua host setup --pair)"
    if "$@" </dev/null; then
        say ""
        say "This machine is added. It shows up in Cua Spaces on your other devices in a few seconds."
        return
    fi
    die "adding this machine did not finish; if the code expired or was used, make a new one in Cua Spaces (Add a computer) and run: cua host setup --pair <code>"
}

# ---------------------------------------------------------------- onboarding

# "a, b and c" from the arguments.
join_and() {
    case $# in
    1) printf '%s' "$1" ;;
    2) printf '%s and %s' "$1" "$2" ;;
    *) printf '%s, %s and %s' "$1" "$2" "$3" ;;
    esac
}

# Where to open the app from, in plain words.
app_where() {
    printf 'open Cua Spaces from %s' "${app_path%/*}"
}

# The closing lines: what was installed, then what to do next, in plain words.
summary() {
    [ "$dry_run" = 0 ] && [ -z "$pair_code" ] || return 0
    set --
    [ -z "$did_cli" ] || set -- "$@" "the command-line tools"
    [ -z "$did_app" ] || set -- "$@" "the Cua Spaces app"
    [ -z "$did_driver" ] || set -- "$@" "Cua Driver"
    say ""
    if [ $# -gt 0 ]; then
        checked=""
        [ -z "$did_cli$did_app" ] || checked=" (built from source)"
        say "Installed $(join_and "$@")$checked."
    fi
    if [ -n "$did_host" ]; then
        say "This computer is added to your account. It shows up in Cua Spaces on your other devices."
    fi
    if [ -n "$did_app" ]; then
        if [ "$signed_in" = 1 ]; then
            say "Next: $(app_where)."
        else
            say "Next: $(app_where). It guides you through signing in and connecting your AI agents. Signing in adds this computer to your account."
        fi
        if [ "$want_cli" = 1 ]; then
            if [ "$signed_in" = 1 ]; then
                say 'To connect more AI agents later, run "cua agents setup" in the Terminal.'
            else
                say 'Prefer the Terminal? Run "cua auth login" to sign in, then "cua agents setup" to connect your AI agents.'
            fi
        fi
    elif [ "$want_cli" = 1 ]; then
        if [ "$signed_in" = 1 ]; then
            say 'Next: run "cua agents setup" to connect your AI agents.'
        else
            say 'Next: run "cua auth login" to sign in, then "cua agents setup" to connect your AI agents.'
            say '(No web browser on this computer? Run "cua auth login --remote" instead.)'
        fi
        if [ -z "$did_host" ] && [ "$no_host" = 0 ]; then
            say 'To add this computer to your account, run "cua host setup" after signing in.'
        fi
    fi
}

# The items this run installs, for --dry-run.
plan_items() {
    out=""
    [ "$want_cli" != 1 ] || out="the cua command-line tools"
    [ "$sel_spaces" != 1 ] || out="${out:+$out, }the Cua Spaces app"
    [ "$sel_driver" != 1 ] || out="${out:+$out, }Cua Driver (its MCP server and skill in your agents)"
    [ "$sel_host" != 1 ] || out="${out:+$out, }host setup"
    printf '%s\n' "${out:-nothing}"
}

run_onboarding() {
    # --pair: the code stands in for the account; nothing to sign in to.
    [ -z "$pair_code" ] || return 0
    if [ "$want_cli" = 0 ] || [ "$onboarding" = 0 ] || [ "$dry_run" = 1 ]; then
        return
    fi
    # Cua Driver on its own: `cua auth login` would end in the Cua Spaces
    # agent onboarding (the cua MCP server and skills), which was not picked.
    if [ "$sel_driver" = 1 ] && [ "$sel_spaces" = 0 ] && [ "$sel_host" = 0 ]; then
        info "skipping sign-in: only Cua Driver was selected"
        return
    fi
    # No terminal to sign in on (piped install, -y, or nobody at the
    # console over ssh): `cua auth login` needs one, so the summary says
    # how to finish instead.
    tty_ok || return 0
    say ""
    step "Signing in to Cua"
    # `cua auth login` runs agent onboarding after a successful sign-in.
    # No browser here (over ssh, or Linux without a display): a device code
    # to approve in a browser on another device.
    set -- auth login
    if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || { [ "$os" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }; then
        set -- "$@" --remote
    fi
    if "$cua_bin" "$@" </dev/tty; then
        signed_in=1
    else
        warn "sign-in did not finish. Run \"cua auth login\" later (add --remote if this computer has no web browser)"
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
        step "Dry run: nothing will be changed"
        say "[dry-run] would install: $(plan_items)"
    fi
    info "platform $platform, checkout $repo_root"
    check_build_tools
    cua_bin="${existing_cua:-cua}"
    app_path=""
    if [ "$want_cli" = 1 ]; then
        install_cli
    fi
    runtime_failed=0
    if [ "$os" = linux ] && [ "$want_cli" = 1 ] && { [ "$dry_run" = 1 ] || has "$cua_bin"; }; then
        linux_runtime
        if [ "$dry_run" != 1 ]; then
            "$cua_bin" runtime doctor || runtime_failed=1
        fi
    fi
    if [ "$sel_spaces" = 1 ]; then
        install_app_darwin
        write_mode
    fi
    if [ "$sel_driver" = 1 ]; then
        install_driver
    fi
    run_onboarding
    # Signing in adds this computer (unless --no-host); --select host adds
    # it even without a sign-in here.
    if [ "$sel_host" = 1 ] || { [ "$signed_in" = 1 ] && [ "$no_host" = 0 ]; }; then
        host_setup
    fi
    summary
    if [ -n "$path_hint" ]; then
        say ""
        say "$path_hint"
    fi
    return "$runtime_failed"
}

main "$@"
