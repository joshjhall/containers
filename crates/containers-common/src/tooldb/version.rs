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
    /// Human-readable image reference exercised by this run, e.g.
    /// `ghcr.io/joshjhall/containers/base-debian-12-amd64:v1.0.0`.
    /// Pair with [`Self::image_digest`] — the tag may move but the
    /// digest pins the artifact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_ref: Option<String>,
    /// Content-addressed digest of the image exercised, formatted
    /// `sha256:<64 hex chars>`. Required for a run to be reproducible
    /// after the tag has moved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_digest: Option<String>,
    /// Wallclock duration of the install step in seconds. Sourced from
    /// `luggage install --json-report`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    /// Captured stdout of the validate stage's `<tool> --version`
    /// invocation, trimmed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_output: Option<String>,
    /// Stage-aligned failure category, populated when [`Self::result`]
    /// is [`TestResult::Fail`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_class: Option<ErrorClass>,
    /// System dependencies resolved to the concrete versions present during
    /// the run (`gcc`, `libc6-dev`, `ca-certificates`, …). Best-effort and
    /// populated only on pass rows from `luggage --json-report`; lets a
    /// "passed last month, fails today" install be correlated with a
    /// base-image toolchain bump. Omitted when nothing was captured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dependencies: Option<Vec<InstalledDependency>>,
    /// Free-form notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// A system dependency resolved to a concrete installed version during an
/// evidence run.
///
/// Catalog `install_methods[].dependencies[]` entries are version-less
/// abstract ids (`{tool: gcc}`); this records what the host package manager
/// actually had installed once luggage translated and installed them, so an
/// evidence row can answer "did this pass because of, or despite, gcc 12.2 vs
/// 13.1?". `version` is best-effort: `None` when the host package-manager
/// query failed or returned nothing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstalledDependency {
    /// Abstract catalog `Dependency.tool` id (e.g. `gcc`, `libc_dev`).
    pub tool: String,
    /// Per-distro package name actually installed (e.g. `libc6-dev`).
    pub package: String,
    /// Resolved version string from the host package manager.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
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

