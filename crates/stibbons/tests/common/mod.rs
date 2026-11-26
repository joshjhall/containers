//! Shared test helpers for stibbons integration tests.
//!
//! This module is compiled independently into each integration-test binary,
//! and each binary uses only a subset of the helpers, so unused-item warnings
//! here are expected and suppressed.
#![allow(dead_code)]

use std::fmt::Write as _;
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

/// Repository-locating git env vars that a hook (pre-commit/pre-push) exports
/// and that would steer a git child at the enclosing repo. All are removed
/// from every stibbons spawn.
pub const LEAKY_GIT_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_PREFIX",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
];

/// Remove every [`LEAKY_GIT_VARS`] entry from `cmd`'s environment. Use on any
/// git or stibbons spawn in these tests.
pub fn scrub_git_env(cmd: &mut Command) -> &mut Command {
    for var in LEAKY_GIT_VARS {
        cmd.env_remove(var);
    }
    cmd
}

/// Build a hermetic `stibbons <subcommand>` command rooted at `cwd`.
///
/// stibbons shells out to git (`worktree add`, `status`, `rebase`, ...), so the
/// enclosing environment must not steer those children: any of
/// [`LEAKY_GIT_VARS`] leaked from e.g. a pre-push hook would retarget them at
/// the outer repo, and a host without a global gitconfig would fail any commit or
/// rebase for lack of an identity.
pub fn stibbons_cmd(subcommand: &str, cwd: &Path) -> Command {
    let mut cmd = Command::new(stibbons_bin());
    scrub_git_env(cmd.current_dir(cwd).arg(subcommand))
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

// --- git fixture helpers (shared by worktree + spawn-hermeticity tests) ---

/// Runs `git <args>` in `dir` with a fixed identity and a clean git env,
/// asserting success.
pub fn git(dir: &Path, args: &[&str]) {
    // Prevent the enclosing repo's git env from leaking into the fixture.
    let out = scrub_git_env(&mut Command::new("git"))
        .current_dir(dir)
        .args(args)
        // Hermetic identity — no reliance on a global gitconfig.
        .env("GIT_AUTHOR_NAME", TEST_GIT_NAME)
        .env("GIT_AUTHOR_EMAIL", TEST_GIT_EMAIL)
        .env("GIT_COMMITTER_NAME", TEST_GIT_NAME)
        .env("GIT_COMMITTER_EMAIL", TEST_GIT_EMAIL)
        .output()
        .expect("failed to spawn git");
    assert!(
        out.status.success(),
        "git {args:?} failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

/// `git -C <dir> rev-parse HEAD` with a clean git env, returning the trimmed SHA.
pub fn rev_parse_head(dir: &Path) -> String {
    let out = scrub_git_env(&mut Command::new("git"))
        .current_dir(dir)
        .args(["rev-parse", "HEAD"])
        .output()
        .expect("failed to spawn git");
    assert!(out.status.success(), "rev-parse failed: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Inits a real repo at `dir` on `main` with one commit (`README.md` = `hi`).
pub fn init_repo(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-b", "main"]);
    std::fs::write(dir.join("README.md"), "hi\n").unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", "init"]);
}

/// Writes `file` = `content` in `dir` and commits it on the current branch.
pub fn commit_file(dir: &Path, file: &str, content: &str, msg: &str) {
    std::fs::write(dir.join(file), content).unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", msg]);
}

/// Writes a minimal `.igor.yml` for project `myapp` rooted at `project` (so
/// `base_dir` is its parent). A non-empty `repos` and/or a `max` add an
/// `agents:` block; with neither, the agent defaults apply (repos `[myapp]`,
/// max 5).
pub fn write_igor_yml(project: &Path, repos: &[&str], max: Option<u32>) {
    let mut cfg = format!(
        "schema_version: 1\n\
         containers_dir: containers\n\
         project:\n\
         \x20 name: myapp\n\
         \x20 working_dir: {}\n\
         features:\n\
         \x20 - python\n",
        project.display()
    );
    if !repos.is_empty() || max.is_some() {
        cfg.push_str("agents:\n");
        if let Some(m) = max {
            writeln!(cfg, "  max: {m}").unwrap();
        }
        if !repos.is_empty() {
            cfg.push_str("  repos:\n");
            for r in repos {
                writeln!(cfg, "    - {r}").unwrap();
            }
        }
    }
    std::fs::write(project.join(".igor.yml"), cfg).unwrap();
}
