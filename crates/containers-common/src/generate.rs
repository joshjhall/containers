//! File generation primitives: SHA-256 hashing, 3-way merge classification,
//! and batch file writes for template-rendered outputs.
//!
//! These building blocks back `stibbons init/update/add/remove` commands so
//! they can safely re-render generated files without clobbering manual
//! edits. See [`classify_file`] for the drift-detection semantics.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// Classification of a single file during a 3-way merge pass.
///
/// Returned by [`classify_file`]. Call [`FileAction::should_write`] to
/// determine whether the file should be written to disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileAction {
    /// File did not exist on disk. Write new content.
    Created,
    /// File exists and matches the previously-recorded hash (user has not
    /// edited it). Safe to overwrite with new content.
    Updated,
    /// File content on disk already matches the new content. No write needed.
    Unchanged,
    /// File exists but differs from the previously-recorded hash, or no
    /// previous hash was recorded. Preserve the user's changes.
    Skipped,
    /// Would have been [`FileAction::Skipped`], but `force` was set. Overwrite.
    Forced,
}

impl FileAction {
    /// Whether this action requires writing the file to disk.
    #[must_use]
    pub const fn should_write(self) -> bool {
        matches!(self, Self::Created | Self::Updated | Self::Forced)
    }
}

/// A path + content pair to be written by [`write_files`].
#[derive(Debug, Clone)]
pub struct FileEntry {
    /// Destination path on disk.
    pub path: PathBuf,
    /// Rendered file content to write.
    pub content: String,
}

/// Returns the SHA-256 hex digest of a string's UTF-8 bytes.
///
/// Matches Go's `fmt.Sprintf("%x", sha256.Sum256([]byte(s)))` exactly for
/// cross-language hash parity with the Igor predecessor.
#[must_use]
pub fn hash_content(content: &str) -> String {
    hash_bytes(content.as_bytes())
}

fn hash_bytes(bytes: &[u8]) -> String {
    let hash = Sha256::digest(bytes);
    format!("{hash:x}")
}

/// Classifies a file for a 3-way merge: compares the file on disk against
/// the previously-recorded hash and the newly-rendered content to decide
/// whether writing would clobber user edits.
///
/// The path is converted to a string via [`Path::to_string_lossy`] for the
/// `old_hashes` lookup. Keys in `old_hashes` must use the same
/// representation (which matches what [`write_files`] returns).
///
/// Semantics (match the Go reference exactly):
///
/// | Condition                               | Action      |
/// |-----------------------------------------|-------------|
/// | File missing on disk                    | `Created`   |
/// | No old hash recorded, `force=false`     | `Skipped`   |
/// | No old hash recorded, `force=true`      | `Forced`    |
/// | Disk hash == new hash                   | `Unchanged` |
/// | Disk hash == old hash (differs from new) | `Updated`   |
/// | Disk hash differs from both, `force=false` | `Skipped` |
/// | Disk hash differs from both, `force=true`  | `Forced`  |
///
/// # Errors
///
/// Returns an [`std::io::Error`] if the file exists but cannot be read.
/// A missing file is not an error — it is reported as [`FileAction::Created`].
pub fn classify_file(
    path: &Path,
    new_content: &str,
    old_hashes: &BTreeMap<String, String>,
    force: bool,
) -> std::io::Result<FileAction> {
    let disk_data = match std::fs::read(path) {
        Ok(data) => data,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(FileAction::Created);
        }
        Err(e) => return Err(e),
    };

    let key = path.to_string_lossy();
    let Some(old_hash) = old_hashes.get(key.as_ref()) else {
        return Ok(if force { FileAction::Forced } else { FileAction::Skipped });
    };

    let new_hash = hash_content(new_content);
    let disk_hash = hash_bytes(&disk_data);

    if disk_hash == new_hash {
        return Ok(FileAction::Unchanged);
    }
    if &disk_hash == old_hash {
        return Ok(FileAction::Updated);
    }
    Ok(if force { FileAction::Forced } else { FileAction::Skipped })
}

