//! Luggage error type and `Result` alias.
//!
//! The CLI maps each variant to an exit code via [`LuggageError::exit_code`]:
//! `0` on success, `2` for "we will not install on this host"
//! ([`LuggageError::UnsupportedPlatform`] or
//! [`LuggageError::NoMatchingInstallMethod`]), and `1` for everything else.
//! Distinguishing the two lets bash callers gate an "install if possible,
//! skip otherwise" pattern without parsing stderr.

use std::fmt;
use std::path::PathBuf;

use containers_common::version::VersionError;
use thiserror::Error;

/// Result alias used throughout the luggage crate.
pub type Result<T> = core::result::Result<T, LuggageError>;

/// Detail payload for [`LuggageError::UnsupportedPlatform`].
///
/// Boxed inside the enum variant so the overall error type stays small.
#[derive(Debug, Clone)]
pub struct UnsupportedPlatformDetails {
    /// Tool id.
    pub tool: String,
    /// Tool version that was selected.
    pub version: String,
    /// Distro id.
    pub os: String,
    /// Distro version (when known).
    pub os_version: Option<String>,
    /// CPU architecture.
    pub arch: String,
    /// Structured reason from `support_matrix[].reason`.
    pub reason: Option<String>,
    /// Optional upstream tracking URL.
    pub tracking_url: Option<String>,
}

/// Errors raised by luggage during catalog load and version resolution.
#[derive(Debug, Error)]
pub enum LuggageError {
    /// Filesystem I/O failed.
    #[error("io error at {path}: {source}")]
    Io {
        /// Path being read or written.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },

    /// JSON parsing failed for a catalog file.
    #[error("failed to parse {path}: {source}")]
    Parse {
        /// Path of the file that failed to parse.
        path: PathBuf,
        /// Underlying serde error.
        #[source]
        source: serde_json::Error,
    },

    /// Tool id is not present in the catalog.
    #[error("tool `{0}` not found in catalog")]
    ToolNotFound(String),

    /// No version satisfied the requested spec.
    #[error("no version of `{tool}` matches spec `{spec}`")]
    VersionNotFound {
        /// Tool whose versions were searched.
        tool: String,
        /// Human-readable description of the spec.
        spec: String,
    },

    /// The host platform is explicitly unsupported by this tool version.
    ///
    /// Distinct from [`Self::NoMatchingInstallMethod`] in that the catalog
    /// has an `unsupported` row in the support matrix specifically calling
    /// out this combination. The fields are boxed so the [`LuggageError`]
    /// enum stays small enough to satisfy `clippy::result_large_err`.
    #[error("{}", FormatUnsupported(_0))]
    UnsupportedPlatform(Box<UnsupportedPlatformDetails>),

    /// No `install_methods[]` entry's platform predicate matched the host.
    #[error("no install method for {tool}@{version} matches {os}/{arch}")]
    NoMatchingInstallMethod {
        /// Tool id.
        tool: String,
        /// Tool version that was selected.
        version: String,
        /// Distro id.
        os: String,
        /// Distro version (when known).
        os_version: Option<String>,
        /// CPU architecture.
        arch: String,
    },

    /// A version literal in the catalog or a request failed to parse.
    #[error(transparent)]
    VersionParse(#[from] VersionError),

    /// Auto-detection of the host platform failed (e.g. `/etc/os-release` missing).
    #[error("could not auto-detect platform: {0}")]
    PlatformDetectionFailed(String),

    /// The requested feature is not yet implemented in this build.
    #[error("not implemented: {0}")]
    NotImplemented(&'static str),

    /// Catalog content failed an internal cross-check (e.g. duplicate version).
    #[error("catalog error: {0}")]
    Catalog(String),
}

impl LuggageError {
    /// Process exit code the CLI should use for this error.
    ///
    /// `2` — host is unsupported or no install method matched. Callers can
    /// branch on this to skip silently in shim scripts.
    /// `1` — everything else (bug, malformed catalog, missing tool, etc.).
    #[must_use]
    pub const fn exit_code(&self) -> i32 {
        match self {
            Self::UnsupportedPlatform { .. } | Self::NoMatchingInstallMethod { .. } => 2,
            _ => 1,
        }
    }
}

/// Renders [`LuggageError::UnsupportedPlatform`] including the optional
/// `os_version`, `reason`, and `tracking_url` tail. Kept as a separate type
/// so the `#[error(...)]` template can stay terse.
struct FormatUnsupported<'a>(&'a UnsupportedPlatformDetails);

impl fmt::Display for FormatUnsupported<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let UnsupportedPlatformDetails {
            tool,
            version,
            os,
            os_version,
            arch,
            reason,
            tracking_url,
        } = self.0;
        let osv = os_version.as_deref().unwrap_or("any");
        write!(f, "platform {os}/{osv}/{arch} is unsupported for {tool}@{version}")?;
        if let Some(r) = reason {
            write!(f, ": {r}")?;
        }
        if let Some(url) = tracking_url {
            write!(f, " ({url})")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_platform_exit_code_is_two() {
        let err = LuggageError::UnsupportedPlatform(Box::new(UnsupportedPlatformDetails {
            tool: "rust".into(),
            version: "1.95.0".into(),
            os: "windows".into(),
            os_version: None,
            arch: "amd64".into(),
            reason: Some("no upstream rustup target".into()),
            tracking_url: None,
        }));
        assert_eq!(err.exit_code(), 2);
    }

    #[test]
    fn no_matching_install_method_exit_code_is_two() {
        let err = LuggageError::NoMatchingInstallMethod {
            tool: "rust".into(),
            version: "1.95.0".into(),
            os: "windows".into(),
            os_version: None,
            arch: "amd64".into(),
        };
        assert_eq!(err.exit_code(), 2);
    }

    #[test]
    fn tool_not_found_exit_code_is_one() {
        let err = LuggageError::ToolNotFound("ghost".into());
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn version_not_found_exit_code_is_one() {
        let err = LuggageError::VersionNotFound { tool: "rust".into(), spec: "9.9.9".into() };
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn unsupported_display_includes_reason_and_url() {
        let err = LuggageError::UnsupportedPlatform(Box::new(UnsupportedPlatformDetails {
            tool: "rust".into(),
            version: "1.95.0".into(),
            os: "windows".into(),
            os_version: Some("11".into()),
            arch: "amd64".into(),
            reason: Some("no upstream rustup target".into()),
            tracking_url: Some("https://example.test/123".into()),
        }));
        let msg = format!("{err}");
        assert!(msg.contains("windows/11/amd64"));
        assert!(msg.contains("rust@1.95.0"));
        assert!(msg.contains("no upstream rustup target"));
        assert!(msg.contains("https://example.test/123"));
    }

    #[test]
    fn unsupported_display_handles_missing_os_version() {
        let err = LuggageError::UnsupportedPlatform(Box::new(UnsupportedPlatformDetails {
            tool: "rust".into(),
            version: "1.95.0".into(),
            os: "windows".into(),
            os_version: None,
            arch: "amd64".into(),
            reason: None,
            tracking_url: None,
        }));
        let msg = format!("{err}");
        assert!(msg.contains("windows/any/amd64"));
    }
}
