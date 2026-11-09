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

/// Unit tests for `init`'s command logic.
///
/// `tests/init_integration.rs` already pins the end-to-end non-interactive
/// path as a subprocess (files exist, YAML/JSON validity, `.igor.yml`
/// round-trip of project + features, hash-map shape, the missing-`--config`
/// error). These tests cover what that suite does not: the explicit vs
/// auto-resolved split, versions/agents/services surviving load *and* save,
/// `run()`'s guard firing before any write, and `force = true` overwriting a
/// hand-edited file.
///
/// **Declined scope:** `load_from_wizard` is not unit-tested. It is TUI-bound
/// (`wizard::run_wizard` needs a terminal) and covering it would need a
/// wizard-injection seam in a production signature — the same reason #867
/// declined `run_setup` / `run_labels_sync`.
#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use containers_common::generate::hash_content;

    use super::*;
    use crate::test_support::with_cwd;

    /// Writes `yaml` to `<dir>/fixture.igor.yml` and returns its path.
    fn write_cfg(dir: &Path, yaml: &str) -> PathBuf {
        let path = dir.join("fixture.igor.yml");
        fs::write(&path, yaml).unwrap();
        path
    }

    /// Only `python_dev` is listed, so `python` can reach the selection solely
    /// through dependency resolution.
    const DEV_ONLY_CFG: &str = "\
schema_version: 1
containers_dir: containers
project:
  name: myapp
  username: developer
  base_image: \"debian:trixie-slim\"
features:
  - python_dev
";

    /// Carries every field `init` must pass through untouched.
    const RICH_CFG: &str = "\
schema_version: 1
containers_dir: containers
project:
  name: richapp
  username: builder
  base_image: \"debian:bookworm-slim\"
features:
  - python
versions:
  PYTHON_VERSION: \"3.9-pinned\"
agents:
  max: 3
  network: richapp-dev-network
services:
  postgres:
    image: postgres:16
    port: 5432
    per_agent_db: true
