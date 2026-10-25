//! Unit tests for the `source-build` method.
//!
//! Hermetic: every step goes through [`RecordingRunner`], so nothing is
//! compiled. Extraction is real (it is in-process, shared with
//! `binary-tarball`), which is what lets these tests assert the cwd a step
//! was given actually holds the unpacked source.

use super::*;

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;

use tar::{Builder, Header};
use tempfile::tempdir;

use crate::installer::methods::archive_limit::DEFAULT_MAX_EXTRACT_BYTES;
use crate::installer::methods::{CommandOutcome, CommandRunner, ProcessRunner, RecordingRunner};

/// A gzip'd tar of `entries`, built in-test rather than checked in.
fn tgz(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut builder = Builder::new(Vec::new());
    for (path, contents) in entries {
        let mut header = Header::new_gnu();
        header.set_size(contents.len() as u64);
        header.set_mode(0o755);
        header.as_old_mut().name[..path.len()].copy_from_slice(path.as_bytes());
        header.set_cksum();
        builder.append(&header, *contents).unwrap();
    }
    let raw = builder.into_inner().unwrap();
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&raw).unwrap();
    encoder.finish().unwrap()
}

/// python's shape: a versioned root holding `configure` and a `Makefile`.
fn python_like() -> Vec<u8> {
    tgz(&[("Python-3.13.1/configure", b"#!/bin/sh\n"), ("Python-3.13.1/Makefile", b"all:\n")])
}

fn step(command: &str, args: &[&str]) -> BuildStep {
    BuildStep {
        command: command.to_owned(),
        args: Some(args.iter().map(|a| (*a).to_owned()).collect()),
    }
}

/// The three-step python build.
fn python_steps() -> Vec<BuildStep> {
    vec![
        step("./configure", &["--prefix=/usr/local", "LDFLAGS=-Wl,-rpath /usr/local/lib"]),
        step("make", &["-j{nproc}"]),
        step("make", &["install"]),
    ]
}

fn failure(stderr: &str) -> CommandOutcome {
    CommandOutcome { status: Some(2), stdout: Vec::new(), stderr: stderr.as_bytes().to_vec() }
}

/// Owns the tempdirs for a run so they outlive the borrowed context.
struct Fixture {
    tmp: tempfile::TempDir,
    cache: tempfile::TempDir,
    bin: tempfile::TempDir,
    prefix: tempfile::TempDir,
    artifact: PathBuf,
    runner: RecordingRunner,
}

impl Fixture {
    fn new(name: &str, bytes: &[u8]) -> Self {
        let tmp = tempdir().unwrap();
        let artifact = tmp.path().join(name);
        fs::write(&artifact, bytes).unwrap();
        Self {
            tmp,
            cache: tempdir().unwrap(),
            bin: tempdir().unwrap(),
            prefix: tempdir().unwrap(),
            artifact,
            runner: RecordingRunner::new(),
        }
    }

    fn python() -> Self {
        Self::new("Python-3.13.1.tgz", &python_like())
    }

    fn run_full(
        &self,
        steps: &[BuildStep],
        strip: u32,
        binaries: &[String],
        bin_source_dir: Option<&str>,
        cache_dirs: &BTreeMap<String, String>,
        env: &BTreeMap<String, String>,
    ) -> Result<()> {
        let args: Vec<String> = vec![];
        let prefix = self.prefix.path().display().to_string();
        run(&MethodContext {
            artifact: &self.artifact,
            args: &args,
            env,
            user: "root",
            cache_root: self.cache.path(),
            bin_root: self.bin.path(),
            binaries,
            bin_source_dir,
            cache_dirs,
            prefix: Some(&prefix),
            strip_components: strip,
            max_extract_bytes: DEFAULT_MAX_EXTRACT_BYTES,
            build_steps: steps,
            log: None,
            runner: &self.runner,
        })
    }

    fn run(&self, steps: &[BuildStep], strip: u32) -> Result<()> {
        self.run_full(steps, strip, &[], None, &BTreeMap::new(), &BTreeMap::new())
    }

