//! `stibbons worktree sync` — rebase agent worktree branches onto a base ref.
//!
//! Extracted from the parent `worktree` module (#843), which the audit lens
//! flagged as a god-module (29 top-level units across 17 concerns). This is the
//! `sync_*` seam the decomposition pre-scan nominated.
//!
//! Topology-agnostic by design: nothing here merges or pushes, it only ever runs
//! `git rebase <base>` inside a worktree. That makes it the seam the
//! orchestrator's cross-PR rebase dispatch can call safely.
//!
//! Items were MOVED here verbatim rather than rewritten, so the split is
//! behavior-preserving by construction. The shared helpers this depends on
//! (`worktree_paths`, `worktree_is_dirty`, `CmdResult`) stay in the parent and
//! are reached through `super::` — they are used by create/remove/status too,
//! so moving them here would have been the wrong direction.

use std::io::Write;
use std::path::Path;

use super::{CmdResult, worktree_is_dirty, worktree_paths};
use crate::agent::context::AgentContext;
use crate::agent::git::GitRunner;

/// Rejects a base ref that git's option parser would treat as a flag.
///
/// `git rebase <base>` passes `base` positionally, but git parses *any* argv
/// element beginning with `-` as an option regardless of position — so a value
/// like `--exec=<cmd>` reaching `git rebase` is arbitrary command execution, not
/// an "unknown ref" error. Since `sync_worktree` is documented as the seam the
/// orchestrator's rebase dispatch calls (potentially with a ref sourced from PR
/// or branch metadata), reject dash-prefixed refs up front. Legitimate branch
/// names can never begin with `-` (`git check-ref-format` forbids it), so this
/// loses no valid input.
fn reject_optionlike_ref(base: &str) -> CmdResult {
    if base.starts_with('-') {
        return Err(format!(
            "invalid base ref {base:?}: refs cannot begin with '-' (would be parsed as a git option)"
        )
        .into());
    }
    Ok(())
}

/// Resolves the branch `sync` rebases onto: an explicit `--onto` ref wins;
/// otherwise the main repo's currently-checked-out branch
/// (`rev-parse --abbrev-ref HEAD`).
///
/// # Errors
///
/// Returns an error when the ref is option-like (begins with `-`, see
/// [`reject_optionlike_ref`]), or when there is no `--onto` and the main repo is
/// in detached HEAD (branch resolves to `HEAD` or empty), pointing the caller at
/// `--onto`.
fn resolve_base_branch(
    git: &dyn GitRunner,
    main_repo_str: &str,
    onto: Option<&str>,
) -> Result<String, Box<dyn std::error::Error>> {
    if let Some(r) = onto {
        reject_optionlike_ref(r)?;
        return Ok(r.to_string());
    }
    let branch =
        git.run(&["-C", main_repo_str, "rev-parse", "--abbrev-ref", "HEAD"])?.trim().to_string();
    if branch.is_empty() || branch == "HEAD" {
        return Err("main repo is in detached HEAD; pass --onto <ref> to choose a base".into());
    }
    Ok(branch)
}

/// Rebases one worktree's branch onto `base_branch`.
///
/// Topology-agnostic (per issue #309's 2026-06-21 note): only ever runs
/// `git rebase <base>` inside the worktree — no merge into the parent branch, no
/// push. A dirty worktree is **refused before** any rebase (mirroring
/// [`remove_worktree`](super::remove_worktree)'s gate), since rebasing over
/// uncommitted work aborts messily. `dry_run` prints the command it would run
/// without touching the branch.
///
/// A rebase that hits conflicts exits non-zero and the error is propagated,
/// leaving the worktree mid-rebase for the user or the orchestrator's
/// `rebase-agent` to resolve — we deliberately do **not** auto-abort, which would
/// hide the conflict.
///
/// # Errors
///
/// Returns an error if `repo` is not a safe name, if the worktree is dirty, or
/// if `git rebase` fails (e.g. conflicts).
pub fn sync_worktree(
    git: &dyn GitRunner,
    base_dir: &Path,
    repo: &str,
    suffix: &str,
    base_branch: &str,
    dry_run: bool,
    out: &mut dyn Write,
) -> Result<SyncOutcome, Box<dyn std::error::Error>> {
    let (_main_repo, worktree_dir) = worktree_paths(base_dir, repo, suffix)?;
    if !worktree_dir.exists() {
        writeln!(out, "  worktree {} does not exist", worktree_dir.display())?;
        return Ok(SyncOutcome::Skipped);
    }
    let worktree_str = worktree_dir.display().to_string();

    // Refuse to rebase over uncommitted work — git itself aborts a dirty rebase,
    // but a clear up-front error beats git's cryptic mid-operation message.
    if worktree_is_dirty(git, &worktree_str) {
        return Err(format!(
            "worktree {} has uncommitted changes; commit or stash them before sync",
            worktree_dir.display()
        )
        .into());
    }

    if dry_run {
        writeln!(out, "  [dry-run] git -C {worktree_str} rebase --end-of-options {base_branch}")?;
        return Ok(SyncOutcome::Skipped);
    }

    // `--end-of-options` stops git parsing later argv as flags, so the base ref
    // is always treated positionally (defense in depth atop reject_optionlike_ref).
    let output = git.run(&["-C", &worktree_str, "rebase", "--end-of-options", base_branch])?;
    writeln!(out, "  rebased {} onto {base_branch}", worktree_dir.display())?;
    let trimmed = output.trim();
    if !trimmed.is_empty() {
        writeln!(out, "    {trimmed}")?;
    }
    Ok(SyncOutcome::Rebased)
}

