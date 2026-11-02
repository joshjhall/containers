#!/usr/bin/env bash
# Create commits through the GitHub API so GitHub signs them (#1573).
#
# A commit made with local `git commit` + `git push` by a bot token is
# unsigned, and a branch ruleset with `required_signatures` refuses to merge
# it. The GraphQL `createCommitOnBranch` mutation commits server-side, and
# GitHub signs the result (`verification.verified == true`) for any token.
#
# Shared by bin/ingest-evidence-batch.sh (containers-db evidence PRs) and
# .github/workflows/auto-patch.yml (patch branch + compatibility-matrix PR).
#
# The flow: stage the local working tree, create the remote branch at the
# local HEAD (which must already exist on the remote), then send the staged
# change set as one commit on that branch. Nothing is pushed with git.
#
# Limitation: createCommitOnBranch cannot set file modes. A NEW file is
# always committed 100644, so a new executable or symlink is refused before
# anything is sent; after the commit the remote tree's modes are checked
# against the local index and a mismatch is an error.
#
# Requires gh (authenticated via GH_TOKEN/GITHUB_TOKEN), git, jq, base64.
# Per CLAUDE.md, bare external commands use `command` to bypass aliases.

# gh_api_retry <cmd...> — run <cmd> up to 3 times with doubling backoff
# starting at GH_API_RETRY_DELAY seconds (default 2; tests set 0).
gh_api_retry() {
    local i=1 delay="${GH_API_RETRY_DELAY:-2}"
    while [ "$i" -le 3 ]; do
        "$@" && return 0
        if [ "$i" -lt 3 ]; then
            command echo "Retry $i/3: $1 $2" >&2
            command sleep "$delay"
            delay=$((delay * 2))
        fi
        i=$((i + 1))
    done
    return 1
}

# gh_api_ensure_branch <owner/repo> <branch> <sha>
#
# Points refs/heads/<branch> at <sha>: creates it, or force-moves an existing
# one (a re-run with the same name starts clean, as the old force push did).
gh_api_ensure_branch() {
    local repo="$1" branch="$2" sha="$3"
    if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
        gh_api_retry gh api -X PATCH "repos/$repo/git/refs/heads/$branch" \
            -f "sha=$sha" -F force=true >/dev/null
    else
        gh_api_retry gh api -X POST "repos/$repo/git/refs" \
            -f "ref=refs/heads/$branch" -f "sha=$sha" >/dev/null
    fi
}

# gh_api_publish_branch <owner/repo> <branch> <dir> <message-file> [pathspec...]
#
# Like gh_api_ensure_branch + gh_api_commit_worktree, but <branch> is created
# only once, directly at the finished signed commit: the commit is built on a
# staging ref "<branch-prefix>-staging/<rest>" (e.g. auto-patch/x ->
# auto-patch-staging/x), the real ref is then created at it and the staging
# ref deleted. A workflow triggered by pushes to <branch> therefore runs once,
# on the real commit, instead of first on the bare base SHA. <branch> must
# not exist yet. Prints the commit oid.
gh_api_publish_branch() {
    local repo="$1" branch="$2" dir="$3" msg_file="$4" staging oid
    shift 4
    case "$branch" in
        */*) staging="${branch%%/*}-staging/${branch#*/}" ;;
        *) staging="$branch-staging" ;;
    esac
    gh_api_ensure_branch "$repo" "$staging" "$(git -C "$dir" rev-parse HEAD)" || return 1
    oid="$(gh_api_commit_worktree "$repo" "$staging" "$dir" "$msg_file" "$@")" || {
        gh api -X DELETE "repos/$repo/git/refs/heads/$staging" >/dev/null 2>&1 || true
        return 1
    }
    gh_api_retry gh api -X POST "repos/$repo/git/refs" \
        -f "ref=refs/heads/$branch" -f "sha=$oid" >/dev/null || return 1
    gh api -X DELETE "repos/$repo/git/refs/heads/$staging" >/dev/null 2>&1 ||
        command echo "::warning::could not delete staging branch $staging on $repo" >&2
    command echo "$oid"
}

# _gh_api_staged_raw <dir> <pathspec...> — `git diff --raw` of the index
# against HEAD, NUL-separated, renames split into delete + add.
_gh_api_staged_raw() {
    local dir="$1"
    shift
    git -C "$dir" diff --cached --raw -z --no-renames --no-abbrev HEAD -- "$@"
}

# gh_api_commit_worktree <owner/repo> <branch> <dir> <message-file> [pathspec...]
#
# Stages <pathspec> (default: everything) in the checkout <dir> and commits
# the staged change set onto <branch> through the API. The first line of
# <message-file> is the headline, the rest (leading blank lines trimmed) the
# body. <branch> must already point at <dir>'s HEAD (gh_api_ensure_branch);
# that HEAD is sent as expectedHeadOid, so a branch that moved is refused
# rather than overwritten.
#
# Prints the new commit oid on stdout. Warns (::warning::) when GitHub does
# not report the commit as verified. Returns 1 on any failure, including an
# empty change set or a mode the API cannot represent.
gh_api_commit_worktree() {
    local work rc=0
    work="$(command mktemp -d)" || return 1
    _gh_api_commit_worktree "$work" "$@" || rc=$?
    command rm -rf "$work"
    return "$rc"
}

