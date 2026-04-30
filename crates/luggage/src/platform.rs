//! Target platform description and predicate matchers.
//!
//! [`Platform`] is the input to [`crate::Catalog::resolve`]. It is a plain
//! struct with no auto-detection logic — that lives in the binary so the
//! library stays deterministic and unit-testable.

use containers_common::tooldb::{PlatformPredicate, SupportEntry};
use serde::{Deserialize, Serialize};

/// A target host platform.
///
/// `os` and `arch` follow the catalog's free-form vocabulary
/// (`debian`/`ubuntu`/`alpine`/`rhel`/`darwin`/`windows`,
/// `amd64`/`arm64`/`armv7`/`riscv64`). `os_version` is optional because
/// some callers (e.g. quick CLI smoke tests) genuinely don't pin a distro
/// version; matching against a [`SupportEntry`] whose `os_version` is also
/// `None` will succeed via the "row applies to all versions" rule.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Platform {
    /// Distro id (e.g. `debian`).
    pub os: String,
    /// Distro version string (e.g. `13`, `3.21`). Optional.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    /// CPU architecture (e.g. `amd64`).
    pub arch: String,
}

/// Returns `true` if `platform` satisfies `predicate`.
///
/// AND-combines all listed fields; missing fields match any value. A
/// [`None`] predicate matches every platform (per the schema's "omit to
/// mean any platform" rule for `install_methods[].platform`).
#[must_use]
pub fn matches_predicate(platform: &Platform, predicate: Option<&PlatformPredicate>) -> bool {
    let Some(pred) = predicate else { return true };

    if let Some(os) = &pred.os
        && !os.contains(&platform.os)
    {
        return false;
    }
    if let Some(arch) = &pred.arch
        && !arch.contains(&platform.arch)
    {
        return false;
    }
    if let Some(os_version) = &pred.os_version {
        // Predicate fixes os_version → host must declare a matching value.
        let Some(host_version) = &platform.os_version else { return false };
        if !os_version.contains(host_version) {
            return false;
        }
    }
    true
}

/// Returns `true` if a `support_matrix[]` row matches `platform`.
///
/// A row whose `os_version` is `None` matches every version of its `os`
/// (per the schema's "row applies to all versions of `os`" rule). When the
/// row pins an `os_version`, the platform's value must equal it; if the
/// platform has no `os_version`, the row does not match.
#[must_use]
pub fn matches_support(platform: &Platform, entry: &SupportEntry) -> bool {
    if entry.os != platform.os {
        return false;
    }
    if entry.arch != platform.arch {
        return false;
    }
    match (&entry.os_version, &platform.os_version) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(a), Some(b)) => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use containers_common::tooldb::{StringOrVec, SupportStatus};

    fn debian_13_amd64() -> Platform {
        Platform { os: "debian".into(), os_version: Some("13".into()), arch: "amd64".into() }
    }

    #[test]
    fn predicate_none_matches_anything() {
        assert!(matches_predicate(&debian_13_amd64(), None));
    }

    #[test]
    fn predicate_matches_when_all_fields_satisfied() {
        let pred = PlatformPredicate {
            os: Some(StringOrVec(vec!["debian".into(), "ubuntu".into()])),
            os_version: None,
            arch: Some(StringOrVec(vec!["amd64".into()])),
        };
        assert!(matches_predicate(&debian_13_amd64(), Some(&pred)));
    }

    #[test]
    fn predicate_rejects_wrong_os() {
        let pred = PlatformPredicate {
            os: Some(StringOrVec(vec!["alpine".into()])),
            os_version: None,
            arch: None,
        };
        assert!(!matches_predicate(&debian_13_amd64(), Some(&pred)));
    }

    #[test]
    fn predicate_rejects_wrong_arch() {
        let pred = PlatformPredicate {
            os: None,
            os_version: None,
            arch: Some(StringOrVec(vec!["arm64".into()])),
        };
        assert!(!matches_predicate(&debian_13_amd64(), Some(&pred)));
    }

    #[test]
    fn predicate_pinned_os_version_requires_match() {
        let pred = PlatformPredicate {
            os: None,
            os_version: Some(StringOrVec(vec!["12".into()])),
            arch: None,
        };
        assert!(!matches_predicate(&debian_13_amd64(), Some(&pred)));
    }

    #[test]
    fn predicate_pinned_os_version_rejects_missing_host_version() {
        let pred = PlatformPredicate {
            os: None,
            os_version: Some(StringOrVec(vec!["13".into()])),
            arch: None,
        };
        let host = Platform { os: "debian".into(), os_version: None, arch: "amd64".into() };
        assert!(!matches_predicate(&host, Some(&pred)));
    }

    fn entry(os: &str, os_version: Option<&str>, arch: &str) -> SupportEntry {
        SupportEntry {
            os: os.into(),
            os_version: os_version.map(Into::into),
            arch: arch.into(),
            status: SupportStatus::Supported,
            notes: None,
            reason: None,
            tracking_url: None,
            recheck_at: None,
        }
    }

    #[test]
    fn support_row_with_explicit_version_matches_only_that_version() {
        let row = entry("debian", Some("13"), "amd64");
        assert!(matches_support(&debian_13_amd64(), &row));

        let other =
            Platform { os: "debian".into(), os_version: Some("12".into()), arch: "amd64".into() };
        assert!(!matches_support(&other, &row));
    }

    #[test]
    fn support_row_without_version_matches_all_versions() {
        let row = entry("alpine", None, "amd64");
        let p1 =
            Platform { os: "alpine".into(), os_version: Some("3.21".into()), arch: "amd64".into() };
        let p2 =
            Platform { os: "alpine".into(), os_version: Some("3.18".into()), arch: "amd64".into() };
        assert!(matches_support(&p1, &row));
        assert!(matches_support(&p2, &row));
    }

    #[test]
    fn support_row_rejects_when_pinned_version_differs() {
        let row = entry("debian", Some("13"), "amd64");
        let host = Platform { os: "debian".into(), os_version: None, arch: "amd64".into() };
        assert!(!matches_support(&host, &row));
    }
}