    /// Scratch build dirs still present beside the artifact.
    fn leftover_build_dirs(&self) -> Vec<String> {
        fs::read_dir(self.tmp.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(BUILD_DIR_PREFIX))
            .collect()
    }
}

// ---- ordering, cwd, and argv -------------------------------------------

/// The core contract: steps run in catalog order, each in the extracted
/// source root, with `./configure` anchored to that root.
#[test]
fn runs_steps_in_order_in_the_extracted_source_root() {
    let f = Fixture::python();
    f.run(&python_steps(), 1).unwrap();

    let calls = f.runner.streaming_calls();
    assert_eq!(calls.len(), 3);

    // Every step shares one cwd, and it really is the unpacked tree —
    // strip 1 flattened `Python-3.13.1/` so `configure` sits at its root.
    let cwd = &calls[0].cwd;
    assert!(calls.iter().all(|c| &c.cwd == cwd), "steps must share the source root");
    assert!(
        cwd.file_name().unwrap().to_string_lossy().starts_with(BUILD_DIR_PREFIX),
        "cwd should be the scratch build dir: {}",
        cwd.display()
    );

    assert_eq!(Path::new(&calls[0].program), cwd.join("configure"));
    assert_eq!(
        calls[0].args,
        vec!["--prefix=/usr/local".to_owned(), "LDFLAGS=-Wl,-rpath /usr/local/lib".to_owned()],
        "an arg with spaces must reach the step as one argv entry",
    );
    assert_eq!(calls[1].program, "make");
    assert_eq!(calls[2].program, "make");
    assert_eq!(calls[2].args, vec!["install".to_owned()]);
}

/// The recorded cwd is gone by the time a test can look at it, so this
/// runner checks it *during* each step: the extracted `configure` and
/// `Makefile` must be sitting in the directory the step was handed.
#[test]
fn each_step_sees_the_extracted_tree_in_its_cwd() {
    struct InspectingRunner(std::sync::Mutex<Vec<bool>>);
    impl CommandRunner for InspectingRunner {
        fn run(&self, _: &str, _: &[String]) -> Result<CommandOutcome> {
            Ok(CommandOutcome { status: Some(0), stdout: Vec::new(), stderr: Vec::new() })
        }
        fn run_streaming(
            &self,
            cmd: &StreamingCommand<'_>,
            _: &mut dyn FnMut(&str),
        ) -> Result<CommandOutcome> {
            let ok = cmd.cwd.join("configure").is_file() && cmd.cwd.join("Makefile").is_file();
            self.0.lock().unwrap().push(ok);
            self.run(cmd.program, cmd.args)
        }
    }

    let f = Fixture::python();
    let runner = InspectingRunner(std::sync::Mutex::new(Vec::new()));
    let args: Vec<String> = vec![];
    let env = BTreeMap::new();
    let cache_dirs = BTreeMap::new();
    let steps = python_steps();
    run(&MethodContext {
        artifact: &f.artifact,
        args: &args,
        env: &env,
        user: "root",
        cache_root: f.cache.path(),
        bin_root: f.bin.path(),
        binaries: &[],
        bin_source_dir: None,
        cache_dirs: &cache_dirs,
        prefix: None,
        strip_components: 1,
        max_extract_bytes: DEFAULT_MAX_EXTRACT_BYTES,
        build_steps: &steps,
        log: None,
        runner: &runner,
    })
    .unwrap();

    assert_eq!(*runner.0.lock().unwrap(), [true, true, true]);
}

/// At strip 0 the archive keeps its `Python-3.13.1/` root inside the build
/// dir, and a relative-with-separator command still anchors to the build
/// dir rather than the process cwd.
#[test]
fn strip_zero_keeps_the_versioned_root_under_the_build_dir() {
    let f = Fixture::python();
    // At strip 0 `./configure` is NOT at the build-dir root, so a catalog
    // entry for that layout would name `./Python-3.13.1/configure`. The
    // relative-with-separator rule anchors it to the root all the same.
    f.run(&[step("./Python-3.13.1/configure", &[])], 0).unwrap();

    let calls = f.runner.streaming_calls();
    assert_eq!(Path::new(&calls[0].program), calls[0].cwd.join("Python-3.13.1/configure"));
}

