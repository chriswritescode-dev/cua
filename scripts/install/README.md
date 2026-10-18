# Cua installers

Two scripts build and install the `cua` CLI, cua-spacesd, the Cua Spaces app and agent extras from a repository checkout, then sign in and set up your AI coding agents with `cua auth login`.

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

In a terminal, install.sh shows a checklist (arrow or number keys to move and toggle, space to toggle, Enter to install; install.ps1 asks for numbers to toggle). The CLI row is locked. Without a terminal, with `--yes`, or with `CUA_INSTALL_NONINTERACTIVE=1`, the defaults plus `--select` are installed without asking. `--only` installs exactly the listed items plus the CLI and never shows the checklist.

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
| `--select a,b` | `-Select a,b` | Preselect items (`spaces`, `cua-driver`, `host`); the checklist still shows |
| `--only a,b` | `-Only a,b` | Exactly these items plus the CLI, no checklist |
| `--cli-only` | `-CliOnly` | Only the `cua` CLI (same as `--only cli`) |
| `--app-only` | `-AppOnly` | Only the Cua Spaces app, no CLI (cannot be combined with `cua-driver` or `host`) |
| `--mode host\|client` | `-Mode host\|client` | Preselect the app's first-run choice (implies `spaces`) |
| `--prefix DIR` | `-Prefix DIR` | Install under `DIR/bin` (and `DIR/Applications` on macOS) |
| `--modify-path` | `-ModifyPath` | Add the bin dir to your shell profile or user PATH without asking |
| `--no-modify-path` | `-NoModifyPath` | Never edit the profile or user PATH; print the command instead |
| `--no-onboarding` | `-NoOnboarding` | Skip `cua auth login` |
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

`CARGO_TARGET_DIR` is honoured the way cargo honours it. On macOS the installer adds the Swift runtime rpath (`-Wl,-rpath,/usr/lib/swift`) to the cua-spacesd build so the installed binary starts outside the build tree.

## Where things go

| | CLI and cua-spacesd | App |
|---|---|---|
| macOS | `~/.local/bin/cua` and `~/.local/bin/cua-spacesd` (`/usr/local/bin` as root) | `/Applications` if writable, else `~/Applications` (macOS 26 or later, skipped on older macOS) |
| Linux | same as macOS | No source app build yet; the CLI and cua-spacesd install normally |
| Windows | `%LOCALAPPDATA%\Programs\cua\bin\cua.exe` and `cua-spacesd.exe` | No source app build yet; the CLI and cua-spacesd install normally |

cua-host finds cua-spacesd next to the running `cua`, which is why both binaries go to the same directory.

cua-driver lands where install-local puts it: `~/.local/bin/cua-driver-local` (or `DIR/bin` with `--prefix` on macOS and Linux), `%LOCALAPPDATA%\Programs\Cua\cua-driver-local\bin` on Windows. install.sh adds `cua-driver` next to it. On Windows the driver keeps its own directory even with `--prefix`.

On Linux and macOS, when the bin dir is not on PATH, install.sh in a terminal asks once ("Add ... to PATH in ~/.zshrc? [Y/n]", Enter = yes). Without a terminal, or with `--yes`, it prints the exact one-line command for your shell instead and never edits a profile unless you pass `--modify-path`; `--no-modify-path` never edits it. `--pair` runs the CLI by its absolute path, so it works before PATH changes. install.ps1 adds the user PATH by default (`-NoModifyPath` opts out). `--mode` writes `~/.cua/spaces-install-mode`, which the app reads on first launch.

`--pair` (`-Pair`) on a computer that already has Cua reuses what is there: a `cua` that knows `host setup --pair` (on PATH, in `~/.local/bin`, or inside the Cua Spaces app) and, on macOS, the installed app. It then builds nothing. `--prefix` and `CUA_INSTALL_REINSTALL=1` install anyway; an older `cua` without `--pair` is replaced as before.

MDM on macOS: `apps/cua-spaces/scripts/build-pkg.sh` builds a `.pkg` (signed with `--sign`, install mode baked with `--mode`) that installs the app and links `/usr/local/bin/cua` to the CLI bundled inside it. The macOS app is the SwiftUI app (`apps/cua-spaces-macos`, `scripts/build-release.sh`), which carries the CLI as `Contents/MacOS/cua`; the Linux and Windows Electron app (`apps/cua-spaces-desktop`) bundles it itself.

## Tests

```sh
scripts/install/tests/run.sh                     # install.sh against a fake cargo and checkout
python3 -m unittest discover scripts/install/tests
scripts/install/tests/docker-pester.sh           # install.ps1 Pester tests in a container
```

`run.sh` uses a fake HOME, fake `cargo` and `git` shims, and `--prefix` temp dirs; it never writes to your real home, `/Applications` or PATH. The `installer-smoke` job in `.github/workflows/ci-installers.yml` runs the suites on Linux, macOS and Windows.

Test hooks: `CUA_INSTALL_OS`, `CUA_INSTALL_ARCH`, `CUA_INSTALL_NONINTERACTIVE`, `CUA_INSTALL_REINSTALL`. With util-linux `script`, run.sh drives the checklist through a pty.

## Release manifest

`release_manifest.py`, `check_release_manifest.py`, `updater_feed.py` and `stamp_installers.py` remain release-publication tools for the CD workflows. The installers above do not read a manifest and download nothing.
