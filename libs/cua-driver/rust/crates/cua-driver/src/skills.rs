//! `cua-driver skills {install|update|uninstall|status|path}` —
//! agent skill-pack management.
//!
//! The binary install scripts intentionally do NOT touch the user's
//! `~/.claude/skills/` (etc.) directories — too invasive for an
//! `irm | iex` / `curl | sh` one-liner that the user might be running
//! just to try the binary. Wiring up an agent is the explicit step:
//! `cua-driver mcp-config --client <agent>` installs the skill pack for
//! that agent by default (`--no-skills` opts out; see
//! [`install_for_client`]), and this verb installs it for every detected
//! agent: stage the skill pack bundled with the local build and symlink it
//! into each detected agent's skills dir.
//!
//! ## Subcommands
//!
//! - `install` — stage + link (idempotent: re-run is a no-op).
//! - `update` — same as `install --force`: re-stage even if a local copy
//!   already exists, refreshing content.
//! - `uninstall [--all]` — remove the agent symlinks. With `--all`, also
//!   delete the local copy under `<HomeDir>/skills/cua-driver/` (and the
//!   pre-rename `cua-driver-rs/` location if present).
//! - `status` — print local install state + per-agent link state.
//! - `path` — print `<HomeDir>/skills/cua-driver` (the local copy).
//!
//! Default install drops only the host platform's deep-dive .md
//! (WINDOWS.md / MACOS.md / LINUX.md — whichever matches). Pass
//! `--all-platforms` to keep all three (useful when assisting users
//! across OSes from one machine).
//!
//! ## Source
//!
//! The skill pack is always the locally built/bundled copy: `install-local.sh`
//! and `install-local.ps1` stage `Skills/cua-driver/` next to the installed
//! binary, and a checkout build can read it from the repository tree. Nothing
//! is downloaded from a release.
//!
//! ## Agent detection
//!
//! Same agent dirs as the Swift cua-driver installer detects:
//!
//! - Claude Code: `~/.claude/skills/`
//! - Codex:       `~/.agents/skills/`
//! - Cursor:      `~/.agents/skills/` (shared with Codex and Pi; Cursor also reads `~/.claude/skills/`)
//! - Pi:          `~/.agents/skills/` (shared global location; Pi also reads `~/.pi/agent/skills/`)
//! - Prime Agent: `~/.prime/agent/skills/`
//! - OpenClaw:    `~/.openclaw/skills/`
//! - OpenCode: `~/.config/opencode/skills/` (macOS / Linux),
//!   `%APPDATA%\opencode\skills\` (Windows)
//! - Antigravity IDE: `~/.gemini/config/skills/` (global skills directory),
//!   plus the legacy `~/.gemini/antigravity/skills/` it still accepts
//! - Antigravity CLI (`agy`): `~/.gemini/antigravity-cli/skills/`
//! - Gemini CLI (legacy): `~/.gemini/skills/`
//! - Hermes: `$HERMES_HOME/skills/` when set, otherwise `~/.hermes/skills/` on
//!   macOS/Linux or `%LOCALAPPDATA%\hermes\skills\` on Windows. This is the
//!   user-level skill space Hermes resolves at agent load time (separate from
//!   the repo-bundled `hermes-agent/skills/` tree, which is read-only and
//!   version-controlled). Hermes' own `computer-use` skill teaches its wrapper
//!   vocabulary; the cua-driver pack provides the platform deep dives.
//!
//! Acts on a given agent when its parent skills dir already exists. For
//! Claude Code, Codex, and Pi, whose fresh installs may not create that directory,
//! the explicit `skills install` verb also creates it when the client's own
//! home directory proves that client is installed. Never clobbers an existing
//! `<agent_skills>/cua-driver` link — preserves dev users' hand-rolled symlinks.

use anyhow::{anyhow, bail, Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

const SKILL_PACK_NAME: &str = "cua-driver";
/// Pre-rename name. The skill pack used to install as `cua-driver-rs`
/// (when the Rust port lived at `libs/cua-driver-rs/`). On install /
/// uninstall we sweep this name out of every agent skills dir and the
/// local stage so a user who had the old skill installed ends up with
/// exactly one pack, named consistently with the rest of the binary.
const LEGACY_SKILL_PACK_NAME: &str = "cua-driver-rs";

/// Per-host filter: returns the platform-specific docs that should NOT
/// land in the local stage. The skill pack ships docs for all three
/// platforms in the same tarball, but a Windows user has no need for
/// LINUX.md / MACOS.md and vice-versa. SKILL.md still references the
/// matching platform doc by name, so the LLM sees one specific deep
/// dive without two extra files of unused noise.
///
/// Override with `cua-driver skills install --all-platforms` to keep
/// the full set (useful when assisting users across OSes from one
/// machine).
fn excluded_platform_docs(all_platforms: bool) -> &'static [&'static str] {
    if all_platforms {
        return &[];
    }
    #[cfg(target_os = "windows")]
    {
        &["LINUX.md", "MACOS.md"]
    }
    #[cfg(target_os = "linux")]
    {
        &["WINDOWS.md", "MACOS.md"]
    }
    #[cfg(target_os = "macos")]
    {
        &["WINDOWS.md", "LINUX.md"]
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        &[]
    }
}

/// True when the basename matches one of the excluded platform docs.
fn is_excluded_platform_doc(basename: &str, all_platforms: bool) -> bool {
    let excluded = excluded_platform_docs(all_platforms);
    excluded.iter().any(|f| basename.eq_ignore_ascii_case(f))
}

/// Legacy subdir name. `sweep_legacy_skill_pack` removes any skill-pack
/// artifacts that landed here before the rename.
const LEGACY_HOME_SUBDIRECTORY: &str = ".cua-driver-rs";

/// Local install path for the skill pack: `<HomeDir>/skills/cua-driver`.
fn local_skill_dir() -> Result<PathBuf> {
    let home = home_dir()?;
    Ok(home.join("skills").join(SKILL_PACK_NAME))
}

/// `<HomeDir>` resolved from the same env override `serve.rs` uses,
/// falling back to platform conventions.
fn home_dir() -> Result<PathBuf> {
    if let Ok(h) = std::env::var("CUA_DRIVER_RS_HOME") {
        return Ok(PathBuf::from(h));
    }
    #[cfg(windows)]
    {
        let userprofile =
            std::env::var("USERPROFILE").map_err(|_| anyhow!("USERPROFILE not set"))?;
        return Ok(PathBuf::from(userprofile).join(crate::bundle::user_home_subdirectory()));
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var("HOME").map_err(|_| anyhow!("HOME not set"))?;
        Ok(PathBuf::from(home).join(crate::bundle::user_home_subdirectory()))
    }
}

/// The pre-rename home (`~/.cua-driver-rs/`) if it exists on disk.
/// `None` when CUA_DRIVER_RS_HOME is set (the env var overrides both
/// the new and legacy defaults — caller is on their own).
fn legacy_home_dir() -> Option<PathBuf> {
    if std::env::var("CUA_DRIVER_RS_HOME").is_ok() || crate::bundle::is_local_installation() {
        return None;
    }
    #[cfg(windows)]
    let base = std::env::var("USERPROFILE").ok()?;
    #[cfg(not(windows))]
    let base = std::env::var("HOME").ok()?;
    let p = PathBuf::from(base).join(LEGACY_HOME_SUBDIRECTORY);
    if p.exists() {
        Some(p)
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy)]
struct Agent {
    label: &'static str,
    /// User-relative parent skills dir, expanded at runtime per OS.
    parent: AgentParent,
    /// A client-owned path that positively identifies an installation. When
    /// present, `skills install` may create the missing parent skills dir.
    install_marker: Option<&'static str>,
}

