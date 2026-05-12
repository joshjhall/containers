//! Tests for [`TaggedVersion`] — prefix detection, round-trip identity,
//! equality semantics, and the trivy-action regression class.

use std::collections::HashSet;

use containers_common::version::{TagPrefix, TaggedVersion, Version, VersionStyle};

fn tagged(s: &str) -> TaggedVersion {
    TaggedVersion::parse(s, VersionStyle::Semver).unwrap()
}

// ---------- 1. Tag-prefix detection ----------

#[test]
fn detects_bare_prefix() {
    let v = tagged("1.95.0");
    assert_eq!(v.prefix, TagPrefix::Bare);
    assert_eq!(format!("{}", v.as_canonical()), "1.95.0");
}

#[test]
fn detects_v_prefix() {
    let v = tagged("v1.95.0");
    assert_eq!(v.prefix, TagPrefix::V);
    assert_eq!(format!("{}", v.as_canonical()), "1.95.0");
}

#[test]
fn detects_capital_v_prefix() {
    let v = tagged("V1.0.0");
    assert_eq!(v.prefix, TagPrefix::VCapital);
    assert_eq!(format!("{}", v.as_canonical()), "1.0.0");
}

#[test]
fn detects_release_prefix() {
    let v = tagged("release-1.95.0");
    assert_eq!(v.prefix, TagPrefix::Release);
    assert_eq!(format!("{}", v.as_canonical()), "1.95.0");
}

#[test]
fn detects_r_prefix() {
    let v = tagged("r1.2.3");
    assert_eq!(v.prefix, TagPrefix::R);
    assert_eq!(format!("{}", v.as_canonical()), "1.2.3");
}

#[test]
fn r_prefix_only_strips_when_followed_by_digit() {
    // Same guard as `Version::parse` — `rhel` is rejected by semver, not
    // silently parsed as a prefix.
    assert!(TaggedVersion::parse("rhel", VersionStyle::Semver).is_err());
}

// ---------- 2. Round-trip identity ----------

#[test]
fn round_trips_three_part_versions_under_every_prefix() {
    let cases = [
        ("1.95.0", TagPrefix::Bare),
        ("v1.95.0", TagPrefix::V),
        ("V1.0.0", TagPrefix::VCapital),
        ("release-1.95.0", TagPrefix::Release),
        ("r1.2.3", TagPrefix::R),
    ];
    for (input, expected_prefix) in cases {
        let parsed = tagged(input);
        assert_eq!(parsed.prefix, expected_prefix, "wrong prefix for {input}");
        assert_eq!(format!("{parsed}"), input, "lost form for {input}");
    }
}

#[test]
fn round_trip_pads_relaxed_semver_consistently() {
    // `Version::parse` pads `1.7` → `1.7.0`; that padding survives the
    // round-trip — the prefix is preserved but the core normalizes.
    let parsed = tagged("v1.7");
    assert_eq!(parsed.prefix, TagPrefix::V);
    assert_eq!(format!("{parsed}"), "v1.7.0");
}

// ---------- 3. Equality semantics ----------

#[test]
fn equality_ignores_prefix() {
    let v = tagged("v1.0.0");
    let bare = tagged("1.0.0");
    let release = tagged("release-1.0.0");
    assert_eq!(v, bare);
    assert_eq!(v, release);
    // Hash agrees with Eq (a hash-set deduplicates across prefixes).
    let set: HashSet<_> = [v, bare, release].into_iter().collect();
    assert_eq!(set.len(), 1);
}

#[test]
fn is_textually_identical_distinguishes_prefix() {
    let v = tagged("v1.0.0");
    let bare = tagged("1.0.0");
    assert!(!v.is_textually_identical(&bare));
    assert!(v.is_textually_identical(&v.clone()));
}

#[test]
fn ordering_follows_canonical_core() {
    let mut versions =
        [tagged("v1.10.0"), tagged("release-1.2.0"), tagged("1.9.0"), tagged("v1.2.5")];
    versions.sort();
    let cores: Vec<_> = versions.iter().map(|v| format!("{}", v.as_canonical())).collect();
    assert_eq!(cores, vec!["1.2.0", "1.2.5", "1.9.0", "1.10.0"]);
}

