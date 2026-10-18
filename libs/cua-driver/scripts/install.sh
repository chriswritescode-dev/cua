#!/bin/bash
# cua-driver installer — build and install cua-driver from this checkout.
#
# Run it from a checkout of the fork:
#
#   git clone https://github.com/chriswritescode-dev/cua.git
#   cd cua
#   git checkout local-build
#   /bin/bash libs/cua-driver/scripts/install.sh
#
# Flags:
#   --bin-dir <path>         install the visible binary to <path> instead of
#                            ~/.local/bin
#   --autostart              register an auto-start daemon (macOS: LaunchAgent;
#                            Linux: systemd user unit). Default off.
#   --require-stable-signing on macOS, refuse to install an ad-hoc-signed app
#   --no-connect             do not connect Claude Code, Codex and Cursor, and
#                            skip the permission guide
#   --no-test                do not run `cua-driver test` at the end
#   --backend=rust           explicit Rust backend (no-op; Rust is the only option)
#   --experimental-rust      legacy alias for --backend=rust (no-op)
#   --backend=swift          retired Swift backend (no-op; accepted for compat)
#
# Env overrides:
#   CUA_DRIVER_LOCAL_INSTALL_DIR=PATH  same as --bin-dir
#   CUA_DRIVER_NO_CONNECT=1            same as --no-connect
#   CUA_DRIVER_NO_TEST=1               same as --no-test
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/_install-rust.sh"

if [[ ! -f "$HELPER" ]]; then
    printf 'error: installer helper not found at %s\n' "$HELPER" >&2
    printf 'Run this script from a clone of:\n' >&2
    printf '  git clone https://github.com/chriswritescode-dev/cua.git\n' >&2
    printf '  cd cua\n' >&2
    printf '  git checkout local-build\n' >&2
    printf '  /bin/bash libs/cua-driver/scripts/install.sh\n' >&2
    exit 1
fi

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
        --)                  PASSTHROUGH=1; shift ;;
        *)                   FORWARDED_ARGS+=("$1"); shift ;;
    esac
done

exec /bin/bash "$HELPER" ${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}
