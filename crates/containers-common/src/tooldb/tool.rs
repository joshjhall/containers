//! `Tool` — top-level metadata for a tool in the containers-db catalog.
//!
//! Mirrors `tools/<id>/index.json` validated by `schema/tool.schema.json`.

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

use crate::version::VersionStyle;

/// Top-level catalog entry for a tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tool {
    /// Schema version. Currently always `1`.
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// Stable lowercase `snake_case` slug.
    pub id: String,
    /// Human-readable name.
    pub display_name: String,
    /// Coarse category.
    pub kind: Kind,
    /// Project homepage URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    /// Source repository URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_repo: Option<String>,
    /// SPDX license identifier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    /// Activity scoring snapshot.
    pub activity: Activity,
    /// Catalog-level summary of available verification tiers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub validation_tiers: Option<ValidationTiers>,
    /// How version strings on this tool should be parsed. Defaults to semver.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_style: Option<VersionStyle>,
    /// Default version selected when no version is requested.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_version: Option<String>,
    /// Lowest version stibbons recommends.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_recommended: Option<String>,
    /// Named release channels (e.g., `stable`, `nightly`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<IndexMap<String, Channel>>,
    /// Install-order constraints relative to other tools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ordering: Option<Ordering>,
    /// Advisory pointers to related/successor tools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alternatives: Option<Vec<Alternative>>,
    /// `system_package` tracking record (only when `kind == SystemPackage`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_package: Option<SystemPackage>,
    /// Catalog of versions known to this tool entry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available: Option<Vec<AvailableEntry>>,
}

/// Coarse category of a catalog tool.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Programming-language toolchain (Rust, Python, Node).
    Language,
    /// End-user binary (`gh`, `just`).
    Cli,
    /// Build-time/runtime library without an entry-point binary.
    Library,
    /// Hosting runtime (JVM, V8) for other code.
    Runtime,
    /// Long-running daemon (Postgres, Redis).
    Service,
    /// OS package the host package manager owns.
    SystemPackage,
    /// Forward-compatibility fallback for kinds added upstream.
    #[serde(other)]
    Unknown,
}

/// Activity scoring snapshot from the most recent scan.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Activity {
    /// Coarse 7-tier bucket driving stibbons recommendation gating.
    pub score: ActivityScore,
    /// Raw scanner observations behind the score.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signals: Option<ActivitySignals>,
    /// Days between scans.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scan_cadence_days: Option<u32>,
    /// When this snapshot was produced.
    pub scanned_at: String,
}

/// Coarse 7-tier activity bucket. Most active first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ActivityScore {
    /// New release in the last week.
    VeryActive,
    /// Active development.
    Active,
    /// Maintained: predictable releases.
    Maintained,
    /// Slow but not stalled.
    Slow,
    /// Stale: no recent activity.
    Stale,
    /// Dormant: months of silence.
    Dormant,
    /// Abandoned: explicitly retired or long-dead.
    Abandoned,
    /// Forward-compatibility fallback.
    #[serde(other)]
    Unknown,
}

/// Raw scanner signals behind an [`ActivityScore`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivitySignals {
    /// Tagged/published releases in the trailing 90 days.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub releases_last_90d: Option<u64>,
    /// Commits to the default branch in the trailing 90 days.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commits_last_90d: Option<u64>,
    /// Distinct authors in the trailing 90 days.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_maintainers: Option<u64>,
    /// Open security advisories at scan time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_advisories: Option<u64>,
    /// Most recent release timestamp.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_release_at: Option<String>,
    /// Most recent commit timestamp.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_commit_at: Option<String>,
}

/// Catalog-level documentation of which verification tiers this tool supports.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ValidationTiers {
    /// Tier 1 — cryptographic signatures (GPG/sigstore).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier1: Option<TierSummary>,
    /// Tier 2 — pinned checksums baked into version files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier2: Option<TierSummary>,
    /// Tier 3 — publisher-served checksums.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier3: Option<TierSummary>,
    /// Tier 4 — TOFU.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier4: Option<TierSummary>,
}