// ---------- 4. trivy-action regression ----------

/// The bug this primitive exists to prevent.
///
/// trivy-action published `0.35.0` for years, then switched to v-prefixed-only
/// tags at v0.36.0. Our shell pipeline normalized everything to bare, wrote
/// `aquasecurity/trivy-action@0.36.0` into CI, and every Security Scan job
/// failed because that tag does not exist.
///
/// With [`TaggedVersion`], a writer that knows the tool's convention can
/// emit the correct form regardless of how the upstream payload arrived.
#[test]
fn trivy_action_writes_v_prefix_even_when_read_bare() {
    // 1. Upstream GitHub API returns `v0.36.0`, parsed into a TaggedVersion.
    let upstream = tagged("v0.36.0");
    assert_eq!(upstream.prefix, TagPrefix::V);

    // 2. Catalog stores the canonical core (`0.36.0`) — same as today.
    let core = upstream.as_canonical().clone();
    assert_eq!(format!("{core}"), "0.36.0");

    // 3. The writer emits using the recorded prefix, NOT bare.
    let to_write = TaggedVersion::new(core, TagPrefix::V);
    assert_eq!(format!("{to_write}"), "v0.36.0");
}

#[test]
fn writer_can_force_prefix_even_for_bare_input() {
    // The reverse scenario: an old catalog entry stored `0.36.0` bare
    // before this primitive existed, but the consumer now requires
    // `v0.36.0`. `with_prefix` upgrades it deterministically.
    let bare = tagged("0.36.0");
    let v_prefixed = bare.with_prefix(TagPrefix::V);
    assert_eq!(format!("{v_prefixed}"), "v0.36.0");
}

// ---------- 5. Serde round-trip ----------

#[test]
fn serde_preserves_prefix_through_json() {
    let original = tagged("v0.36.0");
    let json = serde_json::to_string(&original).unwrap();
    assert_eq!(json, "\"v0.36.0\"");
    let reparsed: TaggedVersion = serde_json::from_str(&json).unwrap();
    assert!(original.is_textually_identical(&reparsed));
}

#[test]
fn serde_round_trip_every_prefix() {
    for input in ["1.95.0", "v1.95.0", "V1.0.0", "release-1.95.0", "r1.2.3"] {
        let v = tagged(input);
        let json = serde_json::to_string(&v).unwrap();
        let back: TaggedVersion = serde_json::from_str(&json).unwrap();
        assert!(v.is_textually_identical(&back), "lost form across serde: {input}");
    }
}

// ---------- 6. Bridge with Version ----------

#[test]
fn as_canonical_returns_same_value_as_version_parse() {
    let direct = Version::parse("v1.95.0", VersionStyle::Semver).unwrap();
    let via_tagged = tagged("v1.95.0");
    assert_eq!(via_tagged.as_canonical(), &direct);
}

#[test]
fn empty_input_is_rejected() {
    assert!(TaggedVersion::parse("", VersionStyle::Semver).is_err());
    assert!(TaggedVersion::parse("   ", VersionStyle::Semver).is_err());
}

#[test]
fn tag_prefix_detect_matches_internal_split() {
    // Public TagPrefix::detect should produce identical results to what
    // TaggedVersion::parse records internally.
    for (raw, expected) in [
        ("1.0.0", TagPrefix::Bare),
        ("v1.0.0", TagPrefix::V),
        ("V1.0.0", TagPrefix::VCapital),
        ("release-1.0.0", TagPrefix::Release),
        ("r1.0.0", TagPrefix::R),
    ] {
        let (prefix, _) = TagPrefix::detect(raw);
        assert_eq!(prefix, expected, "detect disagreed for {raw}");
        let parsed = tagged(raw);
        assert_eq!(parsed.prefix, prefix);
    }
}
