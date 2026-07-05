//! `stibbons worktree` — create and remove per-agent git worktrees.
//!
//! Each agent container runs against its own git worktree so multiple golems can
//! work different branches simultaneously. This module is the Rust port of the
//! retired Go `igor worktree` command group (issue #362); the Go original lived
//! in `cmd/igor/internal/cmd/worktree.go` and was removed with the submodule, so
//! the issue's inline snippet is the reference.
//!
//! The subtle part is **`.git` pointer rewriting**. `git worktree add` writes
//! the worktree's `.git` file and the main repo's back-link `gitdir` file using
//! host-absolute paths. Inside the container those paths don't exist, so git
//! operations fail. [`create_worktree`] rewrites both to container-internal
//! paths after the `add`.
//!
//! Layering mirrors the sibling `agent` commands:
//!
//! - [`GitRunner`] — a trait over the `git` CLI (with a test double), the git
//!   analogue of [`super::docker::DockerRunner`].
//! - [`resolve_git_dir`] / [`detect_worktree_mounts`] — pure filesystem helpers,
//!   directly unit-testable.
//! - [`create_worktree`] / [`remove_worktree`] — orchestration over a
//!   `&dyn GitRunner`.
//! - [`run`] — the single entry point wired into `main.rs`.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use clap::Subcommand;
use containers_common::config::IgorConfig;
use containers_common::feature::{self, Registry};
use containers_common::generate;
use containers_common::template::{RenderContext, Renderer};

use super::CONFIG_PATH;
use super::context::{AgentContext, agent_suffix, validate_agent_num};

/// Boxed error alias matching the stibbons CLI convention (`main.rs`).
type CmdResult = Result<(), Box<dyn std::error::Error>>;

/// The generated compose file this command owns and re-renders.
const COMPOSE_FILE: &str = ".devcontainer/docker-compose.yml";
/// Template name registered in [`Renderer`] for the compose file.
const COMPOSE_TEMPLATE: &str = "docker-compose.yml.tmpl";

/// Subcommands under `stibbons worktree`.
#[derive(Subcommand, Debug)]
pub enum WorktreeCommands {
    /// Create the worktree(s) for agent N and re-render compose mounts.
    Create {
        /// Agent number (1..=max).
        n: String,

        /// Overwrite `docker-compose.yml` even if it was modified locally.
        #[arg(long)]
        force: bool,
    },

    /// Remove the worktree(s) for agent N and re-render compose mounts.
    Remove {
        /// Agent number (1..=max).
        n: String,

        /// Force removal of a dirty worktree (discards uncommitted changes) and
        /// overwrite a locally-modified `docker-compose.yml`.
        #[arg(long)]
        force: bool,
    },
}