/// `{nproc}` expands to the host's available parallelism — the value
/// `make -j"$(nproc)"` produced in python.sh.
#[test]
fn nproc_placeholder_resolves_to_host_cpu_count() {
    let f = Fixture::python();
    f.run(&python_steps(), 1).unwrap();

    let expected = std::thread::available_parallelism().unwrap().get();
    let calls = f.runner.streaming_calls();
    assert_eq!(calls[1].args, vec![format!("-j{expected}")]);
}

/// Any placeholder besides `{nproc}` is a catalog error raised before the
/// step runs — never passed through as a literal `{version}`.
#[test]
fn unknown_placeholder_fails_before_the_step_runs() {
    let f = Fixture::python();
    let err = f.run(&[step("make", &["VERSION={version}"])], 1).unwrap_err();

    match err {
        LuggageError::TemplateMissingKey(key) => assert_eq!(key, "version"),
        other => panic!("expected TemplateMissingKey, got {other:?}"),
    }
    assert_eq!(f.runner.streaming_calls(), []);
}

/// A bare command is left for `PATH`; an absolute one is used as-is.
#[test]
fn resolve_command_anchors_only_relative_paths_with_a_separator() {
    let root = Path::new("/build/src");
    assert_eq!(resolve_command("./configure", root), root.join("configure"));
    assert_eq!(resolve_command("tools/gen.sh", root), root.join("tools/gen.sh"));
    assert_eq!(resolve_command("make", root), PathBuf::from("make"));
    assert_eq!(resolve_command("/usr/bin/make", root), PathBuf::from("/usr/bin/make"));
}

// ---- failure reporting -------------------------------------------------

/// A failing step aborts the build: later steps never run, and the error
/// names the step's position, its argv as the catalog wrote it, and the
/// stderr tail.
#[test]
fn first_failing_step_aborts_with_index_argv_and_stderr_tail() {
    let f = Fixture::python();
    // `./configure` resolves to an absolute path, so `make` is the first
    // program the pin can match — step 2, `make -j{nproc}`.
    f.runner.set_outcome("make", failure("cc: fatal error\nmake: *** [all] Error 1"));

    let err = f.run(&python_steps(), 1).unwrap_err();
    let nproc = std::thread::available_parallelism().unwrap().get();
    match err {
        LuggageError::BuildStepFailed { step, total, argv, status, stderr_tail } => {
            assert_eq!(step, 2);
            assert_eq!(total, 3);
            assert_eq!(argv, format!("make -j{nproc}"));
            assert_eq!(status, Some(2));
            assert!(stderr_tail.ends_with("make: *** [all] Error 1"), "{stderr_tail}");
        }
        other => panic!("expected BuildStepFailed, got {other:?}"),
    }
    let calls = f.runner.streaming_calls();
    assert_eq!(calls.len(), 2, "`make install` must not run after a failed build");
}

/// The argv in the error is the catalog's spelling — `./configure` — not the
/// scratch-dir absolute path nobody can act on after cleanup, and an arg
/// with spaces is quoted so the reported command is copy-pasteable.
#[test]
fn failure_argv_uses_the_catalog_spelling_and_quotes_spaced_args() {
    // The spawned program is `<scratch>/configure`, unknown until the run
    // creates the scratch dir, so a by-name pin cannot target it. Fail it
    // with a runner that rejects everything instead.
    struct AlwaysFails;
    impl CommandRunner for AlwaysFails {
        fn run(&self, _: &str, _: &[String]) -> Result<CommandOutcome> {
            Ok(failure("configure: error: no C compiler"))
        }
        fn run_streaming(
            &self,
            _: &StreamingCommand<'_>,
            _: &mut dyn FnMut(&str),
        ) -> Result<CommandOutcome> {
            Ok(failure("configure: error: no C compiler"))
        }
    }

    let f = Fixture::python();
    let args: Vec<String> = vec![];
    let env = BTreeMap::new();
    let cache_dirs = BTreeMap::new();
    let steps = vec![step("./configure", &["LDFLAGS=-Wl,-rpath /usr/local/lib"])];
    let err = run(&MethodContext {
        artifact: &f.artifact,
        args: &args,
        env: &env,
        user: "root",
        cache_root: f.cache.path(),
        bin_root: f.bin.path(),
        binaries: &[],
        bin_source_dir: None,
        cache_dirs: &cache_dirs,
        prefix: None,
        strip_components: 1,
        max_extract_bytes: DEFAULT_MAX_EXTRACT_BYTES,
        build_steps: &steps,
        log: None,
        runner: &AlwaysFails,
    })
    .unwrap_err();

    match err {
        LuggageError::BuildStepFailed { step, argv, stderr_tail, .. } => {
            assert_eq!(step, 1);
            assert_eq!(argv, "./configure 'LDFLAGS=-Wl,-rpath /usr/local/lib'");
            assert_eq!(stderr_tail, "configure: error: no C compiler");
        }
        other => panic!("expected BuildStepFailed, got {other:?}"),
    }
}

