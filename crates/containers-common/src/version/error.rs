//! Error types returned by the version module.

use super::VersionStyle;

/// Failure to parse a version literal or constraint expression.
#[derive(Debug, thiserror::Error)]
pub enum VersionError {
    /// The string did not parse as a valid semver version or comparator.
    #[error("invalid {style:?} version `{input}`: {source}")]
    Semver {
        /// The original input that failed to parse.
        input: String,
        /// The style under which the parse was attempted.
        style: VersionStyle,
        /// The underlying error from the `semver` crate.
        #[source]
        source: semver::Error,
    },

    /// A calver component was not a non-negative integer.
    #[error("calver components must be non-negative integers, got `{input}`")]
    Calver {
        /// The original input.
        input: String,
    },

    /// A comparator was used in opaque mode (only exact equality and `*`/`any` are allowed).
    #[error("opaque mode does not support comparator `{input}`; only exact and `*`/`any` allowed")]
    OpaqueComparator {
        /// The disallowed input.
        input: String,
    },

    /// A wildcard appeared on the version side, where only literals are valid.
    #[error("wildcards (`x`, `*`) are not valid in a version literal: `{input}`")]
    WildcardInVersion {
        /// The disallowed input.
        input: String,
    },

    /// The input was empty.
    #[error("empty version string")]
    Empty,
}

/// Failure to compute the intersection of two constraints.
#[derive(Debug, thiserror::Error)]
pub enum IntersectError {
    /// The two constraints share no satisfying version.
    #[error("empty intersection: `{left}` ∩ `{right}` matches no version")]
    Empty {
        /// Left-hand operand string form.
        left: String,
        /// Right-hand operand string form.
        right: String,
    },

    /// The two constraints belong to different version styles.
    #[error("cannot intersect constraints of different version styles")]
    StyleMismatch,
}
