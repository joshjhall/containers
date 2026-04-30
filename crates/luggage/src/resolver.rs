//! Version selection and platform resolution.
//!
//! This module implements the core algorithm: given a [`crate::ToolEntry`],
//! a [`VersionSpec`], and a [`Platform`], produce a [`ResolvedInstall`].
//!
//! The algorithm is:
//! 1. Pick a candidate `(Version, &ToolVersion)` from the entry's parsed
//!    `versions` map per the spec rules below.
//! 2. Walk the version's `support_matrix`. If a row matches the platform
//!    with status `unsupported`, return [`LuggageError::UnsupportedPlatform`].
//!    `supported` rows pass; missing rows are non-blocking.
//! 3. Walk `install_methods[]` in array order; the first whose
//!    [`PlatformPredicate`] matches wins. None matching →
//!    [`LuggageError::NoMatchingInstallMethod`].
//!
//! Spec selection:
//! - [`VersionSpec::Latest`] → the tool's `default_version` if set; else the
//!   highest parsed key.
//! - [`VersionSpec::Channel`] → the highest version whose `channel` matches.
//! - [`VersionSpec::Exact`] → the version literal must be a key.
//! - [`VersionSpec::Partial`] → synthesizes a constraint (`>=X, <X+1` for
//!   major-only, `>=X.Y, <X.Y+1` for major.minor) and picks the highest
//!   matching key. Anything with two or more dots is treated as `Exact`.

use std::fmt;

use containers_common::tooldb::{
    ActivityScore, Dependency, InstallMethod, Invoke, PostInstall, SupportStatus, Verification,
};
use containers_common::version::{Constraint, Version, VersionStyle};
use serde::Serialize;

use crate::catalog::ToolEntry;
use crate::error::{LuggageError, Result};
use crate::platform::{self, Platform};
use crate::policy::ResolutionPolicy;

/// What version of a tool to resolve.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VersionSpec {
    /// Pick the tool's default; fall back to highest parsed version.
    Latest,
    /// Pick the highest version belonging to this named channel.
    Channel(String),
    /// Pick this exact version literal (must already be in the catalog).
    Exact(String),
    /// Pick the highest version whose major (or major.minor) prefix matches.
    Partial(String),
}

impl fmt::Display for VersionSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Latest => f.write_str("latest"),
            Self::Channel(c) => write!(f, "channel:{c}"),
            Self::Exact(v) => write!(f, "exact:{v}"),
            Self::Partial(v) => write!(f, "partial:{v}"),
        }
    }
}

/// The output of [`crate::Catalog::resolve`] — a concrete install plan.
///
/// `verification_tier` is flattened to a top-level `u8` so JSON consumers
/// can branch on it without descending into the `verification` object.
#[derive(Debug, Clone, Serialize)]
pub struct ResolvedInstall {
    /// Tool id.
    pub tool: String,
    /// Concrete version chosen.
    pub version: String,
    /// `install_methods[].name` of the chosen method.
    pub method_name: String,
    /// Convenience copy of `verification.tier`.
    pub verification_tier: u8,
    /// Full verification block as it appeared in the catalog.
    pub verification: Verification,
    /// `source_url_template` for the chosen method, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_url_template: Option<String>,
    /// Installer invocation arguments, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invoke: Option<Invoke>,
    /// Post-install steps, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub post_install: Option<Vec<PostInstall>>,
    /// Method-level dependencies, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dependencies: Option<Vec<Dependency>>,
    /// The platform that produced this resolution.
    pub platform: Platform,
    /// Non-fatal warnings raised by the policy gate.
    ///
    /// Empty by default. JSON consumers can branch on the `kind` discriminant.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<ResolutionWarning>,
}

/// A non-fatal observation from the policy gate.
///
/// Tagged with `kind` so JSON consumers can match on a stable string and
/// pull the variant-specific fields off the same object.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResolutionWarning {
    /// The tool's activity tier is `Slow` or `Stale`.
    SlowOrStaleActivity {
        /// The actual activity score (always `Slow` or `Stale` here).
        score: ActivityScore,
    },
    /// The chosen version is below the tool's `minimum_recommended` and
    /// the policy chose to allow it rather than refuse outright.
    BelowMinimumRecommended {
        /// Resolved version literal.
        version: String,
        /// The tool's `minimum_recommended` value.
        minimum: String,
    },
}