/// Catalog-level note about whether a verification tier is available.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TierSummary {
    /// True when at least one install method on at least one supported version uses this tier.
    pub available: bool,
    /// Free-form reviewer notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Named release channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Channel {
    /// Human-readable channel summary.
    pub description: String,
    /// True when this is the channel `default_version` resolves against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<bool>,
}

/// Install-order constraints relative to other catalog tools.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ordering {
    /// Hard constraint: every listed tool id must install before this one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub must_install_before: Option<Vec<String>>,
    /// Soft constraint: prefer to install the listed tool ids first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub should_install_before: Option<Vec<String>>,
}

/// Advisory pointer to a related tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Alternative {
    /// Target tool id.
    pub tool: String,
    /// Nature of the relationship.
    pub relationship: AlternativeRelationship,
    /// Optional narrowing of where the relationship applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// Free-form reviewer notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Direction and nature of a tool-to-tool relationship.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AlternativeRelationship {
    /// Same problem, comparable tradeoffs.
    Similar,
    /// Partial functional overlap.
    Overlaps,
    /// Listed tool came after this one.
    Successor,
    /// This tool came after the listed one.
    Predecessor,
}

/// Cross-distro identification for a `kind: system_package` tracking record.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SystemPackage {
    /// Map of distro id → per-distro package name.
    pub platforms: IndexMap<String, SystemPackagePlatform>,
}

/// Per-distro package-manager name for a `system_package` tracking record.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SystemPackagePlatform {
    /// Package name as the distro's package manager sees it.
    pub name: String,
}

/// One entry in a tool's `available[]` list.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AvailableEntry {
    /// Version string. Matches the basename of the sibling `versions/<v>.json` file.
    pub version: String,
    /// Fossil map: distro id → highest distro version this tool version was last tested on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_known_good_for: Option<IndexMap<String, String>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    const RUST_INDEX: &str = include_str!("../../testdata/tooldb/rust_index.json");

    #[test]
    fn parses_rust_index() {
        let tool: Tool = serde_json::from_str(RUST_INDEX).expect("parse rust index");
        assert_eq!(tool.id, "rust");
        assert_eq!(tool.kind, Kind::Language);
        assert_eq!(tool.activity.score, ActivityScore::VeryActive);
        assert_eq!(tool.default_version.as_deref(), Some("1.95.0"));
        let avail = tool.available.as_ref().expect("available[]");
        assert_eq!(avail.len(), 5);
        let channels = tool.channels.as_ref().expect("channels");
        assert_eq!(channels.get("stable").unwrap().default, Some(true));
    }

    #[test]
    fn unknown_kind_falls_back() {
        let json = r#"{
            "schemaVersion": 1,
            "id": "future_tool",
            "display_name": "Future",
            "kind": "frobnicator",
            "activity": { "score": "active", "scanned_at": "2026-01-01T00:00:00Z" }
        }"#;
        let tool: Tool = serde_json::from_str(json).unwrap();
        assert_eq!(tool.kind, Kind::Unknown);
    }

    #[test]
    fn unknown_activity_score_falls_back() {
        let json = r#"{ "score": "vibing", "scanned_at": "2026-01-01T00:00:00Z" }"#;
        let activity: Activity = serde_json::from_str(json).unwrap();
        assert_eq!(activity.score, ActivityScore::Unknown);
    }

    #[test]
    fn round_trips_full_tool() {
        let tool: Tool = serde_json::from_str(RUST_INDEX).unwrap();
        let serialized = serde_json::to_string(&tool).unwrap();
        let reparsed: Tool = serde_json::from_str(&serialized).unwrap();
        assert_eq!(tool.id, reparsed.id);
        assert_eq!(tool.kind, reparsed.kind);
        assert_eq!(tool.default_version, reparsed.default_version);
    }

    #[test]
    fn deny_unknown_fields_rejects_extras() {
        let json = r#"{
            "schemaVersion": 1,
            "id": "rust",
            "display_name": "Rust",
            "kind": "language",
            "activity": { "score": "active", "scanned_at": "2026-01-01T00:00:00Z" },
            "default_version": "1.0.0",
            "available": [{"version": "1.0.0"}],
            "made_up_field": true
        }"#;
        let res: Result<Tool, _> = serde_json::from_str(json);
        assert!(res.is_err(), "extra fields should be rejected");
    }
}
