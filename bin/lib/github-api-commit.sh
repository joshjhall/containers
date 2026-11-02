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

# _gh_api_is_permanent <stderr-file> — true when the LAST non-empty line of a
# failed gh call's stderr is an error a retry cannot fix (#1583): an HTTP 4xx
# other than 408 (timeout), 409 (conflict, e.g. a racing ref update), 429 or
# a rate/abuse limit (a 403 secondary limit), or a GraphQL permission,
# validation or ruleset message. Only the last line counts:
# _gh_api_create_or_move logs an expected create 422 before a move that may
# have failed transiently. Anything unrecognised (no status, network error,
# 5xx) is transient.
_gh_api_is_permanent() {
    local line
    line="$(command sed '/^[[:space:]]*$/d' "$1" 2>/dev/null | command tail -n 1)"
    [ -n "$line" ] || return 1
    case "$line" in
        *[Rr]ate\ limit* | *[Aa]buse* | *"HTTP 408"* | *"HTTP 409"* | *"HTTP 429"*) return 1 ;;
        *"HTTP 4"[0-9][0-9]*) return 0 ;;
        *"Resource not accessible"* | *"Repository rule violations"* | \
            *"Could not resolve"* | *"No commits between"* | *"not permitted"*) return 0 ;;
    esac
    return 1
}

# gh_api_retry <cmd...> — run <cmd> up to 3 times with doubling backoff
# starting at GH_API_RETRY_DELAY seconds (default 2; tests set 0). stdout
# passes through; each attempt's stderr is captured, replayed to stderr
# indented (so a "::" line from GitHub is never read as a workflow command),
# and classified: a permanent error (_gh_api_is_permanent) fails at once instead
# of being retried.
gh_api_retry() {
    local i=1 delay="${GH_API_RETRY_DELAY:-2}" err rc=1
    err="$(command mktemp)" || return 1
    while [ "$i" -le 3 ]; do
        if "$@" 2>"$err"; then
            command sed 's/^/  /' "$err" >&2
            rc=0
            break
        fi
        command sed 's/^/  /' "$err" >&2
        if _gh_api_is_permanent "$err"; then
            command echo "gh_api_retry: permanent error from $1 $2, not retrying" >&2
            break
        fi
        if [ "$i" -lt 3 ]; then
            command echo "Retry $i/3: $1 $2" >&2
            command sleep "$delay"
            delay=$((delay * 2))
        fi
        i=$((i + 1))
    done
    command rm -f "$err"
    return "$rc"
}

# gh_api_create_pr <gh pr create args...> — `gh pr create` that tolerates a
# lost response (#1583): every attempt first looks for an open PR on the
# --head branch (in --repo, when given) and prints its URL instead of
# creating a second one; a failed create is looked up once more before it
# counts as a failure (GitHub answers "already exists" to a re-send).
gh_api_create_pr() {
    local repo="" head="" prev=""
    local a
    for a in "$@"; do
        case "$prev" in
            --repo | -R) repo="$a" ;;
            --head | -H) head="$a" ;;
        esac
        prev="$a"
    done
    [ -n "$head" ] || {
        command echo "gh_api_create_pr: --head is required" >&2
        return 1
    }
    gh_api_retry _gh_api_pr_create_or_find "$repo" "$head" "$@"
}

# _gh_api_find_pr <repo|""> <head> — print the URL of the open PR for <head>.
# `--head` matches the branch name only, so a fork PR on a same-named branch
# is skipped: only a same-repository PR is adopted (and later auto-merged).
_gh_api_find_pr() {
    local url
    url="$(gh pr list ${1:+--repo "$1"} --head "$2" --state open --json url,isCrossRepository \
        --jq '[.[] | select(.isCrossRepository | not)][0].url // empty' 2>/dev/null)" || return 1
    [ -n "$url" ] || return 1
    command echo "$url"
}

_gh_api_pr_create_or_find() {
    local repo="$1" head="$2" out rc=0
    shift 2
    _gh_api_find_pr "$repo" "$head" && return 0
    out="$(gh pr create "$@")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        command echo "$out"
        return 0
    fi
    if _gh_api_find_pr "$repo" "$head"; then
        command echo "gh_api_create_pr: create failed but a PR for $head is open; using it" >&2
        return 0
    fi
    return "$rc"
}