/// Resolve `(entry, spec, platform)` into an install plan using the
/// [`ResolutionPolicy::default()`] (stibbons-strict) policy.
///
/// # Errors
///
/// See [`resolve_with_policy`] for the full set of possible errors.
pub fn resolve(
    entry: &ToolEntry,
    spec: &VersionSpec,
    platform: &Platform,
) -> Result<ResolvedInstall> {
    resolve_with_policy(entry, spec, platform, &ResolutionPolicy::default())
}

/// Resolve `(entry, spec, platform)` into an install plan, gated by a
/// caller-supplied [`ResolutionPolicy`].
///
/// Order of operations:
///
/// 1. **Activity gate** — refuse outright when the tool's activity score
///    is below `policy.min_activity`.
/// 2. **Version pick** — same logic as the unpoliced path.
/// 3. **`minimum_recommended` gate** — when the chosen version is below
///    the tool's `minimum_recommended`, either refuse (default) or attach
///    a warning (when `policy.allow_below_min_recommended`).
/// 4. **Support matrix gate** — refuse when the platform appears with
///    `unsupported` status.
/// 5. **Install method walk** — first matching predicate wins; refuse
///    when none match.
/// 6. **Slow/stale warning** — when `policy.warn_on_slow_or_stale` and the
///    activity tier is `Slow` or `Stale`, attach a warning.
///
/// # Errors
///
/// - [`LuggageError::ActivityBelowThreshold`] if step 1 fails.
/// - [`LuggageError::VersionNotFound`] if no version satisfied `spec`.
/// - [`LuggageError::BelowMinimumRecommended`] if step 3 refuses.
/// - [`LuggageError::UnsupportedPlatform`] if step 4 refuses.
/// - [`LuggageError::NoMatchingInstallMethod`] if step 5 finds no match.
/// - [`LuggageError::VersionParse`] if a version literal is malformed.
pub fn resolve_with_policy(
    entry: &ToolEntry,
    spec: &VersionSpec,
    platform: &Platform,
    policy: &ResolutionPolicy,
) -> Result<ResolvedInstall> {
    let mut warnings = Vec::new();

    // Step 1 — activity gate.
    let score = entry.index.activity.score;
    if !score.is_at_least(policy.min_activity) {
        return Err(LuggageError::ActivityBelowThreshold {
            tool: entry.index.id.clone(),
            score,
            threshold: policy.min_activity,
        });
    }

    let style = entry.index.version_style.unwrap_or(VersionStyle::Semver);
    let (chosen_version, chosen_doc) = pick_version(entry, spec, style)?;

    // Step 3 — minimum_recommended gate.
    if let Some(min_str) = entry.index.minimum_recommended.as_deref() {
        let parsed_min = Version::parse(min_str, style)?;
        if chosen_version < &parsed_min {
            if policy.allow_below_min_recommended {
                warnings.push(ResolutionWarning::BelowMinimumRecommended {
                    version: chosen_doc.version.clone(),
                    minimum: min_str.to_owned(),
                });
            } else {
                return Err(LuggageError::BelowMinimumRecommended {
                    tool: entry.index.id.clone(),
                    version: chosen_doc.version.clone(),
                    minimum: min_str.to_owned(),
                });
            }
        }
    }

    // Step 4 — support matrix gate.
    for row in &chosen_doc.support_matrix {
        if platform::matches_support(platform, row) && row.status == SupportStatus::Unsupported {
            return Err(LuggageError::UnsupportedPlatform(Box::new(
                crate::error::UnsupportedPlatformDetails {
                    tool: entry.index.id.clone(),
                    version: chosen_doc.version.clone(),
                    os: platform.os.clone(),
                    os_version: platform.os_version.clone(),
                    arch: platform.arch.clone(),
                    reason: row.reason.clone(),
                    tracking_url: row.tracking_url.clone(),
                },
            )));
        }
    }

    // Step 5 — install method walk.
    let method = chosen_doc
        .install_methods
        .iter()
        .find(|m| platform::matches_predicate(platform, m.platform.as_ref()))
        .ok_or_else(|| LuggageError::NoMatchingInstallMethod {
            tool: entry.index.id.clone(),
            version: chosen_doc.version.clone(),
            os: platform.os.clone(),
            os_version: platform.os_version.clone(),
            arch: platform.arch.clone(),
        })?;

    // Step 6 — slow/stale warning.
    if policy.warn_on_slow_or_stale && matches!(score, ActivityScore::Slow | ActivityScore::Stale) {
        warnings.push(ResolutionWarning::SlowOrStaleActivity { score });
    }

    Ok(build_resolved(&entry.index.id, &chosen_doc.version, method, platform.clone(), warnings))
}

