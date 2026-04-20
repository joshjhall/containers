//! Stibbons: Host orchestrator for the containers build system.

mod wizard;

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use containers_common::config::{AgentConfig, IgorConfig, ProjectConfig};
use containers_common::feature::{self, Registry, Selection};
use containers_common::template::{RenderContext, Renderer};

/// Stibbons - Container build system orchestrator.
///
/// Scaffolds devcontainer configurations and manages container builds.
/// (Successor to igor, rewritten in Rust.)
#[derive(Parser, Debug)]
#[command(name = "stibbons", version, about, long_about = None)]
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
        None => {
            tracing::info!("stibbons v{}", env!("CARGO_PKG_VERSION"));
            eprintln!(
                "Run `stibbons init` to set up a new project, or `stibbons --help` for usage."
            );
        }
    }
}

/// Inputs to template rendering, produced by either the wizard or a loaded config.
struct InitInputs {
    project: ProjectConfig,
    containers_dir: String,
    selection: Selection,
    versions: BTreeMap<String, String>,
    agents: AgentConfig,
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

/// Render templates, write the 5 files, compute hashes, and save `.igor.yml`.
fn write_outputs(inputs: &InitInputs, reg: &Registry) -> Result<(), Box<dyn std::error::Error>> {
    let ctx = RenderContext::new(
        inputs.project.clone(),
        &inputs.containers_dir,
        &inputs.selection,
        reg,
        inputs.versions.clone(),
        inputs.agents.clone(),
    );

    let renderer = Renderer::new()?;
    let files = [
        (".devcontainer/docker-compose.yml", "docker-compose.yml.tmpl"),
        (".devcontainer/devcontainer.json", "devcontainer.json.tmpl"),
        (".devcontainer/.env", "env.tmpl"),
        (".env.example", "env-example.tmpl"),
        (".igor.yml", "igor.yml.tmpl"),
    ];

    let existing: Vec<&str> =
        files.iter().filter(|(p, _)| Path::new(p).exists()).map(|(p, _)| *p).collect();
    if !existing.is_empty() {
        println!("\nExisting files will be overwritten:");
        for path in &existing {
            println!("  ! {path}");
        }
        println!();
    }

    let mut generated_hashes = BTreeMap::new();
    for (path, template) in &files {
        let content = renderer.render(template, &ctx)?;
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, &content)?;
        generated_hashes.insert((*path).to_string(), sha256_hex(&content));
    }

    let mut explicit_list: Vec<String> = inputs.selection.explicit.iter().cloned().collect();
    explicit_list.sort();

    let state = IgorConfig {
        schema_version: 1,
        containers_dir: inputs.containers_dir.clone(),
        project: inputs.project.clone(),
        features: explicit_list,
        versions: inputs.versions.clone(),
        generated: generated_hashes,
        agents: inputs.agents.clone(),
        ..IgorConfig::default()
    };
    state.save(".igor.yml")?;

    println!("\nFiles generated successfully:");
    for (path, _) in &files {
        println!("  {path}");
    }
    println!("\nNext steps:");
    println!("  1. Review the generated files");
    println!("  2. Commit .igor.yml and .devcontainer/ to your repo");
    println!("  3. Open in VS Code with Remote-Containers, or run:");
    println!("     docker compose -f .devcontainer/docker-compose.yml up -d");

    Ok(())
}

/// Returns the SHA-256 hex digest of a string.
fn sha256_hex(content: &str) -> String {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(content.as_bytes());
    format!("{hash:x}")
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
}
