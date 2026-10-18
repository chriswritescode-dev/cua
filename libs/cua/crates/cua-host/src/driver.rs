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
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        // Next to the CLI, or in a macOS bundle's Contents/MacOS or
        // Contents/Resources.
        for candidate in [
            dir.join(binary_name()),
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
    std::fs::rename(&tmp, dest)?;
    Ok(())
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