fn pick_version<'a>(
    entry: &'a ToolEntry,
    spec: &VersionSpec,
    style: VersionStyle,
) -> Result<(&'a Version, &'a containers_common::tooldb::ToolVersion)> {
    match spec {
        VersionSpec::Latest => pick_latest(entry, style),
        VersionSpec::Channel(name) => pick_channel(entry, name),
        VersionSpec::Exact(literal) => pick_exact(entry, literal, style),
        VersionSpec::Partial(literal) => pick_partial(entry, literal, style),
    }
}

fn pick_latest(
    entry: &ToolEntry,
    style: VersionStyle,
) -> Result<(&Version, &containers_common::tooldb::ToolVersion)> {
    if let Some(default) = &entry.index.default_version {
        let parsed = Version::parse(default, style)?;
        if let Some((k, v)) = entry.versions.get_key_value(&parsed) {
            return Ok((k, v));
        }
        return Err(LuggageError::VersionNotFound {
            tool: entry.index.id.clone(),
            spec: format!("default {default}"),
        });
    }
    entry.versions.iter().next_back().ok_or_else(|| LuggageError::VersionNotFound {
        tool: entry.index.id.clone(),
        spec: "latest".into(),
    })
}

fn pick_channel<'a>(
    entry: &'a ToolEntry,
    channel: &str,
) -> Result<(&'a Version, &'a containers_common::tooldb::ToolVersion)> {
    entry.versions.iter().rev().find(|(_, doc)| doc.channel.as_deref() == Some(channel)).ok_or_else(
        || LuggageError::VersionNotFound {
            tool: entry.index.id.clone(),
            spec: format!("channel:{channel}"),
        },
    )
}

fn pick_exact<'a>(
    entry: &'a ToolEntry,
    literal: &str,
    style: VersionStyle,
) -> Result<(&'a Version, &'a containers_common::tooldb::ToolVersion)> {
    let parsed = Version::parse(literal, style)?;
    entry.versions.get_key_value(&parsed).ok_or_else(|| LuggageError::VersionNotFound {
        tool: entry.index.id.clone(),
        spec: literal.to_owned(),
    })
}

fn pick_partial<'a>(
    entry: &'a ToolEntry,
    literal: &str,
    style: VersionStyle,
) -> Result<(&'a Version, &'a containers_common::tooldb::ToolVersion)> {
    let constraint_string = build_partial_constraint(literal)?;
    let constraint = Constraint::parse(&constraint_string, style)?;
    entry.versions.iter().rev().find(|(v, _)| constraint.matches(v)).ok_or_else(|| {
        LuggageError::VersionNotFound {
            tool: entry.index.id.clone(),
            spec: format!("partial:{literal}"),
        }
    })
}

