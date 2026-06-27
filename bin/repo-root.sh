#!/usr/bin/env bash
# repo-root.sh — print the main checkout's root directory, bare-repo-safe.
#
# The worktree/golem `just` recipes need the repository root to locate
# `.worktrees/`. The obvious `git rev-parse --show-toplevel` ABORTS in a bare
# repository (the worktree-host layout):
#
#     fatal: this operation must be run in a work tree   (exit 128)
#
# A bare host is exactly where the golem flow runs, so the recipes broke there
# (issue #604). Resolve the root from the git COMMON dir instead, whose parent
# is the main checkout — the same cwd- and bare-independent trick
# `.claude/hooks/golem-notify.sh` already uses:
#
#   - From the bare root: common-dir is `<root>/.git` → parent is `<root>`.
#   - From inside a worktree: common-dir still points at the MAIN `<root>/.git`
#     (worktrees share it), so this returns the main root, not the worktree —
#     which is what the recipes want (they operate on `<root>/.worktrees/…`).
#   - From a normal (non-bare) checkout: identical result to `--show-toplevel`.
#
# Prints the absolute root on stdout and exits 0; prints nothing and exits 1
# when not inside a git repository at all.
set -euo pipefail

common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -z "$common_dir" ]; then
    echo "repo-root: not inside a git repository" >&2
    exit 1
fi

# `--path-format=absolute` guarantees an absolute path, but stay defensive in
# case a future git omits it for the common dir (older gits did for --git-dir).
case "$common_dir" in
    /*) ;;
    *) common_dir="$(pwd)/$common_dir" ;;
esac

/usr/bin/dirname "$common_dir"