/// Only the last [`STDERR_TAIL_LINES`] of stderr reach the error — a failed
/// PGO build must not carry its whole log in a single error string.
#[test]
fn stderr_tail_is_bounded() {
    let f = Fixture::python();
    let noisy: String = (0..500).fold(String::new(), |mut acc, i| {
        let _ = writeln!(acc, "line {i}");
        acc
    });
    f.runner.set_outcome("make", failure(&noisy));

    let err = f.run(&[step("make", &[])], 1).unwrap_err();
    let LuggageError::BuildStepFailed { stderr_tail, .. } = err else { panic!("{err:?}") };
    let lines: Vec<_> = stderr_tail.lines().collect();
    assert_eq!(lines.len(), super::super::STDERR_TAIL_LINES);
    assert_eq!(*lines.last().unwrap(), "line 499");
    assert!(!stderr_tail.contains("line 0\n"));
}

// ---- cleanup -----------------------------------------------------------

#[test]
fn scratch_build_dir_is_removed_on_success() {
    let f = Fixture::python();
    f.run(&python_steps(), 1).unwrap();
    assert_eq!(f.leftover_build_dirs(), Vec::<String>::new());
    // The cwd the steps saw is gone too — not just some other dir.
    assert!(!f.runner.streaming_calls()[0].cwd.exists());
}

#[test]
fn scratch_build_dir_is_removed_on_step_failure() {
    let f = Fixture::python();
    f.runner.set_outcome("make", failure("boom"));
    f.run(&python_steps(), 1).unwrap_err();
    assert_eq!(f.leftover_build_dirs(), Vec::<String>::new());
}

/// A traversal entry is rejected by the shared extractor before any step
/// runs — the build never executes a tree that failed validation — and the
/// scratch dir is still cleaned up.
#[test]
fn unsafe_archive_is_rejected_before_any_step_and_cleaned_up() {
    let evil = tgz(&[("Python-3.13.1/configure", b"ok"), ("../../etc/passwd", b"pwned")]);
    let f = Fixture::new("Python-3.13.1.tgz", &evil);

    let err = f.run(&python_steps(), 1).unwrap_err();
    assert!(matches!(err, LuggageError::UnsafeArchiveEntry { .. }), "{err:?}");
    assert_eq!(f.runner.streaming_calls(), []);
    assert_eq!(f.leftover_build_dirs(), Vec::<String>::new());
}

// ---- catalog validation ------------------------------------------------

#[test]
fn empty_build_steps_is_a_catalog_error_that_runs_nothing() {
    let f = Fixture::python();
    let err = f.run(&[], 1).unwrap_err();
    match err {
        LuggageError::Catalog(msg) => assert!(msg.contains("build_steps"), "{msg}"),
        other => panic!("expected Catalog, got {other:?}"),
    }
    assert_eq!(f.runner.calls(), []);
    assert_eq!(f.leftover_build_dirs(), Vec::<String>::new());
}

#[test]
fn blank_step_command_is_a_catalog_error() {
    let f = Fixture::python();
    let err = f.run(&[step("make", &[]), step("  ", &[])], 1).unwrap_err();
    match err {
        LuggageError::Catalog(msg) => assert!(msg.contains("step 2 of 2"), "{msg}"),
        other => panic!("expected Catalog, got {other:?}"),
    }
    assert_eq!(f.runner.streaming_calls(), [], "validation precedes every step");
}