/// Build a `>=X, <X+1` (major-only) or `>=X.Y, <X.Y+1` (major.minor) constraint.
///
/// Inputs with two or more dots are not "partial" by this definition and
/// are rejected so callers can fall back to [`pick_exact`].
fn build_partial_constraint(literal: &str) -> Result<String> {
    let trimmed = literal.trim();
    let parts: Vec<&str> = trimmed.split('.').collect();
    match parts.as_slice() {
        [major] => {
            let n: u64 = major.parse().map_err(|_| {
                LuggageError::Catalog(format!("partial version `{literal}` is not numeric"))
            })?;
            Ok(format!(">={n}, <{}", n + 1))
        }
        [major, minor] => {
            let m: u64 = major.parse().map_err(|_| {
                LuggageError::Catalog(format!("partial version `{literal}` major is not numeric"))
            })?;
            let n: u64 = minor.parse().map_err(|_| {
                LuggageError::Catalog(format!("partial version `{literal}` minor is not numeric"))
            })?;
            Ok(format!(">={m}.{n}, <{m}.{}", n + 1))
        }
        _ => Err(LuggageError::Catalog(format!(
            "`{literal}` is not a partial version (expected major or major.minor)",
        ))),
    }
}

fn build_resolved(
    tool: &str,
    version: &str,
    method: &InstallMethod,
    platform: Platform,
    warnings: Vec<ResolutionWarning>,
) -> ResolvedInstall {
    ResolvedInstall {
        tool: tool.to_owned(),
        version: version.to_owned(),
        method_name: method.name.clone(),
        verification_tier: method.verification.tier,
        verification: method.verification.clone(),
        source_url_template: method.source_url_template.clone(),
        invoke: method.invoke.clone(),
        post_install: method.post_install.clone(),
        dependencies: method.dependencies.clone(),
        platform,
        warnings,
    }
}

