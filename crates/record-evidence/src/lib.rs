//! Evidence-row builder: combines a [`luggage::InstallReport`] with
//! CI-runner-supplied metadata (image digest, image ref, `ci_run`, tuple
//! coords) into a [`containers_common::tooldb::TestEntry`] matching
//! containers-db's `tested[]` schema.
//!
//! See containers#473 (evidence-runs design tracker) and containers-db#14
//! (schema extension that added `image_digest`, `duration_seconds`, and
//! `error_class`).

use containers_common::tooldb::{ErrorClass as DbErrorClass, TestEntry, TestResult};
use luggage::{ErrorClass as LuggageErrorClass, InstallReport};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

/// Inputs to [`build_test_entry`].
///
/// `luggage_report` is the [`InstallReport`] luggage wrote via
/// `--json-report`. Everything else is metadata only the surrounding CI
/// runner knows.
#[derive(Debug, Clone)]
pub struct RecorderInputs {
    /// The parsed `--json-report` file luggage produced.
    pub luggage_report: InstallReport,
    /// Pull-spec for the base image exercised
    /// (`ghcr.io/.../base-debian-12-amd64:v1.0.0`).
    pub image_ref: String,
    /// Content-addressed digest of `image_ref`.
    pub image_digest: String,
    /// CI run URL.
    pub ci_run: Option<String>,
    /// Distro id.
    pub os: String,
    /// Distro version.
    pub os_version: Option<String>,
    /// CPU architecture.
    pub arch: String,
}

