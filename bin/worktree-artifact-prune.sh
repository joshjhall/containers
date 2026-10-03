#!/usr/bin/env bash
# worktree-artifact-prune.sh — offer to prune issue N's per-checkout build
# artifacts after its worktree is removed. Called by `just worktree-rm` (#1015).
#
# Per-checkout build artifacts (#1005) live at /cache/<kind>/<project>--issue-N,
# off the worktree, so removing the worktree orphans them. Offer to prune them:
# ask on a TTY, otherwise only print the command — never delete unprompted.
# Best-effort: every failure path exits 0 so it never fails the teardown. Only a
# malformed N exits 2 (a caller bug, not a teardown condition).
#
# Usage: worktree-artifact-prune.sh <N>
#
# WORKTREE_PRUNE_ARTIFACT_DIR_BIN overrides which artifact-dir is run (tests pin
# the in-repo copy). It is namespaced on purpose: a bare ARTIFACT_DIR is a common
# CI variable naming an artifacts *directory*, and picking that up would
# silently break this tail.

set -euo pipefail

_n="${1:-}"
[[ "$_n" =~ ^[0-9]+$ ]] || {
    command echo "worktree-artifact-prune: N must be an issue number, got '$_n'" >&2
    exit 2
}

_repo="$(cd "$(command dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_ad="${WORKTREE_PRUNE_ARTIFACT_DIR_BIN:-$(command -v artifact-dir || command echo "$_repo/lib/runtime/commands/artifact-dir")}"
# --project is the main checkout's name even when run from inside another
# worktree (and even if the project name itself contains "--").
_proj="$(bash "$_ad" --project 2>/dev/null)" || exit 0
_name="$_proj--issue-$_n"
_hits="$(bash "$_ad" prune "$_name" --dry-run 2>/dev/null | command grep '^would remove: ')" || exit 0
command echo "Build-artifact dirs left by issue-$_n:"
command echo "$_hits" | command sed 's/^would remove: /  /'
if [ -t 0 ] && [ -t 1 ]; then
    read -r -p "Remove them? [y/N] " _ans || _ans=""
    case "$_ans" in
        [yY]*) bash "$_ad" prune "$_name" || true ;;
        *) command echo "  kept — remove later with: artifact-dir prune $_name" ;;
    esac
else
    command echo "  remove with: artifact-dir prune $_name"
fi
