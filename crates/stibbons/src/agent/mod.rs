//! `stibbons agent` — build, start, and connect to agent containers.
//!
//! Agent containers are headless development environments that run alongside
//! git worktrees, each executing the autonomous golem pipeline for one issue.
//! This module is the Rust port of the retired Go `igor agent` command group
//! (issue #310).
//!
//! Layering:
//!
//! - [`docker`] — the [`DockerRunner`](docker::DockerRunner) abstraction over
//!   the `docker` CLI (with a test double).
//! - [`context`] — [`AgentContext`](context::AgentContext) config resolution and
//!   container-naming/validation helpers.
//! - [`db`] — per-agent `PostgreSQL` provisioning.
//! - [`commands`] — the seven subcommand bodies.
//! - [`worktree`] — the `stibbons worktree` create/remove command group.
//!
//! [`run`] is the entry point for the `agent` subcommands; [`worktree::run`] is
//! the sibling entry point for `stibbons worktree`. Both are wired into
//! `main.rs`.

mod commands;
mod context;
mod db;
mod docker;
#[cfg(test)]
mod test_support;
pub mod worktree;

use clap::Subcommand;

use commands::{ConnectOptions, LogsOptions, StartOptions};
use context::AgentContext;
use docker::ProcessDockerRunner;

/// Default `.igor.yml` path in the project root.
const CONFIG_PATH: &str = ".igor.yml";

/// Subcommands under `stibbons agent`.
#[derive(Subcommand, Debug)]
pub enum AgentCommands {
    /// Build the agent container image.
    Build {
        /// Print the docker build command without executing it.
        #[arg(long)]
        dry_run: bool,
    },

    /// Start agent container N (create if needed, or restart if stopped).
    Start {
        /// Agent number (1..=max).
        n: String,

        /// Rebuild the image before starting.
        #[arg(long)]
        rebuild: bool,
    },

    /// Stop agent container N.
    Stop {
        /// Agent number (1..=max).
        n: String,
    },

    /// Restart agent container N (stop + remove + start).
    Restart {
        /// Agent number (1..=max).
        n: String,
    },

    /// Show status of all agent containers.
    Status,

    /// Show logs for agent container N.
    Logs {
        /// Agent number (1..=max).
        n: String,

        /// Follow log output.
        #[arg(short, long)]
        follow: bool,
    },

    /// Wait for agent container N to be ready, then open an interactive shell.
    Connect {
        /// Agent number (1..=max).
        n: String,

        /// Readiness timeout in seconds.
        #[arg(long, default_value_t = 60)]
        timeout: u64,
    },
}

/// Dispatches an `agent` subcommand, loading the shared context and shelling to
/// the real Docker CLI.
///
/// # Errors
///
/// Returns an error if `.igor.yml` is missing/invalid or the subcommand fails
/// (bad agent number, Docker failure, etc.).
pub fn run(command: &AgentCommands) -> Result<(), Box<dyn std::error::Error>> {
    let ctx = AgentContext::load(std::path::Path::new(CONFIG_PATH))?;
    let docker = ProcessDockerRunner;
    let mut out = std::io::stdout();

    match command {
        AgentCommands::Build { dry_run } => commands::run_build(&ctx, &docker, &mut out, *dry_run),
        AgentCommands::Start { n, rebuild } => {
            commands::run_start(&ctx, &docker, &mut out, n, StartOptions { rebuild: *rebuild })
        }
        AgentCommands::Stop { n } => commands::run_stop(&ctx, &docker, &mut out, n),
        AgentCommands::Restart { n } => commands::run_restart(&ctx, &docker, &mut out, n),
        AgentCommands::Status => commands::run_status(&ctx, &docker, &mut out),
        AgentCommands::Logs { n, follow } => {
            commands::run_logs(&ctx, &docker, &mut out, n, LogsOptions { follow: *follow })
        }
        AgentCommands::Connect { n, timeout } => {
            commands::run_connect(&ctx, &docker, &mut out, n, ConnectOptions { timeout: *timeout })
        }
    }
}
