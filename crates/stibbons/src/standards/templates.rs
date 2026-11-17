//! Where `setup standards` reads its templates: the containers-db snapshot
//! compiled in through the pinned `repo-baseline` git dependency, or a
//! directory on disk (`--templates-dir`).

use std::path::PathBuf;

use super::manifest::{Manifest, SourceReader};

/// The containers-db commit the embedded templates come from: the
/// `repo-baseline` dependency's pinned rev, stamped by `build.rs` after
/// checking it against Cargo.lock.
pub const SNAPSHOT_SHA: &str = env!("REPO_BASELINE_SHA");

/// Where templates are read from.
#[derive(Debug, Clone)]
pub enum Templates {
    /// The snapshot compiled into this binary.
    Embedded,
    /// A `baseline/templates` directory on disk.
    Dir(PathBuf),
}

impl Templates {
    /// `Dir` when `dir` is given, else `Embedded`.
    #[must_use]
    pub fn from_flag(dir: Option<PathBuf>) -> Self {
        dir.map_or(Self::Embedded, Self::Dir)
    }

    /// Load and validate the manifest.
    ///
    /// # Errors
    ///
    /// Returns an error when `manifest.tsv` is missing or fails validation.
    pub fn manifest(&self) -> Result<Manifest, Box<dyn std::error::Error>> {
        let bytes = self.read("manifest.tsv").ok_or_else(|| match self {
            Self::Embedded => "embedded templates have no manifest.tsv".to_string(),
            Self::Dir(d) => format!("manifest.tsv not found in {}", d.display()),
        })?;
        let text = String::from_utf8(bytes).map_err(|_| "manifest.tsv is not valid UTF-8")?;
        Ok(Manifest::parse(&text, self)?)
    }

    /// A human-readable provenance label, recorded in the state file.
    #[must_use]
    pub fn label(&self) -> String {
        match self {
            Self::Embedded => format!("containers-db {SNAPSHOT_SHA}"),
            Self::Dir(d) => format!("dir {}", d.display()),
        }
    }

    /// The containers-db snapshot SHA, for the embedded templates only: a
    /// directory has no pinned commit.
    #[must_use]
    pub const fn snapshot(&self) -> Option<&'static str> {
        match self {
            Self::Embedded => Some(SNAPSHOT_SHA),
            Self::Dir(_) => None,
        }
    }
}

impl SourceReader for Templates {
    fn read(&self, source: &str) -> Option<Vec<u8>> {
        match self {
            Self::Embedded => repo_baseline::get(source).map(<[u8]>::to_vec),
            Self::Dir(d) => std::fs::read(d.join(source)).ok(),
        }
    }
}
