//! Version constraint expressions and the operations on them.

use std::fmt;

use semver::{Comparator, Op, Version as SemverVersion, VersionReq};

use super::error::{IntersectError, VersionError};
use super::parse::{Version, strip_prefix};
use super::style::VersionStyle;

/// A parsed version constraint expression.
///
/// The variant is determined by the [`VersionStyle`] passed to
/// [`Constraint::parse`]. Use [`Constraint::matches`] to test a [`Version`]
/// against the constraint, and [`Constraint::intersect`] to combine two
/// constraints (e.g. when multiple consumers depend on the same tool with
/// different `requires`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Constraint {
    /// Matches every version. Produced by `*` or `any` in any style.
    Any,
    /// Semver-style constraint (also produced by `Prefix` mode).
    Semver(VersionReq),
    /// Calver pin: matches the exact tuple.
    CalverExact(Vec<u64>),
    /// Calver range with optional inclusive/exclusive bounds.
    CalverRange {
        /// Lower bound, if any.
        lo: Option<(Vec<u64>, bool)>,
        /// Upper bound, if any.
        hi: Option<(Vec<u64>, bool)>,
    },
    /// Opaque pin: matches only the exact string.
    OpaqueExact(String),
}

impl Constraint {
    /// Parses a constraint expression under the given style.
    ///
    /// # Errors
    ///
    /// Returns [`VersionError::Empty`] for empty input,
    /// [`VersionError::OpaqueComparator`] when a comparator is used in
    /// `Opaque` mode, [`VersionError::Calver`] for malformed calver
    /// components, or [`VersionError::Semver`] when the underlying
    /// `semver` crate rejects the input.
    pub fn parse(s: &str, style: VersionStyle) -> Result<Self, VersionError> {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            return Err(VersionError::Empty);
        }
        if is_any(trimmed) {
            return Ok(Self::Any);
        }

        match style {
            VersionStyle::Semver | VersionStyle::Prefix => {
                let normalized = normalize_semver_constraint(trimmed);
                let req = VersionReq::parse(&normalized).map_err(|source| {
                    VersionError::Semver { input: trimmed.to_owned(), style, source }
                })?;
                Ok(Self::Semver(req))
            }
            VersionStyle::Calver => parse_calver_constraint(trimmed),
            VersionStyle::Opaque => parse_opaque_constraint(trimmed),
        }
    }

    /// Returns `true` if `v` satisfies this constraint.
    ///
    /// Cross-style mismatches always return `false` — a `Semver`
    /// constraint never matches a `Calver` version, and so on.
    #[must_use]
    pub fn matches(&self, v: &Version) -> bool {
        match (self, v) {
            (Self::Any, _) => true,
            (Self::Semver(req), Version::Semver(ver)) => req.matches(ver),
            (Self::CalverExact(parts), Version::Calver(other)) => parts == other,
            (Self::CalverRange { lo, hi }, Version::Calver(other)) => {
                lo.as_ref().is_none_or(|(b, incl)| calver_cmp(other, b, *incl, true))
                    && hi.as_ref().is_none_or(|(b, incl)| calver_cmp(other, b, *incl, false))
            }
            (Self::OpaqueExact(s), Version::Opaque(other)) => s == other,
            _ => false,
        }
    }

    /// Returns the intersection of `self` and `other`.
    ///
    /// # Errors
    ///
    /// Returns [`IntersectError::Empty`] if no version satisfies both
    /// constraints, and [`IntersectError::StyleMismatch`] if the two
    /// constraints belong to different version styles (e.g. semver vs
    /// calver — the data layer should never produce this combination).
    pub fn intersect(&self, other: &Self) -> Result<Self, IntersectError> {
        match (self, other) {
            (Self::Any, x) | (x, Self::Any) => Ok(x.clone()),
            (Self::Semver(a), Self::Semver(b)) => intersect_semver(a, b, self, other),
            (Self::CalverExact(a), Self::CalverExact(b)) => {
                if a == b {
                    Ok(Self::CalverExact(a.clone()))
                } else {
                    Err(IntersectError::Empty {
                        left: format!("{self}"),
                        right: format!("{other}"),
                    })
                }
            }
            (
                Self::CalverRange { lo: a_lo, hi: a_hi },
                Self::CalverRange { lo: b_lo, hi: b_hi },
            ) => {
                let lo = max_calver_bound(a_lo.as_ref(), b_lo.as_ref(), true);
                let hi = max_calver_bound(a_hi.as_ref(), b_hi.as_ref(), false);
                let combined = Self::CalverRange { lo: lo.cloned(), hi: hi.cloned() };
                if calver_range_satisfiable(&combined) {
                    Ok(combined)
                } else {
                    Err(IntersectError::Empty {
                        left: format!("{self}"),
                        right: format!("{other}"),
                    })
                }
            }
            (Self::CalverRange { .. }, Self::CalverExact(_))
            | (Self::CalverExact(_), Self::CalverRange { .. }) => {
                let (range, exact) = match self {
                    Self::CalverExact(_) => (other, self),
                    _ => (self, other),
                };
                if range.matches(&match exact {
                    Self::CalverExact(p) => Version::Calver(p.clone()),
                    _ => unreachable!(),
                }) {
                    Ok(exact.clone())
                } else {
                    Err(IntersectError::Empty {
                        left: format!("{self}"),
                        right: format!("{other}"),
                    })
                }
            }
            (Self::OpaqueExact(a), Self::OpaqueExact(b)) => {
                if a == b {
                    Ok(Self::OpaqueExact(a.clone()))
                } else {
                    Err(IntersectError::Empty {
                        left: format!("{self}"),
                        right: format!("{other}"),
                    })
                }
            }
            _ => Err(IntersectError::StyleMismatch),
        }
    }
}

