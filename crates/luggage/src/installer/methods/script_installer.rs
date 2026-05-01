//! `rustup-init` / `rustup-init-musl` install method.
//!
//! Reproduces the side-effects of `lib/features/rust.sh` in Rust:
//!
//! 1. Ensure `cache_root/cargo` and `cache_root/rustup` exist.
//! 2. Mark the downloaded artifact executable.
//! 3. `su - <user> -c "export CARGO_HOME=...; export RUSTUP_HOME=...;
//!    <artifact> <args...>"`.
//! 4. Symlink the standard set of rust binaries into `bin_root`.
//!
//! Only the rust-shape symlink set is wired up. Future install methods
//! that produce different binary sets get their own dispatch arm.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs as unix_fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt as _;

use shell_words::quote;

use super::{CommandRunner, MethodContext};
use crate::error::{LuggageError, Result};
use crate::installer::user::su_command;

/// Binaries the rust install must surface in `bin_root` for parity with
/// `lib/features/rust.sh`.
pub const RUST_BINARIES: &[&str] =
    &["rustc", "cargo", "rustup", "rust-analyzer", "rustfmt", "clippy-driver"];

/// Run the rustup-init flow.
///
/// # Errors
///
/// - [`LuggageError::Io`] when cache or bin directories cannot be
///   created/manipulated.
/// - [`LuggageError::InstallStageFailed`] when chmod or the runner cannot
///   perform a step.
/// - [`LuggageError::PostInstallFailed`] when `su -c rustup-init` exits
///   non-zero. (Despite the name, the failure happens during install
///   rather than post-install — but the error variant fits "user-running
///   command failed" semantics best.)
pub fn run(ctx: &MethodContext<'_>) -> Result<()> {
    // 1. Ensure cache directories exist.
    let cargo_home = ctx.cache_root.join("cargo");
    let rustup_home = ctx.cache_root.join("rustup");
    for dir in [&cargo_home, &rustup_home] {
        fs::create_dir_all(dir).map_err(|e| LuggageError::Io { path: dir.clone(), source: e })?;
    }

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

    // 3. Build the env map (caller's exports + our cargo/rustup pins) and
    //    the inner shell payload, then dispatch to su.
    let mut env: BTreeMap<String, String> = ctx.env.clone();
    env.entry("CARGO_HOME".to_owned()).or_insert_with(|| cargo_home.display().to_string());
    env.entry("RUSTUP_HOME".to_owned()).or_insert_with(|| rustup_home.display().to_string());

    let mut body = String::new();
    body.push_str(&quote(&ctx.artifact.display().to_string()));
    for arg in ctx.args {
        body.push(' ');
        body.push_str(&quote(arg));
    }

    let argv = su_command(ctx.user, &env, &body);
    let outcome = ctx.runner.run(&argv[0], &argv[1..])?;
    if !outcome.success() {
        return Err(LuggageError::PostInstallFailed {
            step: "rustup-init".into(),
            message: format!(
                "rustup-init exited with status {:?}: {}",
                outcome.status,
                String::from_utf8_lossy(&outcome.stderr).trim_end(),
            ),
        });
    }

    // 4. Symlink the rust binaries into bin_root.
    install_symlinks(&cargo_home, ctx.bin_root, ctx.runner)?;

    Ok(())
}

/// Symlink `<cargo_home>/bin/<name>` → `<bin_root>/<name>` for each
/// binary in [`RUST_BINARIES`]. Existing symlinks are replaced; existing
/// non-symlinks are left alone (avoids clobbering distro-managed files).
fn install_symlinks(
    cargo_home: &std::path::Path,
    bin_root: &std::path::Path,
    runner: &dyn CommandRunner,
) -> Result<()> {
    fs::create_dir_all(bin_root)
        .map_err(|e| LuggageError::Io { path: bin_root.to_owned(), source: e })?;
    for name in RUST_BINARIES {
        let target = cargo_home.join("bin").join(name);
        let link = bin_root.join(name);
        if link.exists() {
            let metadata = fs::symlink_metadata(&link)
                .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
            if metadata.file_type().is_symlink() {
                fs::remove_file(&link)
                    .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
            } else {
                continue;
            }
        }
        unix_fs::symlink(&target, &link)
            .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
    }
    // The runner is unused here today (symlink syscalls go direct), but
    // accepting it keeps the API uniform and lets future versions of this
    // function shell out for cross-distro quirks (e.g. SELinux contexts).
    let _ = runner;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use std::path::Path;

    use tempfile::tempdir;

    use crate::installer::methods::{CommandOutcome, RecordingRunner};

    fn make_artifact(dir: &Path) -> std::path::PathBuf {
        let path = dir.join("rustup-init");
        fs::write(&path, b"#!/bin/sh\necho stub\n").unwrap();
        path
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
            runner: &runner,
        };
        run(&ctx).unwrap();

        for name in RUST_BINARIES {
            let link = bin.path().join(name);
            assert!(
                link.is_symlink(),
                "expected {name} to be symlinked under {}",
                bin.path().display(),
            );
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
}
