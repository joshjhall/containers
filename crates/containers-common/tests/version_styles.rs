//! Tests for non-semver style modes: `Calver` and `Opaque`, plus
//! cross-style behavior.

use containers_common::version::{Constraint, IntersectError, Version, VersionError, VersionStyle};

// ===== Calver =====

#[test]
fn calver_exact_match() {
    let v = Version::parse("2026.04.29", VersionStyle::Calver).unwrap();
    let c = Constraint::parse("2026.04.29", VersionStyle::Calver).unwrap();
    assert!(c.matches(&v));
    assert!(!c.matches(&Version::parse("2026.05.01", VersionStyle::Calver).unwrap()));
}

#[test]
fn calver_lexicographic_ordering() {
    let earlier = Version::parse("2026.04.29", VersionStyle::Calver).unwrap();
    let later = Version::parse("2026.05.01", VersionStyle::Calver).unwrap();
    let range = Constraint::parse(">=2026.04.30", VersionStyle::Calver).unwrap();
    assert!(!range.matches(&earlier));
    assert!(range.matches(&later));
}

#[test]
fn calver_bounded_range() {
    let c = Constraint::parse(">=2026.01.01, <2027.01.01", VersionStyle::Calver).unwrap();
    assert!(c.matches(&Version::parse("2026.04.29", VersionStyle::Calver).unwrap()));
    assert!(!c.matches(&Version::parse("2025.12.31", VersionStyle::Calver).unwrap()));
    assert!(!c.matches(&Version::parse("2027.06.01", VersionStyle::Calver).unwrap()));
}

#[test]
fn calver_intersect_overlapping() {
    let a = Constraint::parse(">=2026.01.01, <2027.01.01", VersionStyle::Calver).unwrap();
    let b = Constraint::parse(">=2026.06.01, <2028.01.01", VersionStyle::Calver).unwrap();
    let combined = a.intersect(&b).unwrap();
    assert!(combined.matches(&Version::parse("2026.07.01", VersionStyle::Calver).unwrap()));
    assert!(!combined.matches(&Version::parse("2026.05.01", VersionStyle::Calver).unwrap()));
    assert!(!combined.matches(&Version::parse("2027.01.01", VersionStyle::Calver).unwrap()));
}

#[test]
fn calver_intersect_disjoint_is_empty() {
    let a = Constraint::parse(">=2026.01.01", VersionStyle::Calver).unwrap();
    let b = Constraint::parse("<2025.01.01", VersionStyle::Calver).unwrap();
    assert!(matches!(a.intersect(&b).unwrap_err(), IntersectError::Empty { .. }));
}

#[test]
fn calver_rejects_non_numeric_components() {
    assert!(matches!(
        Version::parse("2026.april.29", VersionStyle::Calver),
        Err(VersionError::Calver { .. })
    ));
}

// ===== Opaque =====

#[test]
fn opaque_exact_match_works() {
    let v = Version::parse("1.95.0", VersionStyle::Opaque).unwrap();
    let c = Constraint::parse("1.95.0", VersionStyle::Opaque).unwrap();
    assert!(c.matches(&v));
}

#[test]
fn opaque_string_pin_matches_only_exact_string() {
    let v = Version::parse("freeform-tag-A", VersionStyle::Opaque).unwrap();
    let c = Constraint::parse("freeform-tag-A", VersionStyle::Opaque).unwrap();
    assert!(c.matches(&v));
    let other = Version::parse("freeform-tag-B", VersionStyle::Opaque).unwrap();
    assert!(!c.matches(&other));
}

#[test]
fn opaque_any_matches_anything() {
    let c = Constraint::parse("any", VersionStyle::Opaque).unwrap();
    assert!(c.matches(&Version::parse("anything", VersionStyle::Opaque).unwrap()));
    assert!(c.matches(&Version::parse("else", VersionStyle::Opaque).unwrap()));
}

#[test]
fn opaque_rejects_comparator() {
    assert!(matches!(
        Constraint::parse(">=1.95", VersionStyle::Opaque),
        Err(VersionError::OpaqueComparator { .. })
    ));
    assert!(matches!(
        Constraint::parse("^1.0", VersionStyle::Opaque),
        Err(VersionError::OpaqueComparator { .. })
    ));
    assert!(matches!(
        Constraint::parse("~1.0", VersionStyle::Opaque),
        Err(VersionError::OpaqueComparator { .. })
    ));
}

#[test]
fn opaque_rejects_wildcard_other_than_any() {
    assert!(matches!(
        Constraint::parse("1.x", VersionStyle::Opaque),
        Err(VersionError::OpaqueComparator { .. })
    ));
}

// ===== Cross-style =====

#[test]
fn semver_constraint_does_not_match_calver_version() {
    let semver_c = Constraint::parse(">=1.0", VersionStyle::Semver).unwrap();
    let calver_v = Version::parse("2026.04.29", VersionStyle::Calver).unwrap();
    assert!(!semver_c.matches(&calver_v));
}

#[test]
fn intersect_across_styles_returns_style_mismatch() {
    let semver = Constraint::parse(">=1.0", VersionStyle::Semver).unwrap();
    let calver = Constraint::parse(">=2026.01.01", VersionStyle::Calver).unwrap();
    assert!(matches!(semver.intersect(&calver).unwrap_err(), IntersectError::StyleMismatch));
}

#[test]
fn intersect_semver_with_opaque_returns_style_mismatch() {
    let semver = Constraint::parse(">=1.0", VersionStyle::Semver).unwrap();
    let opaque = Constraint::parse("1.0", VersionStyle::Opaque).unwrap();
    assert!(matches!(semver.intersect(&opaque).unwrap_err(), IntersectError::StyleMismatch));
}