// ===== semver helpers =====

fn is_any(s: &str) -> bool {
    let t = s.trim().to_ascii_lowercase();
    t == "*" || t == "any"
}

/// Normalises a semver constraint string before handing it to `VersionReq::parse`.
///
/// Strips `v`/`V`/`release-`/`r<digit>` prefixes from individual
/// version tokens and lowercases `X` to `x` (the semver crate accepts
/// both, but we normalize for consistency).
fn normalize_semver_constraint(s: &str) -> String {
    s.split(',').map(|part| normalize_one_comparator(part.trim())).collect::<Vec<_>>().join(", ")
}

fn normalize_one_comparator(s: &str) -> String {
    // A comparator is an optional operator (`>=`, `<=`, `>`, `<`, `=`,
    // `~`, `^`) followed by a version-like token. Strip prefix from the
    // version-like token. A bare literal becomes an exact match — the
    // issue's grammar table says `1.95.0` is exact, but the semver
    // crate would otherwise interpret it as `^1.95.0`.
    let (op, rest) = split_op(s);
    let stripped = strip_prefix(rest.trim());
    if op.is_empty() {
        if contains_wildcard(stripped) { stripped.to_owned() } else { format!("={stripped}") }
    } else {
        format!("{op}{stripped}")
    }
}

fn contains_wildcard(s: &str) -> bool {
    s.chars().any(|c| c == 'x' || c == 'X' || c == '*')
}

fn split_op(s: &str) -> (&str, &str) {
    for op in [">=", "<=", "==", "~=", ">", "<", "=", "~", "^"] {
        if let Some(rest) = s.strip_prefix(op) {
            return (op, rest);
        }
    }
    ("", s)
}

fn intersect_semver(
    a: &VersionReq,
    b: &VersionReq,
    self_for_msg: &Constraint,
    other_for_msg: &Constraint,
) -> Result<Constraint, IntersectError> {
    let mut comparators = a.comparators.clone();
    comparators.extend(b.comparators.iter().cloned());
    let combined = VersionReq { comparators };
    if semver_req_satisfiable(&combined) {
        Ok(Constraint::Semver(combined))
    } else {
        Err(IntersectError::Empty {
            left: format!("{self_for_msg}"),
            right: format!("{other_for_msg}"),
        })
    }
}

