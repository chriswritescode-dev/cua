//! Repository-backed update guidance.
//!
//! Installing a release build over the running installation is disabled: the
//! driver only ever reports that a newer release exists and tells the user to
//! pull the repository and rebuild from source.

pub(crate) const PACMAN_UPDATE_GUIDANCE: &str =
    "This executable is managed by pacman. Update with `sudo pacman -Syu`; \
     release selection and availability are controlled by your package repository. \
     The upstream installer and stable/nightly channel switching are disabled.";

/// Only positive package ownership disables the upstream updater. Missing
/// pacman, failed queries, and unresolved paths retain unmanaged behavior.
pub(crate) fn is_pacman_managed() -> bool {
    #[cfg(target_os = "linux")]
    {
        std::env::current_exe()
            .map(|path| pacman_owns_executable(&path, std::path::Path::new("/usr/bin/pacman")))
            .unwrap_or(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
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
    use std::process::Stdio;
    use std::time::{Duration, Instant};

    let Ok(mut child) = std::process::Command::new(pacman)
        .args(["-Qoq", "--"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
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
