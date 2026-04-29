//! Tests for [`Constraint::parse`] and [`Constraint::matches`] — the
//! grammar surface (cargo `^`/`~`, npm `1.x`, ranges, `any`/`*`).

use containers_common::version::{Constraint, Version, VersionError, VersionStyle};

fn ver(s: &str) -> Version {
    Version::parse(s, VersionStyle::Semver).unwrap()
}

fn cn(s: &str) -> Constraint {
    Constraint::parse(s, VersionStyle::Semver).unwrap()
}

#[test]
fn exact_pin_matches_only_that_version() {
    let c = cn("1.95.0");
    assert!(c.matches(&ver("1.95.0")));
    assert!(!c.matches(&ver("1.95.1")));
    assert!(!c.matches(&ver("1.94.0")));
}

#[test]
fn ge_minimum_matches_higher() {
    let c = cn(">=1.7.0");
    assert!(c.matches(&ver("1.7.0")));
    assert!(c.matches(&ver("1.7.5")));
    assert!(c.matches(&ver("2.0.0")));
    assert!(!c.matches(&ver("1.6.99")));
}

#[test]
fn bounded_range_matches_inside_only() {
    let c = cn(">=1.7, <2");
    assert!(c.matches(&ver("1.7.0")));
    assert!(c.matches(&ver("1.99.0")));
    assert!(!c.matches(&ver("2.0.0")));
    assert!(!c.matches(&ver("1.6.0")));
}

#[test]
fn caret_minor_compatible() {
    // ^1.2.3 := >=1.2.3, <2.0.0
    let c = cn("^1.2.3");
    assert!(c.matches(&ver("1.2.3")));
    assert!(c.matches(&ver("1.5.0")));
    assert!(!c.matches(&ver("2.0.0")));
    assert!(!c.matches(&ver("1.2.2")));
}

#[test]
fn tilde_patch_compatible() {
    // ~1.2.3 := >=1.2.3, <1.3.0
    let c = cn("~1.2.3");
    assert!(c.matches(&ver("1.2.3")));
    assert!(c.matches(&ver("1.2.9")));
    assert!(!c.matches(&ver("1.3.0")));
    assert!(!c.matches(&ver("1.2.2")));
}

#[test]
fn npm_minor_wildcard() {
    // 1.x matches any 1.y.z
    let c = cn("1.x");
    assert!(c.matches(&ver("1.0.0")));
    assert!(c.matches(&ver("1.7.5")));
    assert!(!c.matches(&ver("2.0.0")));
}

#[test]
fn npm_patch_wildcard() {
    // 1.7.x matches any 1.7.z
    let c = cn("1.7.x");
    assert!(c.matches(&ver("1.7.0")));
    assert!(c.matches(&ver("1.7.99")));
    assert!(!c.matches(&ver("1.8.0")));
    assert!(!c.matches(&ver("1.6.99")));
}

#[test]
fn star_matches_anything() {
    let c = cn("*");
    assert!(c.matches(&ver("0.0.1")));
    assert!(c.matches(&ver("99.99.99")));
}

#[test]
fn any_keyword_is_unconstrained() {
    let c = cn("any");
    assert!(c.matches(&ver("0.0.1")));
    assert!(c.matches(&ver("100.0.0")));
    let c2 = cn("ANY");
    assert!(c2.matches(&ver("0.0.1")));
}

#[test]
fn constraint_strips_v_prefix_in_tokens() {
    let c = Constraint::parse(">=v1.7.0, <v2", VersionStyle::Semver).unwrap();
    assert!(c.matches(&ver("1.7.0")));
    assert!(!c.matches(&ver("2.0.0")));
}

#[test]
fn empty_constraint_is_rejected() {
    assert!(matches!(Constraint::parse("", VersionStyle::Semver), Err(VersionError::Empty)));
}

#[test]
fn malformed_constraint_returns_semver_error() {
    assert!(matches!(
        Constraint::parse("nope", VersionStyle::Semver),
        Err(VersionError::Semver { .. })
    ));
}
