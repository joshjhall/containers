//! `stibbons update` — re-generate devcontainer files after a containers
//! version bump or a manual `.igor.yml` edit.
//!
//! Unlike `add`/`remove`, `update` changes no feature selection: it re-renders
//! the existing selection against the current templates, records the detected
//! containers version as `containers_ref`, and reports any newly-available
//! features.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use containers_common::config::IgorConfig;
use containers_common::feature::{self, Registry, Selection};
use containers_common::generate::FileAction;
use containers_common::template::RenderContext;

use super::shared::load_project_config;
use crate::render;

/// Re-generates the devcontainer files after a containers version bump or a
/// manual `.igor.yml` edit.
///
/// Locally-modified files are skipped unless `force` is set. Port of the Go
/// `igor update` command.
pub fn run(force: bool) -> Result<(), Box<dyn std::error::Error>> {
    let reg = Registry::new();
    let cfg = load_project_config()?;

    let old_ref = cfg.containers_ref.clone();
    // Prefer the freshly-detected VERSION; fall back to the recorded ref when
    // no VERSION file is found (safer than the Go predecessor, which would
    // overwrite a known ref with an empty string).
    let new_ref = detect_containers_version(&cfg.containers_dir).or_else(|| old_ref.clone());

    let explicit: HashSet<String> = cfg.features.iter().cloned().collect();
    let selection = feature::resolve(&explicit, &reg);

    let mut versions = cfg.versions.clone();
    feature::fill_default_versions(&mut versions, &selection.all(), &reg);

    let ctx = RenderContext::new(
        cfg.project.clone(),
        &cfg.containers_dir,
        &selection,
        &reg,
        versions.clone(),
        cfg.agents.clone(),
    );

    let plan = render::plan_render(&ctx, &cfg.generated, force)?;
    render::commit_render(&plan)?;

    let generated = render::reconcile_hashes(&plan, &cfg.generated);

    // `update` preserves the feature selection verbatim; only the render
    // outputs, versions, containers_ref, and hashes may change.
    let state = IgorConfig {
        schema_version: cfg.schema_version,
        containers_ref: new_ref.clone(),
        containers_dir: cfg.containers_dir.clone(),
        project: cfg.project.clone(),
        features: cfg.features.clone(),
        versions,
        generated,
        agents: cfg.agents.clone(),
        services: cfg.services,
    };
    state.save(".igor.yml")?;

    let new_features = detect_new_features(&selection, &reg);
    print_update_summary(old_ref.as_deref(), new_ref.as_deref(), &plan.actions, &new_features);

    Ok(())
}

/// Detects the containers version by reading a `VERSION` file.
///
/// Looks first in the configured containers directory, then walks the Go
/// predecessor's fallback list relative to the current directory. Returns the
/// trimmed contents of the first `VERSION` file found, or `None`.
///
/// Deliberately distinct from [`super::version::detect_containers_version`],
/// which takes no configured directory and searches a fixed candidate list.
/// This one honors `.igor.yml`'s `containers_dir` and treats a whitespace-only
/// `VERSION` as absent rather than as an empty ref — the two are not
/// interchangeable.
fn detect_containers_version(containers_dir: &str) -> Option<String> {
    let dir = if containers_dir.is_empty() { "containers" } else { containers_dir };
    let candidates =
        [Path::new(dir).join("VERSION"), PathBuf::from("VERSION"), PathBuf::from("../VERSION")];
    for candidate in candidates {
        if let Ok(data) = std::fs::read_to_string(&candidate) {
            let trimmed = data.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

/// Returns the sorted feature IDs available in the registry but not in the
/// current selection, excluding internal (auto-implied) and `_dev` features.
///
/// These are surfaced as "new features available" so a user who bumped the
/// containers version can see what became installable. Port of the Go
/// `detectNewFeatures`.
fn detect_new_features(selection: &Selection, reg: &Registry) -> Vec<String> {
    // Internal features are pulled in implicitly by others and are never
    // something a user would opt into directly.
    const INTERNAL: &[&str] = &["cron", "bindfs"];

    let selected = selection.all();
    let mut new_feats: Vec<String> = reg
        .all()
        .filter(|f| !selected.contains(&f.id) && !INTERNAL.contains(&f.id.as_str()) && !f.is_dev)
        .map(|f| f.id.clone())
        .collect();
    new_feats.sort();
    new_feats
}

/// Prints the `update` summary: a containers-version line, the per-file action
/// table (excluding the always-rewritten state file), and any newly-available
/// features.
fn print_update_summary(
    old_ref: Option<&str>,
    new_ref: Option<&str>,
    actions: &[(String, FileAction)],
    new_features: &[String],
) {
    match (old_ref, new_ref) {
        (Some(old), Some(new)) if old != new => println!("containers: {old} → {new}"),
        (_, Some(new)) => println!("containers: {new}"),
        _ => {}
    }

    // The state file is always rewritten via `save`, so it is excluded from the
    // change table (mirrors `print_render_plan`).
    let tracked = || actions.iter().filter(|(path, _)| path != render::STATE_FILE);

    if tracked().all(|(_, a)| matches!(a, FileAction::Unchanged)) {
        println!("All files up to date.");
        return;
    }

    println!("\nFiles:");
    for (path, action) in tracked() {
        match action {
            FileAction::Created => println!("  + created:   {path}"),
            FileAction::Updated => println!("  ✓ updated:   {path}"),
            FileAction::Unchanged => println!("  - unchanged: {path}"),
            FileAction::Skipped => {
                println!("  ~ skipped:   {path} (user-modified, use --force to overwrite)");
            }
            FileAction::Forced => println!("  ! forced:    {path}"),
        }
    }

    if !new_features.is_empty() {
        println!("\nNew features available:");
        println!("  + {} (run 'stibbons add <feature>' to enable)", new_features.join(", "));
    }
}
