//! Version literal parsing.
//!
//! This module owns the [`Version`] enum and the prefix-tolerance helper
//! used by both [`Version::parse`] and constraint parsing.

use std::fmt;

use super::error::VersionError;
use super::style::VersionStyle;

/// Strips a single tag-style prefix from a version literal.
///
/// Recognised prefixes (longest first): `release-`, `v`, `V`, and `r`
/// when followed by a digit. The function only strips at the start; it
/// does not recurse. This is used at parse time so the catalog can store
/// `1.95.0` while upstream tags ship as `v1.95.0` or `release-1.95.0`.
#[must_use]
pub(super) fn strip_prefix(s: &str) -> &str {
    if let Some(rest) = s.strip_prefix("release-") {
        return rest;
    }
    if let Some(rest) = s.strip_prefix('v').or_else(|| s.strip_prefix('V')) {
        return rest;
    }
    if let Some(rest) = s.strip_prefix('r')
        && rest.chars().next().is_some_and(|c| c.is_ascii_digit())
    {
        return rest;
    }
    s
}

/// A parsed version literal.
///
/// The variant is determined by the [`VersionStyle`] passed to [`Version::parse`].
/// `Prefix` mode produces `Self::Semver` like `Semver` mode does — the
/// distinction is purely a documentation hint at the data layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Version {
    /// Semver-shaped version (also used by `Prefix` mode).
    Semver(semver::Version),
    /// Calver: dot-separated non-negative integer components, ordered lexicographically.
    Calver(Vec<u64>),
    /// Opaque: stored verbatim, only exact equality is meaningful.
    Opaque(String),
}

impl Version {
    /// Parses a version literal under the given style.
    ///
    /// # Errors
    ///
    /// Returns [`VersionError::Empty`] if `s` is empty after trimming,
    /// [`VersionError::WildcardInVersion`] if `s` contains `x`, `X`, or `*`,
    /// [`VersionError::Calver`] if a calver component is non-numeric, or
    /// [`VersionError::Semver`] if the semver crate rejects the input.
    pub fn parse(s: &str, style: VersionStyle) -> Result<Self, VersionError> {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            return Err(VersionError::Empty);
        }

        if matches!(style, VersionStyle::Semver | VersionStyle::Prefix | VersionStyle::Calver)
            && contains_wildcard(trimmed)
        {
            return Err(VersionError::WildcardInVersion { input: trimmed.to_owned() });
        }

        match style {
            VersionStyle::Semver | VersionStyle::Prefix => {
                let stripped = strip_prefix(trimmed);
                let parsed = parse_semver_relaxed(stripped).map_err(|source| {
                    VersionError::Semver { input: trimmed.to_owned(), style, source }
                })?;
                Ok(Self::Semver(parsed))
            }
            VersionStyle::Calver => {
                let stripped = strip_prefix(trimmed);
                let mut parts = Vec::new();
                for part in stripped.split('.') {
                    let n: u64 = part
                        .parse()
                        .map_err(|_| VersionError::Calver { input: trimmed.to_owned() })?;
                    parts.push(n);
                }
                if parts.is_empty() {
                    return Err(VersionError::Calver { input: trimmed.to_owned() });
                }
                Ok(Self::Calver(parts))
            }
            VersionStyle::Opaque => Ok(Self::Opaque(trimmed.to_owned())),
        }
    }
}

/// Parses a version, padding missing minor/patch components with zero.
///
/// `semver::Version::parse` requires `major.minor.patch`; the catalog
/// often holds `1.7` or even `2`. This helper accepts those forms.
fn parse_semver_relaxed(s: &str) -> Result<semver::Version, semver::Error> {
    let core_end = s.find(['-', '+']).unwrap_or(s.len());
    let (core, suffix) = s.split_at(core_end);
    let dots = core.matches('.').count();
    let padded_core = match dots {
        0 => format!("{core}.0.0"),
        1 => format!("{core}.0"),
        _ => core.to_owned(),
    };
    let combined = format!("{padded_core}{suffix}");
    semver::Version::parse(&combined)
}

fn contains_wildcard(s: &str) -> bool {
    s.chars().any(|c| c == 'x' || c == 'X' || c == '*')
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Semver(v) => write!(f, "{v}"),
            Self::Calver(parts) => {
                let mut first = true;
                for p in parts {
                    if !first {
                        f.write_str(".")?;
                    }
                    first = false;
                    write!(f, "{p}")?;
                }
                Ok(())
            }
            Self::Opaque(s) => f.write_str(s),
        }
    }
}

impl serde::Serialize for Version {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> serde::Deserialize<'de> for Version {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        // Default to Semver for serde — consumers who need a different
        // style should deserialize as String and call `Version::parse`.
        Self::parse(&s, VersionStyle::Semver).map_err(serde::de::Error::custom)
    }
}
