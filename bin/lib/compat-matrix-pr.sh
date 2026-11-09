#!/usr/bin/env bash
# Land a compatibility-matrix update as an auto-merging PR (#1573, #1584).
#
# Used by the post-merge job of .github/workflows/auto-patch.yml. A direct push
# to main would be unsigned and bypass required checks, so the update is an
# API-created (GitHub-signed) commit on chore/compat-matrix-v<version>, opened
# (or reused) as a PR with auto-merge. The head ref does not start with
# auto-patch/, so its merge does not re-enter the auto-patch job.

_COMPAT_MATRIX_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/github-api-commit.sh
source "$_COMPAT_MATRIX_PR_DIR/github-api-commit.sh"

# compat_matrix_publish_pr <owner/repo> <version> <dir> <file>
#
# Commits <file> (a path inside the checkout <dir>) onto
# chore/compat-matrix-v<version> through the API, reuses the open PR for that
# branch or creates one, prints its URL, and enables auto-merge (squash +
# delete branch). Auto-merge can be refused right after PR creation, so it is
# tried 5 times, COMPAT_MATRIX_MERGE_DELAY seconds apart (default 10).
#
# Returns 1 when the commit or the PR fails. Auto-merge that never sticks is
# only a ::warning:: (return 0): the PR is open and correct, a human merges it.
compat_matrix_publish_pr() {
    local repo="$1" version="$2" dir="$3" file="$4"
    local branch="chore/compat-matrix-v$version" msg pr attempt rc=0
    msg="$(command mktemp)" || return 1
    command printf 'chore: update compatibility matrix for v%s\n\nPassing test results from the automated patch release.\n' \
        "$version" >"$msg"
    gh_api_publish_branch "$repo" "$branch" "$dir" "$msg" "$file" >/dev/null || rc=1
    command rm -f "$msg"
    if [ "$rc" -ne 0 ]; then
        command echo "compat_matrix_publish_pr: could not commit $file to $repo:$branch" >&2
        return 1
    fi

    # Reuses the open PR for the branch (a previous run, or a create whose
    # response was lost) instead of opening a second one.
    pr="$(gh_api_create_pr --repo "$repo" --base main --head "$branch" \
        --title "chore: update compatibility matrix for v$version" \
        --body "Passing test results from the automated patch release v$version. Auto-merges when checks pass.")" || {
        command echo "compat_matrix_publish_pr: could not open a PR for $branch on $repo" >&2
        return 1
    }
    command echo "$pr"

    for attempt in 1 2 3 4 5; do
        if gh pr merge "$pr" --repo "$repo" --auto --squash --delete-branch >&2; then
            command echo "Auto-merge enabled on attempt $attempt" >&2
            return 0
        fi
        [ "$attempt" -eq 5 ] || command sleep "${COMPAT_MATRIX_MERGE_DELAY:-10}"
    done
    command echo "::warning::could not enable auto-merge on $pr; merge it manually" >&2
    return 0
}