// ---- layout (#806) -----------------------------------------------------

/// Cache dirs are created and exported to every step, layered under an
/// explicit `invoke.env` value for the same variable.
#[test]
fn cache_dirs_and_invoke_env_reach_every_step() {
    let f = Fixture::python();
    let cache_dirs = BTreeMap::from([("PIP_CACHE_DIR".to_owned(), "pip".to_owned())]);
    let env = BTreeMap::from([("CFLAGS".to_owned(), "-O2".to_owned())]);
    f.run_full(&python_steps(), 1, &[], None, &cache_dirs, &env).unwrap();

    let pip = f.cache.path().join("pip");
    assert!(pip.is_dir(), "cache dir should be created");
    for call in f.runner.streaming_calls() {
        assert_eq!(call.env.get("PIP_CACHE_DIR"), Some(&pip.display().to_string()));
        assert_eq!(call.env.get("CFLAGS").map(String::as_str), Some("-O2"));
    }
}

/// Binaries link out of the prefix, as for a tarball — `make install` put
/// them there, not under the cache root.
#[test]
fn binaries_are_symlinked_from_the_prefix() {
    let f = Fixture::python();
    fs::create_dir_all(f.prefix.path().join("bin")).unwrap();
    fs::write(f.prefix.path().join("bin/python3"), b"").unwrap();
    let binaries = vec!["python3".to_owned()];

    f.run_full(&python_steps(), 1, &binaries, Some("bin"), &BTreeMap::new(), &BTreeMap::new())
        .unwrap();

    let link = f.bin.path().join("python3");
    assert_eq!(fs::read_link(&link).unwrap(), f.prefix.path().join("bin/python3"));
}

/// Binaries with no `bin_source_dir` are a catalog defect — but one only
/// detectable after the build, so the build runs first and a step failure
/// is what gets reported when both are wrong.
#[test]
fn binaries_without_bin_source_dir_is_a_catalog_error() {
    let f = Fixture::python();
    let binaries = vec!["python3".to_owned()];
    let err = f
        .run_full(&python_steps(), 1, &binaries, None, &BTreeMap::new(), &BTreeMap::new())
        .unwrap_err();
    assert!(matches!(err, LuggageError::Catalog(_)), "{err:?}");
    assert_eq!(f.runner.streaming_calls().len(), 3, "every step runs before linking");

    let g = Fixture::python();
    g.runner.set_outcome("make", failure("boom"));
    let err = g
        .run_full(&python_steps(), 1, &binaries, None, &BTreeMap::new(), &BTreeMap::new())
        .unwrap_err();
    assert!(matches!(err, LuggageError::BuildStepFailed { step: 2, .. }), "{err:?}");
}

/// The #809 progress requirement: with a feature log open, each step's
/// banner and every streamed line land in it — not just in `tracing`.
#[test]
fn steps_stream_banner_and_output_into_the_feature_log() {
    let f = Fixture::python();
    f.runner.set_outcome(
        "make",
        CommandOutcome {
            status: Some(0),
            stdout: b"gcc -c Python/ceval.c\n".to_vec(),
            stderr: b"warning: unused variable\n".to_vec(),
        },
    );
    let log_dir = tempdir().unwrap();
    let logger =
        crate::installer::logging::FeatureLogger::open(log_dir.path(), "python", "3.13.1").unwrap();
    let args: Vec<String> = vec![];
    let env = BTreeMap::new();
    let cache_dirs = BTreeMap::new();
    let steps = python_steps();
    run(&MethodContext {
        artifact: &f.artifact,
        args: &args,
        env: &env,
        user: "root",
        cache_root: f.cache.path(),
        bin_root: f.bin.path(),
        binaries: &[],
        bin_source_dir: None,
        cache_dirs: &cache_dirs,
        prefix: None,
        strip_components: 1,
        max_extract_bytes: DEFAULT_MAX_EXTRACT_BYTES,
        build_steps: &steps,
        log: Some(&logger),
        runner: &f.runner,
    })
    .unwrap();

    let log = fs::read_to_string(logger.path()).unwrap();
    let nproc = std::thread::available_parallelism().unwrap().get();
    for needle in [
        "build step 1/3: ./configure",
        &format!("build step 2/3: make -j{nproc}"),
        "build step 3/3: make install",
        "gcc -c Python/ceval.c",
        "warning: unused variable",
    ] {
        assert!(log.contains(needle), "log missing {needle:?}:\n{log}");
    }
    // Order matters: step 2's output follows step 2's banner.
    let banner = log.find("build step 2/3").unwrap();
    assert!(log.find("gcc -c Python/ceval.c").unwrap() > banner, "{log}");
}

