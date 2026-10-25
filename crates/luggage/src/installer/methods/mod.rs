//! Install-method execution dispatch.
//!
//! Dispatch keys off the catalog's [`InstallMethodKind`] discriminant, not
//! the sibling `name`. `name` is a free string label for diagnostics; a
//! match on it would need one arm per tool forever and would make every new
//! catalog entry a luggage code change. Switching on the kind means a
//! catalog entry using an already-implemented shape needs no code here at
//! all.
//!
//! [`InstallMethodKind::ScriptInstaller`],
//! [`InstallMethodKind::BinaryTarball`], and
//! [`InstallMethodKind::SourceBuild`] are wired up; `package-manager`
//! returns [`crate::LuggageError::NotImplemented`] and ships in a follow-up
//! issue per #405's decomposition note.
//!
//! The catalog-driven layout the methods share — cache dirs, env, `bin_root`
//! symlinks (#806) — lives in [`layout`] rather than in either method, so the
//! two cannot drift apart.

use std::collections::{BTreeMap, VecDeque};
use std::io::{BufRead as _, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, mpsc};

use containers_common::tooldb::{BuildStep, InstallMethodKind};

use super::logging::FeatureLogger;
use crate::error::{LuggageError, Result};

pub mod archive_limit;
pub mod archive_path;
pub mod layout;
pub mod script_installer;
pub mod source_build;
pub mod tarball;

/// Stderr lines a streamed command keeps for its error report.
///
/// Everything is forwarded to the log as it arrives; only this tail is held
/// in memory, because a PGO python build writes far more stderr than is
/// worth buffering and the cause of a failure is almost always at the end.
pub const STDERR_TAIL_LINES: usize = 40;

/// A command run through [`CommandRunner::run_streaming`].
#[derive(Debug, Clone, Copy)]
pub struct StreamingCommand<'a> {
    /// Program to execute — an absolute path or a bare name looked up on
    /// `PATH`.
    pub program: &'a str,
    /// Argument vector.
    pub args: &'a [String],
    /// Working directory for the child.
    pub cwd: &'a Path,
    /// Variables added to the inherited environment.
    pub env: &'a BTreeMap<String, String>,
}

/// One [`CommandRunner::run_streaming`] call as [`RecordingRunner`] saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamingCall {
    /// Program executed.
    pub program: String,
    /// Argument vector.
    pub args: Vec<String>,
    /// Working directory the child was given.
    pub cwd: PathBuf,
    /// Environment additions the child was given.
    pub env: BTreeMap<String, String>,
}

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

    /// Run `cmd`, handing each output line to `on_line` as it is produced.
    ///
    /// For long-running steps (a source build's `make`) that must show
    /// progress rather than buffer silently for minutes. The returned
    /// outcome's `stderr` holds only the last [`STDERR_TAIL_LINES`] lines;
    /// `stdout` is empty, since every line already went to `on_line`.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::InstallStageFailed`] when the child could not be
    ///   spawned or waited on.
    fn run_streaming(
        &self,
        cmd: &StreamingCommand<'_>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<CommandOutcome>;
}

/// Keeps the last [`STDERR_TAIL_LINES`] lines of a stream.
#[derive(Debug, Default)]
struct Tail(VecDeque<String>);

impl Tail {
    fn push(&mut self, line: &str) {
        if self.0.len() == STDERR_TAIL_LINES {
            self.0.pop_front();
        }
        self.0.push_back(line.to_owned());
    }

    fn into_bytes(self) -> Vec<u8> {
        Vec::from(self.0).join("\n").into_bytes()
    }
}

/// Which pipe a streamed line came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pipe {
    Stdout,
    Stderr,
}

/// Forward every line of `pipe` to `tx`, tagged with `which`.
///
/// Lossy UTF-8: a compiler printing a non-UTF-8 byte must not stall the
/// stream or abort the build's log.
fn pump(pipe: impl Read, which: Pipe, tx: &mpsc::Sender<(Pipe, String)>) {
    let mut reader = BufReader::new(pipe);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => return,
            Ok(_) => {
                let line = String::from_utf8_lossy(&buf);
                let line = line.trim_end_matches(['\n', '\r']).to_owned();
                if tx.send((which, line)).is_err() {
                    return;
                }
            }
        }
    }
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

    fn run_streaming(
        &self,
        cmd: &StreamingCommand<'_>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<CommandOutcome> {
        let program = cmd.program;
        let mut child = Command::new(program)
            .args(cmd.args)
            .current_dir(cmd.cwd)
            .envs(cmd.env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| LuggageError::InstallStageFailed {
                stage: "spawn",
                message: format!("failed to launch `{program}` in {}: {e}", cmd.cwd.display()),
            })?;

        // Both pipes are drained concurrently: reading one to EOF before the
        // other deadlocks once the unread pipe's buffer fills and the child
        // blocks writing to it. Lines from both arrive on one channel, so the
        // log interleaves them in roughly the order they were written.
        let (tx, rx) = mpsc::channel();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let mut tail = Tail::default();
        let status = std::thread::scope(|scope| {
            if let Some(pipe) = stdout {
                let tx = tx.clone();
                scope.spawn(move || pump(pipe, Pipe::Stdout, &tx));
            }
            if let Some(pipe) = stderr {
                let tx = tx.clone();
                scope.spawn(move || pump(pipe, Pipe::Stderr, &tx));
            }
            drop(tx);
            for (which, line) in rx {
                if which == Pipe::Stderr {
                    tail.push(&line);
                }
                on_line(&line);
            }
            child.wait()
        })
        .map_err(|e| LuggageError::InstallStageFailed {
            stage: "spawn",
            message: format!("failed to wait for `{program}`: {e}"),
        })?;

        Ok(CommandOutcome { status: status.code(), stdout: Vec::new(), stderr: tail.into_bytes() })
    }
}

