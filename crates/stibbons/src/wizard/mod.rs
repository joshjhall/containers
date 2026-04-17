//! Interactive TUI wizard for project setup.
//!
//! Ports the Go charmbracelet/huh wizard to Rust using the `inquire` crate.
//! Walks the user through 5 steps: project config, language selection,
//! dev tools, cloud/infrastructure, and tools/services.

mod review;
mod steps;

use std::collections::HashSet;

use containers_common::feature::Registry;

/// Holds the user's selections from the interactive wizard.
#[derive(Debug, Clone)]
pub struct WizardResult {
    pub project_name: String,
    pub username: String,
    pub base_image: String,
    pub containers_dir: String,
    /// All explicitly selected feature IDs (merged from all steps).
    pub features: HashSet<String>,
}

/// Pre-filled defaults for the wizard.
#[derive(Debug, Clone)]
pub struct WizardDefaults {
    pub project_name: String,
    pub username: String,
    pub base_image: String,
    pub containers_dir: String,
}

impl Default for WizardDefaults {
    fn default() -> Self {
        Self {
            project_name: String::new(),
            username: "developer".into(),
            base_image: "debian:trixie-slim".into(),
            containers_dir: "containers".into(),
        }
    }
}

/// Runs the interactive TUI wizard and returns the user's selections.
///
/// # Errors
///
/// Returns an error if any prompt fails or the user cancels.
pub fn run_wizard(
    reg: &Registry,
    defaults: &WizardDefaults,
) -> Result<WizardResult, Box<dyn std::error::Error>> {
    // Step 1: Project configuration
    let (project_name, username, base_image, containers_dir) = steps::project_config(defaults)?;

    // Step 2: Language selection
    let selected_langs = steps::language_selection(reg)?;

    // Step 3: Dev tools (only if languages were selected)
    let selected_dev =
        if selected_langs.is_empty() { Vec::new() } else { steps::dev_tool_selection(reg)? };

    // Step 4: Cloud & infrastructure
    let selected_cloud = steps::cloud_selection(reg)?;

    // Step 5: Tools & services
    let selected_tools = steps::tool_selection(reg)?;

    // Merge all selections into a single feature set
    let mut features = HashSet::new();
    for id in selected_langs {
        features.insert(id);
    }
    for id in selected_dev {
        features.insert(id);
    }
    for id in selected_cloud {
        features.insert(id);
    }
    for id in selected_tools {
        features.insert(id);
    }

    let result = WizardResult { project_name, username, base_image, containers_dir, features };

    // Review step
    review::run_review(reg, &result)?;

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wizard_defaults() {
        let defaults = WizardDefaults::default();
        assert_eq!(defaults.username, "developer");
        assert_eq!(defaults.base_image, "debian:trixie-slim");
        assert_eq!(defaults.containers_dir, "containers");
    }

    #[test]
    fn wizard_result_features_merge() {
        let result = WizardResult {
            project_name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            containers_dir: "containers".into(),
            features: ["python", "python_dev", "docker"].iter().map(|s| (*s).to_string()).collect(),
        };
        assert_eq!(result.features.len(), 3);
        assert!(result.features.contains("python"));
        assert!(result.features.contains("python_dev"));
        assert!(result.features.contains("docker"));
    }
}