";

    #[test]
    fn load_from_config_resolves_dependencies_and_keeps_explicit_set() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();

        let inputs = load_from_config(&reg, &write_cfg(tmp.path(), DEV_ONLY_CFG)).unwrap();

        let explicit: Vec<&str> = inputs.selection.explicit.iter().map(String::as_str).collect();
        assert_eq!(explicit, ["python_dev"], "explicit set must be exactly the config's list");
        assert!(
            inputs.selection.auto_resolved.contains("python"),
            "python_dev requires python, so it must be auto-resolved; got {:?}",
            inputs.selection.auto_resolved
        );
        assert!(inputs.selection.has("python"), "resolved selection must include python");
    }

    #[test]
    fn load_from_config_carries_project_versions_agents_services() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();

        let inputs = load_from_config(&reg, &write_cfg(tmp.path(), RICH_CFG)).unwrap();

        assert_eq!(inputs.project.name, "richapp");
        assert_eq!(inputs.project.username, "builder");
        assert_eq!(inputs.project.base_image, "debian:bookworm-slim");
        assert_eq!(inputs.containers_dir, "containers");
        assert_eq!(
            inputs.versions.get("PYTHON_VERSION").map(String::as_str),
            Some("3.9-pinned"),
            "a pinned version must come through load unchanged"
        );
        assert_eq!(inputs.agents.max, 3);
        assert_eq!(inputs.agents.network, "richapp-dev-network");
        let pg = inputs.services.get("postgres").expect("postgres service must be loaded");
        assert_eq!(pg.image, "postgres:16");
        assert_eq!(pg.port, 5432);
        assert!(pg.per_agent_db);
    }

    #[test]
    fn load_from_config_errors_on_missing_file() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();

        let Err(err) = load_from_config(&reg, &tmp.path().join("absent.igor.yml")) else {
            panic!("a missing config must be an error, not a default");
        };

        let io = err.downcast_ref::<std::io::Error>().expect("expected the read's io::Error");
        assert_eq!(io.kind(), std::io::ErrorKind::NotFound, "got: {err}");
    }

    #[test]
    fn load_from_config_errors_on_malformed_yaml() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();

        let Err(err) = load_from_config(&reg, &write_cfg(tmp.path(), "features: [unclosed\n"))
        else {
            panic!("malformed YAML must be an error");
        };

        // The file exists and is readable, so the failure must come from
        // parsing, not from the read.
        assert!(
            err.downcast_ref::<std::io::Error>().is_none(),
            "expected a parse error, got an io::Error: {err}"
        );
    }

    /// The guard must fire before anything else: no wizard, no render, no
    /// `.igor.yml`. Asserting the CWD stays empty is what fails if the check
    /// is moved below the load/write steps.
    #[test]
    fn run_non_interactive_without_config_errors_before_writing() {
        let tmp = tempfile::tempdir().unwrap();

        let err = with_cwd(tmp.path(), || run(true, None)).expect_err("guard must reject");

        let msg = err.to_string();
        assert!(
            msg.contains("--config") && msg.contains("--non-interactive"),
            "error should name both flags, got: {msg}"
        );
        let entries: Vec<_> = fs::read_dir(tmp.path()).unwrap().collect();
        assert!(entries.is_empty(), "guard must return before writing anything: {entries:?}");
    }

    #[test]
    fn write_outputs_preserves_versions_agents_services_on_save() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();
        let cfg_path = write_cfg(tmp.path(), RICH_CFG);
        let inputs = load_from_config(&reg, &cfg_path).unwrap();

        with_cwd(tmp.path(), || write_outputs(&inputs, &reg)).unwrap();

        let saved = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
        assert_eq!(saved.features, ["python"], "the explicit feature list is persisted");
        assert_eq!(saved.versions, inputs.versions, "versions must survive init's save");
        assert_eq!(saved.agents.max, 3);
        assert_eq!(saved.agents.network, "richapp-dev-network");
        let pg = saved.services.get("postgres").expect("services must survive init's save");
        assert_eq!(pg.image, "postgres:16");
        assert_eq!(pg.port, 5432);
        assert!(pg.per_agent_db);
    }

    #[test]
    fn write_outputs_saves_explicit_not_auto_resolved_features() {
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();
        let inputs = load_from_config(&reg, &write_cfg(tmp.path(), DEV_ONLY_CFG)).unwrap();

        with_cwd(tmp.path(), || write_outputs(&inputs, &reg)).unwrap();

        let saved = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
        assert_eq!(
            saved.features,
            ["python_dev"],
            "auto-resolved python must not be promoted to an explicit selection"
        );
    }

    /// `init` renders with `force = true`: a hand-edited generated file is
    /// overwritten, and the recorded hash matches the fresh content.
    #[test]
    fn write_outputs_overwrites_existing_generated_file() {
        const SENTINEL: &str = "HAND_EDITED_SENTINEL=1\n";
        let reg = Registry::new();
        let tmp = tempfile::tempdir().unwrap();
        let inputs = load_from_config(&reg, &write_cfg(tmp.path(), DEV_ONLY_CFG)).unwrap();
        let env_rel = ".devcontainer/.env";
        fs::create_dir_all(tmp.path().join(".devcontainer")).unwrap();
        fs::write(tmp.path().join(env_rel), SENTINEL).unwrap();

        with_cwd(tmp.path(), || write_outputs(&inputs, &reg)).unwrap();

        let content = fs::read_to_string(tmp.path().join(env_rel)).unwrap();
        assert!(!content.contains("HAND_EDITED_SENTINEL"), "existing file must be overwritten");
        let saved = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
        assert_eq!(
            saved.generated.get(env_rel),
            Some(&hash_content(&content)),
            "recorded hash must describe the freshly written content"
        );
    }

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
