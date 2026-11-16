// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Cua AI, Inc.

//! Repository-backed update guidance.
//!
//! Installing a release build over the running installation is disabled: the
//! driver only ever reports that a newer release exists and tells the user to
//! pull the repository and rebuild from source.


/// Something other than Driver's own installer updates this executable, so
/// Driver's update check, `update --apply` and channel commands refuse and
/// point at it instead.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum UpdateOwner {
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    Pacman,
    /// The app that carries this driver in its `Contents/Helpers`, by name
    /// (`Cua Spaces`). The driver updates with the app; the standalone
    /// installer would add a second driver beside it.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    HostApp(String),
}

impl UpdateOwner {
    pub(crate) fn guidance(&self) -> String {
        match self {
            Self::Pacman => {
                "This executable is managed by pacman. Update with `sudo pacman -Syu`; \
                 release selection and availability are controlled by your package repository. \
                 The upstream installer and stable/nightly channel switching are disabled."
                    .to_owned()
            }
            Self::HostApp(app) => format!(
                "This Cua Driver is part of {app} and updates with it. Update {app} itself \
                 (in Cua Spaces: Cua Spaces > Check for Updates…). The standalone installer and \
                 stable/nightly channel switching are disabled, so a second driver is never \
                 installed beside it."
            ),
        }
    }
}

/// Only positive ownership disables the upstream updater. Missing pacman,
/// failed queries, and unresolved paths retain unmanaged behavior.
pub(crate) fn update_owner() -> Option<UpdateOwner> {
    #[cfg(target_os = "macos")]
    {
        let executable = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
        host_app(&executable).map(UpdateOwner::HostApp)
    }
    #[cfg(target_os = "linux")]
    {
        let executable = std::env::current_exe().ok()?;
        pacman_owns_executable(&executable, std::path::Path::new("/usr/bin/pacman"))
            .then_some(UpdateOwner::Pacman)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

/// The `<App>` of `<App>.app/Contents/Helpers/<executable>`: the app that
/// ships this executable as a helper. Driver's own apps keep theirs in
/// `Contents/MacOS`.
#[cfg(any(target_os = "macos", test))]
fn host_app(path: &std::path::Path) -> Option<String> {
    let mut parents = path.ancestors().skip(1).map(|dir| dir.file_name());
    let helpers = parents.next().flatten()?;
    let contents = parents.next().flatten()?;
    let app = parents.next().flatten()?.to_str()?.strip_suffix(".app")?;
    (helpers == "Helpers" && contents == "Contents" && !app.is_empty()).then(|| app.to_owned())
}

#[cfg(any(target_os = "linux", all(test, unix)))]
fn pacman_owns_executable(executable: &std::path::Path, pacman: &std::path::Path) -> bool {
    if pacman_owns_path(executable, pacman) {
        return true;
    }
    executable
        .canonicalize()
        .is_ok_and(|resolved| resolved != executable && pacman_owns_path(&resolved, pacman))
}

#[cfg(any(target_os = "linux", all(test, unix)))]
fn pacman_owns_path(path: &std::path::Path, pacman: &std::path::Path) -> bool {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    // A just-written executable is briefly ETXTBSY while a concurrent fork
    // still holds its write descriptor; that is not an answer, so retry.
    let mut attempts = 0;
    let mut child = loop {
        match Command::new(pacman)
            .args(["-Qoq", "--"])
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => break child,
            Err(error)
                if error.kind() == std::io::ErrorKind::ExecutableFileBusy && attempts < 20 =>
            {
                attempts += 1;
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return false,
        }
    };
    let deadline = Instant::now() + Duration::from_millis(500);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

/// Rebuild instruction for the current target, run from the repository root.
pub(crate) fn rebuild_instruction() -> String {
    #[cfg(windows)]
    {
        "git pull; libs\\cua-driver\\scripts\\install-local.ps1".to_owned()
    }
    #[cfg(not(windows))]
    {
        "git pull && libs/cua-driver/scripts/install-local.sh".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_helper_inside_an_app_is_owned_by_that_app() {
        use std::path::Path;
        for (path, app) in [
            (
                "/Applications/Cua Spaces.app/Contents/Helpers/cua-driver",
                Some("Cua Spaces"),
            ),
            (
                "/Users/me/Applications/Cua Spaces Local.app/Contents/Helpers/cua-driver",
                Some("Cua Spaces Local"),
            ),
            (
                "/Applications/Other.app/Contents/Helpers/cua-driver",
                Some("Other"),
            ),
            (
                "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
                None,
            ),
            ("/Users/me/.local/bin/cua-driver", None),
            ("/Applications/Helpers/Contents/Helpers/cua-driver", None),
            ("/opt/.app/Contents/Helpers/cua-driver", None),
            ("cua-driver", None),
        ] {
            assert_eq!(host_app(Path::new(path)).as_deref(), app, "{path}");
        }
    }

    #[test]
    fn rebuild_instruction_names_the_local_installer() {
        let instruction = rebuild_instruction();
        assert!(instruction.starts_with("git pull"));
        #[cfg(windows)]
        assert!(instruction.contains("install-local.ps1"));
        #[cfg(not(windows))]
        assert!(instruction.contains("install-local.sh"));
    }

    #[cfg(unix)]
    fn fake_pacman(root: &std::path::Path, script: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = root.join("pacman");
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn ownership_requires_successful_query_with_literal_path() {
        let root = tempfile::tempdir().unwrap();
        let pacman = fake_pacman(
            root.path(),
            "[ \"$1\" = -Qoq ] && [ \"$2\" = -- ] && [ \"$3\" = '/usr/bin/driver ; $(false)' ]",
        );
        assert!(pacman_owns_executable(
            std::path::Path::new("/usr/bin/driver ; $(false)"),
            &pacman
        ));
        assert!(!pacman_owns_executable(
            std::path::Path::new("/usr/bin/unmanaged"),
            &pacman
        ));
    }

    #[cfg(unix)]
    #[test]
    fn ownership_queries_symlink_target() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("packaged-driver");
        std::fs::write(&target, "fixture").unwrap();
        let link = root.path().join("driver");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let pacman = fake_pacman(
            root.path(),
            "case \"$3\" in */packaged-driver) exit 0;; *) exit 1;; esac",
        );
        assert!(pacman_owns_executable(&link, &pacman));
    }

    #[cfg(unix)]
    #[test]
    fn missing_failed_and_timed_out_queries_are_not_ownership() {
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("missing-driver");
        assert!(!pacman_owns_executable(
            &executable,
            &root.path().join("missing-pacman")
        ));
        let pacman = fake_pacman(root.path(), "exit 2");
        assert!(!pacman_owns_executable(&executable, &pacman));
        fake_pacman(root.path(), "while :; do :; done");
        let started = std::time::Instant::now();
        assert!(!pacman_owns_executable(&executable, &pacman));
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }
}