#[derive(Debug, Clone, Copy)]
enum AgentParent {
    /// `<HOME or USERPROFILE>/<segment>`.
    Home(&'static str),
    /// Hermes' effective user skill directory. Unlike the other agents,
    /// Hermes supports an explicit `HERMES_HOME` and uses a native-Windows
    /// default outside `USERPROFILE`.
    Hermes,
    /// `<APPDATA>/<segment>` (Windows roaming app config).
    ///
    /// `#[allow(dead_code)]`: constructed only inside `#[cfg(windows)]`
    /// AGENTS entries (OpenCode on Windows reads from `%APPDATA%`) and
    /// matched only inside `#[cfg(windows)]` arms of `parent_path`. The
    /// enum variant itself sits in cross-platform code so rustc's
    /// post-cfg-strip dead-code pass flags it on macOS/Linux even though
    /// the Windows build uses it.
    #[allow(dead_code)]
    AppData(&'static str),
}

const AGENTS: &[Agent] = &[
    Agent {
        label: "Claude Code",
        parent: AgentParent::Home(".claude/skills"),
        install_marker: Some(".claude"),
    },
    Agent {
        label: "Codex",
        parent: AgentParent::Home(".agents/skills"),
        install_marker: Some(".codex"),
    },
    Agent {
        label: "Pi",
        // Pi discovers both ~/.pi/agent/skills and ~/.agents/skills. Reuse the
        // latter so Pi + Codex converge on one managed cua-driver link instead
        // of making Pi report a duplicate skill-name collision.
        parent: AgentParent::Home(".agents/skills"),
        install_marker: Some(".pi/agent"),
    },
    Agent {
        label: "Cursor",
        // Cursor loads ~/.agents/skills too. Reuse it so Cursor, Codex and Pi
        // converge on one managed cua-driver link.
        parent: AgentParent::Home(".agents/skills"),
        install_marker: Some(".cursor"),
    },
    Agent {
        label: "Prime Agent",
        parent: AgentParent::Home(".prime/agent/skills"),
        install_marker: None,
    },
    Agent {
        label: "OpenClaw",
        parent: AgentParent::Home(".openclaw/skills"),
        install_marker: None,
    },
    #[cfg(windows)]
    Agent {
        label: "OpenCode",
        parent: AgentParent::AppData("opencode/skills"),
        install_marker: None,
    },
    #[cfg(not(windows))]
    Agent {
        label: "OpenCode",
        parent: AgentParent::Home(".config/opencode/skills"),
        install_marker: None,
    },
    Agent {
        label: "Antigravity IDE",
        parent: AgentParent::Home(".gemini/config/skills"),
        install_marker: None,
    },
    Agent {
        label: "Antigravity IDE (legacy dir)",
        parent: AgentParent::Home(".gemini/antigravity/skills"),
        install_marker: None,
    },
    Agent {
        label: "Antigravity CLI",
        parent: AgentParent::Home(".gemini/antigravity-cli/skills"),
        install_marker: None,
    },
    Agent {
        label: "Gemini CLI (legacy)",
        parent: AgentParent::Home(".gemini/skills"),
        install_marker: None,
    },
    // Hermes (NousResearch/hermes-agent) resolves user skills from its
    // effective home at agent load time. `HERMES_HOME` can select a custom
    // home or profile; otherwise Hermes uses `~/.hermes` on macOS/Linux and
    // `%LOCALAPPDATA%\hermes` on native Windows. Hermes' bundled
    // `skills/computer-use/SKILL.md` teaches the wrapper vocabulary; this
    // pack adds the platform-specific deep dives.
    Agent {
        label: "Hermes",
        parent: AgentParent::Hermes,
        install_marker: None,
    },
];

fn hermes_skills_dir_from_env() -> Result<PathBuf> {
    resolve_hermes_skills_dir(
        std::env::var("HERMES_HOME").ok().as_deref(),
        default_hermes_home,
    )
}

fn resolve_hermes_skills_dir(
    override_home: Option<&str>,
    default_home: impl FnOnce() -> Result<PathBuf>,
) -> Result<PathBuf> {
    let home = match override_home.map(str::trim).filter(|path| !path.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => default_home()?,
    };
    Ok(home.join("skills"))
}

#[cfg(not(windows))]
fn default_hermes_home() -> Result<PathBuf> {
    unix_hermes_home(std::env::var("HOME").ok().as_deref())
}

#[cfg(any(not(windows), test))]
fn unix_hermes_home(home: Option<&str>) -> Result<PathBuf> {
    let home = home
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| anyhow!("HOME not set"))?;
    Ok(PathBuf::from(home).join(".hermes"))
}

#[cfg(windows)]
fn default_hermes_home() -> Result<PathBuf> {
    windows_hermes_home(
        std::env::var("LOCALAPPDATA").ok().as_deref(),
        std::env::var("USERPROFILE").ok().as_deref(),
    )
}

#[cfg(any(windows, test))]
fn windows_hermes_home(local_appdata: Option<&str>, userprofile: Option<&str>) -> Result<PathBuf> {
    if let Some(path) = local_appdata.map(str::trim).filter(|path| !path.is_empty()) {
        return Ok(PathBuf::from(path).join("hermes"));
    }
    let profile = userprofile
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| anyhow!("LOCALAPPDATA and USERPROFILE not set"))?;
    Ok(PathBuf::from(profile)
        .join("AppData")
        .join("Local")
        .join("hermes"))
}

impl Agent {
    fn parent_path(&self) -> Result<PathBuf> {
        match self.parent {
            AgentParent::Home(seg) => {
                #[cfg(windows)]
                let base =
                    std::env::var("USERPROFILE").map_err(|_| anyhow!("USERPROFILE not set"))?;
                #[cfg(not(windows))]
                let base = std::env::var("HOME").map_err(|_| anyhow!("HOME not set"))?;
                Ok(PathBuf::from(base).join(seg.replace('/', std::path::MAIN_SEPARATOR_STR)))
            }
            AgentParent::Hermes => hermes_skills_dir_from_env(),
            AgentParent::AppData(seg) => {
                #[cfg(windows)]
                let base = std::env::var("APPDATA").map_err(|_| anyhow!("APPDATA not set"))?;
                #[cfg(not(windows))]
                let base = std::env::var("HOME").map_err(|_| anyhow!("HOME not set"))?;
                Ok(PathBuf::from(base).join(seg.replace('/', std::path::MAIN_SEPARATOR_STR)))
            }
        }
    }
    fn install_marker_path(&self) -> Result<Option<PathBuf>> {
        let Some(marker) = self.install_marker else {
            return Ok(None);
        };
        #[cfg(windows)]
        let base = std::env::var("USERPROFILE").map_err(|_| anyhow!("USERPROFILE not set"))?;
        #[cfg(not(windows))]
        let base = std::env::var("HOME").map_err(|_| anyhow!("HOME not set"))?;
        Ok(Some(PathBuf::from(base).join(marker)))
    }
}

// ── Public dispatcher ─────────────────────────────────────────────────────

pub fn run(subcommand: &str, flags: &[String]) {
    let result = match subcommand {
        "install" => install(flags, false),
        "update" => install(flags, true),
        "uninstall" => uninstall(flags),
        "status" => status(),
        "path" => print_path(),
        other => {
            eprintln!("Unknown skills subcommand: {other:?}");
            eprintln!("Usage: cua-driver skills {{install|update|uninstall|status|path}}");
            std::process::exit(64);
        }
    };
    match result {
        Ok(()) => {}
        Err(e) => {
            // `anyhow::Error`'s default Display only prints the outermost
            // context. Use alternate Display so failures include the source
            // URL and the underlying HTTP, extraction, or filesystem error.
            eprintln!("cua-driver skills {subcommand}: {e:#}");
            std::process::exit(1);
        }
    }
}

