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
pub fn set_executable(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path)?.permissions();
    perms.set_mode(perms.mode() | 0o755);
    std::fs::set_permissions(path, perms)
        .map_err(|e| format!("failed to chmod {}: {e}", path.display()).into())
}

#[cfg(not(unix))]
pub fn set_executable(_path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    Ok(())
}
