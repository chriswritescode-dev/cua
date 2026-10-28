//! Finding the cua-spacesd binary the service runs.
//!
//! Order: an explicit path, `CUA_SPACESD_BIN` (or the older `CUA_GUESTD_BIN`
//! / `CUA_ENV_DRIVER_BIN`), a binary next to the current executable (the app
//! bundle / CLI install ships one). There is no download: cua-spacesd comes
//! from the repository you built this from.
//!
//! ```text
//! cargo build --release --manifest-path libs/cua-spacesd/Cargo.toml -p cua-spacesd
//! export CUA_SPACESD_BIN="$PWD/libs/cua-spacesd/target/release/cua-spacesd"
//! ```

use crate::{Error, Result};
use std::path::{Path, PathBuf};

/// Binary file name for this OS.
pub fn binary_name() -> &'static str {
    if cfg!(windows) {
        "cua-spacesd.exe"
    } else {
        "cua-spacesd"
    }
}

/// `CUA_SPACESD_<name>`, else the older `CUA_GUESTD_<name>` or
/// `CUA_ENV_DRIVER_<name>` (the new name wins). Empty values count as unset.
fn spacesd_env(name: &str) -> Option<std::ffi::OsString> {
    [
        format!("CUA_SPACESD_{name}"),
        format!("CUA_GUESTD_{name}"),
        format!("CUA_ENV_DRIVER_{name}"),
    ]
    .iter()
    .find_map(|k| std::env::var_os(k).filter(|v| !v.is_empty()))
}

fn missing_binary() -> Error {
    Error::NotFound(format!(
        "cua-spacesd is not installed: pass its path, set CUA_SPACESD_BIN, or put \
         {} next to this executable. Build it from the repository first: \
         cargo build --release --manifest-path libs/cua-spacesd/Cargo.toml \
         -p cua-spacesd",
        binary_name()
    ))
}

/// Resolves the binary without touching the network.
pub fn locate(explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return if p.is_file() {
            Ok(p.to_path_buf())
        } else {
            Err(Error::InvalidArgument(format!(
                "cua-spacesd binary {} does not exist",
                p.display()
            )))
        };
    }
    if let Some(p) = spacesd_env("BIN") {
        let p = PathBuf::from(p);
        return if p.is_file() {
            Ok(p)
        } else {
            Err(Error::InvalidArgument(format!(
                "CUA_SPACESD_BIN={} does not exist",
                p.display()
            )))
        };
    }
    if let Ok(exe) = std::env::current_exe().and_then(std::fs::canonicalize)
        && let Some(dir) = exe.parent()
    {
        // Next to the CLI (also a Cua Spaces app before 0.15), or in a macOS
        // bundle's Contents/Helpers (the app's own) or Contents/Resources.
        for candidate in [
            dir.join(binary_name()),
            dir.join("../Helpers").join(binary_name()),
            dir.join("../Resources").join(binary_name()),
        ] {
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(missing_binary())
}

/// Puts the driver at `dest` (copying the local binary) and makes it
/// executable.
pub fn install_to(source: &Path, dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("partial");
    if same_file(source, dest) {
        return Ok(());
    }
    std::fs::copy(source, &tmp)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    }
    replace_file(&tmp, dest, |from, to| std::fs::rename(from, to))
}

/// Moves `tmp` over `dest`. Windows will not overwrite or delete a running
/// executable (`os error 5` or `32`), which is what a second setup on a
/// machine whose host service is already up hit at the install stage
/// (the service holds `cua-spacesd.exe` open). It does allow renaming it,
/// so the running copy is moved aside to `<dest>.old` and the new one takes
/// its name; the old copy goes on the next install, once it has exited.
/// The same bytes are left alone: nothing to replace.
fn replace_file(
    tmp: &Path,
    dest: &Path,
    rename: impl Fn(&Path, &Path) -> std::io::Result<()>,
) -> Result<()> {
    if same_bytes(tmp, dest) {
        let _ = std::fs::remove_file(tmp);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(dest, std::fs::Permissions::from_mode(0o755))?;
        }
        return Ok(());
    }
    let aside = dest.with_extension("old");
    let _ = std::fs::remove_file(&aside);
    match rename(tmp, dest) {
        Ok(()) => Ok(()),
        Err(first) if dest.exists() => {
            rename(dest, &aside).map_err(|_| first)?;
            rename(tmp, dest).inspect_err(|_| {
                let _ = rename(&aside, dest);
            })?;
            Ok(())
        }
        Err(e) => Err(e.into()),
    }
}

