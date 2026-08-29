//! `stibbons worktree` — create, remove, list, and sync per-agent git worktrees.
//!
//! Each agent container runs against its own git worktree so multiple golems can
//! work different branches simultaneously. This module is the Rust port of the
//! retired Go `igor worktree` command group (issues #362, #309); the Go original
//! lived in `cmd/igor/internal/cmd/worktree.go` and was removed with the
//! submodule, so the issue's inline snippet is the reference.
//!
//! The subtle part is **`.git` pointer rewriting**. `git worktree add` writes
//! the worktree's `.git` file and the main repo's back-link `gitdir` file using
//! host-absolute paths. Inside the container those paths don't exist, so git
//! operations fail. [`create_worktree`] rewrites both to container-internal
//! paths after the `add`.
//!
//! Layering mirrors the sibling `agent` commands:
//!
//! - [`GitRunner`](super::git::GitRunner) — a trait over the `git` CLI (with a
//!   test double), the git analogue of [`super::docker::DockerRunner`]. It and
//!   [`resolve_git_dir`](super::git::resolve_git_dir) live in the sibling
//!   [`super::git`] module (#843).
//! - [`detect_worktree_mounts`] — a pure filesystem helper, directly
//!   unit-testable.
//! - [`create_worktree`] / [`remove_worktree`] / [`sync_worktree`] —
//!   orchestration over a `&dyn GitRunner`.
//! - [`collect_worktree_status`] — the read-only scan behind `worktree list`.
//! - [`run`] — the single entry point wired into `main.rs`.

use std::io::Write;
use std::path::{Path, PathBuf};

use clap::Subcommand;
use containers_common::config::IgorConfig;
use containers_common::feature::{self, Registry};
use containers_common::generate;
use containers_common::template::{RenderContext, Renderer};

use super::CONFIG_PATH;
use super::context::{AgentContext, agent_suffix, validate_agent_num, validate_repo_name};
// The git CLI abstraction moved to the sibling `git` module (#843). Nothing
// outside this module referenced those items by a `worktree::` path, so the
// move needs no re-export.
use super::git::{GitRunner, ProcessGitRunner, resolve_git_dir};

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

    /// List existing agent worktrees with their branch and clean/dirty status.
    List,

    /// Rebase agent N's worktree branch onto its base branch, per repo.
    ///
    /// Topology-agnostic: this only ever runs `git rebase <base>` inside the
    /// worktree — no merge into the parent branch, no push. It is the seam the
    /// orchestrator's cross-PR rebase dispatch calls.
    Sync {
        /// Agent number (1..=max).
        n: String,

        /// Rebase target ref. Defaults to the main repo's current branch.
        #[arg(long)]
        onto: Option<String>,

        /// Print the git commands that would run without executing the rebase.
        #[arg(long)]
        dry_run: bool,
    },
}

