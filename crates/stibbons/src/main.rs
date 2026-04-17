//! Stibbons: Host orchestrator for the containers build system.

mod wizard;

use std::collections::BTreeMap;
use std::path::Path;

use clap::{Parser, Subcommand};
use containers_common::config::{AgentConfig, IgorConfig, ProjectConfig};
use containers_common::feature::{self, Registry};
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
    Init,
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
        Some(Commands::Init) => {
            if let Err(e) = run_init() {
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

fn run_init() -> Result<(), Box<dyn std::error::Error>> {
    let reg = Registry::new();

    // Detect defaults from current directory.
    let current_dir = std::env::current_dir()?;
    let dir_name =
        current_dir.file_name().and_then(|n| n.to_str()).unwrap_or("myproject").to_string();

    let containers_dir_default = detect_containers_dir();
    let defaults = wizard::WizardDefaults {
        project_name: dir_name,
        containers_dir: containers_dir_default,
        ..wizard::WizardDefaults::default()
    };

    let result = wizard::run_wizard(&reg, &defaults)?;

    // Resolve dependencies.
    let selection = feature::resolve(&result.features, &reg);

    // Fill default versions for selected features.
    let mut versions = BTreeMap::new();
    for f in reg.all() {
        if selection.has(&f.id)
            && let (Some(arg), Some(default)) = (&f.version_arg, &f.default_version)
        {
            versions.entry(arg.clone()).or_insert_with(|| default.clone());
        }
    }

    // Build render context.
    let project = ProjectConfig {
        name: result.project_name.clone(),
        username: result.username.clone(),
        base_image: result.base_image.clone(),
        ..ProjectConfig::default()
    };
    let ctx = RenderContext::new(
        project.clone(),
        &result.containers_dir,
        &selection,
        &reg,
        versions.clone(),
        AgentConfig::default(),
    );

    // Render templates.
    let renderer = Renderer::new()?;
    let files = [
        (".devcontainer/docker-compose.yml", "docker-compose.yml.tmpl"),
        (".devcontainer/devcontainer.json", "devcontainer.json.tmpl"),
        (".devcontainer/.env", "env.tmpl"),
        (".env.example", "env-example.tmpl"),
        (".igor.yml", "igor.yml.tmpl"),
    ];

    // Check for existing files.
    let mut existing = Vec::new();
    for (path, _) in &files {
        if Path::new(path).exists() {
            existing.push(*path);
        }
    }
    if !existing.is_empty() {
        println!("\nExisting files will be overwritten:");
        for path in &existing {
            println!("  ! {path}");
        }
        println!();
    }

    // Write all files and compute hashes.
    let mut generated_hashes = BTreeMap::new();
    for (path, template) in &files {
        let content = renderer.render(template, &ctx)?;

        // Create parent directory if needed.
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, &content)?;

        let hash = sha256_hex(&content);
        generated_hashes.insert((*path).to_string(), hash);
    }

    // Build sorted explicit feature list for state file.
    let mut explicit_list: Vec<String> = selection.explicit.iter().cloned().collect();
    explicit_list.sort();

    // Save state to .igor.yml.
    let state = IgorConfig {
        schema_version: 1,
        containers_dir: result.containers_dir,
        project,
        features: explicit_list,
        versions,
        generated: generated_hashes,
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
