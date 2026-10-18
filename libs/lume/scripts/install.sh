#!/bin/bash
set -e

# Lume source installer.
#
# Run it from a checkout of the fork:
#
#   git clone https://github.com/chriswritescode-dev/cua.git
#   cd cua
#   git checkout local-build
#   libs/lume/scripts/install.sh
#
# It builds Lume with libs/lume/scripts/build/build-release.sh (the documented
# local build), installs the .app bundle under ~/.local/share/lume, then puts
# the `lume` wrapper in the install directory. The build also installs its own
# wrapper under ~/.local/bin.
#
# Options:
#   --install-dir DIR         Install the `lume` wrapper to DIR (default: $HOME/.local/bin)
#   --port PORT               Port for lume serve (default: 7777)
#   --no-background-service   Do not setup the Lume background service (LaunchAgent)
#   --help                    Display this help message

# Define colors for output
BOLD=$(tput bold 2>/dev/null || echo "")
NORMAL=$(tput sgr0 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")

clone_hint() {
  echo "Lume is installed from a source checkout now. Build it locally:" >&2
  echo "" >&2
  echo "  git clone https://github.com/chriswritescode-dev/cua.git" >&2
  echo "  cd cua" >&2
  echo "  git checkout local-build" >&2
  echo "  libs/lume/scripts/install.sh" >&2
  echo "" >&2
}

# Check if running as root or with sudo
if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO_USER" ]; then
  echo "${RED}Error: Do not run this script with sudo or as root.${NORMAL}"
  echo "If you need to install to a system directory, create it first with proper permissions:"
  echo "  sudo mkdir -p /desired/directory && sudo chown $(whoami) /desired/directory"
  echo "Then run the installer normally:"
  echo "  ./install.sh --install-dir=/desired/directory"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LUME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$LUME_DIR/scripts/build/build-release.sh"

if [ ! -f "$LUME_DIR/Package.swift" ] || [ ! -f "$BUILD_SCRIPT" ]; then
  clone_hint
  echo "${RED}Error: $SCRIPT_DIR is not a Lume checkout.${NORMAL}" >&2
  exit 1
fi

# Default installation directory (user-specific, doesn't require sudo)
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# Default .app bundle installation directory
APP_INSTALL_DIR="$HOME/.local/share/lume"

# Option to skip background service setup (default: install it)
INSTALL_BACKGROUND_SERVICE=true

# Default port for lume serve (default: 7777)
LUME_PORT=7777

# Parse command line arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift
      ;;
    --port)
      LUME_PORT="$2"
      shift
      ;;
    --no-background-service)
      INSTALL_BACKGROUND_SERVICE=false
      ;;
    --help)
      echo "${BOLD}${BLUE}Lume Source Installer${NORMAL}"
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --install-dir DIR         Install the wrapper to the specified directory (default: $DEFAULT_INSTALL_DIR)"
      echo "  --port PORT               Specify the port for lume serve (default: 7777)"
      echo "  --no-background-service   Do not setup the Lume background service (LaunchAgent)"
      echo "  --help                    Display this help message"
      echo ""
      echo "Examples:"
      echo "  $0                                   # Install to $DEFAULT_INSTALL_DIR and setup background service"
      echo "  $0 --install-dir=/usr/local/bin      # Install the wrapper to a system directory"
      echo "  $0 --port 7778                       # Use port 7778 instead of the default 7777"
      echo "  $0 --no-background-service           # Install without setting up the background service"
      echo "  INSTALL_DIR=/opt/lume $0             # Install to /opt/lume (legacy env var support)"
      exit 0
      ;;
    *)
      echo "${RED}Unknown option: $1${NORMAL}"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
  shift
done

echo "${BOLD}${BLUE}"
echo "  ⠀⣀⣀⡀⠀⠀⠀⠀⢀⣀⣀⣀⡀⠘⠋⢉⠙⣷⠀⠀ ⠀"
echo " ⠀⠀⢀⣴⣿⡿⠋⣉⠁⣠⣾⣿⣿⣿⣿⡿⠿⣦⡈⠀⣿⡇⠃⠀"
echo " ⠀⠀⠀⣽⣿⣧⠀⠃⢰⣿⣿⡏⠙⣿⠿⢧⣀⣼⣷⠀⡿⠃⠀⠀"
echo " ⠀⠀⠀⠉⣿⣿⣦⠀⢿⣿⣿⣷⣾⡏⠀⠀⢹⣿⣿⠀⠀⠀⠀⠀⠀"
echo " ⠀⠀⠀⠀⠀⠉⠛⠁⠈⠿⣿⣿⣿⣷⣄⣠⡼⠟⠁${NORMAL}${BOLD}  Lume Installer${NORMAL}"
echo "${BLUE}           macOS VM CLI and server${NORMAL}"
echo ""
echo "This script will build and install Lume from $LUME_DIR."