_gh_api_commit_worktree() {
    local work="$1" repo="$2" branch="$3" dir="$4" msg_file="$5"
    shift 5
    [ $# -gt 0 ] || set -- .
    [ -f "$msg_file" ] || {
        command echo "gh_api_commit_worktree: no message file: $msg_file" >&2
        return 1
    }

    local base
    base="$(git -C "$dir" rev-parse HEAD)" || return 1
    git -C "$dir" add -A -- "$@" || return 1

    # Walk the raw diff: ":<old> <new> <oldsha> <newsha> <status>\0<path>\0".
    local meta path old_mode new_mode status n=0 bad=0
    : >"$work/add.jsonl"
    : >"$work/del.jsonl"
    : >"$work/modes.tsv"
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        meta="${meta#:}"
        old_mode="${meta%% *}"
        new_mode="${meta#* }"
        new_mode="${new_mode%% *}"
        status="${meta##* }"
        case "$status" in
            D)
                command jq -cn --arg p "$path" '{path: $p}' >>"$work/del.jsonl"
                ;;
            A | M | T)
                if [ "$status" = A ] && [ "$new_mode" != 100644 ]; then
                    command echo "gh_api_commit_worktree: $path is new with mode $new_mode; the API can only add 100644 files" >&2
                    bad=1
                    continue
                fi
                if [ "$status" != A ] && [ "$old_mode" != "$new_mode" ]; then
                    command echo "gh_api_commit_worktree: $path changes mode $old_mode -> $new_mode; the API cannot change modes" >&2
                    bad=1
                    continue
                fi
                command base64 <"$dir/$path" | command tr -d '\n' >"$work/blob"
                command jq -cn --arg p "$path" --rawfile c "$work/blob" \
                    '{path: $p, contents: $c}' >>"$work/add.jsonl"
                command printf '%s\t%s\n' "$path" "$new_mode" >>"$work/modes.tsv"
                ;;
            *)
                command echo "gh_api_commit_worktree: unsupported change '$status' for $path" >&2
                bad=1
                ;;
        esac
        n=$((n + 1))
    done < <(_gh_api_staged_raw "$dir" "$@")
    [ "$bad" -eq 0 ] || return 1
    if [ "$n" -eq 0 ]; then
        command echo "gh_api_commit_worktree: nothing staged to commit" >&2
        return 1
    fi

    local headline body
    headline="$(command sed -n '1p' "$msg_file")"
    body="$(command sed '1d' "$msg_file" | command sed '/./,$!d')"
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
    command jq -n \
        --arg repo "$repo" --arg branch "$branch" --arg base "$base" \
        --arg headline "$headline" --arg body "$body" \
        --slurpfile add "$work/add.jsonl" --slurpfile del "$work/del.jsonl" \
        '{query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }",
          variables: {input: {
            branch: {repositoryNameWithOwner: $repo, branchName: $branch},
            message: ({headline: $headline} + (if $body == "" then {} else {body: $body} end)),
            expectedHeadOid: $base,
            fileChanges: {additions: $add, deletions: $del}}}}' >"$work/payload.json" || return 1

    local resp oid
    resp="$(gh_api_retry gh api graphql --input "$work/payload.json")" || {
        command echo "gh_api_commit_worktree: createCommitOnBranch failed on $repo:$branch" >&2
        return 1
    }
    oid="$(command jq -r '.data.createCommitOnBranch.commit.oid // empty' <<<"$resp" 2>/dev/null || true)"
    if [ -z "$oid" ]; then
        command echo "gh_api_commit_worktree: no commit oid in response: $resp" >&2
        return 1
    fi

    _gh_api_check_modes "$repo" "$oid" "$work/modes.tsv" || return 1

    local verified
    verified="$(gh api "repos/$repo/commits/$oid" 2>/dev/null |
        command jq -r '.commit.verification.verified // false' 2>/dev/null || true)"
    if [ "$verified" != true ]; then
        command echo "::warning::commit $oid on $repo:$branch is not reported as verified (signed)" >&2
    fi
    command echo "$oid"
}

# _gh_api_check_modes <owner/repo> <oid> <modes.tsv> — every path in
# <modes.tsv> ("path\tmode") has that mode in <oid>'s tree.
_gh_api_check_modes() {
    local repo="$1" oid="$2" modes="$3" tree path want got bad=0
    [ -s "$modes" ] || return 0
    tree="$(gh api "repos/$repo/git/trees/$oid?recursive=1")" || {
        command echo "gh_api_commit_worktree: could not read the tree of $oid to check modes" >&2
        return 1
    }
    if [ "$(command jq -r '.truncated // false' <<<"$tree")" = true ]; then
        command echo "::warning::tree of $oid is truncated; file modes not verified" >&2
        return 0
    fi
    while IFS=$'\t' read -r path want; do
        got="$(command jq -r --arg p "$path" '.tree[] | select(.path == $p) | .mode' <<<"$tree")"
        if [ "$got" != "$want" ]; then
            command echo "gh_api_commit_worktree: $path committed as mode '${got:-missing}', expected $want" >&2
            bad=1
        fi
    done <"$modes"
    [ "$bad" -eq 0 ]
}
