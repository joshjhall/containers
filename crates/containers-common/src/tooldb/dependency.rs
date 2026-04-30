//! `Dependency` — a typed reference to another catalog tool that must be
//! present in the resolver's view of an install plan.
//!
//! Mirrors the `Dependency` definition shared by `requires[]` and
//! `install_methods[].dependencies[]` in `version.schema.json`.

use serde::{Deserialize, Serialize};

/// Reference to another catalog tool.
///
/// `version` and `version_constraint` are mutually exclusive; the schema
/// enforces this with a `oneOf`. Both omitted means "take whatever the
/// resolver picks".
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Dependency {
    /// Target tool's id.
    pub tool: String,
    /// Exact version pin. Mutually exclusive with `version_constraint`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Comparator expression. Mutually exclusive with `version`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_constraint: Option<String>,
    /// When this dep is needed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub purpose: Option<DependencyPurpose>,
    /// Whether the resolver must refuse to install when the dep is unmet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    /// Optional narrowing — restrict this dep to the listed distros.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platforms: Option<Vec<String>>,
}

/// When a dependency is needed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DependencyPurpose {
    /// Present at install time only.
    Build,
    /// Needed every time the tool runs.
    Runtime,
    /// Needed throughout (default).
    #[default]
    Both,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bare_tool_reference() {
        let json = r#"{ "tool": "ca_certificates" }"#;
        let dep: Dependency = serde_json::from_str(json).unwrap();
        assert_eq!(dep.tool, "ca_certificates");
        assert!(dep.version.is_none());
        assert!(dep.version_constraint.is_none());
    }

    #[test]
    fn parses_pinned_dependency() {
        let json = r#"{ "tool": "openssl", "version": "3.0.0", "purpose": "runtime" }"#;
        let dep: Dependency = serde_json::from_str(json).unwrap();
        assert_eq!(dep.version.as_deref(), Some("3.0.0"));
        assert_eq!(dep.purpose, Some(DependencyPurpose::Runtime));
    }

    #[test]
    fn parses_constraint_dependency() {
        let json = r#"{ "tool": "rust", "version_constraint": ">=1.85" }"#;
        let dep: Dependency = serde_json::from_str(json).unwrap();
        assert_eq!(dep.version_constraint.as_deref(), Some(">=1.85"));
    }

    #[test]
    fn purpose_default() {
        assert_eq!(DependencyPurpose::default(), DependencyPurpose::Both);
    }
}
