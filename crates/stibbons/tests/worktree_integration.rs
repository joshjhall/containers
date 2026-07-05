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

use std::path::Path;
use std::process::Command;

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
    git(&project, &["init", "-b", "main"]);
    std::fs::write(project.join("README.md"), "hi\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "-m", "init"]);

    // Minimal `.igor.yml` with working_dir set so base_dir == <base>.
    let cfg = format!(
        "schema_version: 1\n\
         containers_dir: containers\n\
         project:\n\
         \x20 name: myapp\n\
         \x20 working_dir: {}\n\
         features:\n\
         \x20 - python\n",
        project.display()
    );
    std::fs::write(project.join(".igor.yml"), cfg).unwrap();

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
