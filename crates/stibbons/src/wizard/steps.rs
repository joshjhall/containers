//! Individual wizard step implementations using `inquire` prompts.

use containers_common::feature::{Category, Registry};
use inquire::validator::Validation;
use inquire::{MultiSelect, Select, Text};

use super::WizardDefaults;

/// Step 1: Project configuration — name, username, base image, containers dir.
pub fn project_config(
    defaults: &WizardDefaults,
) -> Result<(String, String, String, String), Box<dyn std::error::Error>> {
    let project_name = Text::new("Project name:")
        .with_help_message("Used for workspace directory and compose project")
        .with_default(&defaults.project_name)
        .with_validator(|input: &str| {
            if input.is_empty() {
                Ok(Validation::Invalid("Project name is required".into()))
            } else if input.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') {
                Ok(Validation::Valid)
            } else {
                Ok(Validation::Invalid(
                    "Only alphanumeric characters, hyphens, and underscores allowed".into(),
                ))
            }
        })
        .prompt()?;

    let username = Text::new("Container username:")
        .with_help_message("Non-root user inside the container")
        .with_default(&defaults.username)
        .prompt()?;

    let base_images = vec![
        "debian:trixie-slim — Debian 13 (stable)",
        "debian:bookworm-slim — Debian 12 (oldstable)",
        "debian:bullseye-slim — Debian 11 (EOL)",
    ];
    let default_idx =
        base_images.iter().position(|s| s.starts_with(&defaults.base_image)).unwrap_or(0);

    let selected_image =
        Select::new("Base image:", base_images).with_starting_cursor(default_idx).prompt()?;

    // Extract just the image name (before the " — " description)
    let base_image = selected_image.split(" — ").next().unwrap_or(selected_image).to_string();

    let containers_dir = Text::new("Containers submodule path:")
        .with_help_message("Relative path from project root to containers/")
        .with_default(&defaults.containers_dir)
        .prompt()?;

    Ok((project_name, username, base_image, containers_dir))
}

/// Step 2: Language selection — non-dev language runtimes.
pub fn language_selection(reg: &Registry) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let options: Vec<String> =
        reg.languages().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    if options.is_empty() {
        return Ok(Vec::new());
    }

    let ids: Vec<String> = reg.languages().map(|f| f.id.clone()).collect();

    let selected = MultiSelect::new("Languages & Runtimes:", options)
        .with_help_message("Select base language runtimes to include")
        .prompt()?;

    // Map display names back to IDs by index
    let all_display: Vec<String> =
        reg.languages().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    Ok(selected
        .iter()
        .filter_map(|s| all_display.iter().position(|d| d == s).map(|i| ids[i].clone()))
        .collect())
}

/// Step 3: Dev tool selection — LSP, formatters, linters per language.
pub fn dev_tool_selection(reg: &Registry) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let dev_features: Vec<_> = reg.by_category(Category::Language).filter(|f| f.is_dev).collect();

    if dev_features.is_empty() {
        return Ok(Vec::new());
    }

    let options: Vec<String> =
        dev_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    let ids: Vec<String> = dev_features.iter().map(|f| f.id.clone()).collect();

    let selected = MultiSelect::new("Dev Tools:", options)
        .with_help_message(
            "LSP, formatters, linters — each includes its base language runtime automatically",
        )
        .prompt()?;

    let all_display: Vec<String> =
        dev_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    Ok(selected
        .iter()
        .filter_map(|s| all_display.iter().position(|d| d == s).map(|i| ids[i].clone()))
        .collect())
}

/// Step 4: Cloud & infrastructure selection.
pub fn cloud_selection(reg: &Registry) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let cloud_features: Vec<_> = reg.by_category(Category::Cloud).collect();

    if cloud_features.is_empty() {
        return Ok(Vec::new());
    }

    let options: Vec<String> =
        cloud_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    let ids: Vec<String> = cloud_features.iter().map(|f| f.id.clone()).collect();

    let selected = MultiSelect::new("Cloud & Infrastructure:", options)
        .with_help_message("Select cloud tools to include")
        .prompt()?;

    let all_display: Vec<String> =
        cloud_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    Ok(selected
        .iter()
        .filter_map(|s| all_display.iter().position(|d| d == s).map(|i| ids[i].clone()))
        .collect())
}

/// Step 5: Tools & services — Tool, Database, AI categories (excluding cron/bindfs).
pub fn tool_selection(reg: &Registry) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let categories = [Category::Tool, Category::Database, Category::Ai];
    let tool_features: Vec<_> = categories
        .iter()
        .flat_map(|cat| reg.by_category(*cat))
        .filter(|f| f.id != "cron" && f.id != "bindfs")
        .collect();

    if tool_features.is_empty() {
        return Ok(Vec::new());
    }

    let options: Vec<String> =
        tool_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    let ids: Vec<String> = tool_features.iter().map(|f| f.id.clone()).collect();

    let selected = MultiSelect::new("Tools & Services:", options)
        .with_help_message("Select additional tools")
        .prompt()?;

    let all_display: Vec<String> =
        tool_features.iter().map(|f| format!("{} — {}", f.display_name, f.description)).collect();

    Ok(selected
        .iter()
        .filter_map(|s| all_display.iter().position(|d| d == s).map(|i| ids[i].clone()))
        .collect())
}
