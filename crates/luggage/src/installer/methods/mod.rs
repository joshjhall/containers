//! Install-method execution dispatch.
//!
//! Dispatch keys off the catalog's [`InstallMethodKind`] discriminant, not
//! the sibling `name`. `name` is a free string label for diagnostics; a
//! match on it would need one arm per tool forever and would make every new
//! catalog entry a luggage code change. Switching on the kind means a
//! catalog entry using an already-implemented shape needs no code here at
//! all.
//!
//! [`InstallMethodKind::ScriptInstaller`] and
//! [`InstallMethodKind::BinaryTarball`] are wired up; `source-build` and
//! `package-manager` return [`crate::LuggageError::NotImplemented`] and ship
//! in follow-up issues per #405's decomposition note.
//!
//! The catalog-driven layout the methods share — cache dirs, env, `bin_root`
//! symlinks (#806) — lives in [`layout`] rather than in either method, so the
//! two cannot drift apart.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

use containers_common::tooldb::InstallMethodKind;

use crate::error::{LuggageError, Result};

pub mod archive_path;
pub mod layout;
pub mod script_installer;
pub mod tarball;

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
    /// User to run the install as, already resolved by
    /// [`crate::installer::user::resolve_install_user`] (e.g. `vscode`, or
    /// `root` when the resolved user doesn't exist on the system). A `root`
    /// value tells the method to skip the cache-dir `chown`.
    pub user: &'a str,
    /// Cache root (`/cache` in production).
    pub cache_root: &'a Path,
    /// Bin root for symlinks (`/usr/local/bin` in production).
    pub bin_root: &'a Path,
    /// Catalog `binaries` — names to surface in [`Self::bin_root`]. Empty
    /// means link nothing; there is deliberately no per-tool default.
    pub binaries: &'a [String],
    /// Catalog `bin_source_dir` — where [`Self::binaries`] are linked from,
    /// relative to [`Self::cache_root`]. `None` with a non-empty `binaries`
    /// is a catalog defect the method reports.
    pub bin_source_dir: Option<&'a str>,
    /// Catalog `cache_dirs` — env-var name to [`Self::cache_root`]-relative
    /// path. Each is created, chowned to [`Self::user`], and exported.
    pub cache_dirs: &'a BTreeMap<String, String>,
    /// Catalog `prefix` — absolute directory a `binary-tarball` extracts
    /// into. `None` means the method's default (`/usr/local`). Unused by
    /// `script-installer`, whose payload chooses its own destination.
    pub prefix: Option<&'a str>,
    /// Catalog `strip_components` — leading path components to drop from
    /// each archive entry (`tar --strip-components`). `0` keeps the
    /// archive's own top-level directory.
    pub strip_components: u32,
    /// Command runner (production: `ProcessRunner`; tests: `RecordingRunner`).
    pub runner: &'a dyn CommandRunner,
}

