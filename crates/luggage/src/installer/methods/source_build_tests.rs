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
use crate::installer::methods::{CommandOutcome, CommandRunner, RecordingRunner};

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
    /// Compiler launcher handed to the method; `None` unless a test opts in.
    launcher: Option<&'static str>,
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
            launcher: None,
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
            compiler_launcher: self.launcher,
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
        compiler_launcher: None,
        log: None,
        runner: &runner,
    })
    .unwrap();

    assert_eq!(*runner.0.lock().unwrap(), [true, true, true]);
}

/// A relative artifact path (`luggage install --tmp-root ./scratch`) must
/// still hand each step an absolute cwd and an absolute `./configure`:
/// a relative root would be applied once by the join and again by the
/// child's chdir. Built relative to the process cwd rather than by
/// changing it, which would race the other tests.
///
/// This pins the end-to-end property, not one line: `tempfile` absolutises
/// its base dir as well, so removing `source_build`'s own `absolute()`
/// alone does not fail this test. It guards against both layers regressing
/// together — e.g. a `tempfile` upgrade that stops absolutising.
#[test]
fn relative_artifact_path_still_yields_absolute_cwd_and_command() {
    let f = Fixture::python();
    let cwd = std::env::current_dir().unwrap();
    let rel = pathdiff_rel(&cwd, &f.artifact);
    assert!(rel.is_relative(), "fixture setup: {}", rel.display());

    let args: Vec<String> = vec![];
    let env = BTreeMap::new();
    let cache_dirs = BTreeMap::new();
    let steps = python_steps();
    run(&MethodContext {
        artifact: &rel,
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
        compiler_launcher: None,
        log: None,
        runner: &f.runner,
    })
    .unwrap();

    let calls = f.runner.streaming_calls();
    assert!(calls[0].cwd.is_absolute(), "cwd must be absolute: {}", calls[0].cwd.display());
    let configure = Path::new(&calls[0].program);
    assert!(configure.is_absolute(), "{}", configure.display());
    assert_eq!(configure, calls[0].cwd.join("configure"));
}