/// Error from invoking the `git` binary itself (spawn failure or a non-zero
/// exit from a captured [`GitRunner::run`] call). Mirrors
/// [`super::docker::DockerError`].
#[derive(Debug, thiserror::Error)]
pub enum GitError {
    /// The `git` process could not be spawned (e.g. binary not on `PATH`).
    #[error("failed to run git: {0}")]
    Spawn(#[source] std::io::Error),

    /// `git` ran but exited non-zero. Carries the trimmed combined output so
    /// callers can surface git's own message.
    #[error("git {args} failed: {output}")]
    NonZero {
        /// The argv that failed, space-joined, for the message.
        args: String,
        /// Trimmed combined stdout+stderr from the failed invocation.
        output: String,
    },
}

/// Abstracts the `git` CLI so worktree logic is testable without a real repo.
///
/// The git analogue of [`super::docker::DockerRunner`]: a production impl that
/// shells out, and a recording test double under `#[cfg(test)]`.
pub trait GitRunner {
    /// Runs `git <args>` and returns the trimmed combined stdout+stderr.
    ///
    /// # Errors
    ///
    /// Returns [`GitError::Spawn`] if the process cannot start, or
    /// [`GitError::NonZero`] if `git` exits non-zero.
    fn run(&self, args: &[&str]) -> Result<String, GitError>;
}

/// Production [`GitRunner`] backed by `std::process::Command`.
#[derive(Debug, Default, Clone, Copy)]
pub struct ProcessGitRunner;

impl GitRunner for ProcessGitRunner {
    fn run(&self, args: &[&str]) -> Result<String, GitError> {
        // Clear the ambient git-dir env: every call targets an explicit repo via
        // `-C <dir>`, so an inherited `GIT_DIR`/`GIT_WORK_TREE` (set by a parent
        // git process — e.g. a pre-push hook, or `git` invoking a subcommand)
        // would silently redirect operations to the wrong repository. Worktree
        // creation is especially sensitive: a leaked `GIT_DIR` makes
        // `git worktree add` register the branch against the parent repo,
        // colliding with its existing worktrees.
        let output = Command::new("git")
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .output()
            .map_err(GitError::Spawn)?;

        // Combine stdout+stderr like Go's `CombinedOutput`, then trim. Ordering
        // is not meaningful to callers — they inspect substrings or surface the
        // whole blob on error.
        let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
        let combined = combined.trim().to_string();

        if output.status.success() {
            Ok(combined)
        } else {
            Err(GitError::NonZero { args: args.join(" "), output: combined })
        }
    }
}

/// Resolves a repo's real git directory, handling both a normal repo (`.git` is
/// a directory) and a worktree/submodule checkout (`.git` is a pointer file
/// holding `gitdir: <path>`).
///
/// A relative `gitdir:` path is resolved against `repo_path`, matching the Go
/// `resolveGitDir`. When `.git` is absent the conventional `<repo>/.git` path is
/// returned so callers still get a usable (if not-yet-created) location.
///
/// # Errors
///
/// Returns an error if the `.git` pointer file exists but cannot be read.
pub fn resolve_git_dir(repo_path: &Path) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let git_path = repo_path.join(".git");
    // No `.git` yet — hand back the conventional location.
    let Ok(meta) = std::fs::metadata(&git_path) else {
        return Ok(git_path);
    };

    if meta.is_dir() {
        return Ok(git_path);
    }

    // Pointer file: parse `gitdir: <path>`.
    let data = std::fs::read_to_string(&git_path)?;
    let gitdir = data.trim().strip_prefix("gitdir:").map_or_else(|| data.trim(), str::trim);
    let gitdir_path = Path::new(gitdir);
    if gitdir_path.is_absolute() {
        Ok(gitdir_path.to_path_buf())
    } else {
        Ok(repo_path.join(gitdir_path))
    }
}

/// Overwrites `path` with `content`, creating parent directories as needed.
fn overwrite_file(path: &Path, content: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, content)
}

/// Creates the worktree for `repo` under `base_dir` with the given agent
/// `suffix`, rewriting the `.git`/`gitdir` pointers to container-internal paths.
///
/// Steps (ported from the Go `createWorktree`):
/// 1. Resolve the main repo's git dir.
/// 2. Create branch `<suffix>` if it doesn't exist.
/// 3. `git worktree add <base_dir>/<repo>-<suffix> <suffix>`.
/// 4. Rewrite `<worktree>/.git` → `gitdir: <git_dir>/worktrees/<repo>-<suffix>`.
/// 5. Rewrite `<git_dir>/worktrees/<repo>-<suffix>/gitdir` →
///    `<base_dir>/<repo>-<suffix>/.git` (the container-internal path).
///
/// Steps 4–5 are the critical rewriting: without them, git inside the container
/// follows host-absolute paths that don't exist.
///
/// # Errors
///
/// Propagates git failures (branch/worktree creation) or I/O errors writing the
/// pointer files.
pub fn create_worktree(
    git: &dyn GitRunner,
    base_dir: &Path,
    repo: &str,
    suffix: &str,
    out: &mut dyn Write,
) -> CmdResult {
    let main_repo = base_dir.join(repo);
    let worktree_dir = base_dir.join(format!("{repo}-{suffix}"));

    if worktree_dir.exists() {
        writeln!(out, "  worktree {} already exists", worktree_dir.display())?;
        return Ok(());
    }

    let git_dir = resolve_git_dir(&main_repo)?;
    let main_repo_str = main_repo.display().to_string();

    // Create the branch if it doesn't already exist (worktree add needs it).
    let list = git.run(&["-C", &main_repo_str, "branch", "--list", suffix]).unwrap_or_default();
    if list.trim().is_empty() {
        git.run(&["-C", &main_repo_str, "branch", suffix])?;
    }

    let worktree_str = worktree_dir.display().to_string();
    git.run(&["-C", &main_repo_str, "worktree", "add", &worktree_str, suffix])?;

    // The name git uses for this worktree's admin dir, `<repo>-<suffix>`.
    let worktree_name = format!("{repo}-{suffix}");

    // Rewrite the worktree's `.git` pointer to the container-internal gitdir.
    let worktree_git_file = worktree_dir.join(".git");
    let worktree_git_content =
        format!("gitdir: {}/worktrees/{}\n", git_dir.display(), worktree_name);
    overwrite_file(&worktree_git_file, &worktree_git_content)?;

    // Rewrite the main repo's back-link `gitdir` to the container-internal path.
    let worktree_link = git_dir.join("worktrees").join(&worktree_name).join("gitdir");
    let new_gitdir = format!("{}/.git\n", worktree_dir.display());
    overwrite_file(&worktree_link, &new_gitdir)?;

    writeln!(out, "  created worktree {}", worktree_dir.display())?;
    Ok(())
}

