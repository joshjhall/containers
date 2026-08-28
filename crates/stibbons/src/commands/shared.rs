//! Plumbing shared by more than one command body.
//!
//! These helpers were factored out of `main.rs` when the command bodies moved
//! into this module tree (issue #846). Each is used by at least two of
//! [`super::init`], [`super::add_remove`], and [`super::update`]; anything used
//! by exactly one command lives with that command instead.

use std::collections::HashSet;
use std::path::Path;

use containers_common::config::IgorConfig;
use containers_common::feature::Selection;
use containers_common::generate::FileAction;

use crate::render;

/// Loads the project's `.igor.yml`, erroring if the project has not been
/// initialized yet.
pub fn load_project_config() -> Result<IgorConfig, Box<dyn std::error::Error>> {
    if !Path::new(".igor.yml").exists() {
        return Err("no .igor.yml found; run `stibbons init` first".into());
    }
    IgorConfig::load(".igor.yml")
}

/// Returns the sorted set of feature IDs newly present in `selection` relative
/// to the `previous` explicit set (both explicit additions and features pulled
/// in by dependency resolution).
pub fn diff_added(previous: &HashSet<String>, selection: &Selection) -> Vec<String> {
    let mut added: Vec<String> = selection.all().difference(previous).cloned().collect();
    added.sort();
    added
}

/// Joins a list for display, or `(none)` when empty.
pub fn join_or_none(items: &[String]) -> String {
    if items.is_empty() { "(none)".to_string() } else { items.join(", ") }
}

/// Prints the per-file action table for a render plan.
///
/// The state file (`.igor.yml`) is omitted: it is always rewritten via
/// `IgorConfig::save`, so classifying it against the templated hash would show
/// a misleading `skip`/`update` line.
pub fn print_render_plan(plan: &render::RenderPlan) {
    println!("\nPlanned changes:");
    for (path, action) in &plan.actions {
        if path == render::STATE_FILE {
            continue;
        }
        match action {
            FileAction::Created => println!("  create    {path}"),
            FileAction::Updated => println!("  update    {path}"),
            FileAction::Unchanged => println!("  unchanged {path}"),
            FileAction::Forced => println!("  overwrite {path} (forced)"),
            FileAction::Skipped => {
                println!("  skip      {path} (modified locally; use --force to overwrite)");
            }
        }
    }
}

/// Detects the containers submodule directory.
pub fn detect_containers_dir() -> String {
    for candidate in ["containers", "docker/containers", ".containers"] {
        let dockerfile = Path::new(candidate).join("Dockerfile");
        if dockerfile.is_file() {
            return candidate.to_string();
        }
    }
    "containers".to_string()
}
