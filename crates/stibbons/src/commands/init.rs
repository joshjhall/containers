//! `stibbons init` — scaffold a new project's devcontainer configuration.
//!
//! Two entry paths converge on [`InitInputs`]: the interactive TUI wizard
//! ([`load_from_wizard`]) and a non-interactive load of an existing `.igor.yml`
//! ([`load_from_config`]). [`write_outputs`] then renders and writes the
//! generated files for either path.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use containers_common::config::{AgentConfig, IgorConfig, ProjectConfig, ServiceConfig};
use containers_common::feature::{self, Registry, Selection};
use containers_common::template::RenderContext;

use super::shared::detect_containers_dir;
use crate::{render, wizard};

/// Inputs to template rendering, produced by either the wizard or a loaded config.
pub struct InitInputs {
    project: ProjectConfig,
    containers_dir: String,
    selection: Selection,
    versions: BTreeMap<String, String>,
    agents: AgentConfig,
    /// Service definitions carried through from an existing config (empty from
    /// the wizard). Preserved on save so re-running `init` on a config with
    /// services does not silently drop them.
    services: BTreeMap<String, ServiceConfig>,
}

pub fn run(non_interactive: bool, config: Option<&Path>) -> Result<(), Box<dyn std::error::Error>> {
    if non_interactive && config.is_none() {
        return Err("--config is required with --non-interactive".into());
    }

    let reg = Registry::new();

    let mut inputs = if non_interactive {
        load_from_config(&reg, config.expect("guarded above"))?
    } else {
        load_from_wizard(&reg)?
    };

    fill_default_versions(&mut inputs.versions, &inputs.selection, &reg);
    write_outputs(&inputs, &reg)
}

/// Interactive path: run the TUI wizard and derive inputs from user selections.
fn load_from_wizard(reg: &Registry) -> Result<InitInputs, Box<dyn std::error::Error>> {
    let current_dir = std::env::current_dir()?;
    let dir_name =
        current_dir.file_name().and_then(|n| n.to_str()).unwrap_or("myproject").to_string();

    let defaults = wizard::WizardDefaults {
        project_name: dir_name,
        containers_dir: detect_containers_dir(),
        ..wizard::WizardDefaults::default()
    };

    let result = wizard::run_wizard(reg, &defaults)?;
    let selection = feature::resolve(&result.features, reg);

    let project = ProjectConfig {
        name: result.project_name,
        username: result.username,
        base_image: result.base_image,
        ..ProjectConfig::default()
    };

    Ok(InitInputs {
        project,
        containers_dir: result.containers_dir,
        selection,
        versions: BTreeMap::new(),
        agents: AgentConfig::default(),
        services: BTreeMap::new(),
    })
}

/// Non-interactive path: load selections from an existing `.igor.yml`.
fn load_from_config(reg: &Registry, path: &Path) -> Result<InitInputs, Box<dyn std::error::Error>> {
    let cfg = IgorConfig::load(path)?;
    let explicit: HashSet<String> = cfg.features.iter().cloned().collect();
    let selection = feature::resolve(&explicit, reg);

    Ok(InitInputs {
        project: cfg.project,
        containers_dir: cfg.containers_dir,
        selection,
        versions: cfg.versions,
        agents: cfg.agents,
        services: cfg.services,
    })
}

/// Fill in default versions from the registry for any feature that doesn't already have one.
fn fill_default_versions(
    versions: &mut BTreeMap<String, String>,
    selection: &Selection,
    reg: &Registry,
) {
    for f in reg.all() {
        if selection.has(&f.id)
            && let (Some(arg), Some(default)) = (&f.version_arg, &f.default_version)
        {
            versions.entry(arg.clone()).or_insert_with(|| default.clone());
        }
    }
}

