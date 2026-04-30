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
    Dependency, InstallMethod, Invoke, PostInstall, SupportStatus, Verification,
};
use containers_common::version::{Constraint, Version, VersionStyle};
use serde::Serialize;

use crate::catalog::ToolEntry;
use crate::error::{LuggageError, Result};
use crate::platform::{self, Platform};

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
}

/// Resolve `(entry, spec, platform)` into an install plan.
///
/// # Errors
///
/// - [`LuggageError::VersionNotFound`] if no version satisfied `spec`.
/// - [`LuggageError::UnsupportedPlatform`] if the version's `support_matrix`
///   has an `unsupported` row matching the platform.
/// - [`LuggageError::NoMatchingInstallMethod`] if no `install_methods[]`
///   entry's predicate matches.
/// - [`LuggageError::VersionParse`] if a version literal is malformed.
pub fn resolve(
    entry: &ToolEntry,
    spec: &VersionSpec,
    platform: &Platform,
) -> Result<ResolvedInstall> {
    let style = entry.index.version_style.unwrap_or(VersionStyle::Semver);
    let (_chosen_version, chosen_doc) = pick_version(entry, spec, style)?;

    // Step 2 — support matrix gate.
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

    // Step 3 — install method walk.
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

    Ok(build_resolved(&entry.index.id, &chosen_doc.version, method, platform.clone()))
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
}