# gh_api_ensure_branch <owner/repo> <branch> <sha>
#
# Points refs/heads/<branch> at <sha>: creates it, or force-moves an existing
# one (a re-run with the same name starts clean, as the old force push did).
# The existence probe is only a hint for which call to try first: a probe that
# fails transiently reads as "absent", so each attempt falls back to the other
# call, and a 422 "already exists" on create still ends in a force-move.
gh_api_ensure_branch() {
    local repo="$1" branch="$2" sha="$3"
    if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
        gh_api_retry _gh_api_move_or_create "$repo" "$branch" "$sha"
    else
        gh_api_retry _gh_api_create_or_move "$repo" "$branch" "$sha"
    fi
}

_gh_api_create_ref() {
    gh api -X POST "repos/$1/git/refs" -f "ref=refs/heads/$2" -f "sha=$3" >/dev/null
}

_gh_api_move_ref() {
    gh api -X PATCH "repos/$1/git/refs/heads/$2" -f "sha=$3" -F force=true >/dev/null
}

_gh_api_create_or_move() { _gh_api_create_ref "$@" || _gh_api_move_ref "$@"; }
_gh_api_move_or_create() { _gh_api_move_ref "$@" || _gh_api_create_ref "$@"; }

# gh_api_publish_branch <owner/repo> <branch> <dir> <message-file> [pathspec...]
#
# Like gh_api_ensure_branch + gh_api_commit_worktree, but <branch> is pointed
# at the commit only once it is finished: the commit is built on a staging ref
# "<branch-prefix>-staging/<rest>" (e.g. auto-patch/x -> auto-patch-staging/x),
# then <branch> is created at it (or force-moved, so a re-run with the same
# name succeeds) and the staging ref is deleted. A workflow triggered by pushes
# to <branch> therefore runs once, on the real commit, instead of first on the
# bare base SHA. The staging ref is deleted on every path. Prints the oid.
gh_api_publish_branch() {
    local repo="$1" branch="$2" dir="$3" msg_file="$4" staging oid rc=0
    shift 4
    case "$branch" in
        */*) staging="${branch%%/*}-staging/${branch#*/}" ;;
        *) staging="$branch-staging" ;;
    esac
    if ! gh_api_ensure_branch "$repo" "$staging" "$(git -C "$dir" rev-parse HEAD)"; then
        # It may still exist (the call landed, its response was lost).
        rc=1
    elif ! oid="$(gh_api_commit_worktree "$repo" "$staging" "$dir" "$msg_file" "$@")"; then
        rc=1
    elif ! gh_api_ensure_branch "$repo" "$branch" "$oid"; then
        command echo "gh_api_publish_branch: could not point $branch at $oid on $repo" >&2
        rc=1
    fi
    gh api -X DELETE "repos/$repo/git/refs/heads/$staging" >/dev/null 2>&1 ||
        command echo "::warning::could not delete staging branch $staging on $repo" >&2
    [ "$rc" -eq 0 ] || return 1
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
                case "$new_mode" in
                    100644 | 100755) ;;
                    *)
                        # 120000 symlink, 160000 submodule: no file bytes to send.
                        command echo "gh_api_commit_worktree: $path has mode $new_mode; the API commits only regular files" >&2
                        bad=1
                        continue
                        ;;
                esac
                # Each stage checked on its own: a failed read must never turn
                # into an empty addition, which would truncate the file.
                if ! command base64 <"$dir/$path" >"$work/b64" ||
                    ! command tr -d '\n' <"$work/b64" >"$work/blob" ||
                    ! command jq -cn --arg p "$path" --rawfile c "$work/blob" \
                        '{path: $p, contents: $c}' >>"$work/add.jsonl"; then
                    command echo "gh_api_commit_worktree: could not encode $path" >&2
                    return 1
                fi
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

    local oid
    oid="$(_gh_api_create_commit "$repo" "$branch" "$base" "$work/payload.json")" || return 1

    _gh_api_check_modes "$repo" "$oid" "$work/modes.tsv" || return 1

    local verified
    verified="$(gh api "repos/$repo/commits/$oid" 2>/dev/null |
        command jq -r '.commit.verification.verified // false' 2>/dev/null || true)"
    if [ "$verified" != true ]; then
        command echo "::warning::commit $oid on $repo:$branch is not reported as verified (signed)" >&2
    fi
    command echo "$oid"
}

