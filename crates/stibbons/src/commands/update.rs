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
    let cwd = std::env::current_dir().ok()?;
    detect_containers_version_in(&cwd, containers_dir)
}

/// Resolves the containers version relative to `base`.
///
/// The testable seam behind [`detect_containers_version`], mirroring
/// [`super::version::detect_containers_version_in`]: taking the base directory
/// as a parameter lets tests point at a temp dir without mutating the
/// process-global CWD.
fn detect_containers_version_in(base: &Path, containers_dir: &str) -> Option<String> {
    let dir = if containers_dir.is_empty() { "containers" } else { containers_dir };
    let candidates =
        [Path::new(dir).join("VERSION"), PathBuf::from("VERSION"), PathBuf::from("../VERSION")];
    for candidate in candidates {
        if let Ok(data) = std::fs::read_to_string(base.join(&candidate)) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes `contents` to `<root>/<dir>/VERSION`, creating the directory.
    fn write_version(root: &Path, dir: &str, contents: &str) {
        let target = if dir.is_empty() { root.to_path_buf() } else { root.join(dir) };
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("VERSION"), contents).unwrap();
    }

    #[test]
    fn reads_version_from_configured_dir() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "containers", "5.1.0\n");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "containers").as_deref(),
            Some("5.1.0")
        );
    }

    #[test]
    fn trims_surrounding_whitespace() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "containers", "  \n 4.19.12 \n\n");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "containers").as_deref(),
            Some("4.19.12")
        );
    }

    /// The behavior distinguishing this from `version::detect_containers_version`:
    /// a whitespace-only VERSION is *absent*, not an empty ref. `Some("")` here
    /// would let `update` overwrite a known-good `containers_ref` with "".
    #[test]
    fn whitespace_only_version_is_none() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "containers", "   \n\t\n  ");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "containers"),
            None,
            "whitespace-only VERSION must be None, not Some(\"\")"
        );
    }

    #[test]
    fn missing_version_is_none() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(detect_containers_version_in(tmp.path(), "containers"), None);
    }

    #[test]
    fn configured_dir_wins_over_root_fallback() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "vendor/containers", "9.9.9");
        write_version(tmp.path(), "", "0.0.1");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "vendor/containers").as_deref(),
            Some("9.9.9"),
            "the configured containers_dir is searched before the root VERSION"
        );
    }

    #[test]
    fn falls_back_to_root_version_when_configured_dir_has_none() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "", "3.2.1");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "containers").as_deref(),
            Some("3.2.1")
        );
    }

    #[test]
    fn empty_configured_dir_defaults_to_containers() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "containers", "7.0.0");
        assert_eq!(detect_containers_version_in(tmp.path(), "").as_deref(), Some("7.0.0"));
    }

    /// A whitespace-only file in the first candidate must not short-circuit the
    /// search — the loop continues to the next candidate.
    #[test]
    fn blank_configured_dir_version_falls_through_to_root() {
        let tmp = tempfile::tempdir().unwrap();
        write_version(tmp.path(), "containers", "\n  \n");
        write_version(tmp.path(), "", "6.5.4");
        assert_eq!(
            detect_containers_version_in(tmp.path(), "containers").as_deref(),
            Some("6.5.4")
        );
    }

    /// Builds a selection from explicit feature IDs, resolved against `reg`.
    fn selection_of(ids: &[&str], reg: &Registry) -> Selection {
        let explicit: HashSet<String> = ids.iter().map(|s| (*s).to_string()).collect();
        feature::resolve(&explicit, reg)
    }

    #[test]
    fn new_features_excludes_internal_features() {
        let reg = Registry::new();
        let new_feats = detect_new_features(&selection_of(&[], &reg), &reg);

        // `cron` and `bindfs` are pulled in implicitly by other features and are
        // never something a user opts into, so they stay out even with nothing
        // selected.
        for internal in ["cron", "bindfs"] {
            assert!(
                !new_feats.contains(&internal.to_string()),
                "internal feature {internal:?} should never be suggested"
            );
        }
    }

    #[test]
    fn new_features_excludes_dev_features() {
        let reg = Registry::new();
        let new_feats = detect_new_features(&selection_of(&[], &reg), &reg);

        for id in &new_feats {
            let f = reg.get(id).expect("suggested feature should exist in the registry");
            assert!(!f.is_dev, "dev feature {id:?} should never be suggested");
        }
        // Guard against the loop above passing vacuously.
        assert!(!new_feats.is_empty(), "an empty selection should suggest something");
    }

    #[test]
    fn new_features_excludes_selected() {
        let reg = Registry::new();
        let selection = selection_of(&["python"], &reg);
        let new_feats = detect_new_features(&selection, &reg);

        // Auto-resolved dependencies are part of `selection.all()`, so they are
        // excluded alongside the explicit picks.
        for id in selection.all() {
            assert!(!new_feats.contains(&id), "selected/resolved {id:?} should be excluded");
        }
    }

    #[test]
    fn new_features_is_sorted() {
        let reg = Registry::new();
        let new_feats = detect_new_features(&selection_of(&["node"], &reg), &reg);

        let mut sorted = new_feats.clone();
        sorted.sort();
        assert_eq!(new_feats, sorted, "detect_new_features should return sorted IDs");
    }
}
