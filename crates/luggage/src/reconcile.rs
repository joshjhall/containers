//! Reconcile a version's `support_matrix` *claims* against its `tested[]`
//! *evidence*.
//!
//! A catalog version file carries two independent views of the same
//! `(os, os_version, arch)` cells:
//!
//! - [`support_matrix`](containers_common::tooldb::ToolVersion::support_matrix)
//!   — hand-authored intent. A row's [`SupportStatus`] says whether we
//!   *claim* the tool runs there.
//! - [`tested`](containers_common::tooldb::ToolVersion::tested) — machine
//!   recorded evidence. A [`TestEntry`] with [`TestResult::Pass`] *proves* an
//!   install happened on that cell.
//!
//! Nothing keeps the two in sync, so a `supported` claim can sit forever with
//! zero passing evidence. This module closes that loop: it classifies every
//! support cell against the evidence and lets a caller (the `luggage
//! reconcile` subcommand) either report coverage or gate CI on it.
//!
//! ## Policy
//!
//! For each `support_matrix` row, keyed on `(os, os_version, arch)` with the
//! same wildcard semantics [`crate::platform::matches_support`] uses:
//!
//! | Claimed status | Passing evidence row exists? | Classification |
//! |----------------|------------------------------|----------------|
//! | `supported`    | yes                          | [`CellStatus::Covered`] |
//! | `supported`    | no                           | [`CellStatus::Uncovered`] — **gate failure** |
//! | `unsupported`  | yes                          | [`CellStatus::Contradiction`] — **gate failure** |
//! | `unsupported`  | no                           | [`CellStatus::NoEvidenceNeeded`] |
//! | `untested`     | yes                          | [`CellStatus::Promotable`] — info only |
//! | `untested`     | no                           | [`CellStatus::NoEvidenceNeeded`] |
//!
//! Freshness (the newest matching row's `tested_at`) is *reported* but never
//! gated — keeping the contract tight. Only `Uncovered` and `Contradiction`
//! count as gate failures.

use containers_common::tooldb::{SupportEntry, SupportStatus, TestEntry, TestResult, ToolVersion};
use serde::Serialize;

use crate::platform::{Platform, matches_support};

/// Outcome of cross-checking a single `support_matrix` cell against the
/// `tested[]` evidence rows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CellStatus {
    /// A `supported` cell that has at least one matching passing row.
    Covered {
        /// `tested_at` of the newest matching passing row.
        tested_at: String,
        /// `ci_run` URL of that newest row, when present.
        #[serde(skip_serializing_if = "Option::is_none")]
        ci_run: Option<String>,
    },
    /// A `supported` cell with no matching passing row. **Gate failure.**
    Uncovered,
    /// An `unsupported` cell that nonetheless has a matching passing row:
    /// the claim says "won't run", the evidence says it did. **Gate failure.**
    Contradiction {
        /// `tested_at` of the newest matching passing row.
        tested_at: String,
    },
    /// An `untested` cell with a matching passing row — a candidate for
    /// promotion to `supported`. Informational; never a gate failure.
    Promotable {
        /// `tested_at` of the newest matching passing row.
        tested_at: String,
    },
    /// An `unsupported` or `untested` cell with no passing row — exactly what
    /// the claim expects, so nothing to do.
    NoEvidenceNeeded,
}

impl CellStatus {
    /// Whether this classification should fail a `--gate` run.
    #[must_use]
    pub const fn is_gate_failure(&self) -> bool {
        matches!(self, Self::Uncovered | Self::Contradiction { .. })
    }
}

/// One `support_matrix` cell paired with its reconciliation outcome.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CellReport {
    /// Distro id (e.g. `debian`).
    pub os: String,
    /// Distro version (e.g. `13`). `None` means the row applies to all
    /// versions of `os`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    /// CPU architecture (e.g. `amd64`).
    pub arch: String,
    /// The `support_matrix` status that was claimed for this cell.
    pub claimed: SupportStatus,
    /// What the evidence says about the claim.
    pub status: CellStatus,
}

/// Reconciliation result for a single tool version: every support cell with
/// its evidence classification.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VersionReconciliation {
    /// Tool id this version belongs to.
    pub tool: String,
    /// Version literal.
    pub version: String,
    /// One entry per `support_matrix` row, in declaration order.
    pub cells: Vec<CellReport>,
}

impl VersionReconciliation {
    /// Number of cells that would fail a `--gate` run (`Uncovered` +
    /// `Contradiction`).
    #[must_use]
    pub fn gate_failures(&self) -> usize {
        self.cells.iter().filter(|c| c.status.is_gate_failure()).count()
    }

    /// `true` when no cell is a gate failure.
    #[must_use]
    pub fn is_clean(&self) -> bool {
        self.gate_failures() == 0
    }