fn same_bytes(a: &Path, b: &Path) -> bool {
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(ma), Ok(mb)) if ma.len() == mb.len() => {
            matches!((std::fs::read(a), std::fs::read(b)), (Ok(x), Ok(y)) if x == y)
        }
        _ => false,
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_name_is_the_repository_package_binary() {
        assert_eq!(
            binary_name(),
            format!("cua-spacesd{}", std::env::consts::EXE_SUFFIX)
        );
    }

    #[test]
    fn explicit_paths_must_exist() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("drv");
        assert!(locate(Some(&bin)).is_err());
        std::fs::write(&bin, b"x").unwrap();
        assert_eq!(locate(Some(&bin)).unwrap(), bin);
    }

    #[test]
    fn a_missing_binary_says_how_to_build_it() {
        let message = missing_binary().to_string();
        assert!(message.contains("CUA_SPACESD_BIN"), "{message}");
        assert!(
            message.contains("cargo build --release --manifest-path libs/cua-spacesd/Cargo.toml"),
            "{message}"
        );
    }

    #[test]
    fn replacing_a_locked_driver_moves_it_aside() {
        let dir = tempfile::tempdir().unwrap();
        let (tmp, dest) = (dir.path().join("d.partial"), dir.path().join("d.exe"));
        std::fs::write(&dest, b"old").unwrap();
        std::fs::write(&tmp, b"new").unwrap();
        // Windows: overwriting the running exe is refused, renaming it is not.
        let locked = |from: &Path, to: &Path| {
            if to.exists() {
                Err(std::io::Error::from_raw_os_error(5))
            } else {
                std::fs::rename(from, to)
            }
        };
        replace_file(&tmp, &dest, locked).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"new");
        assert_eq!(std::fs::read(dir.path().join("d.old")).unwrap(), b"old");
        // A later install clears the stale copy.
        std::fs::write(&tmp, b"newer").unwrap();
        replace_file(&tmp, &dest, locked).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"newer");
    }

    #[test]
    fn an_unchanged_driver_is_not_touched() {
        let dir = tempfile::tempdir().unwrap();
        let (tmp, dest) = (dir.path().join("d.partial"), dir.path().join("d.exe"));
        std::fs::write(&dest, b"same").unwrap();
        std::fs::write(&tmp, b"same").unwrap();
        replace_file(&tmp, &dest, |_, _| panic!("must not rename")).unwrap();
        assert!(!tmp.exists());
        assert_eq!(std::fs::read(&dest).unwrap(), b"same");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o644)).unwrap();
            std::fs::write(&tmp, b"same").unwrap();
            replace_file(&tmp, &dest, |_, _| panic!("must not rename")).unwrap();
            let mode = std::fs::metadata(&dest).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "execute bits are repaired");
        }
    }

    #[test]
    fn a_failed_replace_restores_the_old_driver() {
        let dir = tempfile::tempdir().unwrap();
        let (tmp, dest) = (dir.path().join("d.partial"), dir.path().join("d.exe"));
        std::fs::write(&dest, b"old").unwrap();
        std::fs::write(&tmp, b"new").unwrap();
        let n = std::cell::Cell::new(0);
        let r = replace_file(&tmp, &dest, |from, to| {
            n.set(n.get() + 1);
            // tmp -> dest always fails; dest -> aside and the restore work.
            if from == tmp {
                Err(std::io::Error::from_raw_os_error(5))
            } else {
                std::fs::rename(from, to)
            }
        });
        assert!(r.is_err());
        assert_eq!(std::fs::read(&dest).unwrap(), b"old");
    }

    #[test]
    fn install_copies_the_local_binary_and_marks_it_executable() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        std::fs::write(&source, b"driver-bytes").unwrap();
        let dest = dir.path().join("bin").join(binary_name());
        install_to(&source, &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"driver-bytes");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&dest).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
    }
}
