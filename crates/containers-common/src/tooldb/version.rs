//! `ToolVersion` — per-version installation and support data.
//!
//! Mirrors `tools/<id>/versions/<v>.json` validated by `schema/version.schema.json`.

use serde::{Deserialize, Serialize};

use super::{Dependency, InstallMethod};

/// Per-version document. One file per `(tool, version)` pair.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToolVersion {
    /// Schema version. Currently always `1`.
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// Tool id this version belongs to (matches the parent directory).
    pub tool: String,
    /// Version string.
    pub version: String,
    /// Upstream release date (calendar date).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released: Option<String>,
    /// Release channel id (must reference the parent tool's `channels` map).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    /// CLAIM: which OS/version/arch combinations this version is said to run on.
    #[serde(default)]
    pub support_matrix: Vec<SupportEntry>,
    /// EVIDENCE: CI runs that demonstrated this version actually worked.
    #[serde(default)]
    pub tested: Vec<TestEntry>,
    /// Version-level compatibility expectations across all install methods.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requires: Option<Vec<Dependency>>,
    /// Ordered list of install strategies (first matching wins).
    pub install_methods: Vec<InstallMethod>,
    /// Optional uninstall steps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uninstall: Option<Uninstall>,
    /// Bookkeeping metadata.
    pub metadata: VersionMetadata,
}

/// One row of the support matrix — a `(distro, distro version, arch)` triple plus a status.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SupportEntry {
    /// Distro id (e.g., `debian`, `alpine`, `windows`).
    pub os: String,
    /// Distro version. When omitted, the row applies to all versions of `os`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    /// CPU architecture.
    pub arch: String,
    /// Status of this combination.
    pub status: SupportStatus,
    /// Free-form reviewer notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Structured explanation surfaced for `unsupported` rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Link to upstream issue/advisory documenting the unsupported state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracking_url: Option<String>,
    /// Calendar date after which the scanner should re-evaluate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recheck_at: Option<String>,
}

/// Status of a support-matrix row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SupportStatus {
    /// We will install and expect it to work.
    Supported,
    /// We refuse to install.
    Unsupported,
    /// We don't know.
    Untested,
}

/// One CI-run record for the `tested[]` evidence list.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestEntry {
    /// Distro id.
    pub os: String,
    /// Distro version under test.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    /// CPU architecture.
    pub arch: String,
    /// When the CI run completed.
    pub tested_at: String,
    /// CI run URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ci_run: Option<String>,
    /// Outcome of the run.
    pub result: TestResult,
    /// Free-form notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Outcome of a CI run row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TestResult {
    /// CI run succeeded.
    Pass,
    /// CI run failed.
    Fail,
    /// CI run was skipped.
    Skip,
}

/// Optional uninstall steps.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Uninstall {
    /// Shell command strings, executed in order.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commands: Option<Vec<String>>,
}

/// Version-file bookkeeping metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VersionMetadata {
    /// When this entry was first added to the catalog.
    pub added_at: String,
    /// When this entry was last modified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    /// Echo of `schemaVersion` so changelog tooling can detect schema drift.
    pub schema_version: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    const RUST_1_95_0: &str = include_str!("../../testdata/tooldb/rust_1_95_0.json");

    #[test]
    fn parses_rust_version_file() {
        let v: ToolVersion = serde_json::from_str(RUST_1_95_0).expect("parse version file");
        assert_eq!(v.tool, "rust");
        assert_eq!(v.version, "1.95.0");
        assert_eq!(v.channel.as_deref(), Some("stable"));
        assert_eq!(v.install_methods.len(), 2);
        assert_eq!(v.support_matrix.len(), 12);
        assert!(v.support_matrix.iter().all(|e| e.status == SupportStatus::Supported));
    }

    #[test]
    fn empty_tested_array_works() {
        let v: ToolVersion = serde_json::from_str(RUST_1_95_0).unwrap();
        assert!(v.tested.is_empty());
    }

    #[test]
    fn unsupported_status_with_reason() {
        let json = r#"{
            "os": "windows",
            "arch": "amd64",
            "status": "unsupported",
            "reason": "no upstream rustup target",
            "tracking_url": "https://github.com/rust-lang/rust/issues/12345"
        }"#;
        let entry: SupportEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.status, SupportStatus::Unsupported);
        assert_eq!(entry.reason.as_deref(), Some("no upstream rustup target"));
    }

    #[test]
    fn round_trips_version_file() {
        let v: ToolVersion = serde_json::from_str(RUST_1_95_0).unwrap();
        let serialized = serde_json::to_string(&v).unwrap();
        let reparsed: ToolVersion = serde_json::from_str(&serialized).unwrap();
        assert_eq!(v.tool, reparsed.tool);
        assert_eq!(v.version, reparsed.version);
        assert_eq!(v.install_methods.len(), reparsed.install_methods.len());
    }
}
