//! Prefix-preserving version literals for round-tripping upstream tags.
//!
//! [`Version`] is lossy by design: `v1.95.0` and `1.95.0` parse to the
//! same canonical value, so comparators and constraint matchers see one
//! release no matter how upstream chooses to spell its tag. That is the
//! right behaviour for storage and comparison.
//!
//! It is the wrong behaviour at I/O boundaries. When auto-patch tooling
//! reads `v0.36.0` from a GitHub release and writes it back into a
//! workflow file, the `v` is not cosmetic — `aquasecurity/trivy-action@0.36.0`
//! does not resolve to a tag, while `aquasecurity/trivy-action@v0.36.0`
//! does. [`TaggedVersion`] is the boundary type that remembers which
//! prefix style the upstream tag used so writers can re-emit it.

use std::fmt;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::error::VersionError;
use super::parse::{Version, split_prefix};
use super::style::VersionStyle;

/// Closed set of recognised upstream tag prefixes.
///
/// One variant per literal form. Modelled as an enum rather than
/// `String` so writers cannot accidentally emit a prefix a downstream
/// reader doesn't recognise — adding a new convention is an explicit
/// schema change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TagPrefix {
    /// No prefix — e.g. `1.95.0`.
    #[default]
    Bare,
    /// Lowercase `v` — e.g. `v1.95.0`. Most common convention.
    V,
    /// Uppercase `V` — e.g. `V1.0.0`. Rare but seen on some legacy tools.
    #[serde(rename = "v-capital")]
    VCapital,
    /// Literal `release-` — e.g. `release-1.95.0`.
    Release,
    /// Lowercase `r` followed by a digit — e.g. `r1.2.3` (Ghidra-style).
    R,
}

impl TagPrefix {
    /// Detects the prefix on `s` and returns the matched variant along
    /// with the trailing version core.
    ///
    /// Returns `(TagPrefix::Bare, s)` when no recognised prefix matches.
    #[must_use]
    pub fn detect(s: &str) -> (Self, &str) {
        split_prefix(s)
    }

    /// Returns the literal characters this prefix renders as.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Bare => "",
            Self::V => "v",
            Self::VCapital => "V",
            Self::Release => "release-",
            Self::R => "r",
        }
    }
}

impl fmt::Display for TagPrefix {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A parsed version literal that remembers its upstream tag prefix.
///
/// Use this at I/O boundaries (release-fetchers, workflow updaters,
/// catalog writers) so the form an upstream publishes survives the
/// round-trip through internal storage and back out.
///
/// Equality and ordering delegate to the canonical [`Version`]:
/// `TaggedVersion::parse("v1.0.0")` and `TaggedVersion::parse("1.0.0")`
/// compare equal because they describe the same release. Use
/// [`Self::is_textually_identical`] when the textual form matters.
#[derive(Debug, Clone)]
pub struct TaggedVersion {
    /// Canonical comparable version. Use this for ordering and constraint matching.
    pub core: Version,
    /// Reference form the upstream tag was published in.
    pub prefix: TagPrefix,
}

impl TaggedVersion {
    /// Parses a version literal, preserving the matched tag prefix.
    ///
    /// # Errors
    ///
    /// Forwards every error from [`Version::parse`] — the prefix
    /// detection step is infallible.
    pub fn parse(s: &str, style: VersionStyle) -> Result<Self, VersionError> {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            return Err(VersionError::Empty);
        }
        let (prefix, _rest) = split_prefix(trimmed);
        // Delegate to Version::parse so relaxed-semver padding (`1.7` →
        // `1.7.0`) and style routing stay in one place. It will strip
        // the prefix again internally — that's fine; the recognised set
        // is the same.
        let core = Version::parse(trimmed, style)?;
        Ok(Self { core, prefix })
    }

    /// Constructs a [`TaggedVersion`] from an already-parsed canonical
    /// version plus an explicit prefix.
    ///
    /// Use this when a writer needs to emit a known core under a
    /// specific convention — e.g. "always render with `v` regardless
    /// of how the user typed it on the CLI".
    #[must_use]
    pub const fn new(core: Version, prefix: TagPrefix) -> Self {
        Self { core, prefix }
    }

    /// Borrows the canonical [`Version`] for comparison or constraint matching.
    #[must_use]
    pub const fn as_canonical(&self) -> &Version {
        &self.core
    }

    /// Returns a copy with the prefix replaced.
    #[must_use]
    pub const fn with_prefix(mut self, prefix: TagPrefix) -> Self {
        self.prefix = prefix;
        self
    }

    /// True when both the prefix and the canonical core match.
    ///
    /// Stricter than `==`, which compares only the canonical core. Use
    /// in assertions where the rendered form is the contract — e.g. a
    /// writer test verifying it emits the form a consumer requires.
    #[must_use]
    pub fn is_textually_identical(&self, other: &Self) -> bool {
        self.prefix == other.prefix && self.core == other.core
    }
}

impl fmt::Display for TaggedVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", self.prefix, self.core)
    }
}

impl PartialEq for TaggedVersion {
    fn eq(&self, other: &Self) -> bool {
        self.core == other.core
    }
}

impl Eq for TaggedVersion {}

impl PartialOrd for TaggedVersion {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TaggedVersion {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.core.cmp(&other.core)
    }
}

impl Hash for TaggedVersion {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.core.hash(state);
    }
}

impl Serialize for TaggedVersion {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for TaggedVersion {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        // Default to Semver for serde — mirrors the convention used by
        // `Version`'s Deserialize. Callers needing a different style
        // should deserialize as String and route through `Self::parse`.
        Self::parse(&s, VersionStyle::Semver).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_returns_bare_when_no_match() {
        let (prefix, rest) = TagPrefix::detect("1.95.0");
        assert_eq!(prefix, TagPrefix::Bare);
        assert_eq!(rest, "1.95.0");
    }

    #[test]
    fn as_str_round_trips_via_display() {
        for prefix in
            [TagPrefix::Bare, TagPrefix::V, TagPrefix::VCapital, TagPrefix::Release, TagPrefix::R]
        {
            assert_eq!(format!("{prefix}"), prefix.as_str());
        }
    }

    #[test]
    fn with_prefix_replaces_only_the_prefix() {
        let original = TaggedVersion::parse("0.36.0", VersionStyle::Semver).unwrap();
        let v_prefixed = original.clone().with_prefix(TagPrefix::V);
        assert_eq!(v_prefixed.core, original.core);
        assert_eq!(v_prefixed.prefix, TagPrefix::V);
        assert_eq!(format!("{v_prefixed}"), "v0.36.0");
    }
}
