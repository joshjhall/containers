//! `stibbons add` / `stibbons remove` — change the feature selection and
//! re-render.
//!
//! Both commands share the same tail ([`apply_and_render`]): resolve the new
//! selection, print the per-file plan, and — unless `--dry-run` — write the
//! files and save the updated `.igor.yml`. Only the head differs, in how the
//! new selection is computed and reported.

use std::collections::{BTreeMap, HashSet};

use containers_common::config::IgorConfig;
use containers_common::feature::{self, AddOptions, Registry, RemoveOptions, Selection};
use containers_common::template::RenderContext;

use super::shared::{diff_added, join_or_none, load_project_config, print_render_plan};
use crate::render;

/// How `add`/`remove` write generated files: whether to preview only, and
/// whether to overwrite locally-modified files.
#[derive(Debug, Clone, Copy)]
pub struct WriteMode {
    /// Preview the plan without writing anything.
    pub dry_run: bool,
    /// Overwrite files even if they were modified locally.
    pub force: bool,
}

/// Adds one or more features to the current project and re-renders.
pub fn run_add(
    features: &[String],
    dev: bool,
    mode: WriteMode,
) -> Result<(), Box<dyn std::error::Error>> {
    let reg = Registry::new();
    let cfg = load_project_config()?;

    let explicit: HashSet<String> = cfg.features.iter().cloned().collect();
    let outcome = feature::plan_add(features, &explicit, AddOptions { dev }, &reg)?;
    let selection = feature::resolve(&outcome.explicit, &reg);

    let mut versions = cfg.versions.clone();
    feature::fill_default_versions(&mut versions, &selection.all(), &reg);

    // Report the net additions (explicit + newly auto-resolved) for the header.
    let added: Vec<String> = diff_added(&explicit, &selection);
    if added.is_empty() && outcome.skipped.iter().all(|s| explicit.contains(s)) {
        println!("Nothing to add.");
        return Ok(());
    }
    println!("Adding: {}", join_or_none(&added));
    if !outcome.skipped.is_empty() {
        let mut skipped = outcome.skipped;
        skipped.sort();
        println!("Already enabled (skipped): {}", skipped.join(", "));
    }

    apply_and_render(&cfg, &selection, versions, &reg, mode)
}

/// Removes one or more features from the current project and re-renders.
pub fn run_remove(
    features: &[String],
    cascade: bool,
    dev_only: bool,
    mode: WriteMode,
) -> Result<(), Box<dyn std::error::Error>> {
    let reg = Registry::new();
    let cfg = load_project_config()?;

    let explicit: HashSet<String> = cfg.features.iter().cloned().collect();
    let new_explicit =
        feature::plan_remove(features, &explicit, RemoveOptions { cascade, dev_only }, &reg)?;
    let selection = feature::resolve(&new_explicit, &reg);

    // The actual departures: features explicit before but gone now (includes
    // any cascaded dependents).
    let mut removed: Vec<String> = explicit.difference(&new_explicit).cloned().collect();
    removed.sort();
    println!("Removing: {}", join_or_none(&removed));

    let mut versions = cfg.versions.clone();
    feature::prune_versions(&mut versions, &selection.all(), &reg);
    feature::fill_default_versions(&mut versions, &selection.all(), &reg);

    apply_and_render(&cfg, &selection, versions, &reg, mode)
}

/// Shared tail of `add`/`remove`: render the generated files against the new
/// selection, print the per-file plan, and (unless `dry_run`) write the files
/// and save the updated `.igor.yml`.
fn apply_and_render(
    cfg: &IgorConfig,
    selection: &Selection,
    versions: BTreeMap<String, String>,
    reg: &Registry,
    mode: WriteMode,
) -> Result<(), Box<dyn std::error::Error>> {
    let ctx = RenderContext::new(
        cfg.project.clone(),
        &cfg.containers_dir,
        selection,
        reg,
        versions.clone(),
        cfg.agents.clone(),
    );

    let plan = render::plan_render(&ctx, &cfg.generated, mode.force)?;
    print_render_plan(&plan);

    if mode.dry_run {
        println!("\nDry run — no files written.");
        return Ok(());
    }

    render::commit_render(&plan)?;

    // Bookkeeping: keep the new hash for files we wrote or that were already
    // current; preserve the previous hash for skipped (user-modified) files so
    // they are not re-detected as stale next run. The state file (`.igor.yml`)
    // is always rewritten via `save` below, so it always takes the fresh hash.
    let generated = render::reconcile_hashes(&plan, &cfg.generated);

    let mut features: Vec<String> = selection.explicit.iter().cloned().collect();
    features.sort();

    // Carry through everything not owned by this operation. Unlike the Go
    // predecessor (which dropped agents/services on save), we preserve them.
    let state = IgorConfig {
        schema_version: cfg.schema_version,
        containers_ref: cfg.containers_ref.clone(),
        containers_dir: cfg.containers_dir.clone(),
        project: cfg.project.clone(),
        features,
        versions,
        generated,
        agents: cfg.agents.clone(),
        services: cfg.services.clone(),
    };
    state.save(".igor.yml")?;

    Ok(())
}