/// `to`, expressed relative to `from` with `..` segments — the minimal
/// `pathdiff` both arguments here need (two absolute paths).
fn pathdiff_rel(from: &Path, to: &Path) -> PathBuf {
    let from: Vec<_> = from.components().collect();
    let to: Vec<_> = to.components().collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut out = PathBuf::new();
    for _ in common..from.len() {
        out.push("..");
    }
    for c in &to[common..] {
        out.push(c.as_os_str());
    }
    out
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
        compiler_launcher: None,
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

/// Binaries with no `bin_source_dir` are a catalog defect knowable before
/// anything runs, so it must fail up front — not after a multi-minute build
/// and a root `make install` into the prefix.
#[test]
fn binaries_without_bin_source_dir_fails_before_extracting_or_building() {
    let f = Fixture::python();
    let binaries = vec!["python3".to_owned()];
    let err = f
        .run_full(&python_steps(), 1, &binaries, None, &BTreeMap::new(), &BTreeMap::new())
        .unwrap_err();
    match err {
        LuggageError::Catalog(msg) => assert!(msg.contains("bin_source_dir"), "{msg}"),
        other => panic!("expected Catalog, got {other:?}"),
    }
    assert_eq!(f.runner.calls(), [], "nothing may run, not even a chown");
    assert_eq!(f.leftover_build_dirs(), Vec::<String>::new(), "nothing extracted");
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
        compiler_launcher: None,
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

// ---- compiler launcher (#1594) -----------------------------------------

/// What `run()` sets `var` to when the catalog names no compiler: `run()`
/// reads the real process env and `PATH` (see [`apply_compiler_launcher`]),
/// so a `CC`/`CXX` exported where the tests run, or a host without `g++`,
/// must not turn these assertions red. `None` = left unset.
fn launched(var: &str) -> Option<String> {
    let probe = if var == "CC" { ["gcc", "cc"] } else { ["g++", "c++"] };
    let base = std::env::var(var).ok().filter(|v| !v.trim().is_empty()).or_else(|| {
        probe.into_iter().find(|p| step_on_path(&BTreeMap::new())(p)).map(str::to_owned)
    })?;
    Some(if already_launched(&base, "ccache") { base } else { format!("ccache {base}") })
}

/// A `PATH` holding exactly `present`, for [`apply_compiler_launcher`].
fn path_with(present: &'static [&'static str]) -> impl Fn(&str) -> bool {
    move |p: &str| present.contains(&p)
}

/// Every probed compiler present — the common full-toolchain image.
const ALL: &[&str] = &["gcc", "cc", "g++", "c++"];

/// Off by default: with no launcher every step's env is exactly what
/// `build_env` produces — no `CC`/`CXX` appears. This is the production
/// path, so it must stay byte-identical to the pre-#1594 behaviour.
#[test]
fn no_launcher_leaves_the_build_env_untouched() {
    let f = Fixture::python();
    let env = BTreeMap::from([("CFLAGS".to_owned(), "-O2".to_owned())]);
    f.run_full(&python_steps(), 1, &[], None, &BTreeMap::new(), &env).unwrap();

    let calls = f.runner.streaming_calls();
    assert_eq!(calls.len(), 3);
    for call in calls {
        assert_eq!(call.env, env, "{}: env must be the catalog's, unchanged", call.program);
    }
}

/// Opted in, every step compiles through the launcher, wrapping the
/// compiler autoconf would probe when the catalog names none.
#[test]
fn launcher_wraps_the_default_compilers_for_every_step() {
    let mut f = Fixture::python();
    f.launcher = Some("ccache");
    f.run(&python_steps(), 1).unwrap();

    let calls = f.runner.streaming_calls();
    assert_eq!(calls.len(), 3);
    for call in calls {
        assert_eq!(call.env.get("CC"), launched("CC").as_ref(), "{}", call.program);
        assert_eq!(call.env.get("CXX"), launched("CXX").as_ref(), "{}", call.program);
    }
}

/// A catalog-chosen compiler is kept and wrapped, not replaced: the cached
/// build must use the same toolchain the uncached one would.
#[test]
fn launcher_wraps_a_catalog_compiler_rather_than_replacing_it() {
    let mut f = Fixture::python();
    f.launcher = Some("ccache");
    let env = BTreeMap::from([("CC".to_owned(), "gcc-13".to_owned())]);
    f.run_full(&python_steps(), 1, &[], None, &BTreeMap::new(), &env).unwrap();

    let call = &f.runner.streaming_calls()[0];
    assert_eq!(call.env.get("CC").map(String::as_str), Some("ccache gcc-13"));
    assert_eq!(call.env.get("CXX"), launched("CXX").as_ref());
}

/// The same holds for `CXX`, and for both at once: neither variable falls
/// back to its default when the catalog names a compiler.
#[test]
fn launcher_wraps_a_catalog_cxx_and_both_together() {
    for (env, want_cc, want_cxx) in [
        (vec![("CXX", "g++-13")], launched("CC"), Some("ccache g++-13".to_owned())),
        (
            vec![("CC", "clang"), ("CXX", "clang++")],
            Some("ccache clang".to_owned()),
            Some("ccache clang++".to_owned()),
        ),
    ] {
        let mut f = Fixture::python();
        f.launcher = Some("ccache");
        let env: BTreeMap<String, String> =
            env.into_iter().map(|(k, v)| (k.to_owned(), v.to_owned())).collect();
        f.run_full(&python_steps(), 1, &[], None, &BTreeMap::new(), &env).unwrap();

        let call = &f.runner.streaming_calls()[0];
        assert_eq!(call.env.get("CC"), want_cc.as_ref(), "{env:?}");
        assert_eq!(call.env.get("CXX"), want_cxx.as_ref(), "{env:?}");
    }
}

/// A compiler inherited from luggage's own environment (an image-level
/// `CC=clang`) reaches an unwrapped build through the streaming runner, so
/// the launcher must wrap it rather than replace it with `cc` — otherwise
/// the cached build would use a different toolchain than the uncached one.
/// The catalog still wins over the inherited value, and an inherited empty
/// value falls back to the default like an unset one.
#[test]
fn launcher_wraps_an_inherited_compiler_and_the_catalog_still_wins() {
    let inherited = |var: &str| match var {
        "CC" => Some("clang".to_owned()),
        "CXX" => Some("clang++".to_owned()),
        _ => None,
    };

    let mut env = BTreeMap::new();
    apply_compiler_launcher(&mut env, "ccache", inherited, path_with(ALL));
    assert_eq!(env["CC"], "ccache clang");
    assert_eq!(env["CXX"], "ccache clang++");

    let mut env = BTreeMap::from([("CC".to_owned(), "gcc-13".to_owned())]);
    apply_compiler_launcher(&mut env, "ccache", inherited, path_with(ALL));
    assert_eq!(env["CC"], "ccache gcc-13", "catalog CC must beat the inherited one");
    assert_eq!(env["CXX"], "ccache clang++");

    let mut env = BTreeMap::new();
    apply_compiler_launcher(
        &mut env,
        "ccache",
        |var: &str| (var == "CC").then(|| "  ".to_owned()),
        path_with(ALL),
    );
    assert_eq!(env["CC"], "ccache gcc", "a blank inherited CC is unset");
    assert_eq!(env["CXX"], "ccache g++");

    // A blank catalog value is unset too: it falls through to the inherited
    // compiler (or the default), never to a bare `ccache ` with no compiler.
    let mut env =
        BTreeMap::from([("CC".to_owned(), String::new()), ("CXX".to_owned(), " ".to_owned())]);
    apply_compiler_launcher(&mut env, "ccache", inherited, path_with(ALL));
    assert_eq!(env["CC"], "ccache clang", "a blank catalog CC defers to the inherited one");
    assert_eq!(env["CXX"], "ccache clang++");
    let mut env = BTreeMap::from([("CC".to_owned(), String::new())]);
    apply_compiler_launcher(&mut env, "ccache", |_: &str| None, path_with(ALL));
    assert_eq!(env["CC"], "ccache gcc", "a blank catalog CC with nothing inherited is probed");
}

/// With nothing named, the default follows autoconf's probe order —
/// `gcc` before `cc`, `g++` before `c++` — so an image whose `cc` is not its
/// `gcc` still caches the compiler `configure` would have picked.
#[test]
fn launcher_default_follows_the_autoconf_probe_order() {
    for (present, want_cc, want_cxx) in [
        (ALL, "ccache gcc", "ccache g++"),
        (&["cc", "c++"][..], "ccache cc", "ccache c++"),
        (&["cc", "gcc", "c++", "g++"][..], "ccache gcc", "ccache g++"),
        (&["gcc", "c++"][..], "ccache gcc", "ccache c++"),
    ] {
        let mut env = BTreeMap::new();
        apply_compiler_launcher(&mut env, "ccache", |_: &str| None, |p: &str| present.contains(&p));
        assert_eq!(env.get("CC").map(String::as_str), Some(want_cc), "{present:?}");
        assert_eq!(env.get("CXX").map(String::as_str), Some(want_cxx), "{present:?}");
    }
}

/// A compiler that is not on `PATH` is not invented: a C-only image keeps
/// `CXX` unset (as the unwrapped build would), and with no compiler at all
/// neither variable is touched.
#[test]
fn launcher_leaves_a_missing_compiler_unset() {
    let mut env = BTreeMap::new();
    apply_compiler_launcher(&mut env, "ccache", |_: &str| None, path_with(&["gcc", "cc"]));
    assert_eq!(env.get("CC").map(String::as_str), Some("ccache gcc"));
    assert!(!env.contains_key("CXX"), "C-only image must not get a CXX: {env:?}");

    let mut env = BTreeMap::from([("CFLAGS".to_owned(), "-O2".to_owned())]);
    let before = env.clone();
    apply_compiler_launcher(&mut env, "ccache", |_: &str| None, path_with(&[]));
    assert_eq!(env, before, "no compiler anywhere: env must be untouched");

    // An explicit compiler still wins over an empty PATH.
    let mut env = BTreeMap::new();
    apply_compiler_launcher(
        &mut env,
        "ccache",
        |var: &str| (var == "CXX").then(|| "clang++".to_owned()),
        path_with(&[]),
    );
    assert!(!env.contains_key("CC"), "{env:?}");
    assert_eq!(env["CXX"], "ccache clang++");
}

/// The compiler probe searches the `PATH` the steps run with: a catalog
/// `PATH` replaces luggage's, so a compiler only there is found and one only
/// on luggage's `PATH` is not.
#[cfg(unix)]
#[test]
fn launcher_probes_the_step_path_when_the_catalog_sets_one() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempdir().unwrap();
    let gcc = dir.path().join("gcc-luggage-probe");
    fs::write(&gcc, "#!/bin/sh\n").unwrap();
    fs::set_permissions(&gcc, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(dir.path().join("not-executable"), "").unwrap();

    let env = BTreeMap::from([("PATH".to_owned(), dir.path().display().to_string())]);
    let probe = step_on_path(&env);
    assert!(probe("gcc-luggage-probe"), "a compiler on the catalog PATH is found");
    assert!(!probe("not-executable"), "a non-executable file is not a compiler");
    assert!(!probe("sh"), "luggage's own PATH is not searched when the catalog sets one");

    // Empty and relative entries resolve against the steps' cwd (the scratch
    // tree), not luggage's, so they are never probed. `rel` reaches the probe
    // directory from luggage's own cwd (`../` up to `/`, then down), so a
    // probe that honoured relative entries would wrongly find the compiler.
    let cwd = std::env::current_dir().unwrap();
    let up = "../".repeat(cwd.components().count() - 1);
    let rel = format!("{up}{}", dir.path().strip_prefix("/").unwrap().display());
    assert!(
        std::path::Path::new(&rel).join("gcc-luggage-probe").is_file(),
        "{rel} must reach the probe dir from the cwd, or this test proves nothing",
    );
    for path in [String::new(), ":".to_owned(), rel.clone(), format!(":{rel}:")] {
        let env = BTreeMap::from([("PATH".to_owned(), path.clone())]);
        assert!(!step_on_path(&env)("gcc-luggage-probe"), "PATH={path:?}");
    }
    let env = BTreeMap::from([("PATH".to_owned(), format!("{rel}:{}", dir.path().display()))]);
    assert!(step_on_path(&env)("gcc-luggage-probe"), "the absolute entry still counts");

    // No catalog PATH: luggage's own is searched.
    assert!(step_on_path(&BTreeMap::new())("sh"), "sh is on luggage's PATH");
    assert!(!step_on_path(&BTreeMap::new())("gcc-luggage-probe"));
}

/// The log note survives a compiler left unset (indexing `env["CXX"]` used
/// to panic on a C-only image) and names exactly what each step receives.
#[test]
fn launcher_note_shows_an_unset_compiler() {
    let mut env = BTreeMap::new();
    apply_compiler_launcher(&mut env, "ccache", |_: &str| None, path_with(&["gcc"]));
    assert_eq!(
        launcher_note("ccache", &env),
        "compiler launcher: ccache (CC=`ccache gcc`, CXX=`unset`)"
    );
    assert_eq!(
        launcher_note("ccache", &BTreeMap::new()),
        "compiler launcher: ccache (CC=`unset`, CXX=`unset`)",
    );
}

/// A compiler already routed through the launcher is kept verbatim, never
/// `ccache ccache gcc` — whether it came from the catalog or the env, and
/// whether the launcher was named bare or by path. A program that merely
/// shares a prefix with the launcher is still wrapped.
#[test]
fn launcher_does_not_wrap_an_already_launched_compiler() {
    let inherited = |var: &str| match var {
        "CC" => Some("ccache gcc".to_owned()),
        "CXX" => Some("/opt/evidence-ccache/ccache g++".to_owned()),
        _ => None,
    };
    for launcher in ["ccache", "/opt/evidence-ccache/ccache"] {
        let mut env = BTreeMap::new();
        apply_compiler_launcher(&mut env, launcher, inherited, path_with(ALL));
        assert_eq!(env["CC"], "ccache gcc", "{launcher}");
        assert_eq!(env["CXX"], "/opt/evidence-ccache/ccache g++", "{launcher}");

        let mut env = BTreeMap::from([("CC".to_owned(), "ccache clang".to_owned())]);
        apply_compiler_launcher(&mut env, launcher, |_: &str| None, path_with(&[]));
        assert_eq!(env["CC"], "ccache clang", "catalog value, {launcher}");
    }

    let mut env = BTreeMap::from([("CC".to_owned(), "ccache-wrapper gcc".to_owned())]);
    apply_compiler_launcher(&mut env, "ccache", |_: &str| None, path_with(&[]));
    assert_eq!(env["CC"], "ccache ccache-wrapper gcc", "a prefix match is not the launcher");
}

#[test]
fn launcher_env_unset_is_off() {
    assert_eq!(parse_compiler_launcher(None).unwrap(), None);
}

#[test]
fn launcher_env_names_the_program() {
    assert_eq!(parse_compiler_launcher(Some("ccache")).unwrap().as_deref(), Some("ccache"));
    assert_eq!(
        parse_compiler_launcher(Some("/usr/bin/sccache")).unwrap().as_deref(),
        Some("/usr/bin/sccache"),
    );
    for ok in [".ccache", "ccache-4.10", "/opt/evidence-ccache/ccache"] {
        assert_eq!(parse_compiler_launcher(Some(ok)).unwrap().as_deref(), Some(ok));
    }
}

/// Empty, multi-word, shell-metacharacter, and directory values are refused
/// by name rather than silently treated as "off" (a silent two-hour cold
/// build), word-split by `make`, run as shell code by `configure` as root, or
/// handed to `make` as a "launcher" that is really a directory or a path that
/// resolves differently in every sub-make.
#[test]
fn launcher_env_rejects_empty_and_whitespace() {
    for bad in [
        "",
        " ",
        "ccache --foo",
        "ccache\t",
        "ccache;id",
        "$(id)",
        "`id`",
        "cc&&id",
        "-x",
        "--foo",
        // Directories, not programs.
        "/",
        ".",
        "..",
        "bin/",
        "/usr/..",
        "/usr/bin/.",
        "//",
        // Relative paths: each step and sub-make resolves them from a
        // different cwd.
        "./ccache",
        "../bin/ccache",
        "bin/ccache",
    ] {
        match parse_compiler_launcher(Some(bad)).unwrap_err() {
            LuggageError::Catalog(msg) => {
                assert!(msg.contains(COMPILER_LAUNCHER_ENV), "{bad:?}: {msg}");
            }
            other => panic!("{bad:?}: expected Catalog, got {other:?}"),
        }
    }
}
