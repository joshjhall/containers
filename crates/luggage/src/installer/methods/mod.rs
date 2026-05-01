//! Install-method execution dispatch.
//!
//! Catalog `InstallMethod.name` is a free string; this module dispatches on
//! it. Only the `rustup-init` family (`rustup-init`, `rustup-init-musl`)
//! is wired up in this issue. Everything else returns
//! [`crate::LuggageError::NotImplemented`] and ships in follow-up issues
//! per #405's decomposition note.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

use crate::error::{LuggageError, Result};

pub mod script_installer;

/// Outcome of running a child process.
#[derive(Debug, Clone)]
pub struct CommandOutcome {
    /// Process exit status (`Some(code)` or `None` if the process was
    /// terminated by a signal).
    pub status: Option<i32>,
    /// Captured stdout.
    pub stdout: Vec<u8>,
    /// Captured stderr.
    pub stderr: Vec<u8>,
}

impl CommandOutcome {
    /// True iff the process exited with code 0.
    #[must_use]
    pub const fn success(&self) -> bool {
        matches!(self.status, Some(0))
    }
}

/// Execute argvs. Trait-wrapped so tests can stub.
pub trait CommandRunner: Send + Sync {
    /// Run `program` with `args`. Production runners shell out; test
    /// runners typically record the argv and return a canned outcome.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::InstallStageFailed`] when the runner could not
    ///   even spawn the child process.
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutcome>;
}

/// Production [`CommandRunner`] backed by `std::process::Command`.
#[derive(Debug, Default)]
pub struct ProcessRunner;

impl CommandRunner for ProcessRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutcome> {
        let output = Command::new(program).args(args).output().map_err(|e| {
            LuggageError::InstallStageFailed {
                stage: "spawn",
                message: format!("failed to launch `{program}`: {e}"),
            }
        })?;
        Ok(CommandOutcome {
            status: output.status.code(),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

/// Recording [`CommandRunner`] for hermetic tests.
///
/// Captures every (program, args) pair, then replays a default-success
/// outcome unless a per-program override is wired via [`Self::set_outcome`].
#[derive(Debug, Default)]
pub struct RecordingRunner {
    calls: Mutex<Vec<(String, Vec<String>)>>,
    outcomes: Mutex<Vec<(String, CommandOutcome)>>,
}

impl RecordingRunner {
    /// Build an empty recorder.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Pin the next outcome for a `program` invocation.
    ///
    /// Outcomes are matched FIFO by program name; missing entries default
    /// to exit-0 with empty output.
    ///
    /// # Panics
    ///
    /// Panics if the inner mutex is poisoned.
    pub fn set_outcome(&self, program: &str, outcome: CommandOutcome) {
        self.outcomes.lock().unwrap().push((program.to_owned(), outcome));
    }

    /// Snapshot of recorded calls in invocation order.
    ///
    /// # Panics
    ///
    /// Panics if the inner mutex is poisoned.
    #[must_use]
    pub fn calls(&self) -> Vec<(String, Vec<String>)> {
        self.calls.lock().unwrap().clone()
    }
}

impl CommandRunner for RecordingRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutcome> {
        self.calls.lock().unwrap().push((program.to_owned(), args.to_vec()));
        let pinned = {
            let mut outcomes = self.outcomes.lock().unwrap();
            outcomes.iter().position(|(p, _)| p == program).map(|idx| outcomes.remove(idx).1)
        };
        Ok(pinned.unwrap_or(CommandOutcome {
            status: Some(0),
            stdout: Vec::new(),
            stderr: Vec::new(),
        }))
    }
}

/// Per-method execution context plumbed in from [`super::Installer`].
pub struct MethodContext<'a> {
    /// Path to the downloaded artifact (e.g. `/tmp/.../rustup-init`).
    pub artifact: &'a Path,
    /// Already-substituted installer args from `Invoke.args`.
    pub args: &'a [String],
    /// Already-substituted env exports from `Invoke.env`.
    pub env: &'a BTreeMap<String, String>,
    /// User to run the install as (e.g. `vscode`).
    pub user: &'a str,
    /// Cache root (`/cache` in production).
    pub cache_root: &'a Path,
    /// Bin root for symlinks (`/usr/local/bin` in production).
    pub bin_root: &'a Path,
    /// Command runner (production: `ProcessRunner`; tests: `RecordingRunner`).
    pub runner: &'a dyn CommandRunner,
}

/// Dispatch on `method_name`.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for any method other than the
///   rustup-init shape.
pub fn dispatch(method_name: &str, ctx: &MethodContext<'_>) -> Result<()> {
    match method_name {
        "rustup-init" | "rustup-init-musl" => script_installer::run(ctx),
        _ => Err(LuggageError::NotImplemented(
            "install method not yet wired (only rustup-init/rustup-init-musl in this issue)",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx<'a>(
        artifact: &'a Path,
        args: &'a [String],
        env: &'a BTreeMap<String, String>,
        user: &'a str,
        cache: &'a Path,
        bin: &'a Path,
        runner: &'a dyn CommandRunner,
    ) -> MethodContext<'a> {
        MethodContext { artifact, args, env, user, cache_root: cache, bin_root: bin, runner }
    }

    #[test]
    fn dispatch_unknown_method_returns_not_implemented() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let bin = Path::new("/tmp/bin");
        let cache = Path::new("/tmp/cache");
        let artifact = Path::new("/tmp/x");
        let c = ctx(artifact, &args, &env, "vscode", cache, bin, &runner);
        let err = dispatch("apt", &c).unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn recording_runner_records_argv_and_returns_default_success() {
        let r = RecordingRunner::new();
        let outcome = r.run("ls", &["-la".into()]).unwrap();
        assert!(outcome.success());
        assert_eq!(r.calls(), vec![("ls".to_owned(), vec!["-la".to_owned()])]);
    }

    #[test]
    fn recording_runner_returns_pinned_outcome() {
        let r = RecordingRunner::new();
        r.set_outcome(
            "rustup-init",
            CommandOutcome { status: Some(2), stdout: b"out".to_vec(), stderr: b"err".to_vec() },
        );
        let outcome = r.run("rustup-init", &[]).unwrap();
        assert!(!outcome.success());
        assert_eq!(outcome.status, Some(2));
        assert_eq!(outcome.stderr, b"err");
    }

    #[test]
    fn command_outcome_success_only_for_zero() {
        assert!(CommandOutcome { status: Some(0), stdout: vec![], stderr: vec![] }.success());
        assert!(!CommandOutcome { status: Some(1), stdout: vec![], stderr: vec![] }.success());
        assert!(!CommandOutcome { status: None, stdout: vec![], stderr: vec![] }.success());
    }
}
