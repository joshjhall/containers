#!/usr/bin/env bash
# Published-evidence sources for a push-triggered evidence run (#1319, #1328).
#
# evidence_db_sources resolves the colon-separated EVIDENCE_TESTED_SOURCE the
# Generate step hands to evidence_matrix_all: containers-db main, plus the rows
# each still-open ingest PR adds over its merge-base.
#
# A previous run's ingest PR (evidence/batch/<run-id>) is often still awaiting
# auto-merge when the next push resolves its matrix, so its rows are not on
# main yet. Only the rows it ADDS over its merge-base count (evidence_pr_rows):
# its whole tools/ tree carries main's rows as of its branch point, so a pass
# row since removed on main would be re-asserted (#1327). evidence_open_prs
# keeps only same-repo PRs by the ingest identity under 24h old. The PRs are
# listed BEFORE main is fetched, so a PR that merges in between is on the main
# read rather than in neither. refs/pull/N/head survives a close, so each PR's
# state is re-read after its fetch and evidence_pr_skip decides whether it
# still counts. A close after that re-read still counts for this one run; that
# seconds-wide window is accepted.
#
# Every failure is fatal: an unreachable or untrusted source must fail the job,
# not yield a matrix that re-queues everything. Each network call (gh, git
# fetch) is retried with backoff first (_es_retry), so one transient error does
# not cost the whole push its evidence; a 401/403/404 is permanent and fails
# at once.
#
# Sourced by .github/workflows/evidence-run.yml and
# tests/unit/bin/lib/evidence-sources.sh. Requires gh, git, jq, tar.

# shellcheck source=bin/lib/evidence-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/evidence-matrix.sh"

# _es_retry <cmd...> — runs cmd up to EVIDENCE_RETRY_ATTEMPTS times (default
# 3), sleeping EVIDENCE_RETRY_DELAY seconds (default 2) between tries, doubled
# each time. Stdout is captured and printed only from the attempt that
# succeeds, so a listing cut off by a failed try is never parsed. A failure
# is permanent — a bad token or a missing ref or compare — and not retried
# when gh reports HTTP 401, 403 or 404 ("HTTP 404: ...") without naming a rate
# limit (GitHub answers its primary and secondary rate limits with a 403, and
# those clear on their own), or git reports a 401 or 404 ("returned error:
# 404"). git's 403 carries no response body, so a throttled fetch cannot be
# told from a refused one, and it is retried. Any other failure is retried.
# Returns the last attempt's exit code either way, so a permanent failure
# still fails the job.
_es_retry() {
    local attempts="${EVIDENCE_RETRY_ATTEMPTS:-3}" delay="${EVIDENCE_RETRY_DELAY:-2}"
    local i=1 rc out errf
    errf="$(command mktemp)" || return 1
    while :; do
        rc=0
        out="$("$@" 2>"$errf")" || rc=$?
        command cat "$errf" >&2
        if [ "$rc" -eq 0 ]; then
            command rm -f "$errf"
            [ -z "$out" ] || command printf '%s\n' "$out"
            return 0
        fi
        command echo "evidence_sources: attempt $i/$attempts failed (exit $rc): $*" >&2
        if command grep -Eq 'returned error: 40[14]' "$errf" ||
            { command grep -Eq 'HTTP 40[134]' "$errf" && ! command grep -iq 'rate limit' "$errf"; }; then
            command echo "evidence_sources: not retrying a permanent failure (exit $rc): $*" >&2
            command rm -f "$errf"
            return "$rc"
        fi
        if [ "$i" -ge "$attempts" ]; then
            command rm -f "$errf"
            return "$rc"
        fi
        command sleep "$delay"
        delay=$((delay * 2))
        i=$((i + 1))
    done
}

# _es_tar_has_links <tar> — exit 0 when the archive lists a symlink or
# hardlink entry, 1 when it lists none, 2 when it cannot be listed. Checked
# before extraction: an untrusted tools/ tree never gets the chance to write
# through a link it planted.
_es_tar_has_links() {
    local listing
    listing="$(command tar -tvf "$1")" || return 2
    command awk 'substr($0, 1, 1) == "l" || substr($0, 1, 1) == "h" { found = 1 } END { exit !found }' <<<"$listing"
}

# evidence_require_sources <sources> — exit 1 when the resolved source list is
# empty. An empty EVIDENCE_TESTED_SOURCE makes evidence_matrix read the
# vendored rows, which never receive tested[], so every cell would be pending.
evidence_require_sources() {
    if [ -z "$1" ]; then
        command echo "No published evidence source resolved" >&2
        return 1
    fi
}