/// Tests satisfiability of a combined `VersionReq` by deriving an
/// interval `[lo, hi)` (or its inclusive variants) from the comparator
/// list and checking it's non-empty.
fn semver_req_satisfiable(req: &VersionReq) -> bool {
    let mut lo: Option<(SemverVersion, bool)> = None;
    let mut hi: Option<(SemverVersion, bool)> = None;
    let mut pin: Option<SemverVersion> = None;

    for c in &req.comparators {
        match c.op {
            Op::Exact => {
                let v = comparator_lower(c);
                if let Some(p) = &pin
                    && *p != v
                {
                    return false;
                }
                pin = Some(v.clone());
                lo = max_lo(lo.take(), Some((v.clone(), true)));
                hi = min_hi(hi.take(), Some((v, true)));
            }
            Op::Greater => {
                lo = max_lo(lo.take(), Some((comparator_lower(c), false)));
            }
            Op::GreaterEq => {
                lo = max_lo(lo.take(), Some((comparator_lower(c), true)));
            }
            Op::Less => {
                hi = min_hi(hi.take(), Some((comparator_lower(c), false)));
            }
            Op::LessEq => {
                hi = min_hi(hi.take(), Some((comparator_lower(c), true)));
            }
            Op::Tilde => {
                let l = comparator_lower(c);
                let u = tilde_upper(c);
                lo = max_lo(lo.take(), Some((l, true)));
                hi = min_hi(hi.take(), Some((u, false)));
            }
            Op::Caret => {
                let l = comparator_lower(c);
                let u = caret_upper(c);
                lo = max_lo(lo.take(), Some((l, true)));
                hi = min_hi(hi.take(), Some((u, false)));
            }
            Op::Wildcard => {
                let (l, u) = wildcard_bounds(c);
                lo = max_lo(lo.take(), Some((l, true)));
                hi = min_hi(hi.take(), Some((u, false)));
            }
            _ => {} // future-compat: ignore unknown ops in satisfiability check
        }
    }

    if let Some(p) = pin {
        if let Some((l, incl)) = &lo
            && (*l > p || (*l == p && !incl))
        {
            return false;
        }
        if let Some((h, incl)) = &hi
            && (*h < p || (*h == p && !incl))
        {
            return false;
        }
        return true;
    }

    match (&lo, &hi) {
        (Some((l, li)), Some((h, hi_inc))) => match l.cmp(h) {
            std::cmp::Ordering::Less => true,
            std::cmp::Ordering::Equal => *li && *hi_inc,
            std::cmp::Ordering::Greater => false,
        },
        _ => true,
    }
}

fn comparator_lower(c: &Comparator) -> SemverVersion {
    SemverVersion {
        major: c.major,
        minor: c.minor.unwrap_or(0),
        patch: c.patch.unwrap_or(0),
        pre: c.pre.clone(),
        build: semver::BuildMetadata::EMPTY,
    }
}

fn tilde_upper(c: &Comparator) -> SemverVersion {
    // `~1.2.3` → <1.3.0; `~1.2` → <1.3.0; `~1` → <2.0.0.
    if c.minor.is_some() {
        SemverVersion::new(c.major, c.minor.unwrap_or(0).saturating_add(1), 0)
    } else {
        SemverVersion::new(c.major.saturating_add(1), 0, 0)
    }
}

fn caret_upper(c: &Comparator) -> SemverVersion {
    // Caret bumps the leftmost non-zero component.
    let major = c.major;
    let minor = c.minor.unwrap_or(0);
    let patch = c.patch.unwrap_or(0);
    if major > 0 || c.minor.is_none() {
        SemverVersion::new(major.saturating_add(1), 0, 0)
    } else if minor > 0 || c.patch.is_none() {
        SemverVersion::new(major, minor.saturating_add(1), 0)
    } else {
        SemverVersion::new(major, minor, patch.saturating_add(1))
    }
}

