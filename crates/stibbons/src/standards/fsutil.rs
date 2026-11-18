//! Filesystem helpers for `setup standards`: tolerant reads, the symlink
//! guard on write targets, and the executable bit.

use std::path::Path;

/// Read `path`, mapping not-found to `None`.
pub fn read_if_exists(path: &Path) -> Result<Option<Vec<u8>>, Box<dyn std::error::Error>> {
    match std::fs::read(path) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("failed to read {}: {e}", path.display()).into()),
    }
}

/// Whether anything is at `path`, without following a final symlink — so a
/// dangling link counts as present, as in `render.sh`'s `[ -e ] || [ -L ]`.
/// Only not-found is "absent": any other error (a permission-denied parent,
/// a file where a directory should be) is returned, never read as absent.
pub fn exists_no_follow(path: &Path) -> Result<bool, Box<dyn std::error::Error>> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("failed to stat {}: {e}", path.display()).into()),
    }
}

/// Refuse a target whose path, at any existing component under `root`, is a
/// symlink — writing through one could land outside the repository.
pub fn ensure_no_symlink(root: &Path, target: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut p = root.to_path_buf();
    for part in target.split('/') {
        p.push(part);
        match std::fs::symlink_metadata(&p) {
            Ok(m) if m.file_type().is_symlink() => {
                return Err(format!(
                    "refusing to write {target}: {} is a symlink",
                    p.strip_prefix(root).unwrap_or(&p).display()
                )
                .into());
            }
            Ok(_) => {}
            // Nothing exists from here down, so nothing deeper can be a link.
            Err(_) => break,
        }
    }
    Ok(())
}

#[cfg(unix)]
pub fn set_executable(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path)?.permissions();
    perms.set_mode(perms.mode() | 0o755);
    std::fs::set_permissions(path, perms)
}

#[cfg(not(unix))]
#[expect(
    clippy::unnecessary_wraps,
    reason = "must match the fallible unix signature; there is no executable bit to set here"
)]
pub const fn set_executable(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn exists_no_follow_counts_a_dangling_link_and_maps_only_not_found_to_false() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(!exists_no_follow(&tmp.path().join("absent")).unwrap());
        let link = tmp.path().join("dangling");
        std::os::unix::fs::symlink(tmp.path().join("nowhere"), &link).unwrap();
        assert!(exists_no_follow(&link).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn exists_no_follow_errors_on_an_unreadable_parent() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("locked");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("f"), b"x").unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
        let probe = std::fs::symlink_metadata(dir.join("f"));
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        // Control: root (or CAP_DAC_OVERRIDE) stats through mode 000. CI runs
        // unprivileged with REQUIRE_UNPRIVILEGED_TESTS=1, making this skip a failure.
        if probe.is_ok() {
            assert!(
                std::env::var("REQUIRE_UNPRIVILEGED_TESTS").as_deref() != Ok("1"),
                "REQUIRE_UNPRIVILEGED_TESTS=1 but mode 000 is traversable (running as root?)"
            );
            eprintln!("skipping: mode 000 is traversable here (running as root?)");
            return;
        }
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
        let res = exists_no_follow(&dir.join("f"));
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let err = res.unwrap_err().to_string();
        assert!(err.starts_with(&format!("failed to stat {}: ", dir.join("f").display())), "{err}");
    }

    #[test]
    fn read_if_exists_maps_only_not_found_to_none() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(read_if_exists(&tmp.path().join("absent")).unwrap(), None);
        std::fs::write(tmp.path().join("f"), b"hi").unwrap();
        assert_eq!(read_if_exists(&tmp.path().join("f")).unwrap(), Some(b"hi".to_vec()));
    }

    #[test]
    fn read_if_exists_errors_on_a_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        std::fs::create_dir(&dir).unwrap();
        let err = read_if_exists(&dir).unwrap_err().to_string();
        assert!(err.starts_with(&format!("failed to read {}: ", dir.display())), "{err}");
    }

    #[cfg(unix)]
    #[test]
    fn read_if_exists_errors_on_permission_denied() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("secret");
        std::fs::write(&f, b"x").unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o000)).unwrap();
        // Control: root (or CAP_DAC_OVERRIDE) reads through mode 000, so the
        // denial cannot be observed there. CI runs unprivileged and sets
        // REQUIRE_UNPRIVILEGED_TESTS=1, so there this skip is a failure.
        if std::fs::read(&f).is_ok() {
            assert!(
                std::env::var("REQUIRE_UNPRIVILEGED_TESTS").as_deref() != Ok("1"),
                "REQUIRE_UNPRIVILEGED_TESTS=1 but mode 000 is readable (running as root?)"
            );
            eprintln!("skipping: mode 000 is readable here (running as root?)");
            return;
        }
        let err = read_if_exists(&f).unwrap_err().to_string();
        assert!(err.starts_with(&format!("failed to read {}: ", f.display())), "{err}");
    }
}
