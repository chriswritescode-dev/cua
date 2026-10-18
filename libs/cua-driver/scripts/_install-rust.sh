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

ln -sf cua-driver-local "$BIN_DIR/cua-driver"
printf 'installed %s/cua-driver -> cua-driver-local\n' "$BIN_DIR"