fn wildcard_bounds(c: &Comparator) -> (SemverVersion, SemverVersion) {
    // `*` is empty comparator list (handled upstream); here we have a
    // partial wildcard like `1.*` (minor=None) or `1.2.*` (patch=None).
    let major = c.major;
    let lower = SemverVersion::new(major, c.minor.unwrap_or(0), 0);
    let upper = if c.minor.is_none() {
        SemverVersion::new(major.saturating_add(1), 0, 0)
    } else {
        SemverVersion::new(major, c.minor.unwrap_or(0).saturating_add(1), 0)
    };
    (lower, upper)
}

fn max_lo(
    a: Option<(SemverVersion, bool)>,
    b: Option<(SemverVersion, bool)>,
) -> Option<(SemverVersion, bool)> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some((av, ai)), Some((bv, bi))) => match av.cmp(&bv) {
            std::cmp::Ordering::Greater => Some((av, ai)),
            std::cmp::Ordering::Less => Some((bv, bi)),
            std::cmp::Ordering::Equal => Some((av, ai && bi)),
        },
    }
}

fn min_hi(
    a: Option<(SemverVersion, bool)>,
    b: Option<(SemverVersion, bool)>,
) -> Option<(SemverVersion, bool)> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some((av, ai)), Some((bv, bi))) => match av.cmp(&bv) {
            std::cmp::Ordering::Less => Some((av, ai)),
            std::cmp::Ordering::Greater => Some((bv, bi)),
            std::cmp::Ordering::Equal => Some((av, ai && bi)),
        },
    }
}

// ===== calver helpers =====

fn parse_calver_constraint(s: &str) -> Result<Constraint, VersionError> {
    // Comma-separated range, e.g. `>=2026.01.01, <2027.01.01`. Must be
    // checked before the single-comparator branch — a comma-joined
    // string starts with `>=` and would otherwise be misread.
    if s.contains(',') {
        let mut lo: Option<(Vec<u64>, bool)> = None;
        let mut hi: Option<(Vec<u64>, bool)> = None;
        for part in s.split(',') {
            let part = part.trim();
            let (op, rest) = peel_comparator(part)
                .ok_or_else(|| VersionError::Calver { input: s.to_owned() })?;
            let parts = parse_calver_components(rest.trim(), s)?;
            match op {
                ">" => lo = Some((parts, false)),
                ">=" => lo = Some((parts, true)),
                "<" => hi = Some((parts, false)),
                "<=" => hi = Some((parts, true)),
                _ => return Err(VersionError::Calver { input: s.to_owned() }),
            }
        }
        return Ok(Constraint::CalverRange { lo, hi });
    }

    if let Some((op, rest)) = peel_comparator(s) {
        let parts = parse_calver_components(rest.trim(), s)?;
        let (lo, hi) = match op {
            ">" => (Some((parts, false)), None),
            ">=" => (Some((parts, true)), None),
            "<" => (None, Some((parts, false))),
            "<=" => (None, Some((parts, true))),
            "=" | "==" => return Ok(Constraint::CalverExact(parts)),
            _ => return Err(VersionError::Calver { input: s.to_owned() }),
        };
        return Ok(Constraint::CalverRange { lo, hi });
    }

    let parts = parse_calver_components(s, s)?;
    Ok(Constraint::CalverExact(parts))
}

fn peel_comparator(s: &str) -> Option<(&'static str, &str)> {
    for op in [">=", "<=", "==", ">", "<", "="] {
        if let Some(rest) = s.strip_prefix(op) {
            return Some((op, rest));
        }
    }
    None
}

