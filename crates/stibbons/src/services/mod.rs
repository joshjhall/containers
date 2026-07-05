//! `stibbons services` — manage the shared service containers (`PostgreSQL`,
//! Redis, …) that run alongside agent containers on the project network.
//!
//! Services are declared in `.igor.yml` under the `services:` map (see
//! [`ServiceConfig`](containers_common::config::ServiceConfig)). This module is
//! the Rust port of the retired Go `igor services` command group (issue #311).
//!
//! It deliberately reuses the agent module's Docker layer rather than
//! duplicating it: the [`DockerRunner`](crate::agent::docker::DockerRunner)
//! abstraction, the [`AgentContext`](crate::agent::context::AgentContext) config
//! resolution (which already parses `services` and the shared network), and the
//! per-agent database helpers in [`crate::agent::db`]. [`run`] is the single
//! entry point wired into `main.rs`.

mod commands;

use clap::Subcommand;

use crate::agent::context::AgentContext;
use crate::agent::docker::ProcessDockerRunner;

/// Default `.igor.yml` path in the project root (matches `agent::CONFIG_PATH`).
const CONFIG_PATH: &str = ".igor.yml";

/// Subcommands under `stibbons services`.
#[derive(Subcommand, Debug)]
pub enum ServicesCommands {
    /// Start all services, or a single named service.
    Start {
        /// Service name from `.igor.yml`; omit to start every service.
        name: Option<String>,
    },

    /// Stop all services, or a single named service.
    Stop {
        /// Service name from `.igor.yml`; omit to stop every service.
        name: Option<String>,

        /// Also remove the container and its named volumes.
        #[arg(long)]
        clean: bool,
    },

    /// Show the network and a status table for every configured service.
    Status,

    /// Reset a service: recreate per-agent databases, or stop+remove otherwise.
    Reset {
        /// Service name from `.igor.yml`.
        name: String,
    },
}

/// Dispatches a `services` subcommand, loading the shared context and shelling
/// to the real Docker CLI.
///
/// # Errors
///
/// Returns an error if `.igor.yml` is missing/invalid or the subcommand fails
/// (unknown service name, Docker failure, etc.).
pub fn run(command: &ServicesCommands) -> Result<(), Box<dyn std::error::Error>> {
    let ctx = AgentContext::load(std::path::Path::new(CONFIG_PATH))?;
    let docker = ProcessDockerRunner;
    let mut out = std::io::stdout();

    match command {
        ServicesCommands::Start { name } => {
            commands::run_start(&ctx, &docker, &mut out, name.as_deref())
        }
        ServicesCommands::Stop { name, clean } => {
            commands::run_stop(&ctx, &docker, &mut out, name.as_deref(), *clean)
        }
        ServicesCommands::Status => commands::run_status(&ctx, &docker, &mut out),
        ServicesCommands::Reset { name } => commands::run_reset(&ctx, &docker, &mut out, name),
    }
}