// ── install / update ──────────────────────────────────────────────────────

fn install(flags: &[String], force: bool) -> Result<()> {
    let force = force || flags.iter().any(|f| f == "--force");
    // `--all-platforms` opts INTO keeping LINUX.md / MACOS.md / WINDOWS.md
    // for every host. Default is host-only — only the matching platform's
    // doc is kept, the other two are skipped while staging.
    let all_platforms = flags.iter().any(|f| f == "--all-platforms");

    // Sweep the legacy `cua-driver-rs`-named pack out FIRST so the
    // post-install state has exactly one skill pack at the new name.
    // Done before staging so a fresh install on a previously-installed
    // machine doesn't leave orphan links pointing at a stale local dir.
    sweep_legacy_skill_pack();

    let local = local_skill_dir()?;
    let already_present = local.join("SKILL.md").exists();

    if !already_present || force {
        stage_local_skill_pack(&local, all_platforms)
            .with_context(|| format!("failed to stage skill pack to {}", local.display()))?;
        println!("✅ Skill pack at {}", local.display());
    } else {
        println!(
            "✅ Skill pack already at {} (use `cua-driver skills update` to refresh)",
            local.display()
        );
    }

    let mut detected_any = false;
    for agent in AGENTS {
        match link_agent(*agent, &local) {
            Ok(LinkStatus::Created | LinkStatus::Existing) => detected_any = true,
            Ok(LinkStatus::NotDetected) => {}
            Err(e) => eprintln!("  warning: failed to link {}: {e}", agent.label),
        }
    }
    if !detected_any {
        println!("(No supported agent installation or skills directory detected. Install an agent, then re-run.)");
    }
    Ok(())
}

