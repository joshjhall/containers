//! Script-installer method — run a downloaded executable installer.
//!
//! Generalises the side-effects `lib/features/rust.sh` performs, driven
//! entirely by the catalog rather than by a per-tool code path:
//!
//! 1. Create each `cache_dirs` entry under `cache_root` and chown it to the
//!    install user so `su -c` writes don't hit EACCES. The chown is skipped
//!    when the install user is `root` — root already owns the freshly-created
//!    dirs (see issue #492).
//! 2. Mark the downloaded artifact executable.
//! 3. `su - <user> -c "export <CACHE_VAR>=...; <artifact> <args...>"`.
//! 4. Symlink the method's `binaries` out of `bin_source_dir` into `bin_root`.
//!
//! Everything tool-shaped — which dirs, which env vars, which binaries —
//! comes from the resolved catalog entry, so a new tool using this shape
//! needs no code here (issue #806). Steps 1, 3's env map, and 4 are shared
//! with the other install methods via [`super::layout`]; only step 2 and the
//! `su -c` invocation are specific to this shape.

use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt as _;

use shell_words::quote;

use super::MethodContext;
use super::layout::{build_env, install_binaries, prepare_cache_dirs};
use crate::error::{LuggageError, Result};
use crate::installer::user::su_command;

/// Run the script-installer flow.
///
/// # Errors
///
/// - [`LuggageError::Io`] when cache or bin directories cannot be
///   created/manipulated.
/// - [`LuggageError::InstallStageFailed`] when chmod or the runner cannot
///   perform a step.
/// - [`LuggageError::Catalog`] when the method lists `binaries` but no
///   `bin_source_dir` to link them from.
/// - [`LuggageError::PostInstallFailed`] when `su -c <artifact>` exits
///   non-zero. (Despite the name, the failure happens during install
///   rather than post-install — but the error variant fits "user-running
///   command failed" semantics best.)
pub fn run(ctx: &MethodContext<'_>) -> Result<()> {
    // 1. Ensure the catalog's cache directories exist and are owned by the
    //    install user, so the `su -c <artifact>` child below can write into
    //    them (issues #462 / #492 — see `layout::prepare_cache_dirs`).
    prepare_cache_dirs(ctx)?;

    // 2. chmod +x the downloaded installer.
    #[cfg(unix)]
    {
        let mut perms = fs::metadata(ctx.artifact)
            .map_err(|e| LuggageError::Io { path: ctx.artifact.to_owned(), source: e })?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(ctx.artifact, perms)
            .map_err(|e| LuggageError::Io { path: ctx.artifact.to_owned(), source: e })?;
    }

    // 3. Build the env map (caller's exports layered over the catalog's
    //    cache-dir paths) and the inner shell payload, then dispatch to su.
    let env = build_env(ctx);

    let mut body = String::new();
    body.push_str(&quote(&ctx.artifact.display().to_string()));
    for arg in ctx.args {
        body.push(' ');
        body.push_str(&quote(arg));
    }

    // The artifact's own filename names the step, so a failing go/node
    // installer doesn't report itself as `rustup-init`.
    let step = ctx
        .artifact
        .file_name()
        .map_or_else(|| "script-installer".to_owned(), |n| n.to_string_lossy().into_owned());
    let argv = su_command(ctx.user, &env, &body);
    let outcome = ctx.runner.run(&argv[0], &argv[1..])?;
    if !outcome.success() {
        return Err(LuggageError::PostInstallFailed {
            step: step.clone(),
            message: format!(
                "{step} exited with status {:?}: {}",
                outcome.status,
                String::from_utf8_lossy(&outcome.stderr).trim_end(),
            ),
        });
    }

    // 4. Symlink the catalog's binaries into bin_root. This shape's binaries
    //    live under the cache root (rust: `cargo/bin`), so that is the root
    //    `bin_source_dir` resolves against.
    install_binaries(ctx, ctx.cache_root)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    use std::collections::BTreeMap;
    use std::fs;
    use std::path::Path;

    use tempfile::tempdir;

    use crate::installer::methods::{CommandOutcome, RecordingRunner};

    fn make_artifact(dir: &Path) -> std::path::PathBuf {
        let path = dir.join("rustup-init");
        fs::write(&path, b"#!/bin/sh\necho stub\n").unwrap();
        path
    }

    /// The catalog values the rust entries carry — what luggage used to
    /// hardcode as `RUST_BINARIES` and the cargo/rustup cache layout. Tests
    /// pass these explicitly now, so a regression that ignores the catalog
    /// and reintroduces a built-in default has nowhere to hide.
    fn rust_binaries() -> Vec<String> {
        ["rustc", "cargo", "rustup", "rust-analyzer", "rustfmt", "clippy-driver"]
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    fn rust_cache_dirs() -> BTreeMap<String, String> {
        BTreeMap::from([
            ("CARGO_HOME".to_owned(), "cargo".to_owned()),
            ("RUSTUP_HOME".to_owned(), "rustup".to_owned()),
        ])
    }

    #[test]
    fn run_invokes_su_with_expected_payload() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args = vec!["-y".to_owned(), "--default-toolchain".to_owned(), "1.95.0".to_owned()];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let calls = runner.calls();
        let su_call = calls.iter().find(|(p, _)| p == "su").expect("expected at least one su call");
        let su_args = &su_call.1;
        assert_eq!(su_args[0], "-");
        assert_eq!(su_args[1], "vscode");
        assert_eq!(su_args[2], "-c");
        let payload = &su_args[3];
        assert!(payload.contains("CARGO_HOME"));
        assert!(payload.contains("RUSTUP_HOME"));
        assert!(payload.contains("--default-toolchain"));
        assert!(payload.contains("1.95.0"));
        assert!(payload.contains(&artifact.display().to_string()));

        // chown must precede su, so the su child can write into the
        // cache subdirs without hitting EACCES.
        let su_idx = calls.iter().position(|(p, _)| p == "su").unwrap();
        let chown_idx = calls
            .iter()
            .position(|(p, _)| p == "chown")
            .expect("expected at least one chown call before su");
        assert!(
            chown_idx < su_idx,
            "expected chown to run before su (chown_idx={chown_idx}, su_idx={su_idx})",
        );
    }

    #[test]
    fn run_chowns_cache_directories() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let calls = runner.calls();
        let chown_calls: Vec<&(String, Vec<String>)> =
            calls.iter().filter(|(p, _)| p == "chown").collect();
        assert_eq!(chown_calls.len(), 2, "expected one chown per cache subdir");

        let cargo_path = cache.path().join("cargo").display().to_string();
        let rustup_path = cache.path().join("rustup").display().to_string();
        let chown_paths: Vec<&String> =
            chown_calls.iter().map(|(_, args)| args.last().unwrap()).collect();
        assert!(
            chown_paths.iter().any(|p| **p == cargo_path),
            "expected a chown for {cargo_path} in {chown_paths:?}",
        );
        assert!(
            chown_paths.iter().any(|p| **p == rustup_path),
            "expected a chown for {rustup_path} in {chown_paths:?}",
        );
        for (_, chown_args) in chown_calls {
            assert_eq!(chown_args[0], "-R");
            assert_eq!(chown_args[1], "vscode:vscode");
        }
    }

    #[test]
    fn run_skips_chown_when_user_is_root() {
        // On a base image without the resolved dev user, the install user
        // falls back to "root"; chown must be skipped (root already owns the
        // freshly-created dirs) while su still runs as root. See issue #492.
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "root",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let calls = runner.calls();
        assert!(
            !calls.iter().any(|(p, _)| p == "chown"),
            "expected no chown calls when user is root, got {calls:?}",
        );
        // The cache dirs are still created, and the install still runs as root.
        assert!(cache.path().join("cargo").is_dir());
        assert!(cache.path().join("rustup").is_dir());
        let su_call = calls.iter().find(|(p, _)| p == "su").expect("expected an su call");
        assert_eq!(su_call.1[1], "root");
    }

    #[test]
    fn run_creates_cache_directories() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        assert!(cache.path().join("cargo").is_dir());
        assert!(cache.path().join("rustup").is_dir());
    }

    #[test]
    fn run_symlinks_rust_binaries() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        for name in rust_binaries() {
            let link = bin.path().join(&name);
            assert!(
                link.is_symlink(),
                "expected {name} to be symlinked under {}",
                bin.path().display(),
            );
        }
    }

    #[test]
    fn run_propagates_chown_failure_as_install_stage_failed() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        runner.set_outcome(
            "chown",
            CommandOutcome {
                status: Some(1),
                stdout: vec![],
                stderr: b"chown: invalid user: 'vscode'".to_vec(),
            },
        );
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        let err = run(&ctx).unwrap_err();
        match err {
            LuggageError::InstallStageFailed { stage, message } => {
                assert_eq!(stage, "chown");
                assert!(message.contains("vscode"), "message missing user: {message}");
                assert!(
                    message.contains("invalid user"),
                    "message missing stderr passthrough: {message}",
                );
            }
            other => panic!("expected InstallStageFailed, got {other:?}"),
        }
    }

    #[test]
    fn run_propagates_runner_failure_as_post_install_failed() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        runner.set_outcome(
            "su",
            CommandOutcome {
                status: Some(7),
                stdout: vec![],
                stderr: b"rustup-init: bad arg".to_vec(),
            },
        );
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &rust_binaries(),
            bin_source_dir: Some("cargo/bin"),
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        let err = run(&ctx).unwrap_err();
        match err {
            LuggageError::PostInstallFailed { step, message } => {
                assert_eq!(step, "rustup-init");
                assert!(message.contains("rustup-init: bad arg"));
            }
            other => panic!("expected PostInstallFailed, got {other:?}"),
        }
    }

    // ---- catalog-driven fallbacks (issue #806) ----------------------------
    //
    // Each field is optional and must degrade to "do nothing", NOT to the
    // rust shape. A default that reinstated `RUST_BINARIES` or the
    // cargo/rustup layout would be invisible to the rust tests above (they
    // pass those values explicitly), so the absent cases are pinned here.

    /// No `cache_dirs` → nothing created, nothing chowned, nothing exported.
    /// A tool whose installer needs no persistent cache must not inherit
    /// rust's cargo/rustup directories.
    #[test]
    fn no_cache_dirs_creates_and_exports_nothing() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let empty = BTreeMap::new();

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &[],
            bin_source_dir: None,
            cache_dirs: &empty,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let calls = runner.calls();
        assert!(
            !calls.iter().any(|(p, _)| p == "chown"),
            "no cache_dirs means nothing to chown, got {calls:?}",
        );
        assert!(
            !cache.path().join("cargo").exists() && !cache.path().join("rustup").exists(),
            "the rust cache layout must not be recreated by default",
        );
        let payload = &calls.iter().find(|(p, _)| p == "su").expect("su ran").1[3];
        assert!(
            !payload.contains("CARGO_HOME") && !payload.contains("RUSTUP_HOME"),
            "no cache_dirs means no derived exports, got: {payload}",
        );
    }

    /// No `binaries` → `bin_root` stays empty. The absent case must link
    /// nothing rather than fall back to the six rust names.
    #[test]
    fn no_binaries_symlinks_nothing() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let empty = BTreeMap::new();

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &[],
            bin_source_dir: None,
            cache_dirs: &empty,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let linked: Vec<_> =
            fs::read_dir(bin.path()).unwrap().filter_map(std::result::Result::ok).collect();
        assert!(
            linked.is_empty(),
            "expected no symlinks with no catalog binaries, got {} entries",
            linked.len(),
        );
    }

    /// A method listing `binaries` with no `bin_source_dir` is a catalog
    /// defect. It must be reported rather than guessed at — the guess that
    /// used to be hardcoded (`cargo/bin`) is wrong for every non-rust tool.
    #[test]
    fn binaries_without_source_dir_is_a_catalog_error() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let empty = BTreeMap::new();
        let binaries = vec!["gofmt".to_owned()];

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &binaries,
            bin_source_dir: None,
            cache_dirs: &empty,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        match run(&ctx).unwrap_err() {
            LuggageError::Catalog(msg) => assert!(
                msg.contains("bin_source_dir"),
                "the error must name the missing field, got: {msg}",
            ),
            other => panic!("expected Catalog, got {other:?}"),
        }
    }

    /// An explicit `invoke.env` value wins over the path derived from
    /// `cache_dirs` for the same variable — the `or_insert` precedence the
    /// rust entry relies on (its `invoke.env` pins absolute `/cache` paths).
    #[test]
    fn invoke_env_takes_precedence_over_derived_cache_path() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let args: Vec<String> = vec![];
        let mut env = BTreeMap::new();
        env.insert("CARGO_HOME".to_owned(), "/explicit/cargo".to_owned());

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &[],
            bin_source_dir: None,
            cache_dirs: &rust_cache_dirs(),
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        let calls = runner.calls();
        let payload = &calls.iter().find(|(p, _)| p == "su").expect("su ran").1[3];
        assert!(
            payload.contains("/explicit/cargo"),
            "the invoke.env value must survive, got: {payload}",
        );
        // RUSTUP_HOME had no explicit value, so it still derives from cache_root.
        let derived = cache.path().join("rustup").display().to_string();
        assert!(
            payload.contains(&derived),
            "an unset variable must still derive from cache_root, got: {payload}",
        );
    }

    /// The cache dirs the catalog names are the ones created — an arbitrary
    /// (non-rust) layout must work end to end, which is the whole point of
    /// moving this out of code.
    #[test]
    fn creates_the_cache_dirs_the_catalog_names() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let go_dirs = BTreeMap::from([
            ("GOPATH".to_owned(), "go".to_owned()),
            ("GOCACHE".to_owned(), "go-build".to_owned()),
        ]);

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &[],
            bin_source_dir: None,
            cache_dirs: &go_dirs,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        assert!(cache.path().join("go").is_dir(), "GOPATH dir must be created");
        assert!(cache.path().join("go-build").is_dir(), "GOCACHE dir must be created");
        let calls = runner.calls();
        let payload = &calls.iter().find(|(p, _)| p == "su").expect("su ran").1[3];
        assert!(payload.contains("GOPATH"), "GOPATH must be exported, got: {payload}");
        assert!(payload.contains("GOCACHE"), "GOCACHE must be exported, got: {payload}");
    }

    /// A failing installer names ITSELF in the error, rather than reporting
    /// every tool's failure as `rustup-init` (the pre-#806 hardcoded literal).
    /// Every other test here uses `make_artifact`, which is always named
    /// `rustup-init` — so without this case the generalisation would be
    /// indistinguishable from the constant it replaced.
    #[test]
    fn failure_step_names_the_actual_artifact() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = tmp.path().join("go-installer");
        fs::write(&artifact, b"#!/bin/sh\necho stub\n").unwrap();
        let runner = RecordingRunner::new();
        runner.set_outcome(
            "su",
            CommandOutcome {
                status: Some(1),
                stdout: vec![],
                stderr: b"go-installer: bad arg".to_vec(),
            },
        );
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let empty = BTreeMap::new();

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &[],
            bin_source_dir: None,
            cache_dirs: &empty,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        match run(&ctx).unwrap_err() {
            LuggageError::PostInstallFailed { step, message } => {
                assert_eq!(step, "go-installer", "the step must name the failing artifact");
                assert!(
                    !message.contains("rustup-init"),
                    "a non-rust installer must not report itself as rustup-init, got: {message}",
                );
            }
            other => panic!("expected PostInstallFailed, got {other:?}"),
        }
    }

    /// Symlinks come from the catalog's `bin_source_dir`, not a hardcoded
    /// `cargo/bin`. Pins the generalisation with a non-rust layout.
    #[test]
    fn symlinks_from_the_catalog_source_dir() {
        let cache = tempdir().unwrap();
        let bin = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let artifact = make_artifact(tmp.path());
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let args: Vec<String> = vec![];
        let empty = BTreeMap::new();
        let binaries = vec!["go".to_owned(), "gofmt".to_owned()];

        let src = cache.path().join("golang").join("bin");
        fs::create_dir_all(&src).unwrap();
        for name in &binaries {
            fs::write(src.join(name), b"#!/bin/sh\necho stub\n").unwrap();
        }

        let ctx = MethodContext {
            artifact: &artifact,
            args: &args,
            env: &env,
            user: "vscode",
            cache_root: cache.path(),
            bin_root: bin.path(),
            binaries: &binaries,
            bin_source_dir: Some("golang/bin"),
            cache_dirs: &empty,
            prefix: None,
            strip_components: 0,
            runner: &runner,
        };
        run(&ctx).unwrap();

        for name in &binaries {
            let link = bin.path().join(name);
            assert!(link.is_symlink(), "expected {name} to be symlinked");
            assert_eq!(
                fs::read_link(&link).unwrap(),
                src.join(name),
                "{name} must point into the catalog's bin_source_dir",
            );
        }
    }
}