/// Dispatch on the catalog's `install_methods[].method_kind`.
///
/// `method_name` is passed for diagnostics only — it never selects the
/// implementation.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for a kind that is valid but not yet
///   wired up (`package-manager`, `source-build`).
/// - [`LuggageError::Catalog`] when the entry carries no `method_kind`, or
///   one this build doesn't recognise. Both are catalog defects rather
///   than missing luggage features, and both are reported rather than
///   guessed at from `method_name`.
pub fn dispatch(
    kind: Option<InstallMethodKind>,
    method_name: &str,
    ctx: &MethodContext<'_>,
) -> Result<()> {
    match kind {
        Some(InstallMethodKind::ScriptInstaller) => script_installer::run(ctx),
        Some(InstallMethodKind::BinaryTarball) => tarball::run(ctx),
        Some(InstallMethodKind::PackageManager) => {
            Err(LuggageError::NotImplemented("install method kind `package-manager` not yet wired"))
        }
        Some(InstallMethodKind::SourceBuild) => {
            Err(LuggageError::NotImplemented("install method kind `source-build` not yet wired"))
        }
        Some(InstallMethodKind::Unknown) => Err(LuggageError::Catalog(format!(
            "install method `{method_name}` declares a `method_kind` this build of luggage \
             does not recognise — upgrade luggage or fix the catalog entry",
        ))),
        None => Err(LuggageError::Catalog(format!(
            "install method `{method_name}` has no `method_kind`; luggage dispatches on that \
             field and will not infer it from the method name",
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// These dispatch tests only assert that a kind bails before touching
    /// anything, so the catalog-driven fields are empty (no binaries to
    /// link, no cache dirs to create) and the install user is always the
    /// unprivileged default — none of them reach the code those vary.
    fn ctx<'a>(
        artifact: &'a Path,
        args: &'a [String],
        env: &'a BTreeMap<String, String>,
        cache: &'a Path,
        bin: &'a Path,
        cache_dirs: &'a BTreeMap<String, String>,
        runner: &'a dyn CommandRunner,
    ) -> MethodContext<'a> {
        MethodContext {
            artifact,
            args,
            env,
            user: "vscode",
            cache_root: cache,
            bin_root: bin,
            binaries: &[],
            bin_source_dir: None,
            cache_dirs,
            prefix: None,
            strip_components: 0,
            runner,
        }
    }

    /// Every not-yet-wired kind must fail as a missing luggage feature,
    /// and must name itself so the message points at the right issue.
    ///
    /// `binary-tarball` is deliberately absent: it is wired as of #808, and
    /// its own dispatch coverage is `dispatch_routes_binary_tarball` below.
    #[test]
    fn dispatch_unwired_kinds_return_not_implemented() {
        for (kind, needle) in [
            (InstallMethodKind::PackageManager, "package-manager"),
            (InstallMethodKind::SourceBuild, "source-build"),
        ] {
            let runner = RecordingRunner::new();
            let env = BTreeMap::new();
            let cache_dirs = BTreeMap::new();
            let args: Vec<String> = vec![];
            let bin = Path::new("/tmp/bin");
            let cache = Path::new("/tmp/cache");
            let artifact = Path::new("/tmp/x");
            let c = ctx(artifact, &args, &env, cache, bin, &cache_dirs, &runner);

            let err = dispatch(Some(kind), "some-method", &c).unwrap_err();
            match err {
                LuggageError::NotImplemented(msg) => assert!(
                    msg.contains(needle),
                    "message for {kind} should name the kind, got: {msg}"
                ),
                other => panic!("expected NotImplemented for {kind}, got {other:?}"),
            }
            assert!(runner.calls().is_empty(), "{kind} must not run anything");
        }
    }

    /// An entry with no `method_kind` is a catalog defect, not a missing
    /// feature — and must NOT fall back to guessing from the name, which is
    /// the behaviour this issue removed.
    #[test]
    fn dispatch_absent_kind_is_a_catalog_error() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let cache_dirs = BTreeMap::new();
        let args: Vec<String> = vec![];
        let bin = Path::new("/tmp/bin");
        let cache = Path::new("/tmp/cache");
        let artifact = Path::new("/tmp/x");
        let c = ctx(artifact, &args, &env, cache, bin, &cache_dirs, &runner);

        // `rustup-init` is precisely the name the old dispatch matched on.
        let err = dispatch(None, "rustup-init", &c).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => {
                assert!(msg.contains("rustup-init"), "should name the method: {msg}");
                assert!(msg.contains("method_kind"), "should name the field: {msg}");
            }
            other => panic!("expected Catalog error, got {other:?}"),
        }
        assert!(runner.calls().is_empty(), "absent kind must not run anything");
    }

    /// A kind from a newer containers-db schema deserializes to `Unknown`
    /// rather than failing to parse; dispatch must then refuse cleanly
    /// instead of panicking.
    #[test]
    fn dispatch_unknown_kind_is_a_catalog_error() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let cache_dirs = BTreeMap::new();
        let args: Vec<String> = vec![];
        let bin = Path::new("/tmp/bin");
        let cache = Path::new("/tmp/cache");
        let artifact = Path::new("/tmp/x");
        let c = ctx(artifact, &args, &env, cache, bin, &cache_dirs, &runner);

        let err = dispatch(Some(InstallMethodKind::Unknown), "future-method", &c).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => {
                assert!(msg.contains("future-method"), "should name the method: {msg}");
            }
            other => panic!("expected Catalog error, got {other:?}"),
        }
        assert!(runner.calls().is_empty(), "unknown kind must not run anything");
    }

    /// The name no longer selects anything: a `script-installer` entry runs
    /// the script installer whatever it is called. `"nvm-install"` is a name
    /// the old literal match would have rejected outright.
    ///
    /// Unix-only, matching `script_installer`'s own `#[cfg(all(test, unix))]`
    /// suite: its `install_symlinks` has a `#[cfg(not(unix))]` arm returning
    /// `NotImplemented`, so asserting a *successful* dispatch is meaningless
    /// on Windows. The error-path tests above stay unconditional — they never
    /// reach the installer.
    #[cfg(unix)]
    #[test]
    fn dispatch_ignores_method_name_for_a_known_kind() {
        let cache = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let artifact = tmp.path().join("installer");
        std::fs::write(&artifact, b"#!/bin/sh\necho stub\n").unwrap();

        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let cache_dirs = BTreeMap::new();
        let args: Vec<String> = vec![];
        let c = ctx(&artifact, &args, &env, cache.path(), bin.path(), &cache_dirs, &runner);

        dispatch(Some(InstallMethodKind::ScriptInstaller), "nvm-install", &c).unwrap();
        assert!(
            runner.calls().iter().any(|(p, _)| p == "su"),
            "script-installer should have run regardless of the method name"
        );
    }

    /// `binary-tarball` must now reach the tarball method rather than
    /// bailing with `NotImplemented`. Proven by the *shape* of the failure:
    /// an artifact whose name carries no recognised compression can only
    /// produce `UnsupportedArchiveFormat` from inside `tarball::run`.
    #[test]
    fn dispatch_routes_binary_tarball() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let cache_dirs = BTreeMap::new();
        let args: Vec<String> = vec![];
        let bin = Path::new("/tmp/bin");
        let cache = Path::new("/tmp/cache");
        let artifact = Path::new("/tmp/payload.bin");
        let c = ctx(artifact, &args, &env, cache, bin, &cache_dirs, &runner);

        let err = dispatch(Some(InstallMethodKind::BinaryTarball), "go-tarball", &c).unwrap_err();
        assert!(
            matches!(err, LuggageError::UnsupportedArchiveFormat { .. }),
            "binary-tarball should reach the tarball method, got {err:?}"
        );
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