check_permissions() {
  SYSTEM_DIRS=("/usr/local/bin" "/usr/bin" "/bin" "/opt")

  NEEDS_ROOT=false
  for DIR in "${SYSTEM_DIRS[@]}"; do
    if [[ "$INSTALL_DIR" == "$DIR"* ]] && [ ! -w "$INSTALL_DIR" ]; then
      NEEDS_ROOT=true
      break
    fi
  done

  if [ "$NEEDS_ROOT" = true ]; then
    echo "${YELLOW}Warning: Installing to $INSTALL_DIR may require root privileges.${NORMAL}"
    echo "Consider these alternatives:"
    echo "  • Install to a user-writable location: $0 --install-dir=$HOME/.local/bin"
    echo "  • Create the directory with correct permissions first:"
    echo "    sudo mkdir -p $INSTALL_DIR && sudo chown $(whoami) $INSTALL_DIR"
    echo ""

    if [ ! -w "$INSTALL_DIR" ] && [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
      echo "${RED}Error: You don't have write permission to $INSTALL_DIR${NORMAL}"
      echo "Please choose a different installation directory or ensure you have the proper permissions."
      exit 1
    fi
  fi
}

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  if [ "$OS" != "darwin" ]; then
    echo "${RED}Error: Currently only macOS is supported.${NORMAL}"
    exit 1
  fi

  if [ "$ARCH" != "arm64" ]; then
    echo "${RED}Error: Lume only supports macOS on Apple Silicon (ARM64).${NORMAL}"
    exit 1
  fi

  PLATFORM="darwin-arm64"
  echo "Detected platform: ${BOLD}$PLATFORM${NORMAL}"
}

build_release() {
  echo "Building Lume from source..."
  bash "$BUILD_SCRIPT" || {
    echo "${RED}Error: the Lume build failed.${NORMAL}" >&2
    exit 1
  }
}

install_binary() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$APP_INSTALL_DIR"

  if [ ! -d "$LUME_DIR/.release/lume.app" ]; then
    echo "${RED}Error: the build produced no .release/lume.app in $LUME_DIR.${NORMAL}" >&2
    exit 1
  fi
  echo "Installing lume.app bundle..."

  if [ -f "$INSTALL_DIR/lume" ] && [ ! -L "$INSTALL_DIR/lume" ]; then
    if file "$INSTALL_DIR/lume" | grep -q "Mach-O"; then
      echo "Migrating from standalone binary to .app bundle..."
      rm -f "$INSTALL_DIR/lume"
    fi
  fi
  rm -rf "$INSTALL_DIR/lume_lume.bundle"

  rm -rf "$APP_INSTALL_DIR/lume.app"
  cp -R "$LUME_DIR/.release/lume.app" "$APP_INSTALL_DIR/"

  cat > "$INSTALL_DIR/lume" <<WRAPPER_EOF
#!/bin/sh
exec "$APP_INSTALL_DIR/lume.app/Contents/MacOS/lume" "\$@"
WRAPPER_EOF
  chmod +x "$INSTALL_DIR/lume"

  echo "${GREEN}Installation complete!${NORMAL}"
  echo "Lume installed to ${BOLD}$APP_INSTALL_DIR/lume.app${NORMAL}"
  echo "CLI available at ${BOLD}$INSTALL_DIR/lume${NORMAL}"

  if [ -n "${PATH##*"$INSTALL_DIR"*}" ]; then
    SHELL_NAME=$(basename "$SHELL")
    echo ""
    echo "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NORMAL}"
    echo "${YELLOW}║  ${BOLD}ACTION REQUIRED:${NORMAL}${YELLOW} $INSTALL_DIR is not in your PATH${NORMAL}"
    echo "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NORMAL}"
    echo ""
    case "$SHELL_NAME" in
      zsh)
        echo "Run these commands:"
        echo "  ${BOLD}echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.zshrc${NORMAL}"
        echo "  ${BOLD}source ~/.zshrc${NORMAL}"
        echo ""
        echo "Or restart your terminal after running the first command."
        ;;
      bash)
        echo "Run these commands:"
        echo "  ${BOLD}echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.bash_profile${NORMAL}"
        echo "  ${BOLD}source ~/.bash_profile${NORMAL}"
        echo ""
        echo "Or restart your terminal after running the first command."
        ;;
      fish)
        echo "Run this command:"
        echo "  ${BOLD}echo 'fish_add_path $INSTALL_DIR' >> ~/.config/fish/config.fish${NORMAL}"
        echo ""
        echo "Then restart your terminal."
        ;;
      *)
        echo "Add $INSTALL_DIR to your PATH in your shell profile file,"
        echo "then restart your terminal or source your profile."
        ;;
    esac
    echo ""
  fi
}

