//! The `git` CLI abstraction used by agent worktree management.
//!
//! Extracted from `worktree.rs` (#843), which had grown to 29 top-level units
//! across 17 concerns. This module is the git analogue of the sibling
//! [`super::docker`] module and mirrors its shape: an error enum, a trait
//! abstracting the CLI, and a production impl that shells out.
//!
//! Items were MOVED here verbatim rather than rewritten, so the split is
//! behavior-preserving by construction.

use std::path::{Path, PathBuf};
use std::process::Command;

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

#[cfg(test)]
mod tests {
    use super::*;

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
}