/// Errors raised by [`build_test_entry`] and the binary entry point.
#[derive(Debug, Error)]
pub enum RecorderError {
    /// `image_digest` does not match the schema's
    /// `^sha256:[0-9a-f]{64}$` pattern.
    #[error(
        "invalid image_digest `{0}`: expected `sha256:<64 hex chars>` per containers-db schema"
    )]
    InvalidImageDigest(String),

    /// `image_ref` was empty or whitespace-only.
    #[error("empty image_ref")]
    EmptyImageRef,

    /// Wallclock retrieval failed. Practically unreachable on a sane
    /// system, but we surface it rather than panic so CI gets a clean
    /// error.
    #[error("could not format current time as RFC3339: {0}")]
    Time(#[from] time::error::Format),

    /// JSON serialization failed.
    #[error("could not serialize TestEntry as JSON: {0}")]
    Json(#[from] serde_json::Error),

    /// Failed to read or parse the luggage `--json-report` file.
    #[error("could not read luggage report at {path}: {message}")]
    LuggageReport {
        /// Path that was being read.
        path: String,
        /// Underlying message.
        message: String,
    },
}

/// Build a [`TestEntry`] from runner inputs and a luggage install report.
///
/// `tested_at` is the current UTC time at call time (RFC3339).
/// `result` is derived from the report: `error_class == None` and
/// `already_installed == true` → [`TestResult::Skip`]; `error_class ==
/// None` and ran → [`TestResult::Pass`]; otherwise [`TestResult::Fail`].
///
/// # Errors
///
/// - [`RecorderError::InvalidImageDigest`] if the digest fails the
///   `sha256:<64 hex>` shape check.
/// - [`RecorderError::EmptyImageRef`] if `image_ref` is empty.
/// - [`RecorderError::Time`] if the system clock cannot be formatted.
pub fn build_test_entry(inputs: RecorderInputs) -> Result<TestEntry, RecorderError> {
    validate_image_digest(&inputs.image_digest)?;
    if inputs.image_ref.trim().is_empty() {
        return Err(RecorderError::EmptyImageRef);
    }

    let report = &inputs.luggage_report;
    let result = derive_result(report);
    let error_class = report.error_class.map(translate_error_class);
    let tested_at = OffsetDateTime::now_utc().format(&Rfc3339)?;

    Ok(TestEntry {
        os: inputs.os,
        os_version: inputs.os_version,
        arch: inputs.arch,
        tested_at,
        ci_run: inputs.ci_run,
        result,
        image_ref: Some(inputs.image_ref),
        image_digest: Some(inputs.image_digest),
        duration_seconds: Some(report.duration_seconds),
        version_output: report.version_output.clone(),
        error_class,
        // Dependency versions are evidence for a successful install only;
        // enforce the "pass rows only" invariant here rather than relying on
        // the producer always leaving them `None` on skip/fail paths.
        dependencies: if result == TestResult::Pass { report.dependencies.clone() } else { None },
        notes: verification_notes(report),
    })
}

/// Carry any [`InstallReport::warnings`] into the evidence row's `notes`.
///
/// A tier-4 TOFU acceptance means the artifact was installed with nothing
/// establishing its authenticity. That fact reaches the JSON report, and this
/// is what stops it dying there: without it, an evidence row for a TOFU
/// install is indistinguishable from one for a properly verified install, and
/// a later audit of the evidence database could not tell them apart.
///
/// `notes` is the right carrier because `TestEntry` has no warning-shaped
/// field and this needs no schema change to containers-db — the tradeoff being
/// that it is prose, so an audit greps it rather than querying it. If TOFU
/// tracking ever needs to be queryable, that is a `TestEntry` schema change
/// and a follow-up.
fn verification_notes(report: &InstallReport) -> Option<String> {
    if report.warnings.is_empty() {
        return None;
    }
    Some(report.warnings.iter().map(|w| w.message.as_str()).collect::<Vec<_>>().join(" | "))
}

const fn derive_result(report: &InstallReport) -> TestResult {
    match (report.error_class, report.already_installed) {
        (Some(_), _) => TestResult::Fail,
        (None, true) => TestResult::Skip,
        (None, false) => TestResult::Pass,
    }
}

const fn translate_error_class(c: LuggageErrorClass) -> DbErrorClass {
    match c {
        LuggageErrorClass::Download => DbErrorClass::Download,
        LuggageErrorClass::Verify => DbErrorClass::Verify,
        LuggageErrorClass::InstallMethod => DbErrorClass::InstallMethod,
        LuggageErrorClass::PostInstall => DbErrorClass::PostInstall,
        LuggageErrorClass::Validate => DbErrorClass::Validate,
        LuggageErrorClass::Infra => DbErrorClass::Infra,
        LuggageErrorClass::Unknown => DbErrorClass::Unknown,
    }
}

fn validate_image_digest(digest: &str) -> Result<(), RecorderError> {
    let Some(hex) = digest.strip_prefix("sha256:") else {
        return Err(RecorderError::InvalidImageDigest(digest.to_owned()));
    };
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) {
        return Err(RecorderError::InvalidImageDigest(digest.to_owned()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_report() -> InstallReport {
        InstallReport {
            tool: "rust".into(),
            version: "1.95.0".into(),
            already_installed: false,
            log_path: None,
            duration_seconds: 12.5,
            version_output: Some("rustc 1.95.0 (abcdef0)".into()),
            error_class: None,
            dependencies: None,
            skipped_dependencies: Vec::new(),
            warnings: Vec::new(),
        }
    }

    fn base_inputs() -> RecorderInputs {
        RecorderInputs {
            luggage_report: base_report(),
            image_ref: "ghcr.io/x/base-debian-12-amd64:v1.0.0".into(),
            image_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
                .into(),
            ci_run: Some("https://github.com/x/runs/1".into()),
            os: "debian".into(),
            os_version: Some("12".into()),
            arch: "amd64".into(),
        }
    }

    /// A TOFU acceptance has to survive the hop from install report to
    /// evidence row. If it stops at the JSON file, an audit of the evidence
    /// database cannot tell a TOFU install from a verified one — which is the
    /// blind spot the warning exists to close.
    #[test]
    fn a_tofu_warning_reaches_the_evidence_row() {
        let mut inputs = base_inputs();
        inputs.luggage_report.warnings = vec![luggage::VerificationWarning {
            tier: 4,
            tool: "python".into(),
            version: "3.13.0".into(),
            algorithm: Some("sha256".into()),
            digest: "deadbeef".into(),
            message: "TIER 4 TOFU: accepted python@3.13.0 on trust-on-first-use".into(),
        }];
        let entry = build_test_entry(inputs).unwrap();
        let notes = entry.notes.expect("a TOFU acceptance must be recorded in the row");
        assert!(notes.contains("TIER 4 TOFU"), "{notes}");
        assert!(notes.contains("python@3.13.0"), "{notes}");
    }

    #[test]
    fn multiple_warnings_are_all_recorded() {
        let warning = |tool: &str| luggage::VerificationWarning {
            tier: 4,
            tool: tool.into(),
            version: "1.0".into(),
            algorithm: None,
            digest: "abc".into(),
            message: format!("TOFU: {tool}"),
        };
        let mut inputs = base_inputs();
        inputs.luggage_report.warnings = vec![warning("python"), warning("pip")];
        let notes = build_test_entry(inputs).unwrap().notes.unwrap();
        assert!(notes.contains("TOFU: python"), "{notes}");
        assert!(notes.contains("TOFU: pip"), "{notes}");
    }

    /// The ordinary verified install must not start carrying a notes string —
    /// that would be noise in every row and would blunt the signal the TOFU
    /// note is meant to be.
    #[test]
    fn a_row_with_no_warnings_has_no_notes() {
        let entry = build_test_entry(base_inputs()).unwrap();
        assert!(entry.notes.is_none());
    }

    #[test]
    fn success_row_maps_to_pass() {
        let entry = build_test_entry(base_inputs()).unwrap();
        assert_eq!(entry.result, TestResult::Pass);
        assert_eq!(entry.duration_seconds, Some(12.5));
        assert_eq!(entry.version_output.as_deref(), Some("rustc 1.95.0 (abcdef0)"));
        assert!(entry.error_class.is_none());
        assert!(entry.tested_at.contains('T'), "RFC3339 has a `T` separator");
    }

    #[test]
    fn dependencies_pass_through_from_report() {
        use containers_common::tooldb::InstalledDependency;
        let mut inputs = base_inputs();
        inputs.luggage_report.dependencies = Some(vec![
            InstalledDependency {
                tool: "gcc".into(),
                package: "gcc".into(),
                version: Some("4:12.2.0-3".into()),
            },
            InstalledDependency {
                tool: "ca_certificates".into(),
                package: "ca-certificates".into(),
                version: None,
            },
        ]);
        let entry = build_test_entry(inputs).unwrap();
        let deps = entry.dependencies.expect("dependencies threaded into row");
        assert_eq!(deps.len(), 2);
        assert_eq!(deps[0].package, "gcc");
        assert_eq!(deps[0].version.as_deref(), Some("4:12.2.0-3"));
        assert!(deps[1].version.is_none());
    }

    #[test]
    fn dependencies_absent_when_report_has_none() {
        // A report without captured versions (skip/dry-run/failure, or
        // recording disabled) yields a row with no `dependencies` field.
        let entry = build_test_entry(base_inputs()).unwrap();
        assert!(entry.dependencies.is_none());
    }

    #[test]
    fn skip_row_emitted_when_already_installed() {
        let mut inputs = base_inputs();
        inputs.luggage_report.already_installed = true;
        let entry = build_test_entry(inputs).unwrap();
        assert_eq!(entry.result, TestResult::Skip);
    }

    #[test]
    fn failure_row_maps_error_class() {
        let mut inputs = base_inputs();
        inputs.luggage_report.error_class = Some(LuggageErrorClass::Verify);
        inputs.luggage_report.version_output = None;
        let entry = build_test_entry(inputs).unwrap();
        assert_eq!(entry.result, TestResult::Fail);
        assert_eq!(entry.error_class, Some(DbErrorClass::Verify));
    }

    #[test]
    fn dependencies_dropped_on_non_pass_row() {
        use containers_common::tooldb::InstalledDependency;
        // Even if a report somehow carries dependencies on a failure, the row
        // must not — dependency evidence is for pass rows only.
        let mut inputs = base_inputs();
        inputs.luggage_report.error_class = Some(LuggageErrorClass::Validate);
        inputs.luggage_report.dependencies = Some(vec![InstalledDependency {
            tool: "gcc".into(),
            package: "gcc".into(),
            version: Some("4:12.2.0-3".into()),
        }]);
        let entry = build_test_entry(inputs).unwrap();
        assert_eq!(entry.result, TestResult::Fail);
        assert!(entry.dependencies.is_none(), "non-pass row must drop dependencies");
    }

    #[test]
    fn rejects_bad_digest_shape() {
        let mut inputs = base_inputs();
        inputs.image_digest = "sha256:not-hex".into();
        assert!(matches!(
            build_test_entry(inputs).unwrap_err(),
            RecorderError::InvalidImageDigest(_),
        ));
    }

    #[test]
    fn rejects_missing_sha_prefix() {
        let mut inputs = base_inputs();
        inputs.image_digest =
            "0000000000000000000000000000000000000000000000000000000000000000".into();
        assert!(matches!(
            build_test_entry(inputs).unwrap_err(),
            RecorderError::InvalidImageDigest(_),
        ));
    }

    #[test]
    fn rejects_empty_image_ref() {
        let mut inputs = base_inputs();
        inputs.image_ref = "  ".into();
        assert!(matches!(build_test_entry(inputs).unwrap_err(), RecorderError::EmptyImageRef));
    }

    #[test]
    fn validate_image_digest_accepts_lowercase_64_hex() {
        validate_image_digest(
            "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        )
        .unwrap();
    }

    #[test]
    fn validate_image_digest_rejects_uppercase() {
        // Schema requires lowercase hex.
        let err = validate_image_digest(
            "sha256:ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
        )
        .unwrap_err();
        assert!(matches!(err, RecorderError::InvalidImageDigest(_)));
    }

    #[test]
    fn every_luggage_error_class_has_db_mapping() {
        // Exhaustiveness check: forces the translator to update when a
        // new variant lands on either side.
        for c in [
            LuggageErrorClass::Download,
            LuggageErrorClass::Verify,
            LuggageErrorClass::InstallMethod,
            LuggageErrorClass::PostInstall,
            LuggageErrorClass::Validate,
            LuggageErrorClass::Infra,
            LuggageErrorClass::Unknown,
        ] {
            let translated = translate_error_class(c);
            // Round-trip through JSON to make sure both enums share the
            // same wire format on each variant.
            let s_luggage = serde_json::to_string(&c).unwrap();
            let s_db = serde_json::to_string(&translated).unwrap();
            assert_eq!(
                s_luggage, s_db,
                "wire-format drift between luggage and containers-common for {c:?}"
            );
        }
    }
}
