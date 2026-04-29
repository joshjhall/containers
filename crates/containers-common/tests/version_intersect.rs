//! Tests for [`Constraint::intersect`] — combining constraints, empty
//! intersections, and style mismatches.

use containers_common::version::{Constraint, IntersectError, Version, VersionStyle};

fn ver(s: &str) -> Version {
    Version::parse(s, VersionStyle::Semver).unwrap()
}

fn cn(s: &str) -> Constraint {
    Constraint::parse(s, VersionStyle::Semver).unwrap()
}

#[test]
fn intersect_overlapping_ranges_narrows_to_inner_bounds() {
    // >=1.7,<2.0 ∩ >=1.8.5,<3.0 should match 1.9.0 but reject the
    // boundaries that fall outside either operand.
    let combined = cn(">=1.7, <2.0").intersect(&cn(">=1.8.5, <3.0")).unwrap();
    assert!(combined.matches(&ver("1.8.5")));
    assert!(combined.matches(&ver("1.9.0")));
    assert!(!combined.matches(&ver("1.8.0")));
    assert!(!combined.matches(&ver("2.0.0")));
    assert!(!combined.matches(&ver("3.0.0")));
}

#[test]
fn intersect_with_any_returns_other() {
    let lhs = cn(">=1.0");
    let rhs = cn("*");
    let combined = lhs.intersect(&rhs).unwrap();
    assert_eq!(combined, lhs);
    let combined2 = rhs.intersect(&lhs).unwrap();
    assert_eq!(combined2, lhs);
}

#[test]
fn empty_intersection_returns_loud_error() {
    let err = cn(">=2.0").intersect(&cn("<1.0")).unwrap_err();
    let IntersectError::Empty { left, right } = err else {
        panic!("expected Empty, got {err:?}");
    };
    assert!(left.contains(">=2.0"), "left should contain operand: {left}");
    assert!(right.contains("<1.0"), "right should contain operand: {right}");
}

#[test]
fn empty_intersection_for_disjoint_ranges() {
    assert!(matches!(
        cn(">=2.0, <3.0").intersect(&cn(">=4.0, <5.0")).unwrap_err(),
        IntersectError::Empty { .. }
    ));
}

#[test]
fn intersect_pin_with_compatible_range() {
    let combined = cn("=1.5.0").intersect(&cn(">=1.0, <2.0")).unwrap();
    assert!(combined.matches(&ver("1.5.0")));
    assert!(!combined.matches(&ver("1.4.0")));
}

#[test]
fn intersect_pin_with_incompatible_range_is_empty() {
    assert!(matches!(
        cn("=1.5.0").intersect(&cn(">=2.0")).unwrap_err(),
        IntersectError::Empty { .. }
    ));
}

#[test]
fn intersect_caret_with_minimum() {
    // ^1.2.3 := >=1.2.3, <2.0.0; ∩ >=1.5 = >=1.5, <2.0.0
    let combined = cn("^1.2.3").intersect(&cn(">=1.5")).unwrap();
    assert!(combined.matches(&ver("1.5.0")));
    assert!(combined.matches(&ver("1.99.99")));
    assert!(!combined.matches(&ver("1.4.0")));
    assert!(!combined.matches(&ver("2.0.0")));
}

#[test]
fn intersect_two_caret_ranges_disjoint() {
    // ^1.0 := >=1.0, <2.0; ^2.0 := >=2.0, <3.0; disjoint at 2.0
    assert!(matches!(cn("^1.0").intersect(&cn("^2.0")).unwrap_err(), IntersectError::Empty { .. }));
}

#[test]
fn intersect_two_pins_same_version_succeeds() {
    let combined = cn("=1.5.0").intersect(&cn("=1.5.0")).unwrap();
    assert!(combined.matches(&ver("1.5.0")));
}

#[test]
fn intersect_two_pins_differing_versions_is_empty() {
    assert!(matches!(
        cn("=1.5.0").intersect(&cn("=1.6.0")).unwrap_err(),
        IntersectError::Empty { .. }
    ));
}
