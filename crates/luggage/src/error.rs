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

use containers_common::tooldb::ActivityScore;
use containers_common::version::VersionError;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Result alias used throughout the luggage crate.
pub type Result<T> = core::result::Result<T, LuggageError>;

/// Stage-aligned classification of an install failure, suitable for
/// inclusion in an evidence row.
///
/// Values match the `error_class` enum in containers-db's
/// `schema/version.schema.json` exactly, so a serialized `ErrorClass`
/// validates as-is against the schema. The mapping from `LuggageError`
/// keeps categorization mechanical: every install-time failure variant
/// maps to a stage; everything else (pre-install resolver, catalog
/// parse, IO) maps to `Unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorClass {
    /// Artifact download failed after retries.
    Download,
    /// 4-tier verification rejected the downloaded artifact.
    Verify,
    /// Install method (rustup-init, script, etc.) failed mid-run.
    InstallMethod,
    /// A `post_install[]` step failed.
    PostInstall,
    /// Post-install `<bin>/<tool> --version` validation failed.
    Validate,
    /// CI runner / network / registry / host-package-manager failure —
    /// anything that wasn't the tool's own fault.
    Infra,
    /// Pre-install resolver, catalog, parse, IO, or otherwise
    /// unclassified error. Older runs predating this enum also surface
    /// here.
    Unknown,
}

