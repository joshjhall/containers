//! [`VersionStyle`] — the four parser modes supported by this crate.

/// The grammar a version string is interpreted under.
///
/// Tooldb tools tag themselves with one of these so the parser knows
/// how to read their version literals and constraints. Defaulting to
/// `Semver` is safe for the common case.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Default, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum VersionStyle {
    /// Semantic versioning (cargo / npm / `semver` crate). Default.
    #[default]
    Semver,
    /// Same grammar as `Semver`, but the data layer documents that
    /// upstream tags routinely carry arbitrary prefixes. Behaviourally
    /// identical to `Semver` in v1; reserved for future tightening.
    Prefix,
    /// Date-shaped versions (e.g. `2026.04.29`). Components are
    /// non-negative integers compared lexicographically.
    Calver,
    /// Genuinely freeform versions. Only exact equality and `*` / `any`
    /// are meaningful; comparators (`>=`, ranges, wildcards) are an
    /// error.
    Opaque,
}