// (Doc-link target re-export removed — the doc comment now references the
// type directly via its containers_common path.)

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    use containers_common::tooldb::{
        Activity, ActivityScore, AvailableEntry, Channel, InstallMethod, Kind, PlatformPredicate,
        StringOrVec, SupportEntry, Tool, ToolVersion, Verification, VersionMetadata,
    };

    fn make_tool() -> Tool {
        Tool {
            schema_version: 1,
            id: "rust".into(),
            display_name: "Rust".into(),
            kind: Kind::Language,
            homepage: None,
            source_repo: None,
            license: None,
            activity: Activity {
                score: ActivityScore::VeryActive,
                signals: None,
                scan_cadence_days: None,
                scanned_at: "2026-01-01T00:00:00Z".into(),
            },
            validation_tiers: None,
            version_style: Some(VersionStyle::Semver),
            default_version: Some("1.95.0".into()),
            minimum_recommended: None,
            channels: Some(
                std::iter::once((
                    "stable".to_string(),
                    Channel { description: "stable".into(), default: Some(true) },
                ))
                .collect(),
            ),
            ordering: None,
            alternatives: None,
            system_package: None,
            available: Some(vec![
                AvailableEntry { version: "1.84.0".into(), last_known_good_for: None },
                AvailableEntry { version: "1.84.1".into(), last_known_good_for: None },
                AvailableEntry { version: "1.95.0".into(), last_known_good_for: None },
            ]),
        }
    }

    fn make_method(os: Vec<&str>) -> InstallMethod {
        InstallMethod {
            name: "rustup-init".into(),
            platform: Some(PlatformPredicate {
                os: Some(StringOrVec(os.into_iter().map(Into::into).collect())),
                os_version: None,
                arch: Some(StringOrVec(vec!["amd64".into()])),
            }),
            verification: Verification {
                tier: 3,
                algorithm: Some("sha256".into()),
                pinned_checksum: None,
                checksum_url_template: Some("https://example.test/{version}".into()),
                gpg_key_url: None,
                signature_url_template: None,
                sigstore_identity: None,
                sigstore_issuer: None,
                tofu: None,
            },
            source_url_template: Some("https://example.test/init".into()),
            invoke: None,
            post_install: None,
            dependencies: None,
        }
    }

    fn make_version(
        literal: &str,
        support: Vec<SupportEntry>,
        methods: Vec<InstallMethod>,
    ) -> ToolVersion {
        ToolVersion {
            schema_version: 1,
            tool: "rust".into(),
            version: literal.into(),
            released: None,
            channel: Some("stable".into()),
            support_matrix: support,
            tested: vec![],
            requires: None,
            install_methods: methods,
            uninstall: None,
            metadata: VersionMetadata {
                added_at: "2026-01-01T00:00:00Z".into(),
                updated_at: None,
                schema_version: 1,
            },
        }
    }

    fn entry_with(versions: Vec<(&str, ToolVersion)>) -> ToolEntry {
        let mut map = BTreeMap::new();
        for (literal, doc) in versions {
            let parsed = Version::parse(literal, VersionStyle::Semver).unwrap();
            map.insert(parsed, doc);
        }
        ToolEntry { index: make_tool(), versions: map }
    }

    fn debian_amd64() -> Platform {
        Platform { os: "debian".into(), os_version: Some("13".into()), arch: "amd64".into() }
    }

    #[test]
    fn latest_picks_default_version() {
        let entry = entry_with(vec![
            ("1.84.0", make_version("1.84.0", vec![], vec![make_method(vec!["debian"])])),
            ("1.95.0", make_version("1.95.0", vec![], vec![make_method(vec!["debian"])])),
        ]);
        let r = resolve(&entry, &VersionSpec::Latest, &debian_amd64()).unwrap();
        assert_eq!(r.version, "1.95.0");
        assert_eq!(r.method_name, "rustup-init");
        assert_eq!(r.verification_tier, 3);
    }

    #[test]
    fn partial_major_minor_picks_highest_patch() {
        let entry = entry_with(vec![
            ("1.84.0", make_version("1.84.0", vec![], vec![make_method(vec!["debian"])])),
            ("1.84.1", make_version("1.84.1", vec![], vec![make_method(vec!["debian"])])),
            ("1.95.0", make_version("1.95.0", vec![], vec![make_method(vec!["debian"])])),
        ]);
        let r = resolve(&entry, &VersionSpec::Partial("1.84".into()), &debian_amd64()).unwrap();
        assert_eq!(r.version, "1.84.1");
    }

    #[test]
    fn partial_major_only_picks_highest() {
        let entry = entry_with(vec![
            ("1.84.0", make_version("1.84.0", vec![], vec![make_method(vec!["debian"])])),
            ("1.95.0", make_version("1.95.0", vec![], vec![make_method(vec!["debian"])])),
            ("2.0.0", make_version("2.0.0", vec![], vec![make_method(vec!["debian"])])),
        ]);
        let r = resolve(&entry, &VersionSpec::Partial("1".into()), &debian_amd64()).unwrap();
        assert_eq!(r.version, "1.95.0");
    }

    #[test]
    fn exact_missing_returns_version_not_found() {
        let entry = entry_with(vec![(
            "1.84.0",
            make_version("1.84.0", vec![], vec![make_method(vec!["debian"])]),
        )]);
        let err =
            resolve(&entry, &VersionSpec::Exact("9.9.9".into()), &debian_amd64()).unwrap_err();
        assert!(matches!(err, LuggageError::VersionNotFound { .. }));
    }

    #[test]
    fn channel_picks_highest_in_channel() {
        let mut a = make_version("1.84.0", vec![], vec![make_method(vec!["debian"])]);
        a.channel = Some("stable".into());
        let mut b = make_version("1.95.0", vec![], vec![make_method(vec!["debian"])]);
        b.channel = Some("nightly".into());
        let entry = entry_with(vec![("1.84.0", a), ("1.95.0", b)]);
        let r = resolve(&entry, &VersionSpec::Channel("stable".into()), &debian_amd64()).unwrap();
        assert_eq!(r.version, "1.84.0");
    }

    #[test]
    fn unsupported_platform_returns_error_with_reason() {
        let unsupported_row = SupportEntry {
            os: "windows".into(),
            os_version: None,
            arch: "amd64".into(),
            status: SupportStatus::Unsupported,
            notes: None,
            reason: Some("no upstream rustup target".into()),
            tracking_url: Some("https://example.test/issue".into()),
            recheck_at: None,
        };
        let entry = entry_with(vec![(
            "1.95.0",
            make_version("1.95.0", vec![unsupported_row], vec![make_method(vec!["debian"])]),
        )]);
        let windows = Platform { os: "windows".into(), os_version: None, arch: "amd64".into() };
        let err = resolve(&entry, &VersionSpec::Latest, &windows).unwrap_err();
        match err {
            LuggageError::UnsupportedPlatform(details) => {
                assert_eq!(details.reason.as_deref(), Some("no upstream rustup target"));
                assert!(details.tracking_url.is_some());
            }
            other => panic!("expected UnsupportedPlatform, got {other:?}"),
        }
    }

    #[test]
    fn no_install_method_match_returns_error_exit_two() {
        let entry = entry_with(vec![(
            "1.95.0",
            make_version("1.95.0", vec![], vec![make_method(vec!["debian"])]),
        )]);
        let alpine =
            Platform { os: "alpine".into(), os_version: Some("3.21".into()), arch: "amd64".into() };
        let err = resolve(&entry, &VersionSpec::Latest, &alpine).unwrap_err();
        assert!(matches!(err, LuggageError::NoMatchingInstallMethod { .. }));
        assert_eq!(err.exit_code(), 2);
    }

    #[test]
    fn install_method_walk_picks_first_matching() {
        // First method covers debian/ubuntu/rhel, second covers alpine — alpine host should pick second.
        let methods = vec![
            make_method(vec!["debian", "ubuntu", "rhel"]),
            InstallMethod { name: "rustup-init-musl".into(), ..make_method(vec!["alpine"]) },
        ];
        let entry = entry_with(vec![("1.95.0", make_version("1.95.0", vec![], methods))]);
        let alpine =
            Platform { os: "alpine".into(), os_version: Some("3.21".into()), arch: "amd64".into() };
        let r = resolve(&entry, &VersionSpec::Latest, &alpine).unwrap();
        assert_eq!(r.method_name, "rustup-init-musl");
    }

    #[test]
    fn build_partial_constraint_rejects_non_numeric() {
        let err = build_partial_constraint("abc").unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn build_partial_constraint_rejects_three_dots() {
        let err = build_partial_constraint("1.2.3").unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    fn entry_with_score(score: ActivityScore) -> ToolEntry {
        let mut tool = make_tool();
        tool.activity.score = score;
        tool.minimum_recommended = None;
        let mut map = BTreeMap::new();
        let parsed = Version::parse("1.95.0", VersionStyle::Semver).unwrap();
        map.insert(parsed, make_version("1.95.0", vec![], vec![make_method(vec!["debian"])]));
        ToolEntry { index: tool, versions: map }
    }

    #[test]
    fn default_policy_accepts_maintained_or_better() {
        for score in [ActivityScore::VeryActive, ActivityScore::Active, ActivityScore::Maintained] {
            let entry = entry_with_score(score);
            let r = resolve_with_policy(
                &entry,
                &VersionSpec::Latest,
                &debian_amd64(),
                &ResolutionPolicy::default(),
            )
            .unwrap();
            assert!(r.warnings.is_empty(), "tier {score:?} should produce no warnings");
        }
    }

    #[test]
    fn warn_on_slow_or_stale_fires_only_when_admitted() {
        // Build a policy that admits Slow/Stale and asks for warnings —
        // this is the only configuration in which the warning is reachable
        // (the default policy refuses Slow/Stale before they get this far).
        let policy = ResolutionPolicy {
            min_activity: ActivityScore::Stale,
            warn_on_slow_or_stale: true,
            allow_below_min_recommended: false,
        };
        for score in [ActivityScore::Slow, ActivityScore::Stale] {
            let entry = entry_with_score(score);
            let r = resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy)
                .unwrap();
            assert_eq!(r.warnings.len(), 1, "tier {score:?} should emit one warning");
            match &r.warnings[0] {
                ResolutionWarning::SlowOrStaleActivity { score: actual } => {
                    assert_eq!(*actual, score);
                }
                ResolutionWarning::BelowMinimumRecommended { .. } => {
                    panic!("expected SlowOrStaleActivity, got BelowMinimumRecommended");
                }
            }
        }
    }

    #[test]
    fn default_policy_refuses_below_maintained() {
        for score in [
            ActivityScore::Slow,
            ActivityScore::Stale,
            ActivityScore::Dormant,
            ActivityScore::Abandoned,
            ActivityScore::Unknown,
        ] {
            let entry = entry_with_score(score);
            let err = resolve_with_policy(
                &entry,
                &VersionSpec::Latest,
                &debian_amd64(),
                &ResolutionPolicy::default(),
            )
            .unwrap_err();
            match err {
                LuggageError::ActivityBelowThreshold { score: actual, threshold, .. } => {
                    assert_eq!(actual, score);
                    assert_eq!(threshold, ActivityScore::Maintained);
                }
                other => panic!("expected ActivityBelowThreshold for {score:?}, got {other:?}"),
            }
        }
    }

    #[test]
    fn permissive_policy_accepts_all_tiers() {
        let policy = ResolutionPolicy::permissive();
        for score in [
            ActivityScore::VeryActive,
            ActivityScore::Active,
            ActivityScore::Maintained,
            ActivityScore::Slow,
            ActivityScore::Stale,
            ActivityScore::Dormant,
            ActivityScore::Abandoned,
        ] {
            let entry = entry_with_score(score);
            let r = resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy)
                .unwrap();
            assert!(r.warnings.is_empty(), "permissive policy should suppress warnings");
        }
    }

    #[test]
    fn igor_policy_accepts_down_to_stale() {
        let policy = ResolutionPolicy::igor();
        for score in [ActivityScore::Maintained, ActivityScore::Slow, ActivityScore::Stale] {
            let entry = entry_with_score(score);
            assert!(
                resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy).is_ok(),
                "igor should accept {score:?}",
            );
        }
        let entry = entry_with_score(ActivityScore::Dormant);
        assert!(
            resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy).is_err(),
            "igor should still refuse Dormant",
        );
    }

    #[test]
    fn below_minimum_recommended_refuses_by_default() {
        let mut entry = entry_with_score(ActivityScore::VeryActive);
        entry.index.minimum_recommended = Some("2.0.0".into());
        // Tool only has 1.95.0 in versions; latest will pick that, which is below 2.0.0.
        let err = resolve_with_policy(
            &entry,
            &VersionSpec::Latest,
            &debian_amd64(),
            &ResolutionPolicy::default(),
        )
        .unwrap_err();
        match err {
            LuggageError::BelowMinimumRecommended { version, minimum, .. } => {
                assert_eq!(version, "1.95.0");
                assert_eq!(minimum, "2.0.0");
            }
            other => panic!("expected BelowMinimumRecommended, got {other:?}"),
        }
    }

    #[test]
    fn below_minimum_recommended_warns_when_allowed() {
        let mut entry = entry_with_score(ActivityScore::VeryActive);
        entry.index.minimum_recommended = Some("2.0.0".into());
        let policy = ResolutionPolicy { allow_below_min_recommended: true, ..Default::default() };
        let r =
            resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy).unwrap();
        assert_eq!(r.warnings.len(), 1);
        match &r.warnings[0] {
            ResolutionWarning::BelowMinimumRecommended { version, minimum } => {
                assert_eq!(version, "1.95.0");
                assert_eq!(minimum, "2.0.0");
            }
            ResolutionWarning::SlowOrStaleActivity { .. } => {
                panic!("expected BelowMinimumRecommended, got SlowOrStaleActivity");
            }
        }
    }

    #[test]
    fn above_minimum_recommended_emits_no_warning() {
        let mut entry = entry_with_score(ActivityScore::VeryActive);
        entry.index.minimum_recommended = Some("1.0.0".into());
        let r = resolve_with_policy(
            &entry,
            &VersionSpec::Latest,
            &debian_amd64(),
            &ResolutionPolicy::default(),
        )
        .unwrap();
        assert!(r.warnings.is_empty());
    }

    #[test]
    fn slow_or_stale_warning_suppressed_when_policy_disables() {
        let entry = entry_with_score(ActivityScore::Slow);
        let policy =
            ResolutionPolicy { warn_on_slow_or_stale: false, ..ResolutionPolicy::permissive() };
        let r =
            resolve_with_policy(&entry, &VersionSpec::Latest, &debian_amd64(), &policy).unwrap();
        assert!(r.warnings.is_empty());
    }
}