impl From<&LuggageError> for ErrorClass {
    fn from(err: &LuggageError) -> Self {
        match err {
            LuggageError::PackageManagerFailed { .. } | LuggageError::UnknownDependency { .. } => {
                Self::Infra
            }
            LuggageError::DownloadFailed { .. } => Self::Download,
            LuggageError::VerificationFailed { .. } => Self::Verify,
            LuggageError::PostInstallFailed { .. } => Self::PostInstall,
            LuggageError::ValidationFailed { .. } => Self::Validate,
            // `chown` and `spawn` are emitted inside install-method
            // execution; any other stage value from a future method
            // also belongs here.
            LuggageError::InstallStageFailed { .. } => Self::InstallMethod,
            LuggageError::Io { .. }
            | LuggageError::Parse { .. }
            | LuggageError::ToolNotFound(_)
            | LuggageError::VersionNotFound { .. }
            | LuggageError::UnsupportedPlatform(_)
            | LuggageError::NoMatchingInstallMethod { .. }
            | LuggageError::VersionParse(_)
            | LuggageError::ActivityBelowThreshold { .. }
            | LuggageError::BelowMinimumRecommended { .. }
            | LuggageError::PlatformDetectionFailed(_)
            | LuggageError::NotImplemented(_)
            | LuggageError::Catalog(_)
            | LuggageError::TemplateMissingKey(_) => Self::Unknown,
        }
    }
}

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

    /// Tool's activity score is below the policy's `min_activity` threshold.
    #[error(
        "tool `{tool}` has activity `{score:?}`, below the policy threshold `{threshold:?}`; \
         pass `--allow-abandoned` or a more permissive `--policy` to override"
    )]
    ActivityBelowThreshold {
        /// Tool id.
        tool: String,
        /// Tool's actual activity tier.
        score: ActivityScore,
        /// Policy's `min_activity` threshold.
        threshold: ActivityScore,
    },

    /// Resolved version is below the tool's `minimum_recommended` and the
    /// policy does not allow it.
    #[error(
        "tool `{tool}` resolved to version `{version}`, below `minimum_recommended` `{minimum}`; \
         pass `--allow-below-min-recommended` to override"
    )]
    BelowMinimumRecommended {
        /// Tool id.
        tool: String,
        /// Resolved version literal.
        version: String,
        /// Tool's `minimum_recommended` value.
        minimum: String,
    },

    /// Auto-detection of the host platform failed (e.g. `/etc/os-release` missing).
    #[error("could not auto-detect platform: {0}")]
    PlatformDetectionFailed(String),

    /// The requested feature is not yet implemented in this build.
    #[error("not implemented: {0}")]
    NotImplemented(&'static str),

    /// Catalog content failed an internal cross-check (e.g. duplicate version).
    #[error("catalog error: {0}")]
    Catalog(String),

    /// An install pipeline stage failed in a way that doesn't map to one of
    /// the more specific variants below.
    #[error("install stage `{stage}` failed: {message}")]
    InstallStageFailed {
        /// Stage identifier (e.g. `"download"`, `"chmod"`).
        stage: &'static str,
        /// Human-readable detail.
        message: String,
    },

    /// 4-tier verification rejected a downloaded artifact.
    #[error("verification (tier {tier}) failed for {tool}@{version}: {reason}")]
    VerificationFailed {
        /// Tool id.
        tool: String,
        /// Tool version.
        version: String,
        /// Verification tier (`1`–`4`).
        tier: u8,
        /// Human-readable detail.
        reason: String,
    },

    /// HTTP fetch failed after the configured retry budget was exhausted.
    #[error("download from {url} failed after {attempts} attempts: {message}")]
    DownloadFailed {
        /// URL being fetched.
        url: String,
        /// Number of attempts before giving up.
        attempts: u32,
        /// Underlying error message.
        message: String,
    },

    /// Host package manager (apt/apk/dnf) refused to install one or more
    /// dependency packages.
    #[error("package manager failed: {message}")]
    PackageManagerFailed {
        /// Human-readable detail.
        message: String,
    },

    /// A `post_install[]` step failed.
    #[error("post-install step `{step}` failed: {message}")]
    PostInstallFailed {
        /// Step identifier (e.g. `"component_add:rust-src"`).
        step: String,
        /// Human-readable detail.
        message: String,
    },

    /// Post-install validation could not confirm the tool is installed.
    #[error("validation failed for {tool}@{version}: {message}")]
    ValidationFailed {
        /// Tool id.
        tool: String,
        /// Tool version.
        version: String,
        /// Human-readable detail.
        message: String,
    },

    /// A URL template referenced a placeholder we don't have a value for.
    #[error("template substitution: missing key `{0}`")]
    TemplateMissingKey(String),

    /// One or more catalog dependency ids had no system-package mapping in
    /// this build of luggage, and strict mode (the default) refused to
    /// proceed. Pass `--allow-unknown-deps` to downgrade to a warn-and-skip.
    #[error("unknown dependency id(s) for {manager}: {ids}")]
    UnknownDependency {
        /// Host package manager the lookup was performed against
        /// (e.g. `Apt`, `Apk`, `Dnf`).
        manager: String,
        /// Comma-separated list of the unrecognized dependency ids.
        ids: String,
    },
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
    fn activity_below_threshold_exit_code_is_one() {
        let err = LuggageError::ActivityBelowThreshold {
            tool: "ghost".into(),
            score: ActivityScore::Abandoned,
            threshold: ActivityScore::Maintained,
        };
        assert_eq!(err.exit_code(), 1);
        let msg = format!("{err}");
        assert!(msg.contains("ghost"));
        assert!(msg.contains("Abandoned"));
        assert!(msg.contains("Maintained"));
    }

    #[test]
    fn below_minimum_recommended_exit_code_is_one() {
        let err = LuggageError::BelowMinimumRecommended {
            tool: "rust".into(),
            version: "1.50.0".into(),
            minimum: "1.84.0".into(),
        };
        assert_eq!(err.exit_code(), 1);
        let msg = format!("{err}");
        assert!(msg.contains("1.50.0"));
        assert!(msg.contains("1.84.0"));
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

    #[test]
    fn install_stage_failed_exit_code_is_one() {
        let err = LuggageError::InstallStageFailed {
            stage: "download",
            message: "connection refused".into(),
        };
        assert_eq!(err.exit_code(), 1);
        assert!(format!("{err}").contains("download"));
    }

    #[test]
    fn verification_failed_exit_code_is_one() {
        let err = LuggageError::VerificationFailed {
            tool: "rust".into(),
            version: "1.95.0".into(),
            tier: 3,
            reason: "sha256 mismatch".into(),
        };
        assert_eq!(err.exit_code(), 1);
        let msg = format!("{err}");
        assert!(msg.contains("tier 3"));
        assert!(msg.contains("rust@1.95.0"));
        assert!(msg.contains("sha256 mismatch"));
    }

    #[test]
    fn download_failed_exit_code_is_one() {
        let err = LuggageError::DownloadFailed {
            url: "https://example.test/x".into(),
            attempts: 8,
            message: "timeout".into(),
        };
        assert_eq!(err.exit_code(), 1);
        let msg = format!("{err}");
        assert!(msg.contains("8 attempts"));
    }

    #[test]
    fn package_manager_failed_exit_code_is_one() {
        let err = LuggageError::PackageManagerFailed { message: "apt-get returned 100".into() };
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn post_install_failed_exit_code_is_one() {
        let err = LuggageError::PostInstallFailed {
            step: "component_add:rust-src".into(),
            message: "rustup component add failed".into(),
        };
        assert_eq!(err.exit_code(), 1);
        assert!(format!("{err}").contains("component_add:rust-src"));
    }

    #[test]
    fn validation_failed_exit_code_is_one() {
        let err = LuggageError::ValidationFailed {
            tool: "rust".into(),
            version: "1.95.0".into(),
            message: "rustc --version mismatch".into(),
        };
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn unknown_dependency_exit_code_is_one() {
        let err =
            LuggageError::UnknownDependency { manager: "Apt".into(), ids: "frobnicator".into() };
        assert_eq!(err.exit_code(), 1);
        let msg = format!("{err}");
        assert!(msg.contains("Apt"));
        assert!(msg.contains("frobnicator"));
    }

    #[test]
    fn template_missing_key_exit_code_is_one() {
        let err = LuggageError::TemplateMissingKey("rustup_target".into());
        assert_eq!(err.exit_code(), 1);
        assert!(format!("{err}").contains("rustup_target"));
    }

    #[test]
    fn error_class_maps_runtime_variants_to_their_stage() {
        let cases: &[(LuggageError, ErrorClass)] = &[
            (LuggageError::PackageManagerFailed { message: "apt".into() }, ErrorClass::Infra),
            (
                LuggageError::UnknownDependency {
                    manager: "Apt".into(),
                    ids: "frobnicator".into(),
                },
                ErrorClass::Infra,
            ),
            (
                LuggageError::DownloadFailed {
                    url: "https://x".into(),
                    attempts: 1,
                    message: "x".into(),
                },
                ErrorClass::Download,
            ),
            (
                LuggageError::VerificationFailed {
                    tool: "rust".into(),
                    version: "1.0".into(),
                    tier: 3,
                    reason: "x".into(),
                },
                ErrorClass::Verify,
            ),
            (
                LuggageError::InstallStageFailed { stage: "spawn", message: "x".into() },
                ErrorClass::InstallMethod,
            ),
            (
                LuggageError::PostInstallFailed { step: "x".into(), message: "x".into() },
                ErrorClass::PostInstall,
            ),
            (
                LuggageError::ValidationFailed {
                    tool: "rust".into(),
                    version: "1.0".into(),
                    message: "x".into(),
                },
                ErrorClass::Validate,
            ),
        ];
        for (err, expected) in cases {
            assert_eq!(ErrorClass::from(err), *expected, "{err}");
        }
    }

    #[test]
    fn error_class_maps_pre_install_variants_to_unknown() {
        let cases: Vec<LuggageError> = vec![
            LuggageError::Io { path: PathBuf::from("/x"), source: std::io::Error::other("x") },
            LuggageError::ToolNotFound("ghost".into()),
            LuggageError::VersionNotFound { tool: "rust".into(), spec: "9.9.9".into() },
            LuggageError::NoMatchingInstallMethod {
                tool: "rust".into(),
                version: "1.0".into(),
                os: "darwin".into(),
                os_version: None,
                arch: "amd64".into(),
            },
            LuggageError::ActivityBelowThreshold {
                tool: "ghost".into(),
                score: ActivityScore::Abandoned,
                threshold: ActivityScore::Maintained,
            },
            LuggageError::BelowMinimumRecommended {
                tool: "rust".into(),
                version: "1.0".into(),
                minimum: "1.84.0".into(),
            },
            LuggageError::PlatformDetectionFailed("missing /etc/os-release".into()),
            LuggageError::NotImplemented("x"),
            LuggageError::Catalog("x".into()),
            LuggageError::TemplateMissingKey("x".into()),
        ];
        for err in &cases {
            assert_eq!(ErrorClass::from(err), ErrorClass::Unknown, "{err}");
        }
    }

    #[test]
    fn error_class_wire_format_matches_containers_db_schema() {
        // Pin the wire format to the containers-db enum exactly. If the
        // schema changes, this test forces a coordinated update.
        let pairs = [
            (ErrorClass::Download, "\"download\""),
            (ErrorClass::Verify, "\"verify\""),
            (ErrorClass::InstallMethod, "\"install_method\""),
            (ErrorClass::PostInstall, "\"post_install\""),
            (ErrorClass::Validate, "\"validate\""),
            (ErrorClass::Infra, "\"infra\""),
            (ErrorClass::Unknown, "\"unknown\""),
        ];
        for (c, expected) in pairs {
            let got = serde_json::to_string(&c).unwrap();
            assert_eq!(got, expected);
            let back: ErrorClass = serde_json::from_str(expected).unwrap();
            assert_eq!(back, c);
        }
    }
}