    /// Borrowing iterator over only the gate-failing cells.
    pub fn failures(&self) -> impl Iterator<Item = &CellReport> {
        self.cells.iter().filter(|c| c.status.is_gate_failure())
    }
}

/// Build a [`Platform`] from a [`TestEntry`] so it can be matched against a
/// [`SupportEntry`] with [`matches_support`].
fn platform_from_test(row: &TestEntry) -> Platform {
    Platform { os: row.os.clone(), os_version: row.os_version.clone(), arch: row.arch.clone() }
}

/// Find the newest passing `tested[]` row that matches `cell`, returning a
/// reference to it. "Newest" is the lexicographically greatest `tested_at`;
/// RFC 3339 UTC timestamps (what evidence runs record) sort chronologically
/// under string ordering, so no date parsing is needed.
fn newest_passing_match<'a>(cell: &SupportEntry, tested: &'a [TestEntry]) -> Option<&'a TestEntry> {
    tested
        .iter()
        .filter(|row| row.result == TestResult::Pass)
        .filter(|row| matches_support(&platform_from_test(row), cell))
        .max_by(|a, b| a.tested_at.cmp(&b.tested_at))
}

/// Classify a single support cell against the evidence rows.
fn classify(cell: &SupportEntry, tested: &[TestEntry]) -> CellStatus {
    let newest = newest_passing_match(cell, tested);
    match (cell.status, newest) {
        (SupportStatus::Supported, Some(row)) => {
            CellStatus::Covered { tested_at: row.tested_at.clone(), ci_run: row.ci_run.clone() }
        }
        (SupportStatus::Supported, None) => CellStatus::Uncovered,
        (SupportStatus::Unsupported, Some(row)) => {
            CellStatus::Contradiction { tested_at: row.tested_at.clone() }
        }
        (SupportStatus::Untested, Some(row)) => {
            CellStatus::Promotable { tested_at: row.tested_at.clone() }
        }
        (SupportStatus::Unsupported | SupportStatus::Untested, None) => {
            CellStatus::NoEvidenceNeeded
        }
    }
}

/// Reconcile one tool version's claims against its evidence.
///
/// Pure: reads only the in-memory [`ToolVersion`], performs no I/O.
#[must_use]
pub fn reconcile_version(doc: &ToolVersion) -> VersionReconciliation {
    let cells = doc
        .support_matrix
        .iter()
        .map(|cell| CellReport {
            os: cell.os.clone(),
            os_version: cell.os_version.clone(),
            arch: cell.arch.clone(),
            claimed: cell.status,
            status: classify(cell, &doc.tested),
        })
        .collect();

    VersionReconciliation { tool: doc.tool.clone(), version: doc.version.clone(), cells }
}

#[cfg(test)]
mod tests {
    use super::*;
    use containers_common::tooldb::{InstallMethod, VersionMetadata};

    /// Minimal `ToolVersion` carrying just the fields reconciliation reads.
    fn doc(support: Vec<SupportEntry>, tested: Vec<TestEntry>) -> ToolVersion {
        ToolVersion {
            schema_version: 1,
            tool: "rust".into(),
            version: "1.96.0".into(),
            released: None,
            channel: None,
            support_matrix: support,
            tested,
            requires: None,
            install_methods: Vec::<InstallMethod>::new(),
            uninstall: None,
            metadata: VersionMetadata {
                added_at: "2026-06-01T00:00:00Z".into(),
                updated_at: None,
                schema_version: 1,
            },
        }
    }

    fn support(
        os: &str,
        os_version: Option<&str>,
        arch: &str,
        status: SupportStatus,
    ) -> SupportEntry {
        SupportEntry {
            os: os.into(),
            os_version: os_version.map(Into::into),
            arch: arch.into(),
            status,
            notes: None,
            reason: None,
            tracking_url: None,
            recheck_at: None,
        }
    }

    fn evidence(
        os: &str,
        os_version: Option<&str>,
        arch: &str,
        result: TestResult,
        tested_at: &str,
    ) -> TestEntry {
        TestEntry {
            os: os.into(),
            os_version: os_version.map(Into::into),
            arch: arch.into(),
            tested_at: tested_at.into(),
            ci_run: None,
            result,
            image_ref: None,
            image_digest: None,
            duration_seconds: None,
            version_output: None,
            error_class: None,
            dependencies: None,
            notes: None,
        }
    }

    #[test]
    fn supported_with_passing_row_is_covered() {
        let d = doc(
            vec![support("debian", Some("13"), "amd64", SupportStatus::Supported)],
            vec![evidence("debian", Some("13"), "amd64", TestResult::Pass, "2026-06-01T00:00:00Z")],
        );
        let r = reconcile_version(&d);
        assert!(r.is_clean());
        assert_eq!(r.gate_failures(), 0);
        match &r.cells[0].status {
            CellStatus::Covered { tested_at, .. } => assert_eq!(tested_at, "2026-06-01T00:00:00Z"),
            other => panic!("expected Covered, got {other:?}"),
        }
    }