/// What [`sync_worktree`] did to one repo's worktree, for the per-repo summary.
///
/// Only the two *successful* shapes are modelled — a failure is carried by the
/// `Err` arm of the return type, so this cannot represent "failed" and no caller
/// can mistake one for the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncOutcome {
    /// The rebase ran.
    Rebased,
    /// Nothing was rebased: the worktree doesn't exist, or this was a dry run.
    Skipped,
}

/// Syncs every repo's worktree for one agent, attempting **all** repos before
/// returning.
///
/// A rebase conflict is an expected, non-error outcome that [`sync_worktree`]
/// deliberately surfaces rather than auto-aborting. Propagating the first one
/// with `?` (the pre-#712 behavior) left every later repo unsynced even when it
/// would have rebased cleanly, with no indication of which repos were reached.
/// So failures are accumulated: each repo is attempted, a
/// succeeded/skipped/failed summary is printed, and an aggregate error is
/// returned only after the whole list has been walked.
///
/// `resolve_base_branch` is called per repo (each has its own current branch
/// when `--onto` is absent) and a resolution failure is accumulated the same
/// way, so one repo with a detached HEAD doesn't strand the others.
///
/// # Errors
///
/// Returns an aggregate error naming every repo that failed, after all repos
/// have been attempted.
pub(super) fn sync_all_repos(
    git: &dyn GitRunner,
    ctx: &AgentContext,
    suffix: &str,
    onto: Option<&str>,
    dry_run: bool,
    out: &mut dyn Write,
) -> CmdResult {
    let mut rebased = Vec::new();
    let mut skipped = Vec::new();
    let mut failed = Vec::new();

    for repo in &ctx.repos {
        let main_repo_str = ctx.base_dir.join(repo).display().to_string();
        let result = resolve_base_branch(git, &main_repo_str, onto)
            .and_then(|base| sync_worktree(git, &ctx.base_dir, repo, suffix, &base, dry_run, out));
        match result {
            Ok(SyncOutcome::Rebased) => rebased.push(repo.clone()),
            Ok(SyncOutcome::Skipped) => skipped.push(repo.clone()),
            Err(e) => {
                // Report each failure as it happens so the operator sees which
                // repo failed next to its own output, not only in the summary.
                writeln!(out, "  {repo}: {e}")?;
                failed.push(format!("{repo}: {e}"));
            }
        }
    }

    writeln!(
        out,
        "Sync summary: {} rebased, {} skipped, {} failed",
        rebased.len(),
        skipped.len(),
        failed.len()
    )?;
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("sync failed for {} repo(s): {}", failed.len(), failed.join("; ")).into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::test_support::{FailGitIn, MockGit, ctx_with_repos};

    #[test]
    fn resolve_base_branch_uses_onto_override() {
        let git = MockGit::new();
        let base = resolve_base_branch(&git, "/repo", Some("develop")).unwrap();
        assert_eq!(base, "develop");
        assert!(!git.has_call("rev-parse"), "an explicit --onto must not shell out to git");
    }

    #[test]
    fn resolve_base_branch_defaults_to_main_branch() {
        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Ok("main"));
        let base = resolve_base_branch(&git, "/repo", None).unwrap();
        assert_eq!(base, "main");
    }

    #[test]
    fn resolve_base_branch_detached_head_errors() {
        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Ok("HEAD"));
        let err = resolve_base_branch(&git, "/repo", None).unwrap_err();
        assert!(err.to_string().contains("--onto"), "got: {err}");
    }

    #[test]
    fn sync_worktree_refuses_dirty() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        git.on("status --porcelain", Ok(" M file.rs"));

        let mut out = Vec::new();
        let err =
            sync_worktree(&git, base, "myapp", "agent01", "main", false, &mut out).unwrap_err();
        assert!(err.to_string().contains("uncommitted changes"), "got: {err}");
        assert!(!git.has_call("rebase"), "must not rebase a dirty worktree");
    }

    #[test]
    fn sync_worktree_dry_run_prints_no_rebase() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        // Clean worktree (default empty porcelain).
        let mut out = Vec::new();
        let outcome =
            sync_worktree(&git, base, "myapp", "agent01", "main", true, &mut out).unwrap();

        assert_eq!(outcome, SyncOutcome::Skipped, "a dry run rebases nothing");
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("[dry-run]"));
        assert!(text.contains("rebase --end-of-options main"));
        assert!(!git.has_call("rebase"), "dry-run must not actually rebase");
    }

    #[test]
    fn sync_worktree_runs_rebase() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        let mut out = Vec::new();
        let outcome =
            sync_worktree(&git, base, "myapp", "agent01", "main", false, &mut out).unwrap();

        assert_eq!(outcome, SyncOutcome::Rebased);
        assert!(git.has_call("rebase --end-of-options main"), "expected the rebase call");
        assert!(String::from_utf8(out).unwrap().contains("rebased"));
    }

    #[test]
    fn sync_worktree_propagates_rebase_conflict() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        // Clean worktree, but the rebase itself fails (conflicts). The error must
        // surface — sync deliberately does NOT auto-abort or swallow it.
        git.on("rebase --end-of-options", Err(()));

        let mut out = Vec::new();
        let err =
            sync_worktree(&git, base, "myapp", "agent01", "main", false, &mut out).unwrap_err();
        assert!(err.to_string().contains("rebase"), "error should reflect the git failure: {err}");
        assert!(
            !String::from_utf8(out).unwrap().contains("rebased"),
            "must not print a success line when the rebase failed",
        );
    }

    #[test]
    fn resolve_base_branch_rejects_optionlike_onto() {
        let git = MockGit::new();
        let err = resolve_base_branch(&git, "/repo", Some("--exec=touch pwned")).unwrap_err();
        assert!(err.to_string().contains("cannot begin with '-'"), "got: {err}");
        assert!(!git.has_call("rev-parse"), "a rejected ref must not shell out");
    }

    #[test]
    fn sync_worktree_missing_dir_noops() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();

        let git = MockGit::new();
        let mut out = Vec::new();
        let outcome =
            sync_worktree(&git, base, "myapp", "agent01", "main", false, &mut out).unwrap();

        assert_eq!(outcome, SyncOutcome::Skipped);
        assert!(String::from_utf8(out).unwrap().contains("does not exist"));
        assert!(!git.has_call("rebase"), "a missing worktree must not rebase");
    }

    // --- #712: sync attempts every repo and reports a per-repo summary ---

    #[test]
    fn sync_all_repos_attempts_every_repo_after_a_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // Two worktrees on disk; the first one's rebase will conflict.
        std::fs::create_dir_all(base.join("alpha-agent01")).unwrap();
        std::fs::create_dir_all(base.join("beta-agent01")).unwrap();

        let git = FailGitIn::new("rebase", "alpha-agent01");
        let ctx = ctx_with_repos(base, &["alpha", "beta"]);

        let mut out = Vec::new();
        let err = sync_all_repos(&git, &ctx, "agent01", None, false, &mut out).unwrap_err();

        // The second repo was still attempted despite the first repo failing.
        let calls = git.calls();
        assert!(
            calls.iter().any(|c| c.contains("rebase") && c.contains("beta-agent01")),
            "beta must still be rebased after alpha failed: {calls:?}"
        );
        // The aggregate error names the failing repo.
        assert!(err.to_string().contains("alpha"), "got: {err}");
        assert!(!err.to_string().contains("beta:"), "beta succeeded; got: {err}");

        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("1 rebased"), "summary should count beta: {text}");
        assert!(text.contains("1 failed"), "summary should count alpha: {text}");
    }

    #[test]
    fn sync_all_repos_succeeds_when_every_repo_rebases() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("alpha-agent01")).unwrap();
        std::fs::create_dir_all(base.join("beta-agent01")).unwrap();

        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Ok("main"));
        let ctx = ctx_with_repos(base, &["alpha", "beta"]);

        let mut out = Vec::new();
        sync_all_repos(&git, &ctx, "agent01", None, false, &mut out).unwrap();

        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("2 rebased, 0 skipped, 0 failed"), "got: {text}");
    }

    #[test]
    fn sync_all_repos_counts_missing_worktrees_as_skipped() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // Only alpha exists; beta's worktree was never created.
        std::fs::create_dir_all(base.join("alpha-agent01")).unwrap();

        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Ok("main"));
        let ctx = ctx_with_repos(base, &["alpha", "beta"]);

        let mut out = Vec::new();
        sync_all_repos(&git, &ctx, "agent01", None, false, &mut out).unwrap();

        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("1 rebased, 1 skipped, 0 failed"), "got: {text}");
    }
}