/// Removes the worktree for `repo`/`suffix`, falling back to a manual
/// `rm -rf`-equivalent if `git worktree remove` fails (e.g. the admin metadata
/// is already gone). Ported from the Go `removeWorktree`.
///
/// When `force` is false, a worktree with uncommitted changes (dirty tree or
/// untracked files) is **refused** with an actionable error — this preserves
/// git's own non-`--force` safety net, which the unconditional `--force` in the
/// Go original discarded. `force` opts into destroying that work. The
/// destructive `git worktree remove` and the manual `remove_dir_all` fallback
/// are both reached only past this gate.
///
/// # Errors
///
/// Returns an error if the worktree is dirty and `force` is false, or if the
/// manual fallback cleanup itself fails.
pub fn remove_worktree(
    git: &dyn GitRunner,
    base_dir: &Path,
    repo: &str,
    suffix: &str,
    force: bool,
    out: &mut dyn Write,
) -> CmdResult {
    let worktree_dir = base_dir.join(format!("{repo}-{suffix}"));
    if !worktree_dir.exists() {
        writeln!(out, "  worktree {} does not exist", worktree_dir.display())?;
        return Ok(());
    }

    let main_repo = base_dir.join(repo);
    let main_repo_str = main_repo.display().to_string();
    let worktree_str = worktree_dir.display().to_string();

    // Refuse to destroy uncommitted work unless the caller explicitly opts in —
    // `git worktree remove --force` (and the manual fallback) would otherwise
    // silently discard an agent's in-progress changes.
    if !force && worktree_is_dirty(git, &worktree_str) {
        return Err(format!(
            "worktree {} has uncommitted changes; commit/stash them or pass --force to discard",
            worktree_dir.display()
        )
        .into());
    }

    if git.run(&["-C", &main_repo_str, "worktree", "remove", "--force", &worktree_str]).is_ok() {
        writeln!(out, "  removed worktree {}", worktree_dir.display())?;
        return Ok(());
    }

    // Git couldn't remove it — fall back to manual directory removal.
    writeln!(out, "  git worktree remove failed; cleaning up {} manually", worktree_dir.display())?;
    std::fs::remove_dir_all(&worktree_dir)?;
    // Best-effort prune of the now-dangling admin metadata.
    let _ = git.run(&["-C", &main_repo_str, "worktree", "prune"]);
    writeln!(out, "  removed worktree {}", worktree_dir.display())?;
    Ok(())
}

/// True when the worktree at `worktree_str` has a dirty tree or untracked files.
///
/// A non-empty `git status --porcelain` means uncommitted work is present. When
/// git can't be run at all (spawn failure, not a repo), we conservatively treat
/// the worktree as **clean** so the caller's own removal path — which handles
/// git failures with a manual fallback — stays reachable; the goal here is only
/// to preserve git's dirty-refusal, not to invent a new failure mode.
fn worktree_is_dirty(git: &dyn GitRunner, worktree_str: &str) -> bool {
    matches!(
        git.run(&["-C", worktree_str, "status", "--porcelain"]),
        Ok(status) if !status.trim().is_empty()
    )
}