# _gh_api_create_commit <owner/repo> <branch> <base> <payload> — send the
# mutation, up to 3 attempts. Not a blind retry: a request can succeed on
# GitHub and still fail here (a lost response), and re-sending it would then
# fail on expectedHeadOid and hide the commit that landed. So after each
# failure the branch head is read back: moved to a commit whose parent is
# <base> and whose headline is ours means the earlier attempt landed (adopt
# it); still at <base> means nothing landed (retry); anything else is an
# error, never adopted. GitHub's error text (the `errors` body and gh's
# stderr) is logged on every failure, and a permission, validation or ruleset
# error stops the retries (#1583). Prints the oid.
_gh_api_create_commit() {
    local repo="$1" branch="$2" base="$3" payload="$4"
    local i=1 delay="${GH_API_RETRY_DELAY:-2}" resp oid head commit parent headline want
    local err errors rc permanent
    want="$(command jq -r '.variables.input.message.headline' "$payload")"
    err="${payload%/*}/graphql.err"
    while [ "$i" -le 3 ]; do
        rc=0
        # gh prints the response body on stdout even when it exits non-zero.
        resp="$(gh api graphql --input "$payload" 2>"$err")" || rc=$?
        if [ "$rc" -eq 0 ]; then
            oid="$(command jq -r '.data.createCommitOnBranch.commit.oid // empty' <<<"$resp" 2>/dev/null || true)"
            if [ -n "$oid" ]; then
                command echo "$oid"
                return 0
            fi
        fi
        errors="$(command jq -r '.errors[]? | "\(.type // "ERROR"): \(.message)"' <<<"$resp" 2>/dev/null || true)"
        command echo "gh_api_commit_worktree: createCommitOnBranch attempt $i failed (exit $rc):" \
            "${errors:-no errors in response}" >&2
        [ -s "$err" ] && command sed 's/^/  gh: /' "$err" >&2
        permanent=0
        if command grep -qE '^(FORBIDDEN|UNPROCESSABLE|NOT_FOUND|INSUFFICIENT_SCOPES):|Repository rule violations' <<<"$errors" ||
            _gh_api_is_permanent "$err"; then
            permanent=1
        fi
        head="$(gh api "repos/$repo/git/ref/heads/$branch" 2>/dev/null |
            command jq -r '.object.sha // empty' 2>/dev/null || true)"
        if [ -n "$head" ] && [ "$head" != "$base" ]; then
            commit="$(gh api "repos/$repo/git/commits/$head" 2>/dev/null || true)"
            parent="$(command jq -r '.parents[0].sha // empty' <<<"$commit" 2>/dev/null || true)"
            headline="$(command jq -r '.message // "" | split("\n")[0]' <<<"$commit" 2>/dev/null || true)"
            if [ "$parent" = "$base" ] && [ "$headline" = "$want" ]; then
                command echo "gh_api_commit_worktree: attempt $i failed but $head landed on $branch; using it" >&2
                command echo "$head"
                return 0
            fi
            command echo "gh_api_commit_worktree: $repo:$branch moved to $head, not our commit on $base" >&2
            return 1
        fi
        if [ "$permanent" -eq 1 ]; then
            command echo "gh_api_commit_worktree: permanent error on $repo:$branch, not retrying" >&2
            return 1
        fi
        if [ "$i" -lt 3 ]; then
            command echo "Retry $i/3: createCommitOnBranch on $repo:$branch" >&2
            command sleep "$delay"
            delay=$((delay * 2))
        fi
        i=$((i + 1))
    done
    command echo "gh_api_commit_worktree: createCommitOnBranch failed on $repo:$branch" >&2
    return 1
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
