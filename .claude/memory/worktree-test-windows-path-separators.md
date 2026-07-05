---
name: worktree-test-windows-path-separators
description: "stibbons worktree .git-pointer test assertions must derive the git dir via PathBuf::join, not hardcode /.git, or Windows CI fails on separator"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a2fad23e-d747-4368-bb97-a6bc14e737f7
---

The stibbons `worktree.rs` `.git`/`gitdir` pointer-rewriting writes
`format!("gitdir: {}/worktrees/...", git_dir.display())` where `git_dir` comes
from `resolve_git_dir` = `repo.join(".git")` (a `PathBuf`). On Windows that
renders `...\myapp\.git` (backslash before `.git`), so the written pointer is
`...\myapp\.git/worktrees/...` — backslash from the join, forward-slash from the
format literal.

An integration-test assertion that hardcodes the expectation as
`format!("gitdir: {}/.git/worktrees/...", project.display())` inserts a
FORWARD-slash before `.git`, so it mismatches on Windows (`\.git` vs `/.git`)
and the `Rust Tests (stibbons) — windows-latest` CI leg fails — even though
Linux/macOS pass and the production code is self-consistent.

**Why:** `Rust Tests (stibbons)` runs `cargo test --workspace` on
ubuntu/macos/windows (ci.yml, `fail-fast: false`); Windows is a real
(non-continue-on-error) leg that must be green. It passes on `main` baseline, so
a new Windows-only failure is yours.

**How to apply:** In worktree-path assertions, build the expected string the
same way production does — join `.git` as a path component
(`let git_dir = project.join(".git"); format!("gitdir: {}/worktrees/...", git_dir.display())`)
— so the separator matches on every OS. The back-link assertion
`format!("{}/.git\n", worktree_dir.display())` already mirrors production's exact
format literal, so it's fine. Compose mounts (`../x:/workspace/x`) are hardcoded
`/` in both prod and test, also fine. Relates to [[git-env-leak-breaks-worktree-tests]]
(the other worktree-test gotcha: clear GIT_DIR/GIT_WORK_TREE). (#362/PR#704)
