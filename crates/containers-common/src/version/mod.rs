//! Centralized version parser and constraint comparator.
//!
//! This module is the single source of truth for parsing version strings
//! and evaluating version constraints across the containers ecosystem
//! (containers-db validator/linter, luggage resolver, stibbons CLI,
//! version-bump automation). One library, one grammar, one bug class
//! retired.
//!
//! # Quick start
//!
//! ```
//! use containers_common::version::{Constraint, Version, VersionStyle};
//!
//! let v = Version::parse("v1.7.0", VersionStyle::Semver).unwrap();
//! let c = Constraint::parse(">=1.5, <2", VersionStyle::Semver).unwrap();
//! assert!(c.matches(&v));
//! ```
//!
//! # Supported grammar
//!
//! | Form          | Meaning                          |
//! | ------------- | -------------------------------- |
//! | `1.95.0`      | exact match                      |
//! | `>=1.7.0`     | minimum                          |
//! | `>=1.7, <2`   | bounded range                    |
//! | `1.7.x`       | prefix wildcard                  |
//! | `~1.7.0`      | patch-compatible (cargo-style)   |
//! | `^1.7.0`      | minor-compatible (cargo-style)   |
//! | `*` / `any`   | unconstrained                    |
//!
//! Tag-style prefixes `v`, `V`, `release-`, and `r<digit>` are stripped
//! at parse time so the catalog can store `1.95.0` while upstream tags
//! ship as `v1.95.0`.
//!
//! # Style modes
//!
//! See [`VersionStyle`]: `Semver` (default), `Prefix`, `Calver`, `Opaque`.
//! `Opaque` disables comparators entirely — only exact equality and
//! `*`/`any` are accepted, which is the safe fallback for tools whose
//! versions don't fit any common grammar.

mod constraint;
mod error;
mod parse;
mod style;

pub use constraint::Constraint;
pub use error::{IntersectError, VersionError};
pub use parse::Version;
pub use style::VersionStyle;