/// Scans `<base_dir>/<repo>-agentNN` for `n in 1..=max_agents` across all
/// `repos`, returning the docker-compose volume-mount spec for each worktree
/// that exists on disk. Ported from the Go `detectWorktreeMounts`.
///
/// Mounts use the compose-relative host path (`../<repo>-agentNN`) so the
/// generated file stays portable, matching the source-code mount already in the
/// template (`../:/workspace/<project>`). The result is **sorted** for
/// deterministic rendering.
#[must_use]
pub fn detect_worktree_mounts(base_dir: &Path, repos: &[String], max_agents: u32) -> Vec<String> {
    let mut mounts = Vec::new();
    for n in 1..=max_agents {
        let suffix = agent_suffix(n);
        for repo in repos {
            let name = format!("{repo}-{suffix}");
            if base_dir.join(&name).is_dir() {
                mounts.push(format!("../{name}:/workspace/{name}"));
            }
        }
    }
    mounts.sort();
    mounts
}

/// Re-renders `.devcontainer/docker-compose.yml` with `mounts` populated in the
/// worktree-mounts slot, honoring the same drift-detection contract as
/// `init`/`add`/`remove`/`update`: a compose file the user has hand-edited since
/// the last render is **preserved** (and a warning printed) unless `force` is
/// set. On a write, the recorded hash in `.igor.yml` is refreshed so the change
/// is not later flagged as a stray user edit.
///
/// Only the compose file is classified/rendered — this operation owns just that
/// file — so the other generated files (`devcontainer.json`, `.env`, …) are
/// untouched.
///
/// # Errors
///
/// Propagates template-render, classification, or file-write failures, or a
/// failure saving the updated `.igor.yml`.
fn update_compose_worktree_mounts(cfg: &IgorConfig, mounts: Vec<String>, force: bool) -> CmdResult {
    let reg = Registry::new();
    let explicit: std::collections::HashSet<String> = cfg.features.iter().cloned().collect();
    let selection = feature::resolve(&explicit, &reg);

    let mut ctx = RenderContext::new(
        cfg.project.clone(),
        &cfg.containers_dir,
        &selection,
        &reg,
        cfg.versions.clone(),
        cfg.agents.clone(),
    );
    ctx.worktree_mounts = mounts;

    let renderer = Renderer::new()?;
    let content = renderer.render(COMPOSE_TEMPLATE, &ctx)?;

    // Classify against the recorded hash before writing — the shared 3-way-merge
    // contract from `render.rs` that keeps a user's local compose edits from
    // being silently clobbered. A `Skipped` result means the file diverged from
    // its last-rendered hash and `force` is off: leave it, warn, and don't touch
    // the recorded hash.
    let compose_path = Path::new(COMPOSE_FILE);
    let action = generate::classify_file(compose_path, &content, &cfg.generated, force)?;
    if !action.should_write() {
        return Err(format!(
            "{COMPOSE_FILE} has local modifications; re-run with --force to overwrite its \
             worktree mounts"
        )
        .into());
    }

    overwrite_file(compose_path, &content)?;

    // Keep the recorded provenance hash in sync so future drift detection sees
    // this compose file as generated, not user-modified.
    let mut updated = cfg.clone();
    updated.generated.insert(COMPOSE_FILE.to_string(), generate::hash_content(&content));
    updated.save(CONFIG_PATH)?;
    Ok(())
}

