//! Tests for [`Version::parse`] — basic parsing, prefix tolerance,
//! and rejection of bad inputs.

use containers_common::version::{Version, VersionError, VersionStyle};

#[test]
fn semver_basic_three_part() {
    let v = Version::parse("1.95.0", VersionStyle::Semver).unwrap();
    assert_eq!(format!("{v}"), "1.95.0");
}

#[test]
fn semver_two_part_pads_to_three() {
    let v = Version::parse("1.7", VersionStyle::Semver).unwrap();
    assert_eq!(format!("{v}"), "1.7.0");
}

#[test]
fn semver_one_part_pads_to_three() {
    let v = Version::parse("2", VersionStyle::Semver).unwrap();
    assert_eq!(format!("{v}"), "2.0.0");
}

#[test]
fn semver_strips_v_prefix() {
    let v = Version::parse("v1.95.0", VersionStyle::Semver).unwrap();
    let bare = Version::parse("1.95.0", VersionStyle::Semver).unwrap();
    assert_eq!(v, bare);
}

#[test]
fn semver_strips_capital_v_prefix() {
    assert_eq!(
        Version::parse("V1.0.0", VersionStyle::Semver).unwrap(),
        Version::parse("1.0.0", VersionStyle::Semver).unwrap(),
    );
}

#[test]
fn semver_strips_release_prefix() {
    assert_eq!(
        Version::parse("release-1.0.0", VersionStyle::Semver).unwrap(),
        Version::parse("1.0.0", VersionStyle::Semver).unwrap(),
    );
}

#[test]
fn semver_strips_r_prefix_when_followed_by_digit() {
    assert_eq!(
        Version::parse("r1.2.3", VersionStyle::Semver).unwrap(),
        Version::parse("1.2.3", VersionStyle::Semver).unwrap(),
    );
}

#[test]
fn semver_does_not_strip_r_when_followed_by_letter() {
    // "release-" is the only `r…` prefix that strips a non-digit; bare
    // `r` followed by a letter (e.g. `rhel`) must not be eaten.
    assert!(Version::parse("rhel", VersionStyle::Semver).is_err());
}

#[test]
fn prefix_drop_regression() {
    // The classic `v0.3.0 → 0.4.0` boundary: all four must round-trip
    // and compare correctly across the prefix change.
    let tags = ["v0.3.0", "v0.3.1", "0.4.0", "0.5.0"];
    let parsed: Vec<_> =
        tags.iter().map(|t| Version::parse(t, VersionStyle::Semver).unwrap()).collect();
    let strings: Vec<_> = parsed.iter().map(|v| format!("{v}")).collect();
    assert_eq!(strings, vec!["0.3.0", "0.3.1", "0.4.0", "0.5.0"]);
}

#[test]
fn mixed_prefix_corpus_all_parse() {
    let tags = ["v1.0", "release-1.1", "1.2", "r1.3"];
    let parsed: Vec<_> =
        tags.iter().map(|t| Version::parse(t, VersionStyle::Semver).unwrap()).collect();
    let strings: Vec<_> = parsed.iter().map(|v| format!("{v}")).collect();
    assert_eq!(strings, vec!["1.0.0", "1.1.0", "1.2.0", "1.3.0"]);
}

#[test]
fn semver_accepts_pre_release() {
    let v = Version::parse("1.0.0-rc.1", VersionStyle::Semver).unwrap();
    assert_eq!(format!("{v}"), "1.0.0-rc.1");
}

#[test]
fn empty_string_is_rejected() {
    assert!(matches!(Version::parse("", VersionStyle::Semver), Err(VersionError::Empty)));
    assert!(matches!(Version::parse("   ", VersionStyle::Semver), Err(VersionError::Empty)));
}

#[test]
fn non_numeric_input_is_rejected() {
    assert!(matches!(
        Version::parse("version", VersionStyle::Semver),
        Err(VersionError::Semver { .. })
    ));
}

#[test]
fn wildcard_in_version_literal_is_rejected() {
    assert!(matches!(
        Version::parse("1.*.0", VersionStyle::Semver),
        Err(VersionError::WildcardInVersion { .. })
    ));
    assert!(matches!(
        Version::parse("1.x", VersionStyle::Semver),
        Err(VersionError::WildcardInVersion { .. })
    ));
}

#[test]
fn prefix_mode_behaves_like_semver_today() {
    let bare = Version::parse("v1.7.0", VersionStyle::Prefix).unwrap();
    let semver = Version::parse("v1.7.0", VersionStyle::Semver).unwrap();
    assert_eq!(bare, semver);
}