/// Structured failure category for [`TestEntry::error_class`].
///
/// Mirrors the enum in containers-db's
/// `schema/version.schema.json`. Values map to luggage installer stages
/// so categorization is mechanical rather than editorial.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorClass {
    /// Artifact fetch failed.
    Download,
    /// Checksum or signature mismatch.
    Verify,
    /// Install-method dispatch failed.
    InstallMethod,
    /// A `post_install[]` step failed.
    PostInstall,
    /// The `<tool> --version` validation did not match the requested version.
    Validate,
    /// CI runner / network / registry failure unrelated to the tool.
    Infra,
    /// Older runs predating this enum or truly unclassifiable.
    Unknown,
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

    #[test]
    fn test_entry_round_trips_evidence_fields() {
        let json = r#"{
            "os": "debian",
            "os_version": "12",
            "arch": "amd64",
            "tested_at": "2026-05-16T12:00:00Z",
            "ci_run": "https://github.com/joshjhall/containers/actions/runs/1",
            "result": "pass",
            "image_ref": "ghcr.io/joshjhall/containers/base-debian-12-amd64:v1.0.0",
            "image_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            "duration_seconds": 42.5,
            "version_output": "rustc 1.95.0 (abcdef0 2026-05-01)"
        }"#;
        let entry: TestEntry = serde_json::from_str(json).expect("parse evidence row");
        assert_eq!(
            entry.image_digest.as_deref(),
            Some("sha256:0000000000000000000000000000000000000000000000000000000000000000",)
        );
        assert_eq!(entry.duration_seconds, Some(42.5));
        assert_eq!(entry.version_output.as_deref(), Some("rustc 1.95.0 (abcdef0 2026-05-01)"));
        assert!(entry.error_class.is_none(), "pass row has no error_class");

        let serialized = serde_json::to_string(&entry).unwrap();
        let reparsed: TestEntry = serde_json::from_str(&serialized).unwrap();
        assert_eq!(reparsed.image_ref, entry.image_ref);
        assert_eq!(reparsed.duration_seconds, entry.duration_seconds);
    }

    #[test]
    fn test_entry_round_trips_failure_row_with_error_class() {
        let json = r#"{
            "os": "alpine",
            "os_version": "3.21",
            "arch": "arm64",
            "tested_at": "2026-05-16T12:30:00Z",
            "result": "fail",
            "image_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            "duration_seconds": 7.25,
            "error_class": "verify",
            "notes": "tier-3 checksum mismatch"
        }"#;
        let entry: TestEntry = serde_json::from_str(json).expect("parse failure row");
        assert_eq!(entry.result, TestResult::Fail);
        assert_eq!(entry.error_class, Some(ErrorClass::Verify));
        assert_eq!(entry.notes.as_deref(), Some("tier-3 checksum mismatch"));
    }

    #[test]
    fn test_entry_legacy_row_without_evidence_fields_still_parses() {
        // Belt-and-braces: rows written by the old (pre-2026-05-14) shape
        // must continue to deserialize so we don't break catalog reads.
        let json = r#"{
            "os": "debian",
            "arch": "amd64",
            "tested_at": "2026-04-01T00:00:00Z",
            "result": "pass"
        }"#;
        let entry: TestEntry = serde_json::from_str(json).unwrap();
        assert!(entry.image_digest.is_none());
        assert!(entry.duration_seconds.is_none());
        assert!(entry.error_class.is_none());
        assert!(entry.dependencies.is_none());
    }

    #[test]
    fn test_entry_round_trips_installed_dependencies() {
        let json = r#"{
            "os": "debian",
            "os_version": "12",
            "arch": "amd64",
            "tested_at": "2026-05-16T12:00:00Z",
            "result": "pass",
            "dependencies": [
                {"tool": "gcc", "package": "gcc", "version": "4:12.2.0-3"},
                {"tool": "libc_dev", "package": "libc6-dev", "version": "2.36-9+deb12u7"},
                {"tool": "ca_certificates", "package": "ca-certificates"}
            ]
        }"#;
        let entry: TestEntry = serde_json::from_str(json).expect("parse row with dependencies");
        let deps = entry.dependencies.as_deref().expect("dependencies present");
        assert_eq!(deps.len(), 3);
        assert_eq!(deps[0].tool, "gcc");
        assert_eq!(deps[0].package, "gcc");
        assert_eq!(deps[0].version.as_deref(), Some("4:12.2.0-3"));
        // Best-effort: a dep whose version could not be resolved omits it.
        assert_eq!(deps[2].tool, "ca_certificates");
        assert!(deps[2].version.is_none());

        let serialized = serde_json::to_string(&entry).unwrap();
        let reparsed: TestEntry = serde_json::from_str(&serialized).unwrap();
        assert_eq!(reparsed.dependencies, entry.dependencies);
    }

    #[test]
    fn installed_dependency_rejects_unknown_fields() {
        // deny_unknown_fields is the strictness guard against silent schema
        // drift — an extra key must error, not be dropped.
        let json = r#"{"tool": "gcc", "package": "gcc", "version": "12.2", "surprise": true}"#;
        assert!(
            serde_json::from_str::<InstalledDependency>(json).is_err(),
            "unknown field should be rejected",
        );
    }

    #[test]
    fn test_entry_omits_dependencies_when_absent() {
        // skip_serializing_if keeps the field out of rows that captured
        // nothing, so existing schema validation stays green until the
        // sibling containers-db schema lands.
        let entry: TestEntry = serde_json::from_str(
            r#"{"os":"debian","arch":"amd64","tested_at":"2026-04-01T00:00:00Z","result":"pass"}"#,
        )
        .unwrap();
        let serialized = serde_json::to_string(&entry).unwrap();
        assert!(!serialized.contains("dependencies"), "absent field must not serialize");
    }

    #[test]
    fn error_class_wire_format_matches_schema_enum() {
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
            assert_eq!(serde_json::to_string(&c).unwrap(), expected);
            let back: ErrorClass = serde_json::from_str(expected).unwrap();
            assert_eq!(back, c);
        }
    }
}
