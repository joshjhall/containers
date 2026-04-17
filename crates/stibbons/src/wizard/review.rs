//! Review step — displays a styled summary and asks for confirmation.

use containers_common::feature::{Registry, resolve};
use inquire::Select;

use super::WizardResult;

// ANSI color codes
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

/// Displays a review of the wizard selections and asks for confirmation.
///
/// # Errors
///
/// Returns an error if the user cancels or the prompt fails.
pub fn run_review(reg: &Registry, result: &WizardResult) -> Result<(), Box<dyn std::error::Error>> {
    let sel = resolve(&result.features, reg);

    // Build review text
    println!();
    println!("{BOLD}Configuration Review{RESET}");
    println!();
    println!("  Project: {}", result.project_name);
    println!("  User:    {}", result.username);
    println!("  Base:    {}", result.base_image);
    println!("  Path:    {}", result.containers_dir);
    println!();

    // Explicit features
    println!("{GREEN}{BOLD}Selected features:{RESET}");
    let mut explicit_ids: Vec<&String> = sel.explicit.iter().collect();
    explicit_ids.sort();
    for id in explicit_ids {
        if let Some(f) = reg.get(id) {
            println!("  {GREEN}+ {}{RESET}", f.display_name);
        }
    }

    // Auto-resolved dependencies
    if !sel.auto_resolved.is_empty() {
        println!();
        println!("{YELLOW}{BOLD}Auto-resolved dependencies:{RESET}");
        let mut auto_ids: Vec<&String> = sel.auto_resolved.iter().collect();
        auto_ids.sort();
        for id in auto_ids {
            if let Some(f) = reg.get(id) {
                println!("  {YELLOW}~ {}{RESET}", f.display_name);
            }
        }
    }

    // Files to generate
    println!();
    println!("{BOLD}Files to generate:{RESET}");
    println!("  .devcontainer/docker-compose.yml");
    println!("  .devcontainer/devcontainer.json");
    println!("  .devcontainer/.env");
    println!("  .env.example");
    println!("  .igor.yml");
    println!();

    // Confirmation
    let options = vec!["Yes, generate files", "No, cancel"];
    let answer = Select::new("Generate these files?", options).prompt()?;

    if answer == "No, cancel" {
        return Err("Cancelled by user".into());
    }

    Ok(())
}
