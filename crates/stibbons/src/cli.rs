//! `clap` argument types for the `stibbons` CLI.
//!
//! This is the parser's surface only. `stibbons` is a binary crate with no
//! `lib.rs`, so every `pub` here is crate-visible at most — the markers exist
//! so `main`'s dispatch and the [`crate::commands`] bodies can name these
//! types, never to expose a public API.
//!
//! The dispatch that consumes these types lives in `main`; the command bodies
//! live under [`crate::commands`].

use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::{agent, labels, services};

/// Stibbons - Container build system orchestrator.
///
/// Scaffolds devcontainer configurations and manages container builds.
/// (Successor to igor, rewritten in Rust.)
#[derive(Parser, Debug)]
#[command(name = "stibbons", version = env!("STIBBONS_VERSION"), about, long_about = None)]
pub struct Cli {
    /// Enable verbose output.
    #[arg(short, long, global = true)]
    pub verbose: bool,

    #[command(subcommand)]
    pub command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
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

    /// Re-generate devcontainer files from `.igor.yml` after a containers
    /// version bump or config change.
    ///
    /// Re-renders every generated file using the current templates and the
    /// selections stored in `.igor.yml`. Files modified locally are skipped
    /// unless `--force` is given.
    Update {
        /// Overwrite generated files even if they were modified locally.
        #[arg(long)]
        force: bool,
    },

    /// Manage agent containers (build, start, stop, connect).
    Agent {
        #[command(subcommand)]
        command: agent::AgentCommands,
    },

    /// Manage per-agent git worktrees (create, remove, list, sync) with compose
    /// mounts.
    Worktree {
        #[command(subcommand)]
        command: agent::worktree::WorktreeCommands,
    },

    /// Manage service containers (start, stop, status, reset).
    Services {
        #[command(subcommand)]
        command: services::ServicesCommands,
    },

    /// Manage issue-tracker labels defined in skill `metadata.yml` files.
    Labels {
        #[command(subcommand)]
        command: LabelsCommand,
    },

    /// Configure the repository (currently: sync issue-tracker labels).
    ///
    /// An umbrella for repo setup. Today it runs `labels sync`; future
    /// additions (branch protection, CI templates) will hang off the same
    /// command.
    Setup(SyncArgs),

    /// Print the stibbons version (and containers version, when detectable).
    Version,

    /// List all available container features.
    Features {
        /// Output format: `table` (default) or `markdown`.
        #[arg(long, default_value = "table")]
        format: String,
    },

    /// Show enabled features and generated-file health (exit 1 on drift).
    Status,
}

/// `labels` subcommands.
#[derive(Subcommand, Debug)]
pub enum LabelsCommand {
    /// Create/update the tracker's labels to match skill metadata (never deletes).
    Sync(SyncArgs),
}

/// Shared flags for `labels sync` and `setup`.
#[derive(clap::Args, Debug)]
pub struct SyncArgs {
    /// Show the planned changes without applying them.
    #[arg(long)]
    pub dry_run: bool,

    /// Override platform auto-detection (`github` or `gitlab`).
    #[arg(long, value_name = "PLATFORM")]
    pub platform: Option<String>,

    /// Skill directory to scan for `metadata.yml` (repeatable). When omitted,
    /// the in-repo template skills and `/opt/librarian/plugins` are scanned.
    #[arg(long, value_name = "DIR")]
    pub skills_dir: Vec<PathBuf>,
}

impl SyncArgs {
    /// Build [`labels::SyncOptions`] from the parsed flags, validating
    /// `--platform`.
    pub fn into_options(self) -> Result<labels::SyncOptions, Box<dyn std::error::Error>> {
        let platform = self.platform.as_deref().map(labels::parse_platform_flag).transpose()?;
        Ok(labels::SyncOptions { dry_run: self.dry_run, platform, skills_dirs: self.skills_dir })
    }
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

    #[test]
    fn verify_update_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let update = cmd.get_subcommands().find(|s| s.get_name() == "update");
        assert!(update.is_some(), "update subcommand should exist");
    }

    #[test]
    fn verify_update_force_flag() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let update = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "update")
            .expect("update subcommand should exist");
        let has_force = update.get_arguments().any(|a| a.get_id() == "force");
        assert!(has_force, "update should expose a --force flag");
    }

    #[test]
    fn verify_agent_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let agent = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "agent")
            .expect("agent subcommand should exist");
        // Every ported agent subcommand should be wired up.
        let names: Vec<&str> = agent.get_subcommands().map(clap::Command::get_name).collect();
        for want in ["build", "start", "stop", "restart", "status", "logs", "connect"] {
            assert!(names.contains(&want), "agent should expose `{want}` (have {names:?})");
        }
    }

    #[test]
    fn verify_introspection_subcommands() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
        for want in ["version", "features", "status"] {
            assert!(names.contains(&want), "should expose `{want}` (have {names:?})");
        }
    }

    #[test]
    fn features_format_defaults_to_table() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let features = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "features")
            .expect("features subcommand should exist");
        let format = features
            .get_arguments()
            .find(|a| a.get_id() == "format")
            .expect("--format arg should exist");
        let default = format.get_default_values().first().and_then(|v| v.to_str());
        assert_eq!(default, Some("table"), "--format should default to table");
    }

    #[test]
    fn verify_services_subcommand() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let services = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "services")
            .expect("services subcommand should exist");
        let names: Vec<&str> = services.get_subcommands().map(clap::Command::get_name).collect();
        for want in ["start", "stop", "status", "reset"] {
            assert!(names.contains(&want), "services should expose `{want}` (have {names:?})");
        }
    }

    #[test]
    fn verify_services_stop_clean_flag() {
        use clap::CommandFactory;
        let cmd = Cli::command();
        let stop = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "services")
            .and_then(|s| s.get_subcommands().find(|c| c.get_name() == "stop").cloned())
            .expect("services stop subcommand should exist");
        assert!(
            stop.get_arguments().any(|a| a.get_id() == "clean"),
            "services stop should expose a --clean flag"
        );
    }
}