/// Resolves the `(main_repo, worktree_dir)` pair for `repo`/`suffix` under
/// `base_dir`, re-validating `repo` first.
///
/// Defense in depth for #705. [`AgentContext::load`] already rejects unsafe
/// `agents.repos` entries, but the `pub` worktree functions take `repo: &str`
/// directly and are reachable from tests and future callers that never went
/// through that load. Since `Path::join` treats `/` and `..` as real path
/// components, an unvalidated `repo` would place `worktree_dir` outside
/// `base_dir` — and `worktree_dir` is what [`remove_worktree`]'s
/// `remove_dir_all` fallback destroys and what [`create_worktree`] writes
/// pointer files into. Re-checking here costs nothing and closes that gap at
/// the point of use.
///
/// Validation is the containment guarantee: a name restricted to
/// `[A-Za-z0-9._-]` (and never `.`/`..`) is always a single path component, so
/// both joins are direct children of `base_dir`. That is checked structurally
/// rather than via `canonicalize`, which would fail on the not-yet-created
/// worktree directory.
///
/// # Errors
///
/// Returns [`AgentError::InvalidRepo`](super::context::AgentError::InvalidRepo)
/// when `repo` is not a safe single path component.
fn worktree_paths(
    base_dir: &Path,
    repo: &str,
    suffix: &str,
) -> Result<(PathBuf, PathBuf), Box<dyn std::error::Error>> {
    validate_repo_name(repo)?;
    Ok((base_dir.join(repo), base_dir.join(format!("{repo}-{suffix}"))))
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
/// 4. Rewrite `<worktree>/.git` → `gitdir: <git_dir>/worktrees/<name>`.
/// 5. Rewrite `<git_dir>/worktrees/<name>/gitdir` →
///    `<base_dir>/<repo>-<suffix>/.git` (the container-internal path).
///
/// Steps 4–5 are the critical rewriting: without them, git inside the container
/// follows host-absolute paths that don't exist. `<name>` is read back from the
/// `.git` pointer git just wrote (see [`resolve_admin_dir_name`]) rather than
/// assumed to be `<repo>-<suffix>`.
///
/// # Errors
///
/// Propagates git failures (branch/worktree creation), an invalid `repo` name,
/// or I/O errors writing the pointer files.
pub fn create_worktree(
    git: &dyn GitRunner,
    base_dir: &Path,
    repo: &str,
    suffix: &str,
    out: &mut dyn Write,
) -> CmdResult {
    let (main_repo, worktree_dir) = worktree_paths(base_dir, repo, suffix)?;

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

    // The name git actually chose for this worktree's admin dir — read back from
    // the pointer git just wrote, not assumed to be `<repo>-<suffix>` (#706).
    let fallback_name = format!("{repo}-{suffix}");
    let worktree_name = resolve_admin_dir_name(&worktree_dir, &fallback_name);

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

/// Reads back the admin-directory name git chose for a freshly-added worktree,
/// falling back to `fallback` when it can't be determined.
///
/// `git worktree add` normally names the admin dir after the worktree's leaf
/// directory — `<repo>-<suffix>` here — but when that name collides with an
/// existing admin dir git disambiguates by appending `-1`, `-2`, … Assuming the
/// constructed name would then rewrite the *wrong* (or a nonexistent) back-link,
/// silently producing a worktree whose `.git` pointer and back-link disagree
/// (#706). Git records the truth in the worktree's own `.git` pointer file
/// (`gitdir: <git_dir>/worktrees/<name>`), so read the final path component from
/// there.
///
/// Falls back to `fallback` — restoring the previous behavior — when the pointer
/// is unreadable, isn't a `gitdir:` line, or yields a component that fails
/// [`validate_repo_name`]'s allow-list. All are non-fatal: a missing pointer
/// means the mocked/odd case the old code already handled, and the caller's
/// subsequent writes create what's needed.
///
/// The name is validated even though git itself just wrote it, because it is
/// joined into `<git_dir>/worktrees/<name>/gitdir` and *overwritten*. Reusing
/// the same allow-list as `repo` keeps a corrupted — or, in the narrow window
/// between the `worktree add` and this read, raced — pointer file from steering
/// that write somewhere unexpected. The name git legitimately chooses
/// (`<repo>-<suffix>`, optionally `-N`) always satisfies the allow-list when
/// `repo` does, so this rejects nothing real.
fn resolve_admin_dir_name(worktree_dir: &Path, fallback: &str) -> String {
    let Ok(data) = std::fs::read_to_string(worktree_dir.join(".git")) else {
        return fallback.to_string();
    };
    let Some(gitdir) = data.trim().strip_prefix("gitdir:") else {
        return fallback.to_string();
    };
    gitdir
        .trim()
        .rsplit(['/', '\\'])
        .next()
        .filter(|name| validate_repo_name(name).is_ok())
        .map_or_else(|| fallback.to_string(), ToString::to_string)
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
/// Returns an error if `repo` is not a safe name, if the worktree is dirty and
/// `force` is false, or if the manual fallback cleanup itself fails.
pub fn remove_worktree(
    git: &dyn GitRunner,
    base_dir: &Path,
    repo: &str,
    suffix: &str,
    force: bool,
    out: &mut dyn Write,
) -> CmdResult {
    let (main_repo, worktree_dir) = worktree_paths(base_dir, repo, suffix)?;
    if !worktree_dir.exists() {
        writeln!(out, "  worktree {} does not exist", worktree_dir.display())?;
        return Ok(());
    }

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

/// One row of `worktree list`: an existing on-disk worktree and its git state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeStatus {
    /// Agent suffix, e.g. `agent01`.
    pub suffix: String,
    /// Repo the worktree belongs to.
    pub repo: String,
    /// Worktree directory, `<base_dir>/<repo>-<suffix>`.
    pub path: PathBuf,
    /// Current branch (`rev-parse --abbrev-ref HEAD`), or `unknown` on git error.
    pub branch: String,
    /// Whether `git status --porcelain` reports uncommitted work.
    pub dirty: bool,
}

/// Scans `<base_dir>/<repo>-agentNN` for `n in 1..=max_agents` across all
/// `repos`, returning the git status of every worktree that exists on disk.
///
/// This is the read-only sibling of [`detect_worktree_mounts`] — same scan, but
/// it reports branch + clean/dirty per worktree rather than compose mounts. Pure
/// over a `&dyn GitRunner` and does no rendering, so it is directly unit-testable
/// and the caller owns presentation.
///
/// A worktree whose branch can't be read (`rev-parse` fails) is still listed with
/// `branch == "unknown"` rather than dropped, so a broken worktree stays visible
/// — mirroring [`worktree_is_dirty`]'s conservative handling of git failures.
#[must_use]
pub fn collect_worktree_status(
    git: &dyn GitRunner,
    base_dir: &Path,
    repos: &[String],
    max_agents: u32,
) -> Vec<WorktreeStatus> {
    let mut rows = Vec::new();
    for n in 1..=max_agents {
        let suffix = agent_suffix(n);
        for repo in repos {
            let dir = base_dir.join(format!("{repo}-{suffix}"));
            if !dir.is_dir() {
                continue;
            }
            let dir_str = dir.display().to_string();
            let branch = git
                .run(&["-C", &dir_str, "rev-parse", "--abbrev-ref", "HEAD"])
                .map_or_else(|_| "unknown".to_string(), |s| s.trim().to_string());
            let dirty = worktree_is_dirty(git, &dir_str);
            rows.push(WorktreeStatus {
                suffix: suffix.clone(),
                repo: repo.clone(),
                path: dir,
                branch,
                dirty,
            });
        }
    }
    rows
}

/// Renders `worktree list` rows to `out`, one greppable line per worktree.
///
/// Prints a friendly `No worktrees found.` when there are none, so the command
/// never produces silent empty output.
fn render_worktree_list(rows: &[WorktreeStatus], out: &mut dyn Write) -> CmdResult {
    if rows.is_empty() {
        writeln!(out, "No worktrees found.")?;
        return Ok(());
    }
    for r in rows {
        let state = if r.dirty { "dirty" } else { "clean" };
        writeln!(out, "{}  {}  {}  [{}]  {}", r.suffix, r.repo, r.path.display(), r.branch, state)?;
    }
    Ok(())
}

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
/// [`remove_worktree`]'s gate), since rebasing over uncommitted work aborts
/// messily. `dry_run` prints the command it would run without touching the branch.
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
fn sync_all_repos(
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

/// Creates every configured repo's worktree for one agent, then re-renders the
/// compose mounts from a fresh on-disk scan.
///
/// # Errors
///
/// Propagates the first repo's creation failure, or a compose render/write
/// failure. Unlike [`sync_all_repos`], a failure here aborts the remaining
/// repos: creation failures are genuine errors (bad git state, I/O), not the
/// expected-and-recoverable conflict outcome that motivated #712's accumulation.
fn create_all_repos(
    git: &dyn GitRunner,
    ctx: &AgentContext,
    suffix: &str,
    force: bool,
    out: &mut dyn Write,
) -> CmdResult {
    for repo in &ctx.repos {
        create_worktree(git, &ctx.base_dir, repo, suffix, out)?;
    }
    rerender_compose_mounts(ctx, force, out)
}

/// Removes every configured repo's worktree for one agent, then re-renders the
/// compose mounts from a fresh on-disk scan.
///
/// # Errors
///
/// Propagates the first repo's removal failure (including the dirty-worktree
/// refusal), or a compose render/write failure.
fn remove_all_repos(
    git: &dyn GitRunner,
    ctx: &AgentContext,
    suffix: &str,
    force: bool,
    out: &mut dyn Write,
) -> CmdResult {
    for repo in &ctx.repos {
        remove_worktree(git, &ctx.base_dir, repo, suffix, force, out)?;
    }
    rerender_compose_mounts(ctx, force, out)
}

/// Re-scans the worktree directories and rewrites the compose mount list so it
/// reflects what is actually on disk after a create/remove.
///
/// # Errors
///
/// Propagates render, drift-classification, or write failures from
/// [`update_compose_worktree_mounts`].
fn rerender_compose_mounts(ctx: &AgentContext, force: bool, out: &mut dyn Write) -> CmdResult {
    let mounts = detect_worktree_mounts(&ctx.base_dir, &ctx.repos, ctx.max_agents);
    update_compose_worktree_mounts(&ctx.cfg, mounts, force)?;
    writeln!(out, "Updated {COMPOSE_FILE} worktree mounts")?;
    Ok(())
}

/// Dispatches a `worktree` subcommand: loads the shared agent context and acts
/// on agent N's worktree(s) across all configured repos.
///
/// `create`/`remove` mutate worktrees and then re-render the compose mounts;
/// `list` and `sync` are read-only w.r.t. compose (`list` takes no agent number
/// at all).
///
/// Every variant is handled in **one** exhaustive `match`, each arm delegating
/// to a named helper (#713). The previous three-match shape — one exhaustive
/// match plus two `_ => unreachable!()` re-matches — meant a newly-added
/// `WorktreeCommands` variant accidentally folded into a shared arm would
/// compile and then panic at runtime. With a single match the compiler flags the
/// missing arm instead.
///
/// # Errors
///
/// Returns an error if `.igor.yml` is missing/invalid, a repo name is unsafe,
/// the agent number is out of range, or a git/I/O/render step fails.
pub fn run(command: &WorktreeCommands) -> CmdResult {
    let ctx = AgentContext::load(Path::new(CONFIG_PATH))?;
    let git = ProcessGitRunner;
    let mut out = std::io::stdout();

    match command {
        WorktreeCommands::List => {
            let rows = collect_worktree_status(&git, &ctx.base_dir, &ctx.repos, ctx.max_agents);
            render_worktree_list(&rows, &mut out)
        }
        WorktreeCommands::Sync { n, onto, dry_run } => {
            let num = validate_agent_num(n, ctx.max_agents)?;
            let suffix = agent_suffix(num);
            writeln!(out, "Syncing worktrees for agent {num} ...")?;
            sync_all_repos(&git, &ctx, &suffix, onto.as_deref(), *dry_run, &mut out)
        }
        WorktreeCommands::Create { n, force } => {
            let num = validate_agent_num(n, ctx.max_agents)?;
            let suffix = agent_suffix(num);
            writeln!(out, "Creating worktrees for agent {num} ...")?;
            create_all_repos(&git, &ctx, &suffix, *force, &mut out)
        }
        WorktreeCommands::Remove { n, force } => {
            let num = validate_agent_num(n, ctx.max_agents)?;
            let suffix = agent_suffix(num);
            writeln!(out, "Removing worktrees for agent {num} ...")?;
            remove_all_repos(&git, &ctx, &suffix, *force, &mut out)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    // Only the test doubles construct `GitError` directly; production code in
    // this module surfaces it through `GitRunner::run`'s return type.
    use crate::agent::git::GitError;

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

    /// [`GitRunner`] double that fails one git subcommand for one repo only —
    /// when the argv contains both `subcommand` and `failing_dir` — succeeding
    /// everywhere else, and recording every call.
    ///
    /// [`MockGit`] keys its canned results on the git *subcommand*, not the
    /// `-C <dir>` argument, so it cannot express "fail repo A's rebase but not
    /// repo B's" — exactly the shape the multi-repo tests need to distinguish
    /// sync's attempt-all walk (#712) from create/remove's abort-on-first.
    struct FailGitIn {
        subcommand: String,
        failing_dir: String,
        calls: RefCell<Vec<String>>,
    }

    impl FailGitIn {
        fn new(subcommand: &str, failing_dir: &str) -> Self {
            Self {
                subcommand: subcommand.to_string(),
                failing_dir: failing_dir.to_string(),
                calls: RefCell::new(Vec::new()),
            }
        }
    }

    impl GitRunner for FailGitIn {
        fn run(&self, args: &[&str]) -> Result<String, GitError> {
            let joined = args.join(" ");
            self.calls.borrow_mut().push(joined.clone());
            if joined.contains(&self.subcommand) && joined.contains(&self.failing_dir) {
                return Err(GitError::NonZero { args: joined, output: "boom".into() });
            }
            // `sync` resolves a base branch before rebasing; keep it off detached HEAD.
            if joined.contains("rev-parse") {
                return Ok("main".into());
            }
            Ok(String::new())
        }
    }

    /// [`GitRunner`] double whose `worktree add` materializes the worktree
    /// directory and writes `gitdir: <gitdir>` into its `.git` pointer, the way
    /// real git does. Needed because `create_worktree` short-circuits on a
    /// pre-existing directory, so the dir must appear *during* the call.
    struct AddWritesPointer {
        worktree_dir: PathBuf,
        gitdir: String,
    }

    impl GitRunner for AddWritesPointer {
        fn run(&self, args: &[&str]) -> Result<String, GitError> {
            if args.contains(&"add") {
                std::fs::create_dir_all(&self.worktree_dir).map_err(GitError::Spawn)?;
                std::fs::write(
                    self.worktree_dir.join(".git"),
                    format!("gitdir: {}\n", self.gitdir),
                )
                .map_err(GitError::Spawn)?;
            }
            Ok(String::new())
        }
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

    #[test]
    fn collect_worktree_status_reports_branch_and_dirty() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Ok("agent01"));
        git.on("status --porcelain", Ok(" M src/lib.rs"));

        let rows = collect_worktree_status(&git, base, &["myapp".to_string()], 5);
        assert_eq!(rows.len(), 1);
        let r = &rows[0];
        assert_eq!(r.suffix, "agent01");
        assert_eq!(r.repo, "myapp");
        assert_eq!(r.path, base.join("myapp-agent01"));
        assert_eq!(r.branch, "agent01");
        assert!(r.dirty, "non-empty porcelain output should mark the worktree dirty");
    }

    #[test]
    fn collect_worktree_status_empty_when_no_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        let git = MockGit::new();
        let rows = collect_worktree_status(&git, tmp.path(), &["myapp".to_string()], 5);
        assert!(rows.is_empty());
    }

    #[test]
    fn collect_worktree_status_branch_unknown_on_git_error() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("myapp-agent01")).unwrap();

        let git = MockGit::new();
        git.on("rev-parse --abbrev-ref", Err(()));

        let rows = collect_worktree_status(&git, base, &["myapp".to_string()], 5);
        assert_eq!(rows.len(), 1, "a worktree with an unreadable branch must still be listed");
        assert_eq!(rows[0].branch, "unknown");
    }

    #[test]
    fn collect_worktree_status_skips_non_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // A file (not a dir) with a matching name must be ignored.
        std::fs::write(base.join("myapp-agent01"), "not a dir").unwrap();

        let git = MockGit::new();
        let rows = collect_worktree_status(&git, base, &["myapp".to_string()], 5);
        assert!(rows.is_empty());
    }

    #[test]
    fn render_worktree_list_empty_message() {
        let mut out = Vec::new();
        render_worktree_list(&[], &mut out).unwrap();
        assert!(String::from_utf8(out).unwrap().contains("No worktrees found."));
    }

    #[test]
    fn render_worktree_list_marks_dirty_and_clean() {
        let rows = vec![
            WorktreeStatus {
                suffix: "agent01".into(),
                repo: "myapp".into(),
                path: PathBuf::from("/w/myapp-agent01"),
                branch: "agent01".into(),
                dirty: true,
            },
            WorktreeStatus {
                suffix: "agent02".into(),
                repo: "myapp".into(),
                path: PathBuf::from("/w/myapp-agent02"),
                branch: "agent02".into(),
                dirty: false,
            },
        ];
        let mut out = Vec::new();
        render_worktree_list(&rows, &mut out).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("[agent01]"), "branch should be shown in brackets");
        assert!(text.contains("dirty"));
        assert!(text.contains("clean"));
    }

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

    /// Builds an [`AgentContext`] over `repos` rooted at `base_dir`, for the
    /// `sync_all_repos` tests (which need a context, not just a base dir).
    fn ctx_with_repos(base_dir: &Path, repos: &[&str]) -> AgentContext {
        use containers_common::config::{AgentConfig, ProjectConfig};

        let mut ctx = AgentContext::from_config(IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig { name: "myapp".into(), ..ProjectConfig::default() },
            agents: AgentConfig {
                repos: repos.iter().map(ToString::to_string).collect(),
                ..AgentConfig::default()
            },
            ..IgorConfig::default()
        });
        ctx.base_dir = base_dir.to_path_buf();
        ctx
    }

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
        let calls = git.calls.borrow();
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

    // --- #706: admin-dir name is read back from git, not assumed ---

    #[test]
    fn resolve_admin_dir_name_reads_git_pointer() {
        let tmp = tempfile::tempdir().unwrap();
        let wt = tmp.path().join("myrepo-agent01");
        std::fs::create_dir_all(&wt).unwrap();
        // Git disambiguated the admin dir with a `-1` suffix on collision.
        std::fs::write(wt.join(".git"), "gitdir: /host/repo/.git/worktrees/myrepo-agent01-1\n")
            .unwrap();

        assert_eq!(resolve_admin_dir_name(&wt, "myrepo-agent01"), "myrepo-agent01-1");
    }

    #[test]
    fn resolve_admin_dir_name_falls_back_when_pointer_missing_or_odd() {
        let tmp = tempfile::tempdir().unwrap();
        let wt = tmp.path().join("myrepo-agent01");
        std::fs::create_dir_all(&wt).unwrap();

        // No `.git` pointer at all.
        assert_eq!(resolve_admin_dir_name(&wt, "fallback"), "fallback");

        // Present but not a `gitdir:` line.
        std::fs::write(wt.join(".git"), "ref: refs/heads/main\n").unwrap();
        assert_eq!(resolve_admin_dir_name(&wt, "fallback"), "fallback");

        // `gitdir:` with a trailing separator — the last component is empty.
        std::fs::write(wt.join(".git"), "gitdir: /host/repo/.git/worktrees/\n").unwrap();
        assert_eq!(resolve_admin_dir_name(&wt, "fallback"), "fallback");

        // A component that fails the repo-name allow-list (here a NUL) must not
        // be trusted into the `<git_dir>/worktrees/<name>/gitdir` write path.
        std::fs::write(wt.join(".git"), "gitdir: /host/repo/.git/worktrees/we\0ird\n").unwrap();
        assert_eq!(resolve_admin_dir_name(&wt, "fallback"), "fallback");
    }

    #[test]
    fn remove_all_repos_aborts_on_first_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // Both worktrees exist; the first is dirty, so remove refuses without
        // --force. That refusal must stop the walk before beta is touched —
        // the deliberate contrast with sync's accumulate-all behavior.
        std::fs::create_dir_all(base.join("alpha-agent01")).unwrap();
        std::fs::create_dir_all(base.join("beta-agent01")).unwrap();

        let git = MockGit::new();
        git.on("status --porcelain", Ok(" M file.rs"));
        let ctx = ctx_with_repos(base, &["alpha", "beta"]);

        let mut out = Vec::new();
        let err = remove_all_repos(&git, &ctx, "agent01", false, &mut out).unwrap_err();

        assert!(err.to_string().contains("uncommitted changes"), "got: {err}");
        assert!(base.join("beta-agent01").exists(), "beta must be untouched after alpha aborted");
        assert!(!git.has_call("worktree remove"), "no removal should have been attempted");
        assert!(
            !String::from_utf8(out).unwrap().contains("Updated"),
            "compose must not be re-rendered when the walk aborted",
        );
    }

    #[test]
    fn create_all_repos_aborts_on_first_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        std::fs::create_dir_all(base.join("alpha/.git")).unwrap();
        std::fs::create_dir_all(base.join("beta/.git")).unwrap();

        // `worktree add` fails for the first repo, keyed on the `-C <dir>` arg.
        let git = FailGitIn::new("worktree add", "alpha");
        let ctx = ctx_with_repos(base, &["alpha", "beta"]);

        let mut out = Vec::new();
        let err = create_all_repos(&git, &ctx, "agent01", false, &mut out).unwrap_err();

        assert!(err.to_string().contains("boom"), "got: {err}");
        let calls = git.calls.borrow();
        assert!(
            !calls.iter().any(|c| c.contains("worktree add") && c.contains("beta")),
            "beta must not be created after alpha failed: {calls:?}",
        );
    }

    #[test]
    fn create_worktree_uses_git_chosen_admin_dir_name() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let git_dir = base.join("myrepo").join(".git");
        std::fs::create_dir_all(&git_dir).unwrap();

        // `worktree add` must materialize the worktree *during* the call — the
        // dir cannot pre-exist or `create_worktree`'s already-exists guard would
        // short-circuit. The double writes the `.git` pointer real git writes,
        // naming a *disambiguated* admin dir (`-1`) — the collision case #706 is
        // about — with a host-absolute path create_worktree must rewrite.
        let worktree_dir = base.join("myrepo-agent01");
        let git = AddWritesPointer {
            worktree_dir: worktree_dir.clone(),
            gitdir: "/host/somewhere/.git/worktrees/myrepo-agent01-1".into(),
        };

        let mut out = Vec::new();
        create_worktree(&git, base, "myrepo", "agent01", &mut out).unwrap();

        // Both pointers must agree on the *disambiguated* name.
        let git_content = std::fs::read_to_string(worktree_dir.join(".git")).unwrap();
        assert_eq!(
            git_content,
            format!("gitdir: {}/worktrees/myrepo-agent01-1\n", git_dir.display()),
        );
        let link = git_dir.join("worktrees/myrepo-agent01-1/gitdir");
        assert_eq!(
            std::fs::read_to_string(link).unwrap(),
            format!("{}/.git\n", worktree_dir.display()),
        );
        assert!(
            !git_dir.join("worktrees/myrepo-agent01/gitdir").exists(),
            "must not write the assumed (colliding) admin-dir name",
        );
    }

    // --- #705: repo names are rejected before they reach a path ---

    #[test]
    fn worktree_ops_reject_traversal_repo_names() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        // A directory the traversal would target if the guard were missing.
        let victim = tmp.path().join("victim");
        std::fs::create_dir_all(&victim).unwrap();

        let git = MockGit::new();
        for bad in ["../victim", "..", "a/b", "a\\b", ".", ""] {
            let mut out = Vec::new();
            let err = remove_worktree(&git, base, bad, "agent01", true, &mut out).unwrap_err();
            assert!(err.to_string().contains("invalid repo name"), "{bad:?}: {err}");

            let mut out = Vec::new();
            let err = create_worktree(&git, base, bad, "agent01", &mut out).unwrap_err();
            assert!(err.to_string().contains("invalid repo name"), "{bad:?}: {err}");

            let mut out = Vec::new();
            let err =
                sync_worktree(&git, base, bad, "agent01", "main", false, &mut out).unwrap_err();
            assert!(err.to_string().contains("invalid repo name"), "{bad:?}: {err}");
        }

        assert!(victim.exists(), "a rejected repo name must not reach any destructive operation");
        assert!(!git.has_call("worktree"), "a rejected repo name must not shell out to git");
    }

    #[test]
    fn worktree_paths_accepts_ordinary_repo_names() {
        let base = Path::new("/workspace");
        let (main, wt) = worktree_paths(base, "my-repo_v2.0", "agent01").unwrap();
        assert_eq!(main, base.join("my-repo_v2.0"));
        assert_eq!(wt, base.join("my-repo_v2.0-agent01"));
    }
}
