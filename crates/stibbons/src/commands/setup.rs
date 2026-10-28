//! `stibbons labels sync` and `stibbons setup` — repository configuration.
//!
//! Bare `stibbons setup` reconciles skill-defined labels onto the issue
//! tracker (the same body as `labels sync`); `setup standards` applies and
//! checks the repo baseline (see [`crate::standards`]).

use crate::cli::{SetupArgs, SetupCommand, StandardsCommand, SyncArgs};
use crate::labels;
use crate::standards::{self, InitOptions, Templates, manifest::Ci};

/// Outcome of a successful `setup` run that `main` maps to an exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupOutcome {
    /// Completed; exit 0.
    Done,
    /// `setup standards check` found drift; exit 1.
    Drift,
}

/// Runs `stibbons labels sync`: reconcile skill-defined labels onto the repo's
/// issue tracker.
pub fn run_labels_sync(args: SyncArgs) -> Result<(), Box<dyn std::error::Error>> {
    let opts = args.into_options()?;
    labels::run_sync(&opts)
}

/// Runs `stibbons setup`: label sync when bare, else the named subcommand.
pub fn run_setup(args: SetupArgs) -> Result<SetupOutcome, Box<dyn std::error::Error>> {
    match args.command {
        None => {
            let opts = args.sync.into_options()?;
            labels::run_sync(&opts)?;
            println!("\nSetup complete. (Repo baseline: `stibbons setup standards init`.)");
            Ok(SetupOutcome::Done)
        }
        Some(SetupCommand::Standards { command }) => run_standards(command),
    }
}

fn run_standards(command: StandardsCommand) -> Result<SetupOutcome, Box<dyn std::error::Error>> {
    let root = std::env::current_dir()?;
    let mut out = std::io::stdout();
    match command {
        StandardsCommand::Init { lang, ci, force, dry_run, templates } => {
            // Only consult the remote when it can matter: no --ci given.
            let origin_ci = if ci.is_none() { labels::detect_origin_platform() } else { None }.map(
                |p| match p {
                    labels::Platform::GitHub => Ci::GitHub,
                    labels::Platform::GitLab => Ci::GitLab,
                },
            );
            let opts = InitOptions {
                root,
                langs: lang,
                ci,
                origin_ci,
                force,
                dry_run,
                templates: Templates::from_flag(templates.templates_dir),
            };
            standards::init(&opts, &mut out)?;
            Ok(SetupOutcome::Done)
        }
        StandardsCommand::Check { templates } => {
            let report =
                standards::check(&root, &Templates::from_flag(templates.templates_dir), &mut out)?;
            Ok(if report.drift() { SetupOutcome::Drift } else { SetupOutcome::Done })
        }
        StandardsCommand::Accept { paths, templates } => {
            standards::accept(
                &root,
                &Templates::from_flag(templates.templates_dir),
                &paths,
                &mut out,
            )?;
            Ok(SetupOutcome::Done)
        }
    }
}