/// Recording [`CommandRunner`] for hermetic tests.
///
/// Captures every (program, args) pair, then replays a default-success
/// outcome unless a per-program override is wired via [`Self::set_outcome`].
#[derive(Debug, Default)]
pub struct RecordingRunner {
    calls: Mutex<Vec<(String, Vec<String>)>>,
    streaming_calls: Mutex<Vec<StreamingCall>>,
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

    /// Snapshot of [`CommandRunner::run_streaming`] calls, with the cwd and
    /// env each was given, in invocation order. Streaming calls also appear
    /// in [`Self::calls`], so ordering across both kinds stays observable.
    ///
    /// # Panics
    ///
    /// Panics if the inner mutex is poisoned.
    #[must_use]
    pub fn streaming_calls(&self) -> Vec<StreamingCall> {
        self.streaming_calls.lock().unwrap().clone()
    }

    /// Record `(program, args)` and pop the pinned outcome for `program`.
    fn record(&self, program: &str, args: &[String]) -> CommandOutcome {
        self.calls.lock().unwrap().push((program.to_owned(), args.to_vec()));
        let pinned = {
            let mut outcomes = self.outcomes.lock().unwrap();
            outcomes.iter().position(|(p, _)| p == program).map(|idx| outcomes.remove(idx).1)
        };
        pinned.unwrap_or(CommandOutcome { status: Some(0), stdout: Vec::new(), stderr: Vec::new() })
    }
}

impl CommandRunner for RecordingRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutcome> {
        Ok(self.record(program, args))
    }

    /// Replays the pinned outcome's stdout then stderr through `on_line`, a
    /// line at a time, and returns the stderr tail — the same contract
    /// [`ProcessRunner`] honours, without spawning anything.
    fn run_streaming(
        &self,
        cmd: &StreamingCommand<'_>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<CommandOutcome> {
        let outcome = self.record(cmd.program, cmd.args);
        self.streaming_calls.lock().unwrap().push(StreamingCall {
            program: cmd.program.to_owned(),
            args: cmd.args.to_vec(),
            cwd: cmd.cwd.to_owned(),
            env: cmd.env.clone(),
        });
        let mut tail = Tail::default();
        for line in String::from_utf8_lossy(&outcome.stdout).lines() {
            on_line(line);
        }
        for line in String::from_utf8_lossy(&outcome.stderr).lines() {
            tail.push(line);
            on_line(line);
        }
        Ok(CommandOutcome { status: outcome.status, stdout: Vec::new(), stderr: tail.into_bytes() })
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
    /// Ceiling on total decompressed bytes a `binary-tarball` may produce,
    /// guarding against decompression bombs. See
    /// [`archive_limit::DEFAULT_MAX_EXTRACT_BYTES`].
    pub max_extract_bytes: u64,
    /// Catalog `build_steps` — the ordered commands a `source-build` runs in
    /// the extracted source tree. Empty for every other kind.
    pub build_steps: &'a [BuildStep],
    /// Per-feature log that long-running steps stream their output into.
    /// `None` when the log could not be opened; output then goes to
    /// `tracing` only.
    pub log: Option<&'a FeatureLogger>,
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
///   wired up (`package-manager`).
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
        Some(InstallMethodKind::SourceBuild) => source_build::run(ctx),
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
            max_extract_bytes: archive_limit::DEFAULT_MAX_EXTRACT_BYTES,
            build_steps: &[],
            log: None,
            runner,
        }
    }

    /// Every not-yet-wired kind must fail as a missing luggage feature,
    /// and must name itself so the message points at the right issue.
    ///
    /// `binary-tarball` (#808) and `source-build` (#809) are deliberately
    /// absent: both are wired, and each has its own `dispatch_routes_*`
    /// coverage below.
    #[test]
    fn dispatch_unwired_kinds_return_not_implemented() {
        #[allow(clippy::single_element_loop)] // one unwired kind left; the next joins this list
        for (kind, needle) in [(InstallMethodKind::PackageManager, "package-manager")] {
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

    /// `source-build` must reach the source-build method rather than bailing
    /// with `NotImplemented`. The test context carries no `build_steps`, and
    /// only `source_build::run` raises a Catalog error naming that field.
    #[test]
    fn dispatch_routes_source_build() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let cache_dirs = BTreeMap::new();
        let args: Vec<String> = vec![];
        let bin = Path::new("/tmp/bin");
        let cache = Path::new("/tmp/cache");
        let artifact = Path::new("/tmp/Python-3.13.1.tgz");
        let c = ctx(artifact, &args, &env, cache, bin, &cache_dirs, &runner);

        let err = dispatch(Some(InstallMethodKind::SourceBuild), "python-source", &c).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => assert!(msg.contains("build_steps"), "{msg}"),
            other => panic!("source-build should reach the source-build method, got {other:?}"),
        }
        assert_eq!(runner.calls(), []);
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
