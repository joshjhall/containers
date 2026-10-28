//! `.stibbons-standards.yml` — what `setup standards init` applied.
//!
//! Kept separate from `.igor.yml` so the baseline works on any repo, with or
//! without a devcontainer. Two hash maps, deliberately distinct:
//!
//! - `files` — the hash of the bytes stibbons last **wrote** for each target.
//!   This is the provenance `init` classifies against: a file whose on-disk
//!   hash still matches is unedited and safe to update.
//! - `accepted` — the hash of a **user edit** recorded by `setup standards
//!   accept`. `check` treats a file matching its accepted hash as clean, and
//!   `init` never overwrites it without `--force`. Folding these into one map
//!   would make an accepted edit look "unedited" to `init`, which would then
//!   silently clobber it.

use std::collections::BTreeMap;
use std::path::Path;

/// File name of the standards state, at the repo root.
pub const STATE_FILE: &str = ".stibbons-standards.yml";

/// Schema version written by this build.
const STATE_VERSION: u32 = 1;

/// Persisted standards state.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StandardsState {
    /// Schema version.
    #[serde(default)]
    pub version: u32,
    /// Where the templates came from (e.g. `librarian 0.18.0`).
    #[serde(default)]
    pub source: String,
    /// Selected language slices.
    #[serde(default)]
    pub slices: Vec<String>,
    /// Selected CI platforms.
    #[serde(default)]
    pub ci: Vec<String>,
    /// Target → SHA-256 of the bytes stibbons last wrote.
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    /// Target → SHA-256 of a user edit accepted via `setup standards accept`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub accepted: BTreeMap<String, String>,
}

impl StandardsState {
    /// A fresh state stamped with the current schema version.
    #[must_use]
    pub fn new() -> Self {
        Self { version: STATE_VERSION, ..Self::default() }
    }

    /// Load the state from `path`, or `None` when it does not exist.
    ///
    /// # Errors
    ///
    /// Returns an error when the file exists but cannot be read or parsed, or
    /// was written by a newer stibbons (unknown schema version).
    pub fn load(path: &Path) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("failed to read {}: {e}", path.display()).into()),
        };
        let state: Self = serde_saphyr::from_str(&text)
            .map_err(|e| format!("failed to parse {}: {e}", path.display()))?;
        if state.version > STATE_VERSION {
            return Err(format!(
                "{} has schema version {}, newer than this stibbons supports ({STATE_VERSION}); \
                 upgrade stibbons",
                path.display(),
                state.version
            )
            .into());
        }
        Ok(Some(state))
    }

    /// Write the state to `path`.
    ///
    /// # Errors
    ///
    /// Returns an error when serialization or the write fails.
    pub fn save(&self, path: &Path) -> Result<(), Box<dyn std::error::Error>> {
        let body = serde_saphyr::to_string(self)?;
        let text = format!(
            "# Managed by `stibbons setup standards`. Records which repo-baseline\n\
             # files were applied and their hashes, for drift detection.\n{body}"
        );
        std::fs::write(path, text)
            .map_err(|e| format!("failed to write {}: {e}", path.display()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_loads_as_none() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(StandardsState::load(&tmp.path().join(STATE_FILE)).unwrap().is_none());
    }

    #[test]
    fn round_trips() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(STATE_FILE);
        let mut s = StandardsState::new();
        s.source = "librarian 0.18.0".into();
        s.slices = vec!["python".into(), "shell".into()];
        s.ci = vec!["github".into()];
        s.files.insert("justfile".into(), "abc".into());
        s.accepted.insert("ruff.toml".into(), "def".into());
        s.save(&path).unwrap();
        assert_eq!(StandardsState::load(&path).unwrap().unwrap(), s);
    }

    #[test]
    fn rejects_newer_schema() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(STATE_FILE);
        std::fs::write(&path, "version: 99\n").unwrap();
        let err = StandardsState::load(&path).unwrap_err().to_string();
        assert!(err.contains("newer than this stibbons supports"), "{err}");
    }

    #[test]
    fn malformed_file_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(STATE_FILE);
        std::fs::write(&path, "files: [not, a, map\n").unwrap();
        assert!(StandardsState::load(&path).is_err());
    }
}