/// Best-effort removal of any pre-rename skill pack. Three legacy
/// locations are swept:
/// 1. `<HomeDir>/skills/cua-driver-rs/`       — old pack NAME under new home dir
/// 2. `<LegacyHomeDir>/skills/cua-driver/`    — new pack NAME under old home dir
/// 3. `<LegacyHomeDir>/skills/cua-driver-rs/` — old pack NAME under old home dir
///
/// Plus every `<agent_skills>/cua-driver-rs` symlink/junction.
///
/// Then attempts to remove the empty `<LegacyHomeDir>/skills/` and
/// `<LegacyHomeDir>/` themselves so the dot-folder doesn't linger.
/// Only when those dirs are actually empty — never blows away a
/// legacy install that still has packages/ alongside.
///
/// Runs at the start of `install` / `update` so a user who had any
/// flavour of the legacy layout installed gets cleanly migrated
/// without having to run `skills uninstall` first.
///
/// Silent on failure — this is a UX nicety, not a correctness boundary.
/// The new pack still installs even if a stale junction can't be cleaned.
fn sweep_legacy_skill_pack() {
    // (1) Old pack NAME under new home dir.
    if let Ok(home) = home_dir() {
        let legacy_local = home.join("skills").join(LEGACY_SKILL_PACK_NAME);
        if legacy_local.exists() {
            if let Err(e) = fs::remove_dir_all(&legacy_local) {
                eprintln!(
                    "  warning: could not remove legacy local pack at {}: {e}",
                    legacy_local.display()
                );
            } else {
                println!(
                    "  cleaned up legacy local pack at {}",
                    legacy_local.display()
                );
            }
        }
    }
    // (2) + (3) Any pack name under the pre-rename home dir, then try
    // to remove the empty skills/ + home/ dirs themselves.
    if let Some(legacy_home) = legacy_home_dir() {
        let legacy_skills_dir = legacy_home.join("skills");
        for name in [SKILL_PACK_NAME, LEGACY_SKILL_PACK_NAME] {
            let dir = legacy_skills_dir.join(name);
            if dir.exists() {
                if let Err(e) = fs::remove_dir_all(&dir) {
                    eprintln!(
                        "  warning: could not remove legacy pack at {}: {e}",
                        dir.display()
                    );
                } else {
                    println!("  cleaned up legacy local pack at {}", dir.display());
                }
            }
        }
        // remove_dir refuses to delete non-empty dirs — safe to ignore
        // errors here, and intentional: a legacy install that still has
        // packages/ alongside the (now-emptied) skills/ keeps its
        // dot-folder.
        let _ = fs::remove_dir(&legacy_skills_dir);
        let _ = fs::remove_dir(&legacy_home);
    }
    // Agent links named `<parent>/cua-driver-rs`.
    for agent in AGENTS {
        let parent = match agent.parent_path() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let legacy_link = parent.join(LEGACY_SKILL_PACK_NAME);
        if !parent.exists() || legacy_link.symlink_metadata().is_err() {
            continue;
        }
        if !is_symlink_or_junction(&legacy_link) {
            // Real directory — don't clobber user-managed content.
            continue;
        }
        if let Err(e) = remove_link(&legacy_link) {
            eprintln!(
                "  warning: could not remove legacy {} link at {}: {e}",
                agent.label,
                legacy_link.display()
            );
        } else {
            println!(
                "  cleaned up legacy {} link at {}",
                agent.label,
                legacy_link.display()
            );
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LinkStatus {
    Created,
    Existing,
    NotDetected,
}

fn ensure_skills_parent(parent: &Path, install_marker: Option<&Path>) -> Result<bool> {
    if parent.is_dir() {
        return Ok(true);
    }
    if parent.symlink_metadata().is_ok() {
        bail!(
            "skills path exists but is not a directory: {}",
            parent.display()
        );
    }
    if !install_marker.is_some_and(Path::is_dir) {
        return Ok(false);
    }
    fs::create_dir_all(parent)
        .with_context(|| format!("create skills directory {}", parent.display()))?;
    Ok(true)
}

/// Links one detected agent and reports whether the link was created, already
/// present, or skipped because neither a skills directory nor installation
/// marker exists.
fn link_agent(agent: Agent, local_skill_dir: &Path) -> Result<LinkStatus> {
    let parent = agent.parent_path()?;
    let install_marker = agent.install_marker_path()?;
    link_agent_paths(
        agent.label,
        &parent,
        install_marker.as_deref(),
        local_skill_dir,
    )
}

fn link_agent_paths(
    agent_label: &str,
    parent: &Path,
    install_marker: Option<&Path>,
    local_skill_dir: &Path,
) -> Result<LinkStatus> {
    link_agent_paths_with(agent_label, parent, install_marker, local_skill_dir, true)
}

/// [`link_agent_paths`] with the progress lines switched off for callers whose
/// stdout carries something else (`mcp-config`).
fn link_agent_paths_with(
    agent_label: &str,
    parent: &Path,
    install_marker: Option<&Path>,
    local_skill_dir: &Path,
    chatty: bool,
) -> Result<LinkStatus> {
    if !ensure_skills_parent(parent, install_marker)? {
        return Ok(LinkStatus::NotDetected);
    }
    let link = parent.join(SKILL_PACK_NAME);
    // Four states for `link`:
    //   1. doesn't exist at all                 → create
    //   2. exists + resolves                    → already linked (skip)
    //   3. exists as link/junction but target dangling → remove + recreate
    //   4. exists as a real directory           → user-managed, leave alone
    //
    // `Path::exists()` follows symlinks, so it returns false for a
    // dangling link even though `symlink_metadata` succeeds — that's
    // the signature of case 3. We then check `is_symlink_or_junction`
    // before deleting, so we never touch a real user directory.
    let has_metadata = link.symlink_metadata().is_ok();
    let resolves = link.exists();
    if has_metadata && resolves {
        if chatty {
            println!(
                "  {} skill link already exists at {} (skipping)",
                agent_label,
                link.display()
            );
        }
        return Ok(LinkStatus::Existing);
    }
    if has_metadata && !resolves && is_symlink_or_junction(&link) {
        // Dangling link/junction — target was removed (typical after
        // sweep_legacy_skill_pack cleaned a pre-rename pack out from
        // under it). Remove + recreate pointing at the new target.
        if let Err(e) = remove_link(&link) {
            if chatty {
                eprintln!(
                    "  warning: could not remove stale {} link at {}: {e}",
                    agent_label,
                    link.display()
                );
            }
            return Ok(LinkStatus::Existing);
        }
        if chatty {
            println!(
                "  cleaned up stale {} link at {}",
                agent_label,
                link.display()
            );
        }
    }
    make_dir_symlink(local_skill_dir, &link).with_context(|| {
        format!(
            "symlink {} -> {}",
            link.display(),
            local_skill_dir.display()
        )
    })?;
    if chatty {
        println!("  ✅ linked {} skill at {}", agent_label, link.display());
    }
    Ok(LinkStatus::Created)
}

#[cfg(windows)]
fn make_dir_symlink(target: &Path, link: &Path) -> Result<()> {
    // NTFS directory junction: works without admin/Developer Mode,
    // unlike `std::os::windows::fs::symlink_dir`. Shell out to cmd's
    // `mklink /J` — the canonical way to create a junction from a
    // standard user token.
    let target: PathBuf = target.components().collect();
    let link: PathBuf = link.components().collect();
    let status = std::process::Command::new("cmd")
        .args(["/c", "mklink", "/J"])
        .arg(link)
        .arg(target)
        .stdout(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        bail!("mklink /J exited with {:?}", status.code());
    }
    Ok(())
}

#[cfg(not(windows))]
fn make_dir_symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link)?;
    Ok(())
}

// ── default install for `mcp-config --client <agent>` ─────────────────────

/// The agents whose skills directory `cua-driver mcp-config --client <client>`
/// installs the skill pack into. A client with no known skills directory
/// (Qwen Code, Factory Droid, ZCode) maps to none.
fn client_agents(client: &str) -> Vec<Agent> {
    let labels: &[&str] = match client {
        "claude" | "claude-code" => &["Claude Code"],
        "codex" => &["Codex"],
        "cursor" => &["Cursor"],
        "openclaw" => &["OpenClaw"],
        "opencode" => &["OpenCode"],
        "hermes" => &["Hermes"],
        "antigravity" | "gemini" => &["Antigravity IDE", "Antigravity CLI"],
        "pi" => &["Pi"],
        "prime-agent" => &["Prime Agent"],
        _ => &[],
    };
    AGENTS
        .iter()
        .filter(|agent| labels.contains(&agent.label))
        .copied()
        .collect()
}

/// How one `mcp-config --client` run left the skill pack.
#[derive(Debug, PartialEq, Eq)]
pub enum ClientSkills {
    /// The client has no skills directory to install into.
    Unsupported,
    /// Linked for these agents; `true` when this run created the link.
    Installed(Vec<(&'static str, PathBuf, bool)>),
    /// The client's own folder is not on this computer yet.
    NotFound(Vec<&'static str>),
}

/// Install the skill pack for the agent behind `cua-driver mcp-config
/// --client <client>`, the default when that command wires up an agent.
///
/// The pack is the one compiled into this binary, so it matches the driver the
/// agent is about to start and needs no network. It lands where the explicit
/// `skills install` puts it: a local copy under `<HomeDir>/skills/cua-driver`
/// and a link to it from the agent's skills directory. The agent was named on
/// the command line, so its skills directory is created when the agent's own
/// folder (`~/.claude`, `~/.config/opencode`, ...) exists. A link or folder
/// that is already there is never replaced, and nothing goes to stdout.
pub fn install_for_client(client: &str) -> Result<ClientSkills> {
    let agents = client_agents(client);
    if agents.is_empty() {
        return Ok(ClientSkills::Unsupported);
    }
    let local = local_skill_dir()?;
    let mut staged = false;
    let mut installed = Vec::new();
    let mut missing = Vec::new();
    for agent in agents {
        let parent = agent.parent_path()?;
        let marker = agent
            .install_marker_path()?
            .filter(|marker| marker.is_dir())
            .or_else(|| parent.parent().map(Path::to_path_buf));
        if !(parent.is_dir() || marker.as_deref().is_some_and(Path::is_dir)) {
            missing.push(agent.label);
            continue;
        }
        if !staged {
            stage_embedded(&local)?;
            staged = true;
        }
        match link_agent_paths_with(agent.label, &parent, marker.as_deref(), &local, false)? {
            LinkStatus::Created => {
                installed.push((agent.label, parent.join(SKILL_PACK_NAME), true))
            }
            LinkStatus::Existing => {
                installed.push((agent.label, parent.join(SKILL_PACK_NAME), false))
            }
            LinkStatus::NotDetected => missing.push(agent.label),
        }
    }
    Ok(if installed.is_empty() {
        ClientSkills::NotFound(missing)
    } else {
        ClientSkills::Installed(installed)
    })
}

/// Write the skill files compiled into this binary to `dest`, host platform
/// only, changing only files whose content differs. A `dest` that is itself a
/// link is somebody's checkout (a developer's hand-rolled setup): leave it be.
fn stage_embedded(dest: &Path) -> Result<()> {
    if is_symlink_or_junction(dest) {
        return Ok(());
    }
    fs::create_dir_all(dest).with_context(|| format!("create {}", dest.display()))?;
    for (name, text) in cua_driver_core::mcp_skills::embedded_files() {
        if is_excluded_platform_doc(name, false) {
            continue;
        }
        let path = dest.join(name);
        if fs::read_to_string(&path).is_ok_and(|current| current == *text) {
            continue;
        }
        fs::write(&path, text).with_context(|| format!("write {}", path.display()))?;
    }
    Ok(())
}

/// The one line `mcp-config --client <client>` prints (to stderr, so the
/// config on stdout stays pasteable) about the skill pack, or `None` when the
/// client has no skills directory.
pub fn install_for_client_line(client: &str) -> Option<String> {
    client_skills_line(client, install_for_client(client))
}

fn client_skills_line(client: &str, outcome: Result<ClientSkills>) -> Option<String> {
    match outcome {
        Ok(ClientSkills::Unsupported) => None,
        Ok(ClientSkills::Installed(links)) => {
            let names = links
                .iter()
                .map(|(label, _, _)| *label)
                .collect::<Vec<_>>()
                .join(", ");
            let paths = links
                .iter()
                .map(|(_, path, _)| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ");
            Some(if links.iter().all(|(_, _, created)| !created) {
                format!("cua-driver: the skill pack for {names} is already installed at {paths}.")
            } else {
                format!(
                    "cua-driver: installed the skill pack for {names} at {paths} \
                     (skip with --no-skills, remove with `cua-driver skills uninstall`)."
                )
            })
        }
        Ok(ClientSkills::NotFound(labels)) => Some(format!(
            "cua-driver: no {} folder found yet, so the skill pack was not installed. \
             Run `cua-driver skills install` once the agent has started.",
            labels.join(" or ")
        )),
        Err(error) => Some(format!(
            "cua-driver: could not install the skill pack for {client}: {error:#}. \
             Run `cua-driver skills install` to retry."
        )),
    }
}

// ── local source ──────────────────────────────────────────────────────────

/// Locate the bundled skill pack beside the running executable.
///
/// `install-local` stages `Skills/cua-driver/` in the versioned install
/// directory next to the binary; a repository build finds the same directory
/// by walking up from `target/<profile>/`.
fn bundled_skill_dir() -> Result<PathBuf> {
    let executable = std::env::current_exe().context("locate the cua-driver executable")?;
    let directory = executable
        .parent()
        .ok_or_else(|| anyhow!("cua-driver executable has no parent directory"))?;
    let beside_executable = directory
        .ancestors()
        .map(|ancestor| ancestor.join("Skills").join(SKILL_PACK_NAME));
    let installed_home = home_dir()
        .map(|home| home.join("packages/current/Skills").join(SKILL_PACK_NAME))
        .into_iter();
    beside_executable
        .chain(installed_home)
        .find(|candidate| candidate.join("SKILL.md").is_file())
        .ok_or_else(|| {
            anyhow!(
                "no local skill pack found next to {}; rebuild and install from the repository:\n  {}",
                executable.display(),
                crate::updater::rebuild_instruction()
            )
        })
}

fn stage_local_skill_pack(dest: &Path, all_platforms: bool) -> Result<()> {
    let source = bundled_skill_dir()?;
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    // Wipe stale content so an update is a clean replace, not a merge.
    if dest.exists() {
        fs::remove_dir_all(dest)?;
    }
    fs::create_dir_all(dest)?;
    copy_skill_pack(&source, dest, all_platforms)
}

fn copy_skill_pack(source: &Path, dest: &Path, all_platforms: bool) -> Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        if name
            .to_str()
            .is_some_and(|name| is_excluded_platform_doc(name, all_platforms))
        {
            continue;
        }
        let from = entry.path();
        let to = dest.join(&name);
        if from.is_dir() {
            fs::create_dir_all(&to)?;
            copy_skill_pack(&from, &to, all_platforms)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

// ── uninstall ──────────────────────────────────────────────────────────────

fn uninstall(flags: &[String]) -> Result<()> {
    let remove_local = flags.iter().any(|f| f == "--all");
    let mut removed_any = false;
    // Try BOTH the current name and the legacy `cua-driver-rs` name so a
    // user who installed under the old name and then `skills uninstall`s
    // ends up clean. Same symlink/junction safety check applies to each.
    for name in [SKILL_PACK_NAME, LEGACY_SKILL_PACK_NAME] {
        for agent in AGENTS {
            let parent = match agent.parent_path() {
                Ok(p) => p,
                Err(_) => continue,
            };
            let link = parent.join(name);
            if link.symlink_metadata().is_ok() {
                // Only remove if it's a symlink/junction we manage. If a
                // user replaced it with a real dir, leave it alone.
                if is_symlink_or_junction(&link) {
                    remove_link(&link)?;
                    println!("  ✅ removed {} link at {}", agent.label, link.display());
                    removed_any = true;
                } else {
                    println!(
                        "  {} link at {} is not a symlink/junction; leaving alone",
                        agent.label,
                        link.display()
                    );
                }
            }
        }
    }
    if remove_local {
        // Local stage at the current name + any legacy stage from before
        // the rename. Both are owned by the installer; safe to delete.
        if let Ok(home) = home_dir() {
            for name in [SKILL_PACK_NAME, LEGACY_SKILL_PACK_NAME] {
                let local = home.join("skills").join(name);
                if local.exists() {
                    fs::remove_dir_all(&local)?;
                    println!("  ✅ removed local skill pack at {}", local.display());
                }
            }
        }
        // Also clean up any pre-rename home (`~/.cua-driver-rs/`) that
        // might still hold a skill pack from before the
        // `.cua-driver-rs/` → `.cua-driver/` migration. Remove the empty
        // skills/ and home/ dirs only if nothing else lives under them.
        if let Some(legacy_home) = legacy_home_dir() {
            let legacy_skills_dir = legacy_home.join("skills");
            for name in [SKILL_PACK_NAME, LEGACY_SKILL_PACK_NAME] {
                let local = legacy_skills_dir.join(name);
                if local.exists() {
                    fs::remove_dir_all(&local)?;
                    println!(
                        "  ✅ removed legacy local skill pack at {}",
                        local.display()
                    );
                }
            }
            let _ = fs::remove_dir(&legacy_skills_dir);
            let _ = fs::remove_dir(&legacy_home);
        }
    }
    if !removed_any {
        println!("(no agent skill links found)");
    }
    Ok(())
}

#[cfg(windows)]
fn is_symlink_or_junction(p: &Path) -> bool {
    if let Ok(md) = p.symlink_metadata() {
        // Both symlinks and junctions have the reparse-point attribute.
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        return md.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }
    false
}

#[cfg(not(windows))]
fn is_symlink_or_junction(p: &Path) -> bool {
    p.symlink_metadata()
        .map(|md| md.file_type().is_symlink())
        .unwrap_or(false)
}

#[cfg(windows)]
fn remove_link(p: &Path) -> Result<()> {
    // For a junction (which appears as a directory) we use rmdir;
    // for a file symlink std::fs::remove_file would work, but
    // junctions are dir-shaped so std::fs::remove_dir is correct.
    fs::remove_dir(p).map_err(Into::into)
}

#[cfg(not(windows))]
fn remove_link(p: &Path) -> Result<()> {
    fs::remove_file(p).map_err(Into::into)
}

// ── status ─────────────────────────────────────────────────────────────────

fn status() -> Result<()> {
    let local = local_skill_dir()?;
    if local.exists() && local.join("SKILL.md").exists() {
        println!("Local skill pack: {} ✅", local.display());
    } else {
        println!("Local skill pack: not installed (`cua-driver skills install` to stage)");
    }
    println!();
    println!("Agent links:");
    for agent in AGENTS {
        let parent = match agent.parent_path() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let link = parent.join(SKILL_PACK_NAME);
        let parent_exists = parent.exists();
        if !parent_exists {
            println!(
                "  {} — agent dir not present ({})",
                agent.label,
                parent.display()
            );
            continue;
        }
        if !link.exists() && link.symlink_metadata().is_err() {
            println!("  {} — not linked ({})", agent.label, link.display());
        } else if is_symlink_or_junction(&link) {
            let target = fs::read_link(&link).ok();
            match target {
                Some(t) => println!(
                    "  {} — ✅ linked: {} → {}",
                    agent.label,
                    link.display(),
                    t.display()
                ),
                None => println!("  {} — ✅ linked: {}", agent.label, link.display()),
            }
        } else {
            println!(
                "  {} — non-symlink path at {} (left alone)",
                agent.label,
                link.display()
            );
        }
    }
    Ok(())
}

fn print_path() -> Result<()> {
    let local = local_skill_dir()?;
    println!("{}", local.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        client_agents, client_skills_line, copy_skill_pack, ensure_skills_parent,
        link_agent_paths, link_agent_paths_with, resolve_hermes_skills_dir, stage_embedded,
        unix_hermes_home, windows_hermes_home, AgentParent, ClientSkills, LinkStatus, AGENTS,
    };
    use anyhow::anyhow;
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn fresh_codex_and_claude_markers_are_explicit() {
        let claude = AGENTS
            .iter()
            .find(|agent| agent.label == "Claude Code")
            .unwrap();
        let codex = AGENTS.iter().find(|agent| agent.label == "Codex").unwrap();

        assert!(matches!(claude.install_marker, Some(".claude")));
        assert!(matches!(codex.install_marker, Some(".codex")));
    }

    #[test]
    fn missing_skills_parent_is_created_only_for_detected_client() {
        let home = tempdir().unwrap();
        let parent = home.path().join(".agents/skills");
        let marker = home.path().join(".codex");

        assert!(!ensure_skills_parent(&parent, Some(&marker)).unwrap());
        assert!(!parent.exists());

        std::fs::create_dir(&marker).unwrap();
        assert!(ensure_skills_parent(&parent, Some(&marker)).unwrap());
        assert!(parent.is_dir());
    }

    #[test]
    fn existing_skills_parent_needs_no_client_marker() {
        let home = tempdir().unwrap();
        let parent = home.path().join("custom/skills");
        std::fs::create_dir_all(&parent).unwrap();

        assert!(ensure_skills_parent(&parent, None).unwrap());
    }

    #[test]
    fn detected_client_links_once_and_rerun_reports_existing_link() {
        let root = tempdir().unwrap();
        for home_name in ["plain", "skills 用户"] {
            let home = root.path().join(home_name);
            let parent = home.join(".claude/skills");
            let marker = home.join(".claude");
            let local_skill = home.join(".cua-driver/skills/cua-driver");
            std::fs::create_dir_all(&marker).unwrap();
            std::fs::create_dir_all(&local_skill).unwrap();
            std::fs::write(local_skill.join("SKILL.md"), "test skill").unwrap();

            assert_eq!(
                link_agent_paths("Claude Code", &parent, Some(&marker), &local_skill).unwrap(),
                LinkStatus::Created
            );
            assert_eq!(
                std::fs::read_to_string(parent.join("cua-driver/SKILL.md")).unwrap(),
                "test skill"
            );
            assert_eq!(
                link_agent_paths("Claude Code", &parent, Some(&marker), &local_skill).unwrap(),
                LinkStatus::Existing
            );
        }
    }

    #[test]
    fn missing_parent_and_marker_are_not_detected() {
        let home = tempdir().unwrap();
        let parent = home.path().join(".agents/skills");
        let marker = home.path().join(".codex");
        let local_skill = home.path().join("skill");
        std::fs::create_dir(&local_skill).unwrap();

        assert_eq!(
            link_agent_paths("Codex", &parent, Some(&marker), &local_skill).unwrap(),
            LinkStatus::NotDetected
        );
        assert!(!parent.exists());
    }

    #[test]
    fn non_directory_parent_is_rejected() {
        let home = tempdir().unwrap();
        let parent = home.path().join("skills");
        std::fs::write(&parent, b"occupied").unwrap();

        let error = ensure_skills_parent(&parent, None).unwrap_err();
        assert!(error.to_string().contains("exists but is not a directory"));
    }

    #[test]
    fn pi_target_matches_its_native_global_skill_directory() {
        let target = AGENTS
            .iter()
            .find(|agent| agent.label == "Pi")
            .expect("Pi must remain a supported skill target");

        assert!(matches!(target.parent, AgentParent::Home(".agents/skills")));
        assert!(matches!(target.install_marker, Some(".pi/agent")));
    }

    #[test]
    fn codex_and_pi_share_one_managed_global_skill_directory() {
        let codex = AGENTS.iter().find(|agent| agent.label == "Codex").unwrap();
        let pi = AGENTS.iter().find(|agent| agent.label == "Pi").unwrap();

        assert!(matches!(codex.parent, AgentParent::Home(".agents/skills")));
        assert!(matches!(pi.parent, AgentParent::Home(".agents/skills")));
        assert!(matches!(codex.install_marker, Some(".codex")));
        assert!(matches!(pi.install_marker, Some(".pi/agent")));
    }

    #[test]
    fn pi_marker_creates_shared_link_and_codex_reuses_it() {
        let home = tempdir().unwrap();
        let parent = home.path().join(".agents/skills");
        let pi_marker = home.path().join(".pi/agent");
        let local_skill = home.path().join(".cua-driver/skills/cua-driver");

        std::fs::create_dir_all(&pi_marker).unwrap();
        std::fs::create_dir_all(&local_skill).unwrap();

        assert_eq!(
            link_agent_paths("Pi", &parent, Some(&pi_marker), &local_skill).unwrap(),
            LinkStatus::Created
        );
        assert!(parent.join("cua-driver").exists());

        // Codex and Pi intentionally share ~/.agents/skills. Once Pi has
        // created the managed link, the Codex path must converge on that same
        // link rather than creating or replacing another skill entry.
        assert_eq!(
            link_agent_paths("Codex", &parent, None, &local_skill).unwrap(),
            LinkStatus::Existing
        );
        assert!(parent.join("cua-driver").exists());
    }

    #[test]
    fn cursor_shares_the_codex_and_pi_skill_directory() {
        let cursor = AGENTS.iter().find(|agent| agent.label == "Cursor").unwrap();
        assert!(matches!(cursor.parent, AgentParent::Home(".agents/skills")));
        assert!(matches!(cursor.install_marker, Some(".cursor")));
    }

    #[test]
    fn every_mcp_config_client_with_a_skills_folder_maps_to_its_agents() {
        let labels = |client: &str| -> Vec<&'static str> {
            client_agents(client)
                .into_iter()
                .map(|agent| agent.label)
                .collect()
        };
        assert_eq!(labels("claude"), ["Claude Code"]);
        assert_eq!(labels("claude-code"), ["Claude Code"]);
        assert_eq!(labels("codex"), ["Codex"]);
        assert_eq!(labels("cursor"), ["Cursor"]);
        assert_eq!(labels("openclaw"), ["OpenClaw"]);
        assert_eq!(labels("opencode"), ["OpenCode"]);
        assert_eq!(labels("hermes"), ["Hermes"]);
        assert_eq!(labels("pi"), ["Pi"]);
        assert_eq!(labels("prime-agent"), ["Prime Agent"]);
        assert_eq!(
            labels("antigravity"),
            ["Antigravity IDE", "Antigravity CLI"]
        );
        assert_eq!(labels("gemini"), labels("antigravity"));
        // No skills folder is known for these.
        for client in [
            "qwen",
            "qwen-code",
            "droid",
            "factory",
            "zcode",
            "",
            "emacs",
        ] {
            assert!(labels(client).is_empty(), "{client}");
        }
    }

    #[test]
    fn quiet_linking_reports_the_same_status_without_printing() {
        let home = tempdir().unwrap();
        let parent = home.path().join(".claude/skills");
        let marker = home.path().join(".claude");
        let local_skill = home.path().join("pack");
        std::fs::create_dir_all(&marker).unwrap();
        std::fs::create_dir_all(&local_skill).unwrap();
        assert_eq!(
            link_agent_paths_with("Claude Code", &parent, Some(&marker), &local_skill, false)
                .unwrap(),
            LinkStatus::Created
        );
        assert_eq!(
            link_agent_paths_with("Claude Code", &parent, Some(&marker), &local_skill, false)
                .unwrap(),
            LinkStatus::Existing
        );
    }

    #[test]
    fn the_staged_pack_is_the_embedded_pack_for_this_host_only() {
        let root = tempdir().unwrap();
        let stage = root.path().join("skills/cua-driver");
        stage_embedded(&stage).unwrap();
        for (name, text) in cua_driver_core::mcp_skills::embedded_files() {
            let other_platform = ["WINDOWS.md", "MACOS.md", "LINUX.md"].contains(name)
                && !name.eq_ignore_ascii_case(if cfg!(target_os = "windows") {
                    "WINDOWS.md"
                } else if cfg!(target_os = "macos") {
                    "MACOS.md"
                } else {
                    "LINUX.md"
                });
            let path = stage.join(name);
            if other_platform {
                assert!(!path.exists(), "{name} belongs to another platform");
            } else {
                assert_eq!(std::fs::read_to_string(&path).unwrap(), *text, "{name}");
            }
        }
        // A refresh rewrites only what changed and keeps files it does not own.
        std::fs::write(stage.join("SKILL.md"), "stale").unwrap();
        std::fs::write(stage.join("NOTES.md"), "mine").unwrap();
        stage_embedded(&stage).unwrap();
        assert_ne!(
            std::fs::read_to_string(stage.join("SKILL.md")).unwrap(),
            "stale"
        );
        assert_eq!(
            std::fs::read_to_string(stage.join("NOTES.md")).unwrap(),
            "mine"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_stage_is_left_alone() {
        let root = tempdir().unwrap();
        let checkout = root.path().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        std::fs::write(checkout.join("SKILL.md"), "mine").unwrap();
        let stage = root.path().join("stage");
        std::os::unix::fs::symlink(&checkout, &stage).unwrap();
        stage_embedded(&stage).unwrap();
        assert_eq!(
            std::fs::read_to_string(checkout.join("SKILL.md")).unwrap(),
            "mine"
        );
    }

    #[test]
    fn the_one_line_says_what_happened_and_how_to_undo_it() {
        let link = PathBuf::from("/home/me/.claude/skills/cua-driver");
        let created = client_skills_line(
            "claude",
            Ok(ClientSkills::Installed(vec![(
                "Claude Code",
                link.clone(),
                true,
            )])),
        )
        .unwrap();
        assert_eq!(created.lines().count(), 1);
        assert!(created.contains("installed the skill pack for Claude Code"));
        assert!(created.contains("/home/me/.claude/skills/cua-driver"));
        assert!(created.contains("--no-skills"));
        assert!(created.contains("cua-driver skills uninstall"));

        let again = client_skills_line(
            "claude",
            Ok(ClientSkills::Installed(vec![("Claude Code", link, false)])),
        )
        .unwrap();
        assert!(again.contains("already installed"));
        assert!(!again.contains("--no-skills"));

        let missing =
            client_skills_line("opencode", Ok(ClientSkills::NotFound(vec!["OpenCode"]))).unwrap();
        assert!(missing.contains("no OpenCode folder found"));
        assert!(missing.contains("cua-driver skills install"));

        let failed = client_skills_line("codex", Err(anyhow!("disk full"))).unwrap();
        assert!(failed.contains("could not install the skill pack for codex: disk full"));
        assert_eq!(failed.lines().count(), 1);

        assert_eq!(
            client_skills_line("qwen", Ok(ClientSkills::Unsupported)),
            None
        );
    }

    #[test]
    fn prime_agent_target_matches_its_native_global_skill_directory() {
        let target = AGENTS
            .iter()
            .find(|agent| agent.label == "Prime Agent")
            .expect("Prime Agent must remain a supported skill target");

        assert!(matches!(
            target.parent,
            AgentParent::Home(".prime/agent/skills")
        ));
    }

    #[test]
    fn antigravity_ide_target_matches_its_global_skill_directory() {
        let target = AGENTS
            .iter()
            .find(|agent| agent.label == "Antigravity IDE")
            .expect("Antigravity IDE must be a supported skill target");

        assert!(matches!(
            target.parent,
            AgentParent::Home(".gemini/config/skills")
        ));
    }

    #[test]
    fn antigravity_ide_legacy_skill_directory_is_also_a_target() {
        let target = AGENTS
            .iter()
            .find(|agent| agent.label == "Antigravity IDE (legacy dir)")
            .expect("the legacy Antigravity IDE directory must be a supported skill target");

        assert!(matches!(
            target.parent,
            AgentParent::Home(".gemini/antigravity/skills")
        ));
    }

    #[test]
    fn antigravity_cli_target_matches_its_global_skill_directory() {
        let target = AGENTS
            .iter()
            .find(|agent| agent.label == "Antigravity CLI")
            .expect("Antigravity CLI must be a supported skill target");

        assert!(matches!(
            target.parent,
            AgentParent::Home(".gemini/antigravity-cli/skills")
        ));
    }

    #[test]
    fn legacy_gemini_skill_directory_stays_a_separate_target() {
        let legacy: Vec<_> = AGENTS
            .iter()
            .filter(|agent| matches!(agent.parent, AgentParent::Home(".gemini/skills")))
            .collect();

        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].label, "Gemini CLI (legacy)");
    }

    #[test]
    fn hermes_target_prefers_hermes_home() {
        let path = resolve_hermes_skills_dir(Some("/profiles/work"), || {
            panic!("the fallback must not be read")
        })
        .unwrap();
        assert_eq!(path, PathBuf::from("/profiles/work/skills"));
    }

    #[test]
    fn hermes_target_ignores_empty_or_whitespace_override() {
        for override_home in [None, Some(""), Some("  \t  ")] {
            let path =
                resolve_hermes_skills_dir(override_home, || Ok(PathBuf::from("/fallback/hermes")))
                    .unwrap();
            assert_eq!(path, PathBuf::from("/fallback/hermes/skills"));
        }
    }

    #[test]
    fn hermes_target_uses_unix_default_home() {
        assert_eq!(
            unix_hermes_home(Some("/home/test")).unwrap(),
            PathBuf::from("/home/test/.hermes")
        );
    }

    #[test]
    fn hermes_target_uses_native_windows_local_appdata() {
        let home = windows_hermes_home(Some("C:/Users/test/AppData/Local"), None).unwrap();
        assert_eq!(home, PathBuf::from("C:/Users/test/AppData/Local/hermes"));
    }

    #[test]
    fn hermes_target_uses_windows_userprofile_fallback() {
        let expected = PathBuf::from("C:/Users/test")
            .join("AppData")
            .join("Local")
            .join("hermes");
        for local_appdata in [None, Some(""), Some("  \t  ")] {
            assert_eq!(
                windows_hermes_home(local_appdata, Some("C:/Users/test")).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn hermes_defaults_report_missing_required_environment() {
        for home in [None, Some(""), Some("  \t  ")] {
            assert_eq!(
                unix_hermes_home(home).unwrap_err().to_string(),
                "HOME not set"
            );
        }
        for (local_appdata, userprofile) in [
            (None, None),
            (Some(""), None),
            (None, Some("  \t  ")),
            (Some("  "), Some("")),
        ] {
            assert_eq!(
                windows_hermes_home(local_appdata, userprofile)
                    .unwrap_err()
                    .to_string(),
                "LOCALAPPDATA and USERPROFILE not set"
            );
        }
    }

    fn core_guidance() -> String {
        let skill_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Skills/cua-driver");
        ["SKILL.md", "WORKFLOW.md", "RUNTIME.md"]
            .iter()
            .map(|file| {
                std::fs::read_to_string(skill_dir.join(file))
                    .unwrap_or_else(|error| panic!("failed to read {file}: {error}"))
            })
            .collect::<Vec<_>>()
            .join("\n")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn macos_skill_keeps_ax_only_and_non_prompting_permission_guidance() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let macos = std::fs::read_to_string(crate_dir.join("../../Skills/cua-driver/MACOS.md"))
            .expect("canonical macOS skill must be readable");

        for required in [
            "screen_recording_capturable` is `null",
            "direct_capture_status` is `\"not_checked\"",
            "include_screenshot:false",
            "`element_token` AX actions",
        ] {
            assert!(
                macos.contains(required),
                "macOS skill lost required permission guidance: {required}"
            );
        }
    }

    #[test]
    fn bundled_skill_keeps_filesystem_outcome_ladder_and_gui_proof_boundaries() {
        let skill = core_guidance();

        for required in [
            "headless filesystem or command capability",
            "perform one batch-safe operation",
            "filesystem rename committed",
            "issue that modified click with",
            "every intended item is selected",
            "source reflects copy-versus-move semantics",
        ] {
            assert!(
                skill.contains(required),
                "skill lost required filesystem outcome guidance: {required}"
            );
        }
    }

    #[test]
    fn bundled_skill_keeps_semantic_clipboard_outcome_ladder() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let skill = core_guidance();
        let browser = std::fs::read_to_string(crate_dir.join("../../Skills/cua-driver/BROWSER.md"))
            .expect("canonical browser skill must be readable");

        for required in [
            "exact value on the system clipboard",
            "`clipboard_write`",
            "`clipboard_read`",
            "passive page-text ref",
        ] {
            assert!(
                skill.contains(required),
                "skill lost required clipboard outcome guidance: {required}"
            );
        }
        for required in [
            "exact page content on the system clipboard",
            "passive headings and text nodes are evidence sources",
            "foreground escalation rules in [RUNTIME.md]",
        ] {
            assert!(
                browser.contains(required),
                "browser skill lost required clipboard outcome guidance: {required}"
            );
        }
    }

    const HISTORY_CONSULTATION_POLICY: &[&str] = &[
        "continue, resume, or recall prior Cua work",
        "call `history_status` first",
        "one bounded initial",
        "before broad application or window discovery",
        "metadata only as a lead",
        "verify current state",
        "Content, geometry, arguments, results, and user intent",
        "remain unknown",
        "session or sequence boundary",
        "never broaden a query to reconstruct excluded fields",
        "either tool is absent",
        "access is denied",
        "query is empty",
        "history is unhealthy",
        "unrelated tasks merely because the tools are advertised",
        "never mutate history",
        "lifecycle or settings",
    ];

    fn assert_history_consultation_policy(skill: &str, source: &str) {
        let normalized = skill.split_whitespace().collect::<Vec<_>>().join(" ");
        for required in HISTORY_CONSULTATION_POLICY {
            assert!(
                normalized.contains(required),
                "{source} lost required history consultation guidance: {required}"
            );
        }
    }

    #[test]
    fn bundled_skill_keeps_conditional_history_consultation_policy() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let skill = std::fs::read_to_string(crate_dir.join("../../Skills/cua-driver/SKILL.md"))
            .expect("canonical skill must be readable");

        assert!(
            skill.lines().any(|line| {
                line.starts_with("description:")
                    && line.contains("continue, resume, or recall recent Cua activity")
            }),
            "skill frontmatter must trigger for recent Cua activity continuation"
        );
        assert_history_consultation_policy(&skill, "canonical skill");
    }

    #[test]
    fn local_skill_pack_staging_keeps_canonical_skill_bytes() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source = crate_dir.join("../../Skills/cua-driver");
        let dest = tempdir().unwrap();

        copy_skill_pack(&source, dest.path(), false).unwrap();

        let packaged = std::fs::read_to_string(dest.path().join("SKILL.md"))
            .expect("staged skill must be readable");
        assert_eq!(
            packaged.as_bytes(),
            std::fs::read(source.join("SKILL.md")).unwrap().as_slice(),
            "staged SKILL.md must equal the canonical skill"
        );
        for reference in ["WORKFLOW.md", "RUNTIME.md"] {
            assert!(
                packaged.contains(&format!("]({reference})")),
                "entrypoint must route to bundled {reference}"
            );
        }
    }

    #[test]
    fn local_staging_keeps_subdirectories_and_filters_platform_docs() {
        let source = tempdir().unwrap();
        std::fs::create_dir_all(source.path().join("examples")).unwrap();
        std::fs::write(source.path().join("SKILL.md"), "s").unwrap();
        std::fs::write(source.path().join("README.md"), "r").unwrap();
        std::fs::write(source.path().join("WINDOWS.md"), "w").unwrap();
        std::fs::write(source.path().join("MACOS.md"), "m").unwrap();
        std::fs::write(source.path().join("LINUX.md"), "l").unwrap();
        std::fs::write(source.path().join("examples/click.md"), "sample").unwrap();
        let dest = tempdir().unwrap();

        copy_skill_pack(source.path(), dest.path(), false).unwrap();

        for file in ["SKILL.md", "README.md", "examples/click.md"] {
            assert!(dest.path().join(file).is_file(), "{file}");
        }
        #[cfg(target_os = "windows")]
        let host = "WINDOWS.md";
        #[cfg(target_os = "linux")]
        let host = "LINUX.md";
        #[cfg(target_os = "macos")]
        let host = "MACOS.md";
        #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
        let host = "";
        for file in ["WINDOWS.md", "MACOS.md", "LINUX.md"] {
            assert_eq!(
                dest.path().join(file).is_file(),
                file == host,
                "{file} presence must match the host filter"
            );
        }

        let all = tempdir().unwrap();
        copy_skill_pack(source.path(), all.path(), true).unwrap();
        for file in ["WINDOWS.md", "MACOS.md", "LINUX.md"] {
            assert!(all.path().join(file).is_file(), "{file}");
        }
    }

    #[test]
    fn bundled_skill_keeps_sessions_and_authorization_as_separate_concepts() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let skill = core_guidance();
        let browser = std::fs::read_to_string(crate_dir.join("../../Skills/cua-driver/BROWSER.md"))
            .expect("canonical browser skill must be readable");

        for required in [
            "Choose the target on each action",
            "transport's implicit session",
            "prefer a short public",
            "pass the same label on every call that accepts it",
            "Passing it once is not sticky",
            "revive a name after",
            "There is no `deescalate_session`",
            "--capability-manifest",
            "--approve-capability-manifest",
            "It can remove tools or typed resources",
            "permission authority. A public session",
        ] {
            assert!(
                skill.contains(required),
                "skill lost required lifecycle/authorization guidance: {required}"
            );
        }
        for forbidden in [
            "one-way session phase",
            "if session policy allows",
            "Pass `session` on the first action",
        ] {
            assert!(
                !skill.contains(forbidden),
                "skill restored stale session-state guidance: {forbidden}"
            );
        }
        for required in [
            "start_session(session?)",
            "optional; can name before acting",
            "prefer a short `session` label",
            "Passing it once is not sticky",
            "one-shot CLI calls use disposable transports",
        ] {
            assert!(
                browser.contains(required),
                "browser skill lost required session guidance: {required}"
            );
        }
    }

    #[test]
    fn bundled_skill_keeps_agent_control_non_interfering_by_default() {
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let skill = core_guidance();
        let linux = std::fs::read_to_string(crate_dir.join("../../Skills/cua-driver/LINUX.md"))
            .expect("canonical Linux skill must be readable");

        for required in [
            "`delivery_mode:\"foreground\"` is a user-visible takeover boundary",
            "ordinary `move_cursor({x,y})` moves only this synthetic cursor",
            "must not be used unless the user asked for",
            "do not retry automatically",
            "stop with the driver's refusal instead of silently escalating",
        ] {
            assert!(
                skill.contains(required),
                "skill lost required agent-control safety guidance: {required}"
            );
        }
        for required in [
            "keyboard actions re-show it automatically",
            "Never select it automatically",
            "explicitly authorized `delivery_mode:\"foreground\"`",
        ] {
            assert!(
                linux.contains(required),
                "Linux skill lost required non-interference guidance: {required}"
            );
        }
    }
}