fn parse_calver_components(token: &str, original: &str) -> Result<Vec<u64>, VersionError> {
    let stripped = strip_prefix(token);
    let mut parts = Vec::new();
    for part in stripped.split('.') {
        let n: u64 =
            part.parse().map_err(|_| VersionError::Calver { input: original.to_owned() })?;
        parts.push(n);
    }
    if parts.is_empty() {
        return Err(VersionError::Calver { input: original.to_owned() });
    }
    Ok(parts)
}

fn calver_cmp(value: &[u64], bound: &[u64], inclusive: bool, is_lower_bound: bool) -> bool {
    use std::cmp::Ordering;
    match value.cmp(bound) {
        Ordering::Equal => inclusive,
        Ordering::Greater => is_lower_bound,
        Ordering::Less => !is_lower_bound,
    }
}

#[allow(clippy::ref_option, clippy::option_if_let_else)]
fn max_calver_bound<'a>(
    a: Option<&'a (Vec<u64>, bool)>,
    b: Option<&'a (Vec<u64>, bool)>,
    is_lower: bool,
) -> Option<&'a (Vec<u64>, bool)> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some(av), Some(bv)) => {
            use std::cmp::Ordering;
            match av.0.cmp(&bv.0) {
                Ordering::Greater => {
                    if is_lower {
                        Some(av)
                    } else {
                        Some(bv)
                    }
                }
                Ordering::Less => {
                    if is_lower {
                        Some(bv)
                    } else {
                        Some(av)
                    }
                }
                Ordering::Equal => {
                    if av.1 && !bv.1 || !av.1 && bv.1 {
                        if av.1 { Some(bv) } else { Some(av) }
                    } else {
                        Some(av)
                    }
                }
            }
        }
    }
}

fn calver_range_satisfiable(c: &Constraint) -> bool {
    let Constraint::CalverRange { lo, hi } = c else {
        return true;
    };
    match (lo, hi) {
        (Some((l, li)), Some((h, hi_inc))) => match l.cmp(h) {
            std::cmp::Ordering::Less => true,
            std::cmp::Ordering::Equal => *li && *hi_inc,
            std::cmp::Ordering::Greater => false,
        },
        _ => true,
    }
}

// ===== opaque helpers =====

fn parse_opaque_constraint(s: &str) -> Result<Constraint, VersionError> {
    // In opaque mode, anything that looks like a comparator is rejected.
    if peel_comparator(s).is_some() || s.contains(',') || s.contains('~') || s.contains('^') {
        return Err(VersionError::OpaqueComparator { input: s.to_owned() });
    }
    if s.chars().any(|c| c == 'x' || c == 'X' || c == '*') && !is_any(s) {
        return Err(VersionError::OpaqueComparator { input: s.to_owned() });
    }
    Ok(Constraint::OpaqueExact(s.to_owned()))
}

// ===== Display =====

impl fmt::Display for Constraint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Any => f.write_str("*"),
            Self::Semver(req) => write!(f, "{req}"),
            Self::CalverExact(parts) => write!(f, "={}", join_dots(parts)),
            Self::CalverRange { lo, hi } => {
                let wrote = if let Some((parts, incl)) = lo {
                    let op = if *incl { ">=" } else { ">" };
                    write!(f, "{op}{}", join_dots(parts))?;
                    true
                } else {
                    false
                };
                if let Some((parts, incl)) = hi {
                    if wrote {
                        f.write_str(", ")?;
                    }
                    let op = if *incl { "<=" } else { "<" };
                    write!(f, "{op}{}", join_dots(parts))?;
                }
                Ok(())
            }
            Self::OpaqueExact(s) => f.write_str(s),
        }
    }
}

fn join_dots(parts: &[u64]) -> String {
    parts.iter().map(u64::to_string).collect::<Vec<_>>().join(".")
}

impl serde::Serialize for Constraint {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> serde::Deserialize<'de> for Constraint {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::parse(&s, VersionStyle::Semver).map_err(serde::de::Error::custom)
    }
}