# evidence_db_sources <db_dir> <work_dir> <now_epoch> — prints the source list
# (db_dir, then <work_dir>/_db_pr/<n>/rows per counted PR), colon-separated.
# db_dir is an absolute path to a containers-db checkout whose origin is the
# repo (EVIDENCE_DB_REPO, default joshjhall/containers-db); it is moved to a
# detached main. work_dir must hold no _db_pr/ from an earlier call: the PR
# trees extracted there are kept (the rows are built from them), and a later
# call refuses to extract over them rather than merge two runs' trees. CI
# gives each job a fresh checkout. Progress goes to stderr. Exit 1 on any
# failure.
evidence_db_sources() {
    local db="$1" work="$2" now="$3" repo="${EVIDENCE_DB_REPO:-joshjhall/containers-db}"
    local list count prs n main_sha sources pr_state state merge in_main verdict
    local head_sha base_sha side rev dir links
    list="$(_es_retry command gh pr list --repo "$repo" --state open --limit 1000 \
        --json number,headRefName,isCrossRepository,author,createdAt)" || {
        command echo "evidence_db_sources: cannot list open PRs of $repo" >&2
        return 1
    }
    # Exactly one JSON array: an empty listing gives jq no input, so it would
    # print nothing, exit 0, and resolve to main alone.
    count="$(command jq -se 'if length == 1 and (.[0] | type) == "array"
        then .[0] | length else error("not one array") end' <<<"$list" 2>/dev/null)" || {
        command echo "evidence_db_sources: unparsable PR listing" >&2
        return 1
    }
    if [ "$count" -ge 1000 ]; then
        command echo "containers-db has 1000+ open PRs; the listing may be truncated" >&2
        return 1
    fi
    prs="$(evidence_open_prs "$now" <<<"$list")" || return 1
    _es_retry command git -C "$db" fetch --quiet --depth 1 origin main || {
        command echo "evidence_db_sources: cannot fetch $repo main" >&2
        return 1
    }
    command git -C "$db" checkout --quiet --detach FETCH_HEAD || return 1
    # Merge-bases are taken against THIS main, not the moving ref: a PR that
    # merged after this fetch has its head on live main, so a live merge-base
    # would equal its head and its rows would be in neither.
    main_sha="$(command git -C "$db" rev-parse HEAD)" || return 1
    sources="$db"
    for n in $prs; do
        _es_retry command git -C "$db" fetch --quiet --depth 1 origin \
            "refs/pull/$n/head:refs/evidence-pr/$n" || {
            command echo "evidence_db_sources: cannot fetch containers-db#$n" >&2
            return 1
        }
        pr_state="$(_es_retry command gh pr view "$n" --repo "$repo" \
            --json state,mergeCommit -q '"\(.state) \(.mergeCommit.oid // "-")"')" || {
            command echo "evidence_db_sources: cannot read the state of containers-db#$n" >&2
            return 1
        }
        read -r state merge <<<"$pr_state"
        in_main=-
        if [ "$state" = MERGED ] && [ -n "$merge" ] && [ "$merge" != - ]; then
            in_main="$(_es_retry command gh api "repos/$repo/compare/$merge...$main_sha" -q .status)" || {
                command echo "evidence_db_sources: cannot compare containers-db#$n's merge to main" >&2
                return 1
            }
        fi
        verdict="$(evidence_pr_skip "$state" "$merge" "$in_main")" || return 1
        case "$verdict" in
            "skip closed")
                command echo "containers-db#$n closed without merging since it was listed; its rows do not count" >&2
                continue
                ;;
            "skip landed")
                command echo "containers-db#$n merged into the main read; its rows come from main" >&2
                continue
                ;;
        esac
        head_sha="$(command git -C "$db" rev-parse "refs/evidence-pr/$n")" || return 1
        base_sha="$(_es_retry command gh api "repos/$repo/compare/$main_sha...$head_sha" \
            -q .merge_base_commit.sha)" || {
            command echo "evidence_db_sources: cannot resolve containers-db#$n's merge-base" >&2
            return 1
        }
        if [ -z "$base_sha" ]; then
            command echo "evidence_db_sources: no merge-base for containers-db#$n" >&2
            return 1
        fi
        _es_retry command git -C "$db" fetch --quiet --depth 1 origin "$base_sha" || {
            command echo "evidence_db_sources: cannot fetch containers-db#$n's merge-base" >&2
            return 1
        }
        for side in head base; do
            dir="$work/_db_pr/$n/$side"
            if [ "$side" = head ]; then rev="$head_sha"; else rev="$base_sha"; fi
            # A fresh, empty directory: leftovers from an earlier run in the
            # same work dir would merge into this PR's tree.
            if [ -n "$(command find "$dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
                command echo "evidence_db_sources: $dir is not empty; refusing to extract into it" >&2
                return 1
            fi
            command mkdir -p "$dir" || return 1
            # Through a file, not a pipe: a pipeline's status is tar's alone.
            if ! command git -C "$db" archive -o "$dir.tar" "$rev" tools; then
                command rm -f "$dir.tar"
                command echo "evidence_db_sources: cannot extract containers-db#$n tools/ ($side)" >&2
                return 1
            fi
            links=0
            _es_tar_has_links "$dir.tar" || links=$?
            if [ "$links" -eq 0 ]; then
                command rm -f "$dir.tar"
                command echo "containers-db#$n tools/ ($side) contains symlinks or hardlinks; refusing it" >&2
                return 1
            fi
            if [ "$links" -ne 1 ] || ! command tar -x --no-same-owner -f "$dir.tar" -C "$dir"; then
                command rm -f "$dir.tar"
                command echo "evidence_db_sources: cannot extract containers-db#$n tools/ ($side)" >&2
                return 1
            fi
            command rm -f "$dir.tar"
            # Defence in depth: the listing above should have caught any link.
            if [ -n "$(command find "$dir" -type l -print -quit)" ]; then
                command echo "containers-db#$n tools/ ($side) contains symlinks or hardlinks; refusing it" >&2
                return 1
            fi
        done
        evidence_pr_rows "$work/_db_pr/$n/base" "$work/_db_pr/$n/head" "$work/_db_pr/$n/rows" || return 1
        sources="$sources:$work/_db_pr/$n/rows"
        command echo "Counting the rows open evidence PR $repo#$n adds as published evidence" >&2
    done
    command printf '%s\n' "$sources"
}
