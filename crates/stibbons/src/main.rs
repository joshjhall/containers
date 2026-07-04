//! Stibbons: Host orchestrator for the containers build system.

mod render;
mod wizard;

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use containers_common::config::{AgentConfig, IgorConfig, ProjectConfig, ServiceConfig};
use containers_common::feature::{self, AddOptions, Registry, RemoveOptions, Selection};
use containers_common::generate::FileAction;
use containers_common::template::RenderContext;

/// Stibbons - Container build system orchestrator.
///
/// Scaffolds devcontainer configurations and manages container builds.
/// (Successor to igor, rewritten in Rust.)
#[derive(Parser, Debug)]
#[command(name = "stibbons", version = env!("STIBBONS_VERSION"), about, long_about = None)]
struct Cli {
    /// Enable verbose output.
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Initialize a new project with an interactive wizard.
    Init {
        /// Skip the wizard and read selections from an existing `.igor.yml`.
        #[arg(long)]
        non_interactive: bool,

        /// Path to an `.igor.yml` config file (required with `--non-interactive`).
        #[arg(long)]
        config: Option<PathBuf>,
    },

    /// Add one or more features to an existing project and re-render.
    Add {
        /// Feature IDs to add (e.g. `python`, `docker`).
        #[arg(required = true, value_name = "FEATURE")]
        features: Vec<String>,

        /// Also add the `<feature>_dev` companion of each feature.
        #[arg(long)]
        dev: bool,

        /// Preview the changes without writing any files.
        #[arg(long)]
        dry_run: bool,

        /// Overwrite generated files even if they were modified locally.
        #[arg(long)]
        force: bool,
    },

    /// Remove one or more features from an existing project and re-render.
    Remove {
        /// Feature IDs to remove (e.g. `python`, `docker`).
        #[arg(required = true, value_name = "FEATURE")]
        features: Vec<String>,

        /// Also remove features that transitively depend on the target(s).
        #[arg(long)]
        cascade: bool,

        /// Remove only the `<feature>_dev` companion, keeping the runtime feature.
        #[arg(long)]
        dev_only: bool,

        /// Preview the changes without writing any files.
        #[arg(long)]
        dry_run: bool,

        /// Overwrite generated files even if they were modified locally.
        #[arg(long)]
        force: bool,
    },
}

fn main() {
    let cli = Cli::parse();

    let filter = if cli.verbose { "debug" } else { "info" };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(filter)),
        )
        .init();

    match cli.command {
        Some(Commands::Init { non_interactive, config }) => {
            if let Err(e) = run_init(non_interactive, config.as_deref()) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Add { features, dev, dry_run, force }) => {
            if let Err(e) = run_add(&features, dev, WriteMode { dry_run, force }) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Remove { features, cascade, dev_only, dry_run, force }) => {
            if let Err(e) = run_remove(&features, cascade, dev_only, WriteMode { dry_run, force }) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        None => {
            tracing::info!("stibbons v{}", env!("STIBBONS_VERSION"));
            eprintln!(
                "Run `stibbons init` to set up a new project, or `stibbons --help` for usage."
            );
        }
    }
}

/// How `add`/`remove` write generated files: whether to preview only, and
/// whether to overwrite locally-modified files.
#[derive(Debug, Clone, Copy)]
struct WriteMode {
    /// Preview the plan without writing anything.
    dry_run: bool,
    /// Overwrite files even if they were modified locally.
    force: bool,
}

/// Inputs to template rendering, produced by either the wizard or a loaded config.
struct InitInputs {
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

fn run_init(
    non_interactive: bool,
    config: Option<&Path>,
) -> Result<(), Box<dyn std::error::Error>> {
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

/// Loads the project's `.igor.yml`, erroring if the project has not been
/// initialized yet.
fn load_project_config() -> Result<IgorConfig, Box<dyn std::error::Error>> {
    if !Path::new(".igor.yml").exists() {
        return Err("no .igor.yml found; run `stibbons init` first".into());
    }
    IgorConfig::load(".igor.yml")
}

/// Adds one or more features to the current project and re-renders.
fn run_add(
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
fn run_remove(
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
    let mut generated = BTreeMap::new();
    for (path, action) in &plan.actions {
        let hash = match action {
            FileAction::Skipped if path != render::STATE_FILE => cfg.generated.get(path).cloned(),
            _ => plan.new_hashes.get(path).cloned(),
        };
        if let Some(h) = hash {
            generated.insert(path.clone(), h);
        }
    }

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

/// Returns the sorted set of feature IDs newly present in `selection` relative
/// to the `previous` explicit set (both explicit additions and features pulled
/// in by dependency resolution).
fn diff_added(previous: &HashSet<String>, selection: &Selection) -> Vec<String> {
    let mut added: Vec<String> = selection.all().difference(previous).cloned().collect();
    added.sort();
    added
}

/// Joins a list for display, or `(none)` when empty.
fn join_or_none(items: &[String]) -> String {
    if items.is_empty() { "(none)".to_string() } else { items.join(", ") }
}

/// Prints the per-file action table for a render plan.
///
/// The state file (`.igor.yml`) is omitted: it is always rewritten via
/// `IgorConfig::save`, so classifying it against the templated hash would show
/// a misleading `skip`/`update` line.
fn print_render_plan(plan: &render::RenderPlan) {
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
fn detect_containers_dir() -> String {
    for candidate in ["containers", "docker/containers", ".containers"] {
        let dockerfile = Path::new(candidate).join("Dockerfile");
        if dockerfile.is_file() {
            return candidate.to_string();
        }
    }
    "containers".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_cli() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }

    #[test]
    fn verify_init_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let init = cmd.get_subcommands().find(|s| s.get_name() == "init");
        assert!(init.is_some(), "init subcommand should exist");
    }

    #[test]
    fn verify_add_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let add = cmd.get_subcommands().find(|s| s.get_name() == "add");
        assert!(add.is_some(), "add subcommand should exist");
    }

    #[test]
    fn verify_remove_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let remove = cmd.get_subcommands().find(|s| s.get_name() == "remove");
        assert!(remove.is_some(), "remove subcommand should exist");
    }
}