// ---- streaming ---------------------------------------------------------

/// Every line a step writes reaches the log callback, stdout then stderr,
/// as `RecordingRunner` replays them — the hook the per-feature log uses.
#[test]
fn recording_runner_streams_lines_through_the_callback() {
    let runner = RecordingRunner::new();
    runner.set_outcome(
        "make",
        CommandOutcome {
            status: Some(0),
            stdout: b"compiling a.c\ncompiling b.c\n".to_vec(),
            stderr: b"warning: x\n".to_vec(),
        },
    );
    let env = BTreeMap::new();
    let cmd = StreamingCommand { program: "make", args: &[], cwd: Path::new("/src"), env: &env };
    let mut seen = Vec::new();
    let outcome = runner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();

    assert_eq!(seen, ["compiling a.c", "compiling b.c", "warning: x"]);
    assert!(outcome.success());
    assert_eq!(outcome.stderr, b"warning: x");
}

/// The production runner, against a real `sh`: it runs in the requested
/// cwd with the requested env, forwards both pipes, and keeps a bounded
/// stderr tail. No compiler involved — this is the plumbing python's
/// `make` will go through.
#[test]
fn process_runner_streams_with_cwd_env_and_bounded_tail() {
    let dir = tempdir().unwrap();
    let env = BTreeMap::from([("LUGGAGE_TEST_VAR".to_owned(), "hello".to_owned())]);
    let script = "pwd; echo \"$LUGGAGE_TEST_VAR\"; \
                  i=0; while [ $i -lt 100 ]; do echo err$i >&2; i=$((i+1)); done; exit 3";
    let args = vec!["-c".to_owned(), script.to_owned()];
    let cmd = StreamingCommand { program: "sh", args: &args, cwd: dir.path(), env: &env };

    let mut seen = Vec::new();
    let outcome = ProcessRunner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();

    assert_eq!(outcome.status, Some(3));
    let cwd = fs::canonicalize(dir.path()).unwrap();
    assert!(seen.iter().any(|l| Path::new(l) == cwd), "pwd should be the cwd: {seen:?}");
    assert!(seen.iter().any(|l| l == "hello"), "env should reach the child: {seen:?}");
    assert_eq!(seen.iter().filter(|l| l.starts_with("err")).count(), 100, "every line streams");

    let tail = String::from_utf8(outcome.stderr).unwrap();
    let tail: Vec<_> = tail.lines().collect();
    assert_eq!(tail.len(), super::super::STDERR_TAIL_LINES);
    assert_eq!(*tail.last().unwrap(), "err99");
}

/// A program that cannot be spawned is a spawn failure naming the program,
/// not a `BuildStepFailed` with a made-up exit code.
#[test]
fn process_runner_spawn_failure_is_install_stage_failed() {
    let dir = tempdir().unwrap();
    let env = BTreeMap::new();
    let cmd = StreamingCommand {
        program: "/nonexistent/luggage-no-such-binary",
        args: &[],
        cwd: dir.path(),
        env: &env,
    };
    let err = ProcessRunner.run_streaming(&cmd, &mut |_| {}).unwrap_err();
    match err {
        LuggageError::InstallStageFailed { stage, message } => {
            assert_eq!(stage, "spawn");
            assert!(message.contains("luggage-no-such-binary"), "{message}");
        }
        other => panic!("expected InstallStageFailed, got {other:?}"),
    }
}

