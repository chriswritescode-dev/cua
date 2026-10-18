# Cua installers

Two scripts build and install the `cua` CLI, cua-spacesd, the Cua Spaces app and agent extras from a repository checkout, then sign in and set up your AI coding agents with `cua auth login`. Two more remove them again: [`uninstall.sh` and `uninstall.ps1`](#uninstall).

```sh
git clone https://github.com/chriswritescode-dev/cua.git
cd cua
git checkout local-build
scripts/install/install.sh
```

```powershell
git clone https://github.com/chriswritescode-dev/cua.git
cd cua
git checkout local-build
powershell -ExecutionPolicy Bypass -File scripts\install\install.ps1
```

There are no release downloads: the scripts run from the checkout that contains them, build `cua` and `cua-spacesd` with cargo, and fail with clone instructions when run from a pipe or from outside a checkout. Updates are explicit: pull the repository and rerun the installer.

The Cua Spaces app is the graphical path. Its first run installs the bundled `cua` CLI onto PATH, signs in and runs the same agent onboarding (`cua agents setup`).

## Choose what to install

In a terminal, install.sh first says what Cua Spaces is, then lists what to add to the command-line tools (the `cua` CLI; arrow or number keys to move or toggle, space to select, Enter to install; install.ps1 asks for numbers to toggle, with a line under each row). The command-line tools are always installed, so they are not a row. Adding this computer to your account (`cua host setup`) is not a row either: signing in adds it. After `cua auth login` succeeds, the installer runs `cua host setup --no-desktop --provide-spaces`: the computer provides Spaces and keeps its screen private (a computer set up before keeps its settings). `--no-host` signs in only. Over ssh, or on Linux without a display, the sign-in uses a device code (`cua auth login --remote`). Without a terminal, with `--yes`, or with `CUA_INSTALL_NONINTERACTIVE=1`, the defaults plus `--select` are installed without asking. `--only` installs exactly the listed items plus the CLI and never shows the list.

| Item | What it does | Default |
|---|---|---|
| `cli` | Builds the `cua` CLI and cua-spacesd with cargo and installs both | Always (not with `--app-only`) |
| `spaces` | Builds and installs the Cua Spaces app | On for macOS 26 or later; no source build for Linux or Windows yet |
| `cua-driver` | Builds cua-driver with `libs/cua-driver/scripts/install-local.sh` (`install-local.ps1` on Windows), exposes it as `cua-driver`, then `cua agents setup --cua-driver --agents all --yes` registers its skill and MCP server for your agents | Off |
| `host` | Runs `cua host setup` after sign-in so others on your account can reach this machine | Off |

```sh
scripts/install/install.sh --select cua-driver    # checklist with cua-driver ticked
scripts/install/install.sh --only cua-driver,host # no checklist
```

For cua-driver, `--prefix DIR` becomes `--bin-dir DIR/bin`. The driver installer needs bash on macOS and Linux. install-local builds and installs the separate `cua-driver-local` product; install.sh adds a `cua-driver` link next to it so agents and the docs keep working.

## Options

| install.sh | install.ps1 | Effect |
|---|---|---|
| `--select a,b` | `-Select a,b` | Preselect items (`spaces`, `cua-driver`, `host`); the list still shows |
| `--only a,b` | `-Only a,b` | Exactly these items plus the CLI, no list |
| `--cli-only` | `-CliOnly` | Only the `cua` CLI (same as `--only cli`) |
| `--app-only` | `-AppOnly` | Only the Cua Spaces app, no CLI (cannot be combined with `cua-driver` or `host`) |
| `--mode host\|client` | `-Mode host\|client` | Preselect the app's first-run choice (implies `spaces`) |
| `--prefix DIR` | `-Prefix DIR` | Install under `DIR/bin` (and `DIR/Applications` on macOS) |
| `--modify-path` | `-ModifyPath` | Add the bin dir to your shell profile or user PATH without asking |
| `--no-modify-path` | `-NoModifyPath` | Never edit the profile or user PATH; print the command instead |
| `--no-onboarding` | `-NoOnboarding` | Skip `cua auth login` (and so adding this computer) |
| `--no-host` | `-NoHost` | Sign in only; do not add this computer to your account |
| `--no-provide-spaces` | `-NoProvideSpaces` | Add this computer without creating Spaces for your other devices on it |
| `--no-skills` | `-NoSkills` | With cua-driver, add only its MCP server to your agents, not its skill |
| `-v`, `--verbose` | `-Verbose` | Print every step: the checkout, each build and install. Also `CUA_INSTALL_VERBOSE=1` |
| `--dry-run` | `-DryRun` | Print the plan, change nothing |
| `--yes` | `-Yes` | Accept the current selection and every prompt |

`--only` and `--select` cannot be combined, nor can `--cli-only` with other items. Set `CUA_INSTALL_NONINTERACTIVE=1` to never prompt.

## Build commands

| Component | Command | Binary |
|---|---|---|
| `cua` | `cargo build --release -p cua-cli --manifest-path libs/cua/Cargo.toml` | `libs/cua/target/release/cua` |
| cua-spacesd | `cargo build --release --manifest-path libs/cua-spacesd/Cargo.toml -p cua-spacesd` | `libs/cua-spacesd/target/release/cua-spacesd` |
| cua-driver | `libs/cua-driver/scripts/install-local.sh --release` | `~/.local/bin/cua-driver-local` |
| Cua Spaces (macOS) | `apps/cua-spaces-macos/scripts/build-release.sh --out DIR` | `DIR/Cua Spaces.app` |

`CARGO_TARGET_DIR` is honoured the way cargo honours it. On macOS the installer adds the Swift runtime rpath (`-Wl,-rpath,/usr/lib/swift`) to the cua-spacesd build so the installed binary starts outside the build tree. On Linux, after the CLI install, the installer makes sure a VM runtime is there (`cua runtime setup qemu` when QEMU or Docker is missing) and finishes with `cua runtime doctor`.

## What it prints

One plain line per step ("Building the cua CLI from ...", "Building cua-spacesd from ...", "Building Cua Driver and installing it into ..."), then what was installed and what to do next: open Cua Spaces, or sign in and run `cua agents setup` to connect your AI agents. `--verbose` adds `cua-install:` lines with the checkout and every installed path.

Questions read from the terminal, never from the script on stdin. With no terminal to ask on, the usual choices apply and the installer says so once. End of input (Ctrl-D, a closed terminal) is never an answer: the install questions take their default, and the PATH question leaves your profile alone.

## Where things go

| | CLI and cua-spacesd | App |
|---|---|---|
| macOS | `~/.local/bin/cua` and `~/.local/bin/cua-spacesd` (`/usr/local/bin` as root) | `/Applications` if writable, else `~/Applications` (macOS 26 or later, skipped on older macOS) |
| Linux | same as macOS | No source app build yet; the CLI and cua-spacesd install normally |
| Windows | `%LOCALAPPDATA%\Programs\cua\bin\cua.exe` and `cua-spacesd.exe` | No source app build yet; the CLI and cua-spacesd install normally |

cua-host finds cua-spacesd next to the running `cua`, which is why both binaries go to the same directory.

cua-driver lands where install-local puts it: `~/.local/bin/cua-driver-local` (or `DIR/bin` with `--prefix` on macOS and Linux), `%LOCALAPPDATA%\Programs\Cua\cua-driver-local\bin` on Windows. install.sh adds `cua-driver` next to it. On Windows the driver keeps its own directory even with `--prefix`.

On Linux and macOS, when the bin dir is not on PATH, install.sh in a terminal asks once ("Add ... to PATH in ~/.zshrc? [Y/n]", Enter = yes). Without a terminal, or with `--yes`, it prints the exact one-line command for your shell instead and never edits a profile unless you pass `--modify-path`; `--no-modify-path` never edits it. `--pair` runs the CLI by its absolute path, so it works before PATH changes. install.ps1 adds the user PATH by default (`-NoModifyPath` opts out). `--mode` writes `~/.cua/spaces-install-mode`, which the app reads on first launch.

`--pair` (`-Pair`) on a computer that already has Cua reuses what is there: a `cua` that knows `host setup --pair` (on PATH, in `~/.local/bin`, or inside the Cua Spaces app) and, on macOS, the installed app. It then builds nothing. `--prefix` and `CUA_INSTALL_REINSTALL=1` build anyway; an older `cua` without `--pair` is replaced as before.

MDM on macOS: `apps/cua-spaces/scripts/build-pkg.sh` builds a `.pkg` (signed with `--sign`, install mode baked with `--mode`) that installs the app and links `/usr/local/bin/cua` to the CLI bundled inside it. The macOS app is the SwiftUI app (`apps/cua-spaces-macos`, `scripts/build-release.sh`), which carries the CLI as `Contents/MacOS/cua`; the Linux and Windows Electron app (`apps/cua-spaces-desktop`) bundles it itself.

## Uninstall

```sh
curl -fsSL https://cua.ai/uninstall.sh | sh
```

```powershell
irm https://cua.ai/uninstall.ps1 | iex
```

It lists what it found, asks once (`--yes` skips the question; without a terminal it refuses to remove anything unless you pass `--yes`), and can be run again at any time: a computer with nothing left, or only part of Cua, is fine. It only touches Cua's own paths and never a file outside them.

| install.sh | install.ps1 | Effect |
|---|---|---|
| (default) | (default) | Removes the app, the CLI, the host service, Cua Spaces' agent skills and MCP entry, launch at login, your sign-in and Cua's settings and caches. Keeps Spaces and their data, and Cua Driver's and other tools' entries in your agents |
| `--keep-data` | `-KeepData` | Keeps `~/.cua` (settings, the Spaces registry, the Cua Volume cache, the device key) and the app's settings. Still removes programs, services, integrations and the sign-in |
| `--delete-spaces` | `-DeleteSpaces` | Also deletes the Spaces on this computer and their data: Space disks, the local Cua Volume files, the Keyvault. Running Spaces are listed and stopped first; asks you to type `delete` (not with `--yes`). Cannot be combined with `--keep-data` |
| `--keep-permissions` | | Keeps the macOS permissions granted to the Cua Spaces app (macOS only; by default they are reset before the app is removed) |
| `--all` | `-All` | Also runs the Cua Driver uninstaller, takes Cua Driver's skill and MCP server out of your agents (`cua agents remove --include-cua-driver`) and, on macOS, runs Lume's uninstaller |
| `--prefix DIR` | `-Prefix DIR` | Also removes what `install.sh --prefix DIR` put under `DIR/bin` and `DIR/Applications` |
| `--no-modify-path` | `-NoModifyPath` | Never edits your shell profile (user PATH on Windows) |
| `--dry-run` | `-DryRun` | Prints what would be removed, changes nothing. It runs `cua agents remove --dry-run` to list the agent skills and MCP entries one by one |
| `--yes` | `-Yes` | Accepts every prompt |

What it removes, in this order (each step is best effort and bounded, so one failure never stops the rest):

1. Quits the Cua Spaces app, lists the Spaces on this computer and stops the running ones (their disks stay).
2. `cua host remove --force --uninstalling`: unregisters this computer from the relay and removes the host service. When `cua` is not there to do it, it removes the service itself (launchd `com.trycua.spacesd.host` on macOS, the systemd unit `cua-spacesd-host` on Linux, the `Cua\SpacesdHost` scheduled task on Windows, and the names used before the rename).
3. `cua agents remove --agents all --yes`: the Cua Spaces skills and the `cua` MCP server (`cua-local` for Local) in your agents. The `cua-driver` skill and MCP server (`cua-driver-local` for Local) and every other tool's entries stay, unless `--all` adds `--include-cua-driver`. The record `cua agents remove` works from (`~/.cua/agent-setup.json`) stays unless `--delete-spaces`.
4. `cua daemon stop`, and the Cua Volume mount (`~/Cua Volume` on macOS, `~/cua-volume` on Linux) is unmounted before any file is deleted.
5. Signs out (`cua auth logout`, which revokes the session) and removes a leftover `credentials.json`.
6. The app: `Cua Spaces.app` in `/Applications` and `~/Applications` (macOS, only when its bundle id is Cua's). On macOS the permissions macOS granted the app are reset with `tccutil` while the app is still installed; `--keep-permissions` skips the reset.
7. The CLI: `~/.local/bin/cua`, `/usr/local/bin/cua` (and `DIR/bin/cua`), only when it is the Cua CLI (`cua --version` says `cua X.Y.Z`, or a link into the app). A `cua` from pip, npm or Homebrew is left alone and named.
8. The `# Added by the cua installer` PATH line in your shell profile (kept while `cua-driver` or `lume` still lives in the same folder).
9. Credentials: the macOS Keychain items of service `run.cua.ai` and `staging.run.cua.ai`, and the Windows Credential Manager entries `cua-cli.*.run.cua.ai`. With `--delete-spaces` also the Keyvault master key (`Cua Keyvault`).
10. Settings and caches: in `~/.cua` the config, caches, telemetry, runtimes, skills, the host folder and the Cua Volume cache; on macOS the app's Application Support, Preferences, Caches, saved state and WebKit folders. Everything else in `~/.cua` (sandboxes, vmm, images, `volume/data`, the Keyvault, trajectories, the Spaces registry) stays until you pass `--delete-spaces`.

Tests: `uninstall.Tests.ps1` (every step that touches the machine is mocked) and `test_uninstall.py` (a throwaway HOME, recording fakes for `cua`, `launchctl`, `systemctl`, `security`, and an `rm` that refuses anything outside the sandbox).

## Tests

```sh
scripts/install/tests/run.sh                     # install.sh against a fake cargo and checkout
uv run python -m unittest discover scripts/install/tests
scripts/install/tests/docker-pester.sh           # install.ps1 Pester tests in a container
```

`run.sh` uses a fake HOME, fake `cargo` and `git` shims, and `--prefix` temp dirs; it never writes to your real home, `/Applications` or PATH. The `installer-smoke` job in `.github/workflows/ci-installers.yml` runs the suites on Linux, macOS and Windows.

Test hooks: `CUA_INSTALL_OS`, `CUA_INSTALL_ARCH`, `CUA_INSTALL_NONINTERACTIVE`, `CUA_INSTALL_REINSTALL`, `CARGO_TARGET_DIR`. With util-linux `script`, run.sh drives the checklist through a pty.

## Release manifest

`release_manifest.py`, `check_release_manifest.py`, `updater_feed.py` and `stamp_installers.py` remain release-publication tools for the CD workflows. The installers above do not read a manifest and download nothing.
