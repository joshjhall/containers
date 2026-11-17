//! Shared test helpers for stibbons integration tests.
//!
//! This module is compiled independently into each integration-test binary,
//! and each binary uses only a subset of the helpers, so unused-item warnings
//! here are expected and suppressed.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// Path to the fixture directory (`crates/containers-common/testdata/`).
pub fn testdata_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../containers-common/testdata")
}

/// Path to the stibbons binary under test.
const fn stibbons_bin() -> &'static str {
    env!("CARGO_BIN_EXE_stibbons")
}

/// Fixed git identity injected into every stibbons spawn (matches the `git()`
/// fixture helper in `worktree_integration.rs`).
pub const TEST_GIT_NAME: &str = "Test";
pub const TEST_GIT_EMAIL: &str = "test@example.com";

/// Build a hermetic `stibbons <subcommand>` command rooted at `cwd`.
///
/// stibbons shells out to git (`worktree add`, `status`, `rebase`, ...), so the
/// enclosing environment must not steer those children: `GIT_DIR` /
/// `GIT_WORK_TREE` leaked from e.g. a pre-push hook would retarget them at the
/// outer repo, and a host without a global gitconfig would fail any commit or
/// rebase for lack of an identity.
pub fn stibbons_cmd(subcommand: &str, cwd: &Path) -> Command {
    let mut cmd = Command::new(stibbons_bin());
    cmd.current_dir(cwd)
        .arg(subcommand)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env("GIT_AUTHOR_NAME", TEST_GIT_NAME)
        .env("GIT_AUTHOR_EMAIL", TEST_GIT_EMAIL)
        .env("GIT_COMMITTER_NAME", TEST_GIT_NAME)
        .env("GIT_COMMITTER_EMAIL", TEST_GIT_EMAIL);
    cmd
}

/// Run `stibbons init --non-interactive --config <fixture>` in `cwd`.
pub fn run_init_noninteractive(cwd: &Path, fixture: &str) -> Output {
    let config_path = testdata_dir().join(fixture);
    stibbons_cmd("init", cwd)
        .args(["--non-interactive", "--config"])
        .arg(config_path)
        .output()
        .expect("failed to spawn stibbons")
}

/// Run `stibbons init` with custom args in `cwd`.
pub fn run_init_with_args(cwd: &Path, extra_args: &[&str]) -> Output {
    stibbons_cmd("init", cwd).args(extra_args).output().expect("failed to spawn stibbons")
}

/// Run `stibbons agent <args...>` in `cwd`.
pub fn run_agent(cwd: &Path, args: &[&str]) -> Output {
    stibbons_cmd("agent", cwd).args(args).output().expect("failed to spawn stibbons")
}

/// Run `stibbons status` in `cwd`, returning the full [`Output`] so callers can
/// assert on both the exit code (0 = clean, 1 = drift/error) and stdout.
pub fn run_status(cwd: &Path) -> Output {
    stibbons_cmd("status", cwd).output().expect("failed to spawn stibbons")
}

/// Run `stibbons worktree <args...>` in `cwd`.
pub fn run_worktree(cwd: &Path, args: &[&str]) -> Output {
    stibbons_cmd("worktree", cwd).args(args).output().expect("failed to spawn stibbons")
}

/// Run `stibbons add <args...>` in `cwd`.
pub fn run_add(cwd: &Path, args: &[&str]) -> Output {
    stibbons_cmd("add", cwd).args(args).output().expect("failed to spawn stibbons")
}

/// Run `stibbons remove <args...>` in `cwd`.
pub fn run_remove(cwd: &Path, args: &[&str]) -> Output {
    stibbons_cmd("remove", cwd).args(args).output().expect("failed to spawn stibbons")
}

/// Run `stibbons update <args...>` in `cwd`.
pub fn run_update(cwd: &Path, args: &[&str]) -> Output {
    stibbons_cmd("update", cwd).args(args).output().expect("failed to spawn stibbons")
}

/// Seed a project by running `init --non-interactive --config <fixture>` in
/// `cwd`, asserting success. Returns nothing; the tempdir now holds a real
/// `.igor.yml` + generated files.
pub fn seed_project(cwd: &Path, fixture: &str) {
    let out = run_init_noninteractive(cwd, fixture);
    assert_success(&out);
}

/// Assert the command exited with code 0, otherwise panic showing stderr.
pub fn assert_success(out: &Output) {
    assert!(
        out.status.success(),
        "stibbons init failed with status {:?}\nstdout: {}\nstderr: {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

/// True if `docker` is available on PATH and responds to `--version`.
pub fn docker_available() -> bool {
    Command::new("docker").arg("--version").output().is_ok_and(|o| o.status.success())
}

/// Strip leading `// ...` comment lines so the remainder parses as JSON.
pub fn strip_json_comments(content: &str) -> String {
    content
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n")
}
