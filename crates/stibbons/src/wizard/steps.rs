//! Individual wizard step implementations using `inquire` prompts.

use containers_common::config::{is_ident_char, is_rel_path_char};
use containers_common::feature::{Category, Registry};
use inquire::validator::Validation;
use inquire::{MultiSelect, Select, Text};

use super::WizardDefaults;

/// Shared message for the two identifier-shaped prompts. Matches
/// [`is_ident_char`], which `IgorConfig::validate` enforces — the wizard must
/// not accept what the loader will later reject.
const IDENT_HELP: &str = "Only letters, digits, '-', '_', and '.' allowed";

/// The base images offered by the wizard, each as `"<image> — <description>"`.
///
/// Debian 11 (Bullseye) was removed at its LTS EOL (#933), so a config carrying
/// `debian:bullseye-slim` no longer matches any entry — see
/// [`default_base_image_index`] for what happens to such a default.
///
/// Always non-empty, which is what makes index 0 a valid fallback.
fn base_image_options() -> Vec<&'static str> {
    vec!["debian:trixie-slim — Debian 13 (stable)", "debian:bookworm-slim — Debian 12 (oldstable)"]
}

/// Resolves the starting cursor for the base-image prompt.
///
/// Matches `default` against the image name at the head of each option. A
/// default that no longer appears in the list — a stale config naming a base
/// image since dropped from the matrix — falls back to index 0 (the current
/// stable) rather than failing: the wizard is interactive, so the user sees and
/// confirms the pre-selected entry either way.
fn default_base_image_index(options: &[&str], default: &str) -> usize {
    options.iter().position(|s| s.starts_with(default)).unwrap_or(0)
}

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
            } else if input.chars().all(is_ident_char) {
                Ok(Validation::Valid)
            } else {
                Ok(Validation::Invalid(IDENT_HELP.into()))
            }
        })
        .prompt()?;

    let username = Text::new("Container username:")
        .with_help_message("Non-root user inside the container")
        .with_default(&defaults.username)
        .with_validator(|input: &str| {
            if input.chars().all(is_ident_char) {
                Ok(Validation::Valid)
            } else {
                Ok(Validation::Invalid(IDENT_HELP.into()))
            }
        })
        .prompt()?;

    let base_images = base_image_options();
    let default_idx = default_base_image_index(&base_images, &defaults.base_image);

    let selected_image =
        Select::new("Base image:", base_images).with_starting_cursor(default_idx).prompt()?;

    // Extract just the image name (before the " — " description)
    let base_image = selected_image.split(" — ").next().unwrap_or(selected_image).to_string();

    let containers_dir = Text::new("Containers submodule path:")
        .with_help_message("Relative path from project root to containers/")
        .with_default(&defaults.containers_dir)
        .with_validator(|input: &str| {
            if input.chars().all(is_rel_path_char) {
                Ok(Validation::Valid)
            } else {
                Ok(Validation::Invalid(
                    "Only letters, digits, '.', '_', '/', and '-' allowed".into(),
                ))
            }
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Index 0 is only a safe fallback while the list is non-empty.
    #[test]
    fn base_image_options_is_non_empty() {
        assert!(!base_image_options().is_empty());
    }

    #[test]
    fn live_default_selects_its_own_entry() {
        let options = base_image_options();

        let trixie = default_base_image_index(&options, "debian:trixie-slim");
        let bookworm = default_base_image_index(&options, "debian:bookworm-slim");

        // Assert on the resolved option, not just the integer: a bare
        // `assert_eq!(idx, 0)` would also pass if matching broke and every
        // default fell through to the fallback.
        assert!(options[trixie].starts_with("debian:trixie-slim"));
        assert!(options[bookworm].starts_with("debian:bookworm-slim"));
        assert_ne!(trixie, bookworm, "distinct defaults must resolve to distinct entries");
    }

    /// A config naming a base image dropped from the matrix (#933 removed
    /// bullseye) must fall back to the first entry — the intended behavior, not
    /// a panic and not a silent mis-selection of some unrelated image.
    #[test]
    fn removed_default_falls_back_to_first_entry() {
        let options = base_image_options();

        let idx = default_base_image_index(&options, "debian:bullseye-slim");

        assert_eq!(idx, 0);
        assert!(
            !options.iter().any(|s| s.starts_with("debian:bullseye-slim")),
            "bullseye must be absent, or this test proves nothing about the fallback"
        );
    }

    /// An unset default is the same fallback path, reached differently:
    /// `starts_with("")` matches the first entry rather than missing entirely.
    #[test]
    fn empty_default_selects_first_entry() {
        let options = base_image_options();

        assert_eq!(default_base_image_index(&options, ""), 0);
    }

    /// The fallback is a floor, not a coincidence of the current list: an
    /// unmatched default resolves to 0 for any list shape.
    #[test]
    fn unmatched_default_falls_back_regardless_of_list_contents() {
        let options = ["alpine:3.22 — Alpine", "debian:trixie-slim — Debian 13"];

        assert_eq!(default_base_image_index(&options, "ubuntu:24.04"), 0);
        assert_eq!(default_base_image_index(&options, "debian:trixie-slim"), 1);
    }
}
