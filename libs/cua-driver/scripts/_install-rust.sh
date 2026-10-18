#!/usr/bin/env bash
# _install-rust.sh — private helper invoked by libs/cua-driver/scripts/install.sh.
# Not intended for direct invocation; user-facing commands go through install.sh.
#
# It builds cua-driver from this checkout and installs it as
# `cua-driver-local` through install-local.sh (the single source of truth for
# the local build), then exposes it as `cua-driver` in the same bin directory.
# There is no release download.
#
# Flags (same shape as install.sh; forwarded to install-local.sh):
#   --bin-dir <path>         install the visible binary to <path> instead of
#                            ~/.local/bin
#   --autostart              register an auto-start daemon (macOS: LaunchAgent;
#                            Linux: systemd user unit). Default off.
#   --require-stable-signing on macOS, refuse to install an ad-hoc-signed app
#   --no-connect             do not connect Claude Code, Codex and Cursor to Cua
#                            Driver (and skip the permission guide); same as
#                            CUA_DRIVER_NO_CONNECT=1
#   --no-test                do not run `cua-driver test` at the end; same as
#                            CUA_DRIVER_NO_TEST=1
#
# After installing, this script runs `cua-driver connect` (connects every
# supported agent found on the computer, installs the skill pack), then on
# macOS, when run from a terminal outside CI, `cua-driver permissions grant`
# (opens the permission guide and waits), then `cua-driver test`. Each step is
# skipped when the installed binary does not have it yet, and a failing step
# never fails the install. install-local.sh already printed the post-install
# hints while it built the binary.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_LOCAL="$SCRIPT_DIR/install-local.sh"

clone_hint() {
    printf 'cua-driver is installed from a source checkout now. Build it locally:\n\n' >&2
    printf '  git clone https://github.com/chriswritescode-dev/cua.git\n' >&2
    printf '  cd cua\n' >&2
    printf '  git checkout local-build\n' >&2
    printf '  /bin/bash libs/cua-driver/scripts/install.sh\n\n' >&2
}

if [[ ! -f "$REPO_ROOT/libs/cua-driver/rust/Cargo.toml" || ! -f "$INSTALL_LOCAL" ]]; then
    clone_hint
    printf 'error: %s is not a cua-driver checkout\n' "$SCRIPT_DIR" >&2
    exit 1
fi

BIN_DIR="${CUA_DRIVER_LOCAL_INSTALL_DIR:-$HOME/.local/bin}"
NO_CONNECT="${CUA_DRIVER_NO_CONNECT:-0}"
NO_TEST="${CUA_DRIVER_NO_TEST:-0}"
FORWARDED_ARGS=()
PASSTHROUGH=0
while [[ $# -gt 0 ]]; do
    if [[ "$PASSTHROUGH" == "1" ]]; then
        FORWARDED_ARGS+=("$1"); shift; continue
    fi
    case "$1" in
        --experimental-rust) shift ;;
        --backend=rust)      shift ;;
        --backend=swift)     shift ;;
        --backend=*)
            printf 'error: unknown backend %q; supported: rust\n' "${1#*=}" >&2
            exit 2
            ;;
        --channel | --channel=* | --require-signature | --no-modify-path)
            printf 'error: %s is a release-installer flag; builds come from the checkout now\n' "${1%%=*}" >&2
            printf 'Use --require-stable-signing for a signed macOS app, and install-local.sh for the rest.\n' >&2
            exit 2
            ;;
        --no-connect) NO_CONNECT=1; shift ;;
        --no-test) NO_TEST=1; shift ;;
        --bin-dir)
            [[ -n "${2:-}" ]] || { printf 'error: --bin-dir requires a value\n' >&2; exit 2; }
            BIN_DIR="$2"; FORWARDED_ARGS+=("$1" "$2"); shift 2 ;;
        --bin-dir=*)
            BIN_DIR="${1#*=}"; FORWARDED_ARGS+=("$1"); shift ;;
        --)                  PASSTHROUGH=1; shift ;;
        *)                   FORWARDED_ARGS+=("$1"); shift ;;
    esac
done

rc=0
/bin/bash "$INSTALL_LOCAL" --release ${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"} || rc=$?
if [[ "$rc" -ne 0 ]]; then
    exit "$rc"
fi

BIN_LINK="$BIN_DIR/cua-driver"
ln -sf cua-driver-local "$BIN_LINK"
printf 'installed %s -> cua-driver-local\n' "$BIN_LINK"

# Ask the installed driver: the switch survives updates, so a user who turned
# it on must not read that it is off.
if command -v kwin_wayland >/dev/null 2>&1; then
    KWIN_STATUS="$("$BIN_LINK" kwin-capture status 2>/dev/null || true)"
    case "$KWIN_STATUS" in
        "kwin window capture: on"*|"kwin window capture: override-portal-deny"*)
            while IFS= read -r line; do
                [[ -z "$line" ]] || printf '==> %s\n' "$line"
            done <<<"$KWIN_STATUS"
            ;;
        *)
            printf '==> KWin window capture is off; `cua-driver kwin-capture on` turns it on\n'
            ;;
    esac
fi

# Connect the user's agents, grant permissions and run the self-test, so one
# run leaves Cua Driver ready to use. Every call uses the absolute path
# ($BIN_DIR may not be on this shell's PATH yet) and is guarded so an older
# binary without `connect` / `test` falls back to the hints install-local.sh
# printed. A failing step never fails the install.
driver_has_command() {
    # `--help` prints one "Subcommands:" line; older binaries do not list the
    # new ones (and exit 0 for any argument, so the exit code says nothing).
    "$BIN_LINK" --help 2>&1 | grep -E "^Subcommands:.*(: |, )$1(,|\$)" >/dev/null 2>&1
}

CONNECTED_AGENT=""
if [[ "$NO_CONNECT" != "1" ]] && driver_has_command connect; then
    CONNECT_OUT="$("$BIN_LINK" connect 2>/dev/null)" && CONNECT_RC=0 || CONNECT_RC=$?
    [[ -n "$CONNECT_OUT" ]] && printf '%s\n' "$CONNECT_OUT"
    if [[ "$CONNECT_RC" == "0" ]]; then
        for _agent in "Claude Code" "Codex" "Cursor"; do
            if printf '%s\n' "$CONNECT_OUT" | grep -E "^$_agent: (already )?connected\$" >/dev/null; then
                CONNECTED_AGENT="$_agent"
                break
            fi
        done
    fi
fi

# The permission guide needs a person at a terminal: stdin and stdout attached
# and no CI.
if [[ "$NO_CONNECT" != "1" && "$(uname -s)" == "Darwin" && -t 0 && -t 1 && -z "${CI:-}" ]]; then
    echo ""
    echo "Next, turn on the two switches Cua Driver needs. A guide window will help."
    "$BIN_LINK" permissions grant || echo "Permissions are not finished. Run later: $BIN_LINK permissions grant"
fi

if [[ "$NO_TEST" != "1" ]] && driver_has_command test; then
    echo ""
    "$BIN_LINK" test || echo "The test did not pass. Run it again later: $BIN_LINK test"
fi

if [[ -n "$CONNECTED_AGENT" ]]; then
    echo ""
    echo "Done. Ask $CONNECTED_AGENT (restart it first if it is open): \"Use Cua Driver to open TextEdit and write a haiku.\""
    exit 0
fi
