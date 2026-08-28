//! Stibbons: Host orchestrator for the containers build system.
//!
//! ## Layout
//!
//! This module is the binary's entry point and nothing else: it initializes
//! tracing and dispatches the parsed command. [`cli`] holds the `clap`
//! argument types, and every command body lives under [`commands`] — including
//! the plumbing they share ([`commands::shared`]). Issue #846 split those out
//! of this file; keeping `main` to the dispatch table alone is what stops it
//! re-accumulating.

mod agent;
mod cli;
mod commands;
mod labels;
mod render;
mod services;
mod wizard;

use clap::Parser;

use crate::cli::{Cli, Commands, LabelsCommand};

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
            if let Err(e) = commands::init::run(non_interactive, config.as_deref()) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Add { features, dev, dry_run, force }) => {
            if let Err(e) = commands::add_remove::run_add(
                &features,
                dev,
                commands::add_remove::WriteMode { dry_run, force },
            ) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Remove { features, cascade, dev_only, dry_run, force }) => {
            if let Err(e) = commands::add_remove::run_remove(
                &features,
                cascade,
                dev_only,
                commands::add_remove::WriteMode { dry_run, force },
            ) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Update { force }) => {
            if let Err(e) = commands::update::run(force) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Agent { command }) => {
            if let Err(e) = agent::run(&command) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Worktree { command }) => {
            if let Err(e) = agent::worktree::run(&command) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Services { command }) => {
            if let Err(e) = services::run(&command) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Labels { command }) => {
            let LabelsCommand::Sync(args) = command;
            if let Err(e) = commands::setup::run_labels_sync(args) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Setup(args)) => {
            if let Err(e) = commands::setup::run_setup(args) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Version) => {
            if let Err(e) = commands::version::run(&mut std::io::stdout()) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Features { format }) => {
            if let Err(e) = commands::features::run(&mut std::io::stdout(), &format) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        Some(Commands::Status) => match commands::status::run(&mut std::io::stdout()) {
            Ok(report) if report.drift => std::process::exit(1),
            Ok(_) => {}
            Err(e) => {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        },
        None => {
            tracing::info!("stibbons v{}", env!("STIBBONS_VERSION"));
            eprintln!(
                "Run `stibbons init` to set up a new project, or `stibbons --help` for usage."
            );
        }
    }
}
