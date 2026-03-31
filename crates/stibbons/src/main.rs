//! Stibbons: Host orchestrator for the containers build system.

mod wizard;

use clap::{Parser, Subcommand};
use containers_common::feature::Registry;

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

    // Detect project name from current directory
    let current_dir = std::env::current_dir()?;
    let dir_name =
        current_dir.file_name().and_then(|n| n.to_str()).unwrap_or("myproject").to_string();

    let defaults =
        wizard::WizardDefaults { project_name: dir_name, ..wizard::WizardDefaults::default() };

    let result = wizard::run_wizard(&reg, &defaults)?;

    tracing::info!(
        project = %result.project_name,
        features = result.features.len(),
        "Project initialized"
    );

    // TODO: Generate files using template::Renderer
    // For now, just report what would be generated
    println!(
        "\nProject '{}' initialized with {} features.",
        result.project_name,
        result.features.len()
    );
    println!("File generation will be implemented when the init command is fully wired up.");

    Ok(())
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