/// Writes each entry to disk, creating parent directories as needed, and
/// returns a map of `path → SHA-256 hex digest` of the written content.
///
/// The caller is expected to filter entries via [`classify_file`] first;
/// this function performs no classification — it writes everything it is
/// given.
///
/// # Errors
///
/// Returns the first [`std::io::Error`] encountered. Remaining entries are
/// not attempted, and already-written files are left in place.
pub fn write_files(entries: &[FileEntry]) -> std::io::Result<BTreeMap<String, String>> {
    let mut hashes = BTreeMap::new();
    for entry in entries {
        if let Some(parent) = entry.path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&entry.path, entry.content.as_bytes())?;
        hashes.insert(entry.path.to_string_lossy().into_owned(), hash_content(&entry.content));
    }
    Ok(hashes)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Known SHA-256 digests (cross-verified with `sha256sum`) confirm Go
    // `fmt.Sprintf("%x", ...)` parity — critical because the hash values
    // get persisted in `.igor.yml` and must round-trip across languages.
    const HASH_EMPTY: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const HASH_ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn hash_content_empty() {
        assert_eq!(hash_content(""), HASH_EMPTY);
    }

    #[test]
    fn hash_content_abc() {
        assert_eq!(hash_content("abc"), HASH_ABC);
    }

    #[test]
    fn hash_content_is_deterministic() {
        assert_eq!(hash_content("hello world"), hash_content("hello world"));
    }

    #[test]
    fn hash_content_differs_for_different_inputs() {
        assert_ne!(hash_content("foo"), hash_content("bar"));
    }

    #[test]
    fn should_write_covers_every_variant() {
        assert!(FileAction::Created.should_write());
        assert!(FileAction::Updated.should_write());
        assert!(FileAction::Forced.should_write());
        assert!(!FileAction::Unchanged.should_write());
        assert!(!FileAction::Skipped.should_write());
    }

    #[test]
    fn classify_missing_file_is_created() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.txt");
        let hashes = BTreeMap::new();

        assert_eq!(classify_file(&path, "new", &hashes, false).unwrap(), FileAction::Created);
        assert_eq!(classify_file(&path, "new", &hashes, true).unwrap(), FileAction::Created);
    }

    #[test]
    fn classify_no_old_hash_without_force_skips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("orphan.txt");
        std::fs::write(&path, "disk content").unwrap();
        let hashes = BTreeMap::new();

        assert_eq!(classify_file(&path, "new", &hashes, false).unwrap(), FileAction::Skipped);
    }

    #[test]
    fn classify_no_old_hash_with_force_forces() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("orphan.txt");
        std::fs::write(&path, "disk content").unwrap();
        let hashes = BTreeMap::new();

        assert_eq!(classify_file(&path, "new", &hashes, true).unwrap(), FileAction::Forced);
    }

    #[test]
    fn classify_disk_matches_new_is_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("same.txt");
        std::fs::write(&path, "identical").unwrap();
        // Old hash differs from disk — Unchanged still wins because we prefer
        // not writing when the rendered output already matches disk.
        let mut hashes = BTreeMap::new();
        hashes.insert(path.to_string_lossy().into_owned(), "stale-hash".into());

        assert_eq!(
            classify_file(&path, "identical", &hashes, false).unwrap(),
            FileAction::Unchanged
        );
        assert_eq!(
            classify_file(&path, "identical", &hashes, true).unwrap(),
            FileAction::Unchanged
        );
    }

    #[test]
    fn classify_disk_matches_old_hash_is_updated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("untouched.txt");
        std::fs::write(&path, "v1 content").unwrap();
        let mut hashes = BTreeMap::new();
        hashes.insert(path.to_string_lossy().into_owned(), hash_content("v1 content"));

        assert_eq!(
            classify_file(&path, "v2 content", &hashes, false).unwrap(),
            FileAction::Updated,
        );
    }

    #[test]
    fn classify_user_modified_without_force_skips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user-edited.txt");
        std::fs::write(&path, "user's edits").unwrap();
        let mut hashes = BTreeMap::new();
        hashes.insert(path.to_string_lossy().into_owned(), hash_content("original"));

        assert_eq!(
            classify_file(&path, "new generated content", &hashes, false).unwrap(),
            FileAction::Skipped,
        );
    }

    #[test]
    fn classify_user_modified_with_force_forces() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user-edited.txt");
        std::fs::write(&path, "user's edits").unwrap();
        let mut hashes = BTreeMap::new();
        hashes.insert(path.to_string_lossy().into_owned(), hash_content("original"));

        assert_eq!(
            classify_file(&path, "new generated content", &hashes, true).unwrap(),
            FileAction::Forced,
        );
    }

    #[test]
    fn write_files_single_file_returns_hash() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.txt");
        let entries = vec![FileEntry { path: path.clone(), content: "hello".into() }];

        let hashes = write_files(&entries).unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello");
        assert_eq!(hashes.len(), 1);
        let key = path.to_string_lossy().into_owned();
        assert_eq!(hashes.get(&key).unwrap(), &hash_content("hello"));
    }

    #[test]
    fn write_files_creates_nested_parent_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a").join("b").join("c").join("deep.txt");
        let entries = vec![FileEntry { path: path.clone(), content: "nested".into() }];

        let hashes = write_files(&entries).unwrap();

        assert!(path.exists(), "nested path should have been created");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "nested");
        assert_eq!(hashes.len(), 1);
    }

    #[test]
    fn write_files_overwrites_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("overwrite.txt");
        std::fs::write(&path, "old").unwrap();
        let entries = vec![FileEntry { path: path.clone(), content: "new".into() }];

        write_files(&entries).unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new");
    }

    #[test]
    fn write_files_empty_slice_returns_empty_map() {
        let hashes = write_files(&[]).unwrap();
        assert!(hashes.is_empty());
    }

    #[test]
    fn write_files_hash_matches_classify_unchanged_on_reread() {
        // Round-trip: writing a file then classifying it with its recorded
        // hash against the same content must yield Unchanged. This is the
        // contract that stibbons init relies on across runs.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("roundtrip.txt");
        let entries = vec![FileEntry { path: path.clone(), content: "stable".into() }];

        let hashes = write_files(&entries).unwrap();
        let action = classify_file(&path, "stable", &hashes, false).unwrap();

        assert_eq!(action, FileAction::Unchanged);
    }
}