cleanup_deprecated_auto_updater() {
  UPDATER_SERVICE_NAME="com.trycua.lume_updater"
  UPDATER_PLIST_PATH="$HOME/Library/LaunchAgents/$UPDATER_SERVICE_NAME.plist"
  UPDATER_SCRIPT="$INSTALL_DIR/lume-update"

  if crontab -l 2>/dev/null | grep -q "lume-update"; then
    echo "Removing deprecated auto-updater cron job..."
    crontab -l 2>/dev/null | grep -v "lume-update" | crontab - 2>/dev/null || true
  fi

  if [ -f "$UPDATER_PLIST_PATH" ]; then
    echo "Removing deprecated auto-updater LaunchAgent..."
    launchctl unload "$UPDATER_PLIST_PATH" 2>/dev/null || true
    rm "$UPDATER_PLIST_PATH"
  fi

  if [ -f "$UPDATER_SCRIPT" ]; then
    rm "$UPDATER_SCRIPT"
  fi
}

setup_background_service() {
  if [ "$INSTALL_BACKGROUND_SERVICE" = true ]; then
    SERVICE_NAME="com.trycua.lume_daemon"
    PLIST_PATH="$HOME/Library/LaunchAgents/$SERVICE_NAME.plist"
    LUME_BIN="$INSTALL_DIR/lume"
    WRAPPER_SCRIPT="$INSTALL_DIR/lume-daemon"

    echo ""
    echo "Setting up LaunchAgent to run lume daemon on login..."

    mkdir -p "$HOME/Library/LaunchAgents"

    if [ -f "$PLIST_PATH" ]; then
      echo "Existing LaunchAgent found. Unloading..."
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    if [ -f "$WRAPPER_SCRIPT" ]; then
      rm -f "$WRAPPER_SCRIPT"
    fi

    cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LUME_BIN</string>
        <string>serve</string>
        <string>--port</string>
        <string>$LUME_PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/lume_daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/lume_daemon.error.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>SessionType</key>
    <string>Aqua</string>
</dict>
</plist>
EOF

    chmod 644 "$PLIST_PATH"
    touch /tmp/lume_daemon.log /tmp/lume_daemon.error.log
    chmod 644 /tmp/lume_daemon.log /tmp/lume_daemon.error.log

    echo "Loading LaunchAgent..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    echo "${GREEN}Lume daemon LaunchAgent installed and loaded. It will start automatically on login!${NORMAL}"
    echo "To check status: launchctl list | grep $SERVICE_NAME"
    echo "To view logs: tail -f /tmp/lume_daemon.log"
    echo ""
    echo "To remove the lume daemon service, run:"
    echo "  launchctl unload \"$PLIST_PATH\""
    echo "  rm \"$PLIST_PATH\""
  else
    SERVICE_NAME="com.trycua.lume_daemon"
    PLIST_PATH="$HOME/Library/LaunchAgents/$SERVICE_NAME.plist"
    if [ -f "$PLIST_PATH" ]; then
      echo "Removing existing Lume background service (LaunchAgent)..."
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      rm "$PLIST_PATH"
      echo "Lume background service (LaunchAgent) removed."
    else
      echo "Skipping Lume background service (LaunchAgent) setup as requested (use --no-background-service)."
    fi
  fi
}

main() {
  check_permissions
  detect_platform
  build_release
  install_binary

  echo ""
  echo "${GREEN}${BOLD}Lume has been successfully installed!${NORMAL}"
  echo "Run ${BOLD}lume${NORMAL} to get started."

  setup_background_service
  cleanup_deprecated_auto_updater

  echo ""
  echo "Updates are explicit. To update a source checkout, run:"
  echo "  ${BOLD}git pull && libs/lume/scripts/install.sh${NORMAL}"
}

main