    #[test]
    fn supported_without_evidence_is_uncovered_and_gates() {
        let d =
            doc(vec![support("alpine", Some("3.21"), "arm64", SupportStatus::Supported)], vec![]);
        let r = reconcile_version(&d);
        assert_eq!(r.cells[0].status, CellStatus::Uncovered);
        assert_eq!(r.gate_failures(), 1);
        assert!(!r.is_clean());
    }

    #[test]
    fn unsupported_with_passing_row_is_contradiction_and_gates() {
        let d = doc(
            vec![support("windows", None, "amd64", SupportStatus::Unsupported)],
            vec![evidence("windows", None, "amd64", TestResult::Pass, "2026-06-02T00:00:00Z")],
        );
        let r = reconcile_version(&d);
        assert!(matches!(r.cells[0].status, CellStatus::Contradiction { .. }));
        assert_eq!(r.gate_failures(), 1);
    }

    #[test]
    fn unsupported_without_evidence_needs_nothing() {
        let d = doc(vec![support("windows", None, "amd64", SupportStatus::Unsupported)], vec![]);
        let r = reconcile_version(&d);
        assert_eq!(r.cells[0].status, CellStatus::NoEvidenceNeeded);
        assert!(r.is_clean());
    }

    #[test]
    fn untested_with_passing_row_is_promotable_not_a_gate_failure() {
        let d = doc(
            vec![support("ubuntu", Some("24.04"), "amd64", SupportStatus::Untested)],
            vec![evidence(
                "ubuntu",
                Some("24.04"),
                "amd64",
                TestResult::Pass,
                "2026-06-03T00:00:00Z",
            )],
        );
        let r = reconcile_version(&d);
        assert!(matches!(r.cells[0].status, CellStatus::Promotable { .. }));
        assert_eq!(r.gate_failures(), 0);
        assert!(r.is_clean());
    }

    #[test]
    fn fail_and_skip_rows_do_not_count_as_evidence() {
        let d = doc(
            vec![support("debian", Some("13"), "amd64", SupportStatus::Supported)],
            vec![
                evidence("debian", Some("13"), "amd64", TestResult::Fail, "2026-06-04T00:00:00Z"),
                evidence("debian", Some("13"), "amd64", TestResult::Skip, "2026-06-05T00:00:00Z"),
            ],
        );
        let r = reconcile_version(&d);
        assert_eq!(r.cells[0].status, CellStatus::Uncovered);
    }

    #[test]
    fn versionless_support_row_matches_any_version_evidence() {
        // A row with os_version=None should be satisfied by a passing row on
        // any version of that os (mirrors matches_support's wildcard rule).
        let d = doc(
            vec![support("alpine", None, "amd64", SupportStatus::Supported)],
            vec![evidence(
                "alpine",
                Some("3.21"),
                "amd64",
                TestResult::Pass,
                "2026-06-06T00:00:00Z",
            )],
        );
        let r = reconcile_version(&d);
        assert!(matches!(r.cells[0].status, CellStatus::Covered { .. }));
    }

    #[test]
    fn covered_reports_newest_passing_row() {
        let d = doc(
            vec![support("debian", Some("13"), "amd64", SupportStatus::Supported)],
            vec![
                evidence("debian", Some("13"), "amd64", TestResult::Pass, "2026-01-01T00:00:00Z"),
                evidence("debian", Some("13"), "amd64", TestResult::Pass, "2026-06-09T00:00:00Z"),
                evidence("debian", Some("13"), "amd64", TestResult::Pass, "2026-03-01T00:00:00Z"),
            ],
        );
        let r = reconcile_version(&d);
        match &r.cells[0].status {
            CellStatus::Covered { tested_at, .. } => assert_eq!(tested_at, "2026-06-09T00:00:00Z"),
            other => panic!("expected Covered, got {other:?}"),
        }
    }

    #[test]
    fn failures_iterator_yields_only_gate_failures() {
        let d = doc(
            vec![
                support("debian", Some("13"), "amd64", SupportStatus::Supported),
                support("alpine", Some("3.21"), "arm64", SupportStatus::Supported),
            ],
            vec![evidence("debian", Some("13"), "amd64", TestResult::Pass, "2026-06-01T00:00:00Z")],
        );
        let r = reconcile_version(&d);
        let failing: Vec<_> = r.failures().collect();
        assert_eq!(failing.len(), 1);
        assert_eq!(failing[0].os, "alpine");
    }
}