/// Run `script` under the real runner, returning (outcome, streamed lines).
fn sh_stream(script: &str) -> (CommandOutcome, Vec<String>) {
    let dir = tempdir().unwrap();
    let env = BTreeMap::new();
    let args = vec!["-c".to_owned(), script.to_owned()];
    let cmd = StreamingCommand { program: "sh", args: &args, cwd: dir.path(), env: &env };
    let mut seen = Vec::new();
    let outcome = ProcessRunner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();
    (outcome, seen)
}

/// A step killed by a signal has no exit code; that reaches the error as
/// `status: None` (rendered "exit signal"), never a made-up number.
#[test]
fn process_runner_reports_signal_death_as_no_status() {
    let (outcome, _) = sh_stream("kill -9 $$");
    assert_eq!(outcome.status, None);
    assert!(!outcome.success());
}

/// The last line of output often has no trailing newline (a `printf`, a
/// crashed compiler); it must still be forwarded, and CRLF is trimmed.
#[test]
fn process_runner_forwards_unterminated_and_crlf_lines() {
    let (_, seen) = sh_stream("printf 'dos\\r\\nlast'");
    assert_eq!(seen, ["dos", "last"]);
}

/// Non-UTF-8 output is replaced, not dropped and not fatal.
#[test]
fn process_runner_survives_non_utf8_output() {
    let (outcome, seen) = sh_stream("printf 'a\\377b\\nnext\\n'");
    assert!(outcome.success());
    assert_eq!(seen, ["a\u{FFFD}b", "next"]);
}

/// A newline-free stream larger than the line cap is cut to the cap and
/// marked, and the line after it still arrives intact — memory stays
/// bounded by `MAX_LINE_BYTES`, not by the child's output.
#[test]
fn process_runner_truncates_oversized_lines() {
    use super::super::{MAX_LINE_BYTES, TRUNCATED_MARKER};
    // 200 KiB of 'x' with no newline, then a normal line.
    let (outcome, seen) = sh_stream("head -c 204800 /dev/zero | tr '\\0' x; printf '\\nafter\\n'");
    assert!(outcome.success());
    assert_eq!(seen.len(), 2, "one truncated line then `after`: {:?}", seen.len());
    assert!(seen[0].ends_with(TRUNCATED_MARKER));
    assert_eq!(seen[0].len(), MAX_LINE_BYTES + TRUNCATED_MARKER.len());
    assert_eq!(seen[1], "after");
}

/// A pipe that fails mid-stream must not end the log silently: the bytes
/// read so far are forwarded, then a marker naming the error (the repo's
/// "degradation must be loud" rule).
#[test]
fn pump_reports_a_read_error_instead_of_ending_silently() {
    use super::super::{Pipe, READ_ERROR_MARKER, pump};

    /// Yields `data` once, then fails every read.
    struct FailsAfter(Option<&'static [u8]>);
    impl std::io::Read for FailsAfter {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let Some(data) = self.0.take() else {
                return Err(std::io::Error::other("pipe went away"));
            };
            out[..data.len()].copy_from_slice(data);
            Ok(data.len())
        }
    }

    let (tx, rx) = std::sync::mpsc::channel();
    pump(FailsAfter(Some(b"configure: ok\npartial")), Pipe::Stderr, &tx);
    drop(tx);
    let lines: Vec<String> = rx.into_iter().map(|(_, l)| l).collect();

    assert_eq!(lines.len(), 3, "{lines:?}");
    assert_eq!(lines[0], "configure: ok");
    assert_eq!(lines[1], "partial", "bytes read before the error are kept");
    assert!(lines[2].starts_with(READ_ERROR_MARKER), "{lines:?}");
    assert!(lines[2].contains("pipe went away"), "{lines:?}");
}

/// A line of exactly the cap is not truncated — the cut is strictly for
/// lines that exceed it.
#[test]
fn process_runner_keeps_a_line_of_exactly_the_cap() {
    use super::super::{MAX_LINE_BYTES, TRUNCATED_MARKER};
    let (_, seen) =
        sh_stream(&format!("head -c {MAX_LINE_BYTES} /dev/zero | tr '\\0' y; printf '\\n'"));
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].len(), MAX_LINE_BYTES);
    assert!(!seen[0].ends_with(TRUNCATED_MARKER));
}
