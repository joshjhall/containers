//! Feature catalog and dependency resolution for the containers build system.
//!
//! Each [`Feature`] represents a toggleable container capability (language runtime,
//! tool, cloud CLI, etc.) controlled by a Docker build argument. The [`Registry`]
//! holds the canonical ordered list of all features, and [`resolve`] expands a set
//! of explicitly selected features by following dependency chains.

mod registry;
mod resolve;

pub use registry::Registry;
pub use resolve::resolve;

use std::collections::HashSet;

/// Groups features in the wizard UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Category {
    Language,
    Cloud,
    Tool,
    Database,
    Ai,
}

/// A single toggleable container feature.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Feature {
    /// Canonical lowercase identifier (e.g. `"python"`, `"python_dev"`).
    pub id: String,

    /// Docker build argument name (e.g. `"INCLUDE_PYTHON"`).
    pub build_arg: String,

    /// Human-readable name shown in the wizard.
    pub display_name: String,

    /// Short description for the wizard.
    pub description: String,

    /// Groups the feature in wizard steps.
    pub category: Category,

    /// Build arg for version selection (e.g. `"PYTHON_VERSION"`).
    pub version_arg: Option<String>,

    /// Default version from the schema.
    pub default_version: Option<String>,

    /// Env example filename under `examples/env/` (e.g. `"python.env"`).
    pub env_file: Option<String>,

    /// Feature IDs that this feature depends on.
    pub requires: Vec<String>,

    /// Feature IDs that auto-enable this feature.
    pub implied_by: Vec<String>,

    /// Whether this is a `*_DEV` companion feature.
    pub is_dev: bool,

    /// Links a `*_DEV` feature to its base language feature ID.
    pub base_lang: Option<String>,

    /// Named Docker volumes for caching (e.g. `"pip-cache:/cache/pip"`).
    pub cache_volumes: Vec<String>,

    /// VS Code extension IDs to recommend.
    pub vscode_extensions: Vec<String>,
}

impl Default for Feature {
    fn default() -> Self {
        Self {
            id: String::new(),
            build_arg: String::new(),
            display_name: String::new(),
            description: String::new(),
            category: Category::Tool,
            version_arg: None,
            default_version: None,
            env_file: None,
            requires: Vec::new(),
            implied_by: Vec::new(),
            is_dev: false,
            base_lang: None,
            cache_volumes: Vec::new(),
            vscode_extensions: Vec::new(),
        }
    }
}

/// Tracks which features the user explicitly chose vs auto-resolved.
#[derive(Debug, Clone)]
pub struct Selection {
    /// Features the user selected.
    pub explicit: HashSet<String>,

    /// Features added by dependency resolution.
    pub auto_resolved: HashSet<String>,
}

impl Selection {
    /// Returns a combined set of all selected feature IDs.
    #[must_use]
    pub fn all(&self) -> HashSet<String> {
        self.explicit.union(&self.auto_resolved).cloned().collect()
    }

    /// Returns true if the feature is in the selection (explicit or auto).
    #[must_use]
    pub fn has(&self, id: &str) -> bool {
        self.explicit.contains(id) || self.auto_resolved.contains(id)
    }
}
