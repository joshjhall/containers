//! Integration tests for `stibbons labels sync` and `stibbons setup`.
//!
//! These drive the compiled binary. To stay hermetic (no live `gh`/`glab`, no
//! network), the tests that reach the backend point `--skills-dir` at a temp
//! dir with **no** label definitions, so sync short-circuits with "nothing to
//! sync" before any tracker call. Platform detection is exercised via
//! `--platform` (bypassing the git remote) and via the undetectable-platform
//! error path.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use tempfile::TempDir;

/// Path to the stibbons binary under test.
const fn stibbons_bin() -> &'static str {
    env!("CARGO_BIN_EXE_stibbons")
}

/// Run `stibbons <args...>` in `cwd`.
///
/// Strips the `GIT_*` variables git exports into hook environments. Under a
/// lefthook pre-push run, `GIT_DIR`/`GIT_WORK_TREE`/etc. point at the *outer*
/// repo; the stibbons binary shells `git remote get-url origin`, which would
/// then resolve against the real repo instead of the test's fixture, so
/// `undetectable_platform_without_remote_errors` (a fixture repo with no
/// `origin`) would spuriously succeed. See
/// `.claude/memory/git-env-leak-breaks-worktree-tests.md`.
fn run(cwd: &Path, args: &[&str]) -> Output {
    without_git_env(Command::new(stibbons_bin()).current_dir(cwd).args(args))
        .output()
        .expect("failed to spawn stibbons")
}

/// Remove the git-exported environment variables that leak the outer repo into
/// a subprocess run in a fixture repo.
fn without_git_env(cmd: &mut Command) -> &mut Command {
    for var in ["GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_COMMON_DIR"] {
        cmd.env_remove(var);
    }
    cmd
}

/// Write a skill `metadata.yml` under `root/<name>/metadata.yml`.
fn write_skill(root: &Path, name: &str, body: &str) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("metadata.yml"), body).unwrap();
}

#[test]
fn labels_sync_help_lists_flags() {
    let tmp = TempDir::new().unwrap();
    let out = run(tmp.path(), &["labels", "sync", "--help"]);
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("--dry-run"), "help should mention --dry-run");
    assert!(stdout.contains("--platform"), "help should mention --platform");
    assert!(stdout.contains("--skills-dir"), "help should mention --skills-dir");
}

#[test]
fn labels_parent_lists_sync() {
    let tmp = TempDir::new().unwrap();
    let out = run(tmp.path(), &["labels", "--help"]);
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("sync"), "labels --help should list the sync subcommand");
}

#[test]
fn setup_command_exists() {
    let tmp = TempDir::new().unwrap();
    let out = run(tmp.path(), &["setup", "--help"]);
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("--dry-run"));
    assert!(stdout.contains("--platform"));
}

#[test]
fn empty_skills_dir_reports_nothing_to_sync() {
    let tmp = TempDir::new().unwrap();
    let skills = tmp.path().join("skills");
    fs::create_dir_all(&skills).unwrap();
    // A skill with no labels: valid metadata, but nothing to reconcile.
    write_skill(&skills, "docker-development", "name: docker-development\nlabels: []\n");

    // --platform bypasses git detection; empty label set short-circuits before
    // any gh/glab call, so this is hermetic.
    let out = run(
        tmp.path(),
        &["labels", "sync", "--platform", "github", "--skills-dir", skills.to_str().unwrap()],
    );
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("Nothing to sync"), "got: {stdout}");
}

#[test]
fn dry_run_and_platform_flags_accepted_together() {
    let tmp = TempDir::new().unwrap();
    let skills = tmp.path().join("skills");
    fs::create_dir_all(&skills).unwrap();
    write_skill(&skills, "empty", "labels: []\n");

    let out = run(
        tmp.path(),
        &[
            "labels",
            "sync",
            "--dry-run",
            "--platform",
            "gitlab",
            "--skills-dir",
            skills.to_str().unwrap(),
        ],
    );
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn unknown_platform_flag_errors() {
    let tmp = TempDir::new().unwrap();
    let out = run(tmp.path(), &["labels", "sync", "--platform", "bitbucket"]);
    assert!(!out.status.success(), "unknown platform should exit non-zero");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unknown platform"), "got: {stderr}");
}

#[test]
fn undetectable_platform_without_remote_errors() {
    // A git repo with no `origin` remote and no --platform: detection must fail
    // with a clear, actionable message rather than panicking.
    let tmp = TempDir::new().unwrap();
    let skills = tmp.path().join("skills");
    fs::create_dir_all(&skills).unwrap();
    write_skill(
        &skills,
        "next-issue",
        "labels:\n  - name: type/feature\n    color: \"1D76DB\"\n    description: New feature\n",
    );
    // Initialize an empty git repo so `git remote get-url origin` fails cleanly.
    // Strip the leaking GIT_* env vars here too, or `git init` may target the
    // outer repo rather than the fixture.
    let init = without_git_env(Command::new("git").current_dir(tmp.path()).args(["init", "-q"]))
        .output()
        .expect("git init");
    assert!(init.status.success());

    let out = run(tmp.path(), &["labels", "sync", "--skills-dir", skills.to_str().unwrap()]);
    assert!(!out.status.success(), "no remote + no --platform should error");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("origin") || stderr.contains("determine platform"),
        "expected a platform-detection error, got: {stderr}"
    );
}