/// Dispatches a `worktree` subcommand: loads the shared agent context, creates
/// or removes agent N's worktree(s) across all configured repos, then re-renders
/// the compose mounts from a fresh on-disk scan.
///
/// # Errors
///
/// Returns an error if `.igor.yml` is missing/invalid, the agent number is out
/// of range, or a git/I/O/render step fails.
pub fn run(command: &WorktreeCommands) -> CmdResult {
    let ctx = AgentContext::load(Path::new(CONFIG_PATH))?;
    let git = ProcessGitRunner;
    let mut out = std::io::stdout();

    let (n_arg, force) = match command {
        WorktreeCommands::Create { n, force } | WorktreeCommands::Remove { n, force } => {
            (n, *force)
        }
    };
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let suffix = agent_suffix(n);

    match command {
        WorktreeCommands::Create { .. } => {
            writeln!(out, "Creating worktrees for agent {n} ...")?;
            for repo in &ctx.repos {
                create_worktree(&git, &ctx.base_dir, repo, &suffix, &mut out)?;
            }
        }
        WorktreeCommands::Remove { .. } => {
            writeln!(out, "Removing worktrees for agent {n} ...")?;
            for repo in &ctx.repos {
                remove_worktree(&git, &ctx.base_dir, repo, &suffix, force, &mut out)?;
            }
        }
    }

    // Re-render compose from a fresh scan so the mount list reflects reality.
    let mounts = detect_worktree_mounts(&ctx.base_dir, &ctx.repos, ctx.max_agents);
    update_compose_worktree_mounts(&ctx.cfg, mounts, force)?;
    writeln!(out, "Updated {COMPOSE_FILE} worktree mounts")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    /// Recording [`GitRunner`] test double. Records every argv and returns a
    /// canned result matched by the first two args, mirroring `MockDocker`.
    #[derive(Default)]
    struct MockGit {
        calls: RefCell<Vec<Vec<String>>>,
        /// Keyed by the first two args joined (e.g. `"worktree add"`); value is
        /// `Ok`/`Err` plus canned output.
        results: RefCell<std::collections::HashMap<String, Result<String, ()>>>,
    }

    impl MockGit {
        fn new() -> Self {
            Self::default()
        }

        /// Pin a canned result for calls whose 2nd/3rd argv join to `key`.
        fn on(&self, key: &str, result: Result<&str, ()>) {
            self.results.borrow_mut().insert(key.to_string(), result.map(ToString::to_string));
        }

        fn has_call(&self, substr: &str) -> bool {
            self.calls.borrow().iter().any(|c| c.join(" ").contains(substr))
        }
    }

    impl GitRunner for MockGit {
        fn run(&self, args: &[&str]) -> Result<String, GitError> {
            self.calls.borrow_mut().push(args.iter().map(ToString::to_string).collect());
            // Worktree subcommands land at args[2..] because of the `-C <dir>`
            // prefix; key on the subcommand + verb.
            let key = if args.len() >= 4 {
                format!("{} {}", args[2], args[3])
            } else if args.len() >= 3 {
                format!("{} {}", args[1], args[2])
            } else {
                String::new()
            };
            match self.results.borrow().get(&key) {
                Some(Ok(out)) => Ok(out.clone()),
                Some(Err(())) => {
                    Err(GitError::NonZero { args: args.join(" "), output: "mock error".into() })
                }
                None => Ok(String::new()),
            }
        }
    }

    #[test]
    fn resolve_git_dir_directory_case() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("myrepo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();

        let resolved = resolve_git_dir(&repo).unwrap();
        assert_eq!(resolved, repo.join(".git"));
    }

    #[test]
    fn resolve_git_dir_pointer_file_absolute() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("myrepo");
        std::fs::create_dir_all(&repo).unwrap();
        let target = tmp.path().join("real/.git/worktrees/x");
        std::fs::write(repo.join(".git"), format!("gitdir: {}\n", target.display())).unwrap();

        let resolved = resolve_git_dir(&repo).unwrap();
        assert_eq!(resolved, target);
    }

    #[test]
    fn resolve_git_dir_pointer_file_relative() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("myrepo");
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::write(repo.join(".git"), "gitdir: ../shared/.git\n").unwrap();

        let resolved = resolve_git_dir(&repo).unwrap();
        assert_eq!(resolved, repo.join("../shared/.git"));
    }

    #[test]
    fn resolve_git_dir_missing_returns_conventional() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("myrepo");
        std::fs::create_dir_all(&repo).unwrap();

        let resolved = resolve_git_dir(&repo).unwrap();
        assert_eq!(resolved, repo.join(".git"));
    }

    #[test]
    fn create_worktree_rewrites_pointers() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // Main repo with a real `.git` directory and the admin worktrees dir the
        // rewrite targets.
        let main = base.join("myrepo");
        let git_dir = main.join(".git");
        std::fs::create_dir_all(git_dir.join("worktrees/myrepo-agent01")).unwrap();

        // `git worktree add` is mocked to just materialize the worktree dir with
        // a stub `.git` file (as real git would, with a host path we overwrite).
        let git = MockGit::new();
        let worktree_dir = base.join("myrepo-agent01");
        std::fs::create_dir_all(&worktree_dir).unwrap();
        std::fs::write(worktree_dir.join(".git"), "gitdir: /host/path\n").unwrap();

        // Existing-worktree guard would short-circuit; remove it so create runs.
        std::fs::remove_dir_all(&worktree_dir).unwrap();
        git.on("worktree add", Ok(""));

        let mut out = Vec::new();
        create_worktree(&git, base, "myrepo", "agent01", &mut out).unwrap();

        // The worktree `.git` pointer now targets the container-internal gitdir.
        let git_content = std::fs::read_to_string(worktree_dir.join(".git")).unwrap();
        assert_eq!(
            git_content,
            format!("gitdir: {}/worktrees/myrepo-agent01\n", git_dir.display())
        );

        // The back-link `gitdir` now targets the container-internal worktree.
        let link = git_dir.join("worktrees/myrepo-agent01/gitdir");
        let link_content = std::fs::read_to_string(link).unwrap();
        assert_eq!(link_content, format!("{}/.git\n", worktree_dir.display()));

        assert!(git.has_call("worktree add"));
    }

    #[test]
    fn create_worktree_creates_branch_when_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let main = base.join("myrepo");
        std::fs::create_dir_all(main.join(".git/worktrees/myrepo-agent01")).unwrap();

        let git = MockGit::new();
        // `branch --list` returns empty → branch must be created.
        git.on("branch --list", Ok(""));

        let mut out = Vec::new();
        create_worktree(&git, base, "myrepo", "agent01", &mut out).unwrap();

        assert!(git.has_call("branch agent01"), "expected branch creation call");
    }

    #[test]
    fn remove_worktree_manual_fallback() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myrepo")).unwrap();
        let worktree_dir = base.join("myrepo-agent01");
        std::fs::create_dir_all(&worktree_dir).unwrap();

        let git = MockGit::new();
        // Clean worktree (default empty `status --porcelain`); git worktree
        // remove fails → manual cleanup kicks in.
        git.on("worktree remove", Err(()));

        let mut out = Vec::new();
        remove_worktree(&git, base, "myrepo", "agent01", false, &mut out).unwrap();

        assert!(!worktree_dir.exists(), "worktree dir should be removed manually");
    }

    #[test]
    fn remove_worktree_refuses_dirty_without_force() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myrepo")).unwrap();
        let worktree_dir = base.join("myrepo-agent01");
        std::fs::create_dir_all(&worktree_dir).unwrap();

        let git = MockGit::new();
        // Dirty worktree: `status --porcelain` reports an uncommitted change.
        git.on("status --porcelain", Ok(" M file.rs"));

        let mut out = Vec::new();
        let err = remove_worktree(&git, base, "myrepo", "agent01", false, &mut out).unwrap_err();

        assert!(err.to_string().contains("uncommitted changes"), "got: {err}");
        assert!(worktree_dir.exists(), "dirty worktree must be preserved without --force");
        assert!(!git.has_call("worktree remove"), "must not attempt removal on a dirty worktree");
    }

    #[test]
    fn remove_worktree_force_discards_dirty() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myrepo")).unwrap();
        let worktree_dir = base.join("myrepo-agent01");
        std::fs::create_dir_all(&worktree_dir).unwrap();

        let git = MockGit::new();
        // Even a dirty worktree is removed when force is set (git remove succeeds).
        git.on("status --porcelain", Ok(" M file.rs"));

        let mut out = Vec::new();
        remove_worktree(&git, base, "myrepo", "agent01", true, &mut out).unwrap();

        assert!(git.has_call("worktree remove --force"), "expected forced removal");
    }

    #[test]
    fn detect_worktree_mounts_sorted_specs() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // Seed agent01 and agent03 worktrees for two repos (skip agent02).
        for name in ["app-agent01", "lib-agent01", "app-agent03"] {
            std::fs::create_dir_all(base.join(name)).unwrap();
        }
        // A non-directory with a matching name must be ignored.
        std::fs::write(base.join("app-agent04"), "not a dir").unwrap();

        let repos = vec!["app".to_string(), "lib".to_string()];
        let mounts = detect_worktree_mounts(base, &repos, 5);

        assert_eq!(
            mounts,
            vec![
                "../app-agent01:/workspace/app-agent01".to_string(),
                "../app-agent03:/workspace/app-agent03".to_string(),
                "../lib-agent01:/workspace/lib-agent01".to_string(),
            ]
        );
    }
}