/// Render templates, write the generated files, compute hashes, and save
/// `.igor.yml`.
///
/// `init` deliberately writes every file unconditionally (its contract is
/// "regenerate + warn on overwrite"), so it renders with `force = true` and
/// does not consult recorded hashes. `add` / `remove` use the same
/// [`render::plan_render`] primitive but honor per-file drift detection.
fn write_outputs(inputs: &InitInputs, reg: &Registry) -> Result<(), Box<dyn std::error::Error>> {
    let ctx = RenderContext::new(
        inputs.project.clone(),
        &inputs.containers_dir,
        &inputs.selection,
        reg,
        inputs.versions.clone(),
        inputs.agents.clone(),
    );

    let existing: Vec<&str> = render::GENERATED_FILES
        .iter()
        .filter(|(p, _)| Path::new(p).exists())
        .map(|(p, _)| *p)
        .collect();
    if !existing.is_empty() {
        println!("\nExisting files will be overwritten:");
        for path in &existing {
            println!("  ! {path}");
        }
        println!();
    }

    // init overwrites everything: an empty old-hash map + force = true means
    // every file classifies as Created or Forced and is written.
    let plan = render::plan_render(&ctx, &BTreeMap::new(), true)?;
    render::commit_render(&plan)?;

    let mut explicit_list: Vec<String> = inputs.selection.explicit.iter().cloned().collect();
    explicit_list.sort();

    let state = IgorConfig {
        schema_version: 1,
        containers_dir: inputs.containers_dir.clone(),
        project: inputs.project.clone(),
        features: explicit_list,
        versions: inputs.versions.clone(),
        generated: plan.new_hashes,
        agents: inputs.agents.clone(),
        services: inputs.services.clone(),
        ..IgorConfig::default()
    };
    state.save(".igor.yml")?;

    println!("\nFiles generated successfully:");
    for (path, _) in render::GENERATED_FILES {
        println!("  {path}");
    }
    println!("\nNext steps:");
    println!("  1. Review the generated files");
    println!("  2. Commit .igor.yml and .devcontainer/ to your repo");
    println!("  3. Open in VS Code with Remote-Containers, or run:");
    println!("     docker compose -f .devcontainer/docker-compose.yml up -d");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selection_of(ids: &[&str], reg: &Registry) -> Selection {
        let explicit: HashSet<String> = ids.iter().map(|s| (*s).to_string()).collect();
        feature::resolve(&explicit, reg)
    }

    #[test]
    fn fills_registry_defaults_into_an_empty_map() {
        let reg = Registry::new();
        let mut versions = BTreeMap::new();

        fill_default_versions(&mut versions, &selection_of(&["python"], &reg), &reg);

        let py = reg.get("python").unwrap();
        let arg = py.version_arg.as_ref().expect("python declares a version arg");
        assert_eq!(
            versions.get(arg),
            py.default_version.as_ref(),
            "should fill the registry default"
        );
    }

    /// The load-bearing behavior of `entry().or_insert_with()`: a version the
    /// user pinned explicitly must survive the fill rather than be clobbered
    /// back to the registry default.
    #[test]
    fn does_not_clobber_an_explicit_version() {
        let reg = Registry::new();
        let py = reg.get("python").unwrap();
        let arg = py.version_arg.clone().expect("python declares a version arg");

        let mut versions = BTreeMap::new();
        versions.insert(arg.clone(), "3.9-pinned".to_string());

        fill_default_versions(&mut versions, &selection_of(&["python"], &reg), &reg);

        assert_eq!(
            versions.get(&arg).map(String::as_str),
            Some("3.9-pinned"),
            "an explicitly-set version must survive the fill"
        );
        assert_ne!(
            versions.get(&arg),
            py.default_version.as_ref(),
            "guard: the pin must differ from the default for this test to mean anything"
        );
    }

    #[test]
    fn unselected_features_contribute_nothing() {
        let reg = Registry::new();
        let mut versions = BTreeMap::new();

        fill_default_versions(&mut versions, &selection_of(&["python"], &reg), &reg);

        let selection = selection_of(&["python"], &reg);
        for arg in versions.keys() {
            let owned =
                reg.all().any(|f| selection.has(&f.id) && f.version_arg.as_ref() == Some(arg));
            assert!(owned, "version arg {arg:?} belongs to no selected feature");
        }
    }

    #[test]
    fn empty_selection_fills_nothing() {
        let reg = Registry::new();
        let mut versions = BTreeMap::new();

        fill_default_versions(&mut versions, &selection_of(&[], &reg), &reg);

        assert!(versions.is_empty(), "nothing selected should fill nothing, got {versions:?}");
    }
}
