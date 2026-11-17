//! End-to-end integration test for `stibbons worktree`, driving the real binary
//! against a real temporary git repository.
//!
//! Satisfies the issue #362 acceptance criterion: "create worktree, verify .git
//! pointer content, verify gitdir link content" — plus the compose re-render.
//!
//! The test is hermetic: it inits a throwaway repo in a tempdir, supplies git
//! identity via env, and clears `GIT_DIR`/`GIT_WORK_TREE` so the outer repo
//! (cargo runs tests from within one) cannot leak in — see the
//! `git-env-leak-breaks-worktree-tests` project memory.

mod common;

use std::fmt::Write as _;
use std::path::Path;
use std::process::{Command, Output};

use common::run_worktree;

/// Runs `git <args>` in `dir` with a fixed identity and a clean git env,
/// asserting success.
fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .current_dir(dir)
        .args(args)
        // Hermetic identity — no reliance on a global gitconfig.
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        // Prevent the enclosing repo's git env from leaking into the fixture.
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .expect("failed to spawn git");
    assert!(
        out.status.success(),
        "git {args:?} failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

/// `worktree create 1` rewrites the `.git` pointer and back-link to
/// container-internal paths and adds the compose mount; `remove 1` cleans up.
#[test]
fn worktree_create_rewrites_pointers_and_updates_compose() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    // The project repo lives at <base>/myapp so base_dir resolves to <base>.
    let project = base.join("myapp");
    std::fs::create_dir_all(&project).unwrap();

    // A real repo with one commit (so `git branch agent01` has a HEAD).
    init_repo(&project);
    // Minimal `.igor.yml` with working_dir set so base_dir == <base>.
    write_igor_yml(&project, &[], None);

    // Create the worktree for agent 1.
    let out = run_worktree(&project, &["create", "1"]);
    assert!(
        out.status.success(),
        "worktree create failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );

    let worktree_dir = base.join("myapp-agent01");
    assert!(worktree_dir.is_dir(), "worktree dir should exist");

    // The worktree's `.git` pointer targets the container-internal gitdir.
    // Build the expectation the same way `create_worktree` does — from the git
    // dir joined as a path component — so the separator matches on every OS
    // (`project.join(".git")` yields `\.git` on Windows, `/.git` elsewhere).
    let git_content = std::fs::read_to_string(worktree_dir.join(".git")).unwrap();
    let git_dir = project.join(".git");
    let expected_gitdir = format!("gitdir: {}/worktrees/myapp-agent01\n", git_dir.display());
    assert_eq!(git_content, expected_gitdir, "worktree .git pointer mismatch");

    // The main repo's back-link `gitdir` targets the container-internal worktree.
    let link = project.join(".git/worktrees/myapp-agent01/gitdir");
    let link_content = std::fs::read_to_string(&link).unwrap();
    assert_eq!(
        link_content,
        format!("{}/.git\n", worktree_dir.display()),
        "gitdir back-link mismatch",
    );

    // Compose gained the worktree mount.
    let compose =
        std::fs::read_to_string(project.join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(
        compose.contains("../myapp-agent01:/workspace/myapp-agent01"),
        "compose should contain the worktree mount, got:\n{compose}",
    );

    // Drift detection: a hand-edited compose is preserved (and the re-render
    // refused) unless --force is given — matching the add/remove/update contract.
    let compose_path = project.join(".devcontainer/docker-compose.yml");
    let edited = format!("{}\n# user edit\n", std::fs::read_to_string(&compose_path).unwrap());
    std::fs::write(&compose_path, &edited).unwrap();
    let out = run_worktree(&project, &["create", "2"]);
    assert!(!out.status.success(), "re-render should refuse to clobber a user-edited compose");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("local modifications"),
        "expected a drift error, got stderr: {}",
        String::from_utf8_lossy(&out.stderr),
    );
    assert_eq!(
        std::fs::read_to_string(&compose_path).unwrap(),
        edited,
        "user edit must be preserved when the re-render is refused",
    );
    // --force overrides the guard and re-renders.
    let out = run_worktree(&project, &["create", "2", "--force"]);
    assert!(
        out.status.success(),
        "forced create failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    // Clean up the extra agent2 worktree so the removal assertions below hold.
    let out = run_worktree(&project, &["remove", "2"]);
    assert!(out.status.success(), "cleanup remove of agent 2 failed");

    // Removal cleans up the worktree and drops the mount.
    let out = run_worktree(&project, &["remove", "1"]);
    assert!(
        out.status.success(),
        "worktree remove failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    assert!(!worktree_dir.exists(), "worktree dir should be removed");

    let compose =
        std::fs::read_to_string(project.join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(
        !compose.contains("../myapp-agent01:/workspace/myapp-agent01"),
        "compose should no longer contain the worktree mount, got:\n{compose}",
    );
}

/// `worktree list` reports an existing worktree's branch and clean status, and
/// `worktree sync --dry-run` prints the rebase it would run without touching the
/// branch; a real `sync` then rebases cleanly onto the (advanced) base branch.
#[test]
fn worktree_list_and_sync() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let project = base.join("myapp");
    std::fs::create_dir_all(&project).unwrap();

    // A real repo with one commit on `main`.
    init_repo(&project);
    write_igor_yml(&project, &[], None);

    // Create the worktree for agent 1 (branch agent01, checked out at HEAD).
    let out = run_worktree(&project, &["create", "1"]);
    assert!(out.status.success(), "create failed: {}", String::from_utf8_lossy(&out.stderr));

    // `list` shows the worktree, its branch, and a clean status.
    let out = run_worktree(&project, &["list"]);
    assert!(out.status.success(), "list failed: {}", String::from_utf8_lossy(&out.stderr));
    let listing = String::from_utf8_lossy(&out.stdout);
    assert!(listing.contains("agent01"), "list should name the agent, got:\n{listing}");
    assert!(listing.contains("myapp-agent01"), "list should show the path, got:\n{listing}");
    assert!(listing.contains("clean"), "a fresh worktree should be clean, got:\n{listing}");

    // Advance `main` so the agent01 branch is strictly behind it — a clean rebase.
    std::fs::write(project.join("CHANGELOG.md"), "v1\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "-m", "advance main"]);

    let worktree_dir = base.join("myapp-agent01");
    let tip_before = rev_parse_head(&worktree_dir);

    // `sync --dry-run` prints the rebase but does NOT run it.
    let out = run_worktree(&project, &["sync", "1", "--dry-run"]);
    assert!(
        out.status.success(),
        "sync --dry-run failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let dry = String::from_utf8_lossy(&out.stdout);
    assert!(dry.contains("[dry-run]"), "expected a dry-run marker, got:\n{dry}");
    assert!(
        dry.contains("rebase --end-of-options main"),
        "expected the target branch, got:\n{dry}"
    );
    assert_eq!(rev_parse_head(&worktree_dir), tip_before, "dry-run must not move the branch tip");

    // A real `sync` rebases agent01 onto main; the tip advances to main's commit.
    let out = run_worktree(&project, &["sync", "1"]);
    assert!(out.status.success(), "sync failed: {}", String::from_utf8_lossy(&out.stderr));
    let main_tip = rev_parse_head(&project);
    assert_eq!(
        rev_parse_head(&worktree_dir),
        main_tip,
        "after a fast-forward rebase, agent01 should sit on main's tip",
    );
}

/// `git -C <dir> rev-parse HEAD` with a clean git env, returning the trimmed SHA.
fn rev_parse_head(dir: &Path) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .args(["rev-parse", "HEAD"])
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .expect("failed to spawn git");
    assert!(out.status.success(), "rev-parse failed: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Inits a real repo at `dir` on `main` with one commit (`README.md` = `hi`).
fn init_repo(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-b", "main"]);
    std::fs::write(dir.join("README.md"), "hi\n").unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", "init"]);
}

/// Writes `file` = `content` in `dir` and commits it on the current branch.
fn commit_file(dir: &Path, file: &str, content: &str, msg: &str) {
    std::fs::write(dir.join(file), content).unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", msg]);
}

/// Writes a minimal `.igor.yml` for project `myapp` rooted at `project` (so
/// `base_dir` is its parent). A non-empty `repos` and/or a `max` add an
/// `agents:` block; with neither, the agent defaults apply (repos `[myapp]`,
/// max 5).
fn write_igor_yml(project: &Path, repos: &[&str], max: Option<u32>) {
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

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

/// Runs `worktree create <n>` in `project`, asserting success.
fn create_agent(project: &Path, n: &str) {
    let out = run_worktree(project, &["create", n]);
    assert!(
        out.status.success(),
        "create {n} failed\nstdout: {}\nstderr: {}",
        stdout(&out),
        stderr(&out)
    );
}

/// True when the worktree at `dir` is stopped mid-rebase: git's own
/// `rebase-merge` state dir (resolved per-worktree via `--git-path`) exists.
fn is_mid_rebase(dir: &Path) -> bool {
    let out = Command::new("git")
        .current_dir(dir)
        .args(["rev-parse", "--git-path", "rebase-merge"])
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .expect("failed to spawn git");
    assert!(out.status.success(), "rev-parse --git-path failed: {}", stderr(&out));
    let rel = String::from_utf8_lossy(&out.stdout).trim().to_string();
    // `--git-path` may answer relative to `dir`; `join` keeps an absolute one as-is.
    dir.join(rel).is_dir()
}

/// `sync` through the real binary refuses a dirty worktree: non-zero exit, the
/// refusal surfaced on stderr, a failed per-repo summary, and the branch tip and
/// the uncommitted file both left untouched.
#[test]
fn worktree_sync_refuses_dirty_worktree() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("myapp");
    init_repo(&project);
    write_igor_yml(&project, &[], None);
    create_agent(&project, "1");

    // Advance main so a (wrongly) permitted rebase would visibly move the tip.
    commit_file(&project, "CHANGELOG.md", "v1\n", "advance main");

    let worktree_dir = tmp.path().join("myapp-agent01");
    std::fs::write(worktree_dir.join("scratch.txt"), "wip\n").unwrap();
    let tip_before = rev_parse_head(&worktree_dir);

    let out = run_worktree(&project, &["list"]);
    assert!(out.status.success(), "list failed: {}", stderr(&out));
    // Match the agent01 row's trailing state column, not a bare substring that a
    // path or branch name could satisfy.
    let listing = stdout(&out);
    let row = listing
        .lines()
        .find(|l| l.contains(&worktree_dir.display().to_string()))
        .unwrap_or_else(|| panic!("list should show the worktree, got:\n{listing}"));
    assert!(row.ends_with("  dirty"), "the agent01 row should be dirty, got: {row:?}");

    let out = run_worktree(&project, &["sync", "1"]);
    assert!(!out.status.success(), "sync must fail on a dirty worktree:\n{}", stdout(&out));
    assert!(
        stderr(&out).contains("has uncommitted changes"),
        "expected the dirty refusal, got stderr: {}",
        stderr(&out)
    );
    assert!(
        stdout(&out).contains("Sync summary: 0 rebased, 0 skipped, 1 failed"),
        "expected a failed summary, got:\n{}",
        stdout(&out)
    );
    assert_eq!(rev_parse_head(&worktree_dir), tip_before, "a refused sync must not move the tip");
    assert!(!is_mid_rebase(&worktree_dir), "a refused sync must not start a rebase");
    assert_eq!(
        std::fs::read_to_string(worktree_dir.join("scratch.txt")).unwrap(),
        "wip\n",
        "uncommitted work must survive the refusal"
    );
}

/// A real rebase conflict (both branches edit the same line) exits non-zero and
/// leaves the worktree **mid-rebase** with conflict markers — sync deliberately
/// does not auto-abort, so the conflict stays visible for resolution.
#[test]
fn worktree_sync_conflict_leaves_worktree_mid_rebase() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("myapp");
    init_repo(&project);
    write_igor_yml(&project, &[], None);
    create_agent(&project, "1");

    let worktree_dir = tmp.path().join("myapp-agent01");
    commit_file(&worktree_dir, "README.md", "agent edit\n", "agent change");
    commit_file(&project, "README.md", "main edit\n", "main change");

    let out = run_worktree(&project, &["sync", "1"]);
    assert!(!out.status.success(), "a conflicting sync must fail:\n{}", stdout(&out));
    let err = stderr(&out);
    assert!(err.contains("sync failed for 1 repo(s): myapp:"), "got stderr: {err}");
    assert!(
        stdout(&out).contains("Sync summary: 0 rebased, 0 skipped, 1 failed"),
        "got:\n{}",
        stdout(&out)
    );
    assert!(is_mid_rebase(&worktree_dir), "the worktree must be left mid-rebase (no auto-abort)");
    let readme = std::fs::read_to_string(worktree_dir.join("README.md")).unwrap();
    assert!(readme.contains("<<<<<<<"), "expected conflict markers, got:\n{readme}");
}

/// With two configured repos, `list` shows both worktrees and `sync` attempts
/// every repo: the first (`myapp`) conflicts, yet the loop still rebases the
/// second (`lib`) and reports a mixed summary with a non-zero exit.
#[test]
fn worktree_list_and_sync_span_multiple_repos() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let project = base.join("myapp");
    let lib = base.join("lib");
    init_repo(&project);
    init_repo(&lib);
    write_igor_yml(&project, &["myapp", "lib"], None);
    create_agent(&project, "1");

    let app_wt = base.join("myapp-agent01");
    let lib_wt = base.join("lib-agent01");
    assert!(app_wt.is_dir() && lib_wt.is_dir(), "create must make a worktree per repo");

    let out = run_worktree(&project, &["list"]);
    assert!(out.status.success(), "list failed: {}", stderr(&out));
    let listing = stdout(&out);
    for wt in [&app_wt, &lib_wt] {
        assert!(
            listing.contains(&wt.display().to_string()),
            "list should show {}, got:\n{listing}",
            wt.display()
        );
    }
    assert!(listing.contains("  myapp  ") && listing.contains("  lib  "), "got:\n{listing}");

    // myapp (first in the loop) conflicts; lib advances cleanly.
    commit_file(&app_wt, "README.md", "agent edit\n", "agent change");
    commit_file(&project, "README.md", "main edit\n", "main change");
    commit_file(&lib, "CHANGELOG.md", "v1\n", "advance lib main");

    let out = run_worktree(&project, &["sync", "1"]);
    assert!(!out.status.success(), "one failed repo must fail the run:\n{}", stdout(&out));
    assert!(
        stdout(&out).contains("Sync summary: 1 rebased, 0 skipped, 1 failed"),
        "expected a mixed summary, got:\n{}",
        stdout(&out)
    );
    assert!(stderr(&out).contains("sync failed for 1 repo(s): myapp:"), "got: {}", stderr(&out));
    assert!(is_mid_rebase(&app_wt), "myapp's worktree should be left mid-rebase");
    assert_eq!(
        rev_parse_head(&lib_wt),
        rev_parse_head(&lib),
        "the loop must continue past myapp's conflict and rebase lib onto its main"
    );
}

/// Out-of-range and non-integer agent numbers are rejected by the real binary
/// before any sync work starts, and leave existing worktrees untouched.
#[test]
fn worktree_sync_rejects_invalid_agent_number() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("myapp");
    init_repo(&project);
    write_igor_yml(&project, &[], Some(2));
    create_agent(&project, "1");
    commit_file(&project, "CHANGELOG.md", "v1\n", "advance main");
    let worktree_dir = tmp.path().join("myapp-agent01");
    let tip_before = rev_parse_head(&worktree_dir);

    for (arg, want) in [
        ("0", "agent number must be between 1 and 2"),
        ("3", "agent number must be between 1 and 2"),
        ("abc", "invalid agent number \"abc\": must be an integer"),
    ] {
        let out = run_worktree(&project, &["sync", arg]);
        assert!(!out.status.success(), "sync {arg} must fail");
        assert!(
            stderr(&out).contains(want),
            "sync {arg}: expected {want:?}, got: {}",
            stderr(&out)
        );
        assert!(
            !stdout(&out).contains("Syncing worktrees"),
            "sync {arg} must be rejected before any work:\n{}",
            stdout(&out)
        );
    }
    assert_eq!(rev_parse_head(&worktree_dir), tip_before, "rejected syncs must not move the tip");
}

/// #1694: every stibbons spawn must strip the enclosing git env and carry a
/// fixed identity, so stibbons' own git children (`worktree add`, `rebase`)
/// can neither retarget the outer repo nor fail on a host with no gitconfig.
#[test]
fn stibbons_cmd_is_hermetic() {
    let dir = tempfile::tempdir().expect("tempdir");
    let cmd = common::stibbons_cmd("worktree", dir.path());
    let envs: std::collections::HashMap<_, _> = cmd
        .get_envs()
        .map(|(k, v)| {
            (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))
        })
        .collect();

    for removed in ["GIT_DIR", "GIT_WORK_TREE"] {
        assert_eq!(envs.get(removed), Some(&None), "{removed} must be explicitly removed");
    }
    for (key, want) in [
        ("GIT_AUTHOR_NAME", common::TEST_GIT_NAME),
        ("GIT_AUTHOR_EMAIL", common::TEST_GIT_EMAIL),
        ("GIT_COMMITTER_NAME", common::TEST_GIT_NAME),
        ("GIT_COMMITTER_EMAIL", common::TEST_GIT_EMAIL),
    ] {
        assert_eq!(envs.get(key), Some(&Some(want.to_owned())), "{key} must be pinned");
    }
}
