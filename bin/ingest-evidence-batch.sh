#!/usr/bin/env bash
# Ingest every evidence row from one evidence run into containers-db as ONE
# pull request, then enable auto-merge on it.
#
# The per-cell path (bin/ingest-evidence.sh) opened one PR per cell. With a
# catalog-derived matrix of up to 200 cells per run, that meant hundreds of
# PRs per push, each appending to tested[] in a version file up to 18 others
# also touched, so merging one conflicted the rest. This script merges all of
# a run's rows into one checkout with the shared dedup policy
# (bin/lib/evidence-merge.sh), validates once, and opens one branch + PR.
#
# Rows are machine-produced and schema-validated, so the PR auto-merges once
# containers-db's own validation passes.
#
# The commit is created through the GitHub API (bin/lib/github-api-commit.sh),
# so GitHub signs it; containers-db main requires signed commits (#1573).
# --dry-run commits locally instead and never touches the remote.
#
# Usage:
#   bin/ingest-evidence-batch.sh --rows-dir DIR --db-path DIR --run-id ID
#                                [--run-url URL]
#                                [--expected-cells N --succeeded-cells S]
#                                [--dry-run] [--no-validate]
#
#   --rows-dir   directory holding the run's rows (*.json, any depth; e.g. the
#                merged download of every evidence-row-* artifact)
#   --db-path    containers-db checkout (cloned when absent)
#   --run-id     identifies the run; the branch is evidence/batch/<run-id>
#   --expected-cells
#                how many cells the run's matrix had (#1569)
#   --succeeded-cells
#                how many of this run's evidence jobs concluded `success`
#                (counted per job from the Jobs API by evidence-run.yml).
#                Required with --expected-cells; must not exceed it.
#
# Zero rows (--rows-dir absent or holding no *.json), with --expected-cells:
#   succeeded 0   ->  `no evidence rows: none of N cells reached upload
#       (cancelled, timed out, or failed)`, exit 0
#   succeeded >0  ->  exit 1: a cell that succeeded uploaded a row, so zero
#       rows means the row upload or download is broken
# The count is per cell on purpose. needs.evidence.result is `failure` when
# ANY cell fails, so one timed-out cell would hide a broken upload from every
# other cell behind a neutral skip.
# Without --expected-cells, an absent --rows-dir stays a usage error (exit 2),
# so a mistyped path in a manual run still fails loudly.
#
# Prints the branch name on success, nothing when there was nothing to ingest.
# Exit: 0 ok (incl. nothing to ingest), 1 runtime error, 2 usage/input error.
#
# Why the cancelled/failed case is a NEUTRAL skip: those cells already fail the
# run with the real cause on each cell (job timeout, a failed build step).
# Failing ingest too added a second red job that blamed --rows-dir instead.
# Ingest cannot see which of those causes it was, so the message names them
# all rather than claiming one.
#
# Per CLAUDE.md, bare external commands use `command` to bypass aliases.

set -euo pipefail

SCRIPT_NAME="$(command basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(command cd "$(command dirname "${BASH_SOURCE[0]}")" && command pwd)"
PROJECT_ROOT="$(command dirname "$SCRIPT_DIR")"

# shellcheck source=bin/lib/evidence-merge.sh
source "$SCRIPT_DIR/lib/evidence-merge.sh"
# shellcheck source=bin/lib/github-api-commit.sh
source "$SCRIPT_DIR/lib/github-api-commit.sh"

die() {
    command echo "$SCRIPT_NAME: $*" >&2
    exit "${2:-1}"
}

ROWS_DIR=""
DB_PATH=""
RUN_ID=""
RUN_URL=""
EXPECTED_CELLS=""
EXPECTED_GIVEN=false
SUCCEEDED_CELLS=""
SUCCEEDED_GIVEN=false
DRY_RUN=false
NO_VALIDATE=false
REMOTE_URL="https://github.com/joshjhall/containers-db.git"
DB_REPO="joshjhall/containers-db"

while [ $# -gt 0 ]; do
    case "$1" in
        --rows-dir)
            ROWS_DIR="${2:-}"
            shift 2
            ;;
        --db-path)
            DB_PATH="${2:-}"
            shift 2
            ;;
        --run-id)
            RUN_ID="${2:-}"
            shift 2
            ;;
        --run-url)
            RUN_URL="${2:-}"
            shift 2
            ;;
        --expected-cells)
            EXPECTED_CELLS="${2:-}"
            EXPECTED_GIVEN=true
            shift 2
            ;;
        --succeeded-cells)
            SUCCEEDED_CELLS="${2:-}"
            SUCCEEDED_GIVEN=true
            shift 2
            ;;
        --remote)
            REMOTE_URL="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-validate)
            NO_VALIDATE=true
            shift
            ;;
        -h | --help)
            command sed -n '2,43p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$ROWS_DIR" ] || die "--rows-dir is required" 2
[ -n "$DB_PATH" ] || die "--db-path is required" 2
[ -n "$RUN_ID" ] || die "--run-id is required" 2
# The run id becomes a branch name component: keep it to a safe shape.
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "--run-id has unsafe characters: $RUN_ID" 2
# Given but blank (an unset job output) is refused, not read as "flag absent".
if $EXPECTED_GIVEN; then
    [[ "$EXPECTED_CELLS" =~ ^[0-9]{1,6}$ ]] ||
        die "--expected-cells must be a non-negative integer: $EXPECTED_CELLS" 2
    $SUCCEEDED_GIVEN || die "--expected-cells needs --succeeded-cells" 2
    [[ "$SUCCEEDED_CELLS" =~ ^[0-9]{1,6}$ ]] ||
        die "--succeeded-cells must be a non-negative integer: $SUCCEEDED_CELLS" 2
    [ "$((10#$SUCCEEDED_CELLS))" -le "$((10#$EXPECTED_CELLS))" ] ||
        die "--succeeded-cells ($SUCCEEDED_CELLS) exceeds --expected-cells ($EXPECTED_CELLS)" 2
    # actions/download-artifact creates no directory when no artifact matched,
    # which is what a run whose every cell died before uploading leaves behind.
    if [ ! -d "$ROWS_DIR" ] ||
        [ -z "$(command find "$ROWS_DIR" -type f -name '*.json' -print -quit)" ]; then
        if [ "$((10#$SUCCEEDED_CELLS))" -eq 0 ]; then
            command echo "::warning::no evidence rows: none of $EXPECTED_CELLS cells reached upload (cancelled, timed out, or failed); nothing to ingest" >&2
            exit 0
        fi
        die "no evidence rows, yet $SUCCEEDED_CELLS of $EXPECTED_CELLS evidence cells succeeded: the row upload or download is broken" 1
    fi
elif $SUCCEEDED_GIVEN; then
    die "--succeeded-cells needs --expected-cells" 2
fi
[ -d "$ROWS_DIR" ] || die "--rows-dir is not a directory: $ROWS_DIR" 2

if [ ! -d "$DB_PATH/.git" ]; then
    command echo "Cloning $REMOTE_URL into $DB_PATH" >&2
    git clone --depth=1 "$REMOTE_URL" "$DB_PATH" >&2
fi

# --- Merge every row --------------------------------------------------------

# Each row names its tool and version (record-evidence writes both alongside
# the TestEntry fields); route it to tools/<tool>/versions/<version>.json.
merged=0 skipped=0
summary=""
while IFS= read -r -d '' row_file; do
    row="$(command cat "$row_file")"
    tool="$(command jq -r '.tool // empty' <<<"$row" 2>/dev/null || true)"
    version="$(command jq -r '.version // empty' <<<"$row" 2>/dev/null || true)"
    if [ -z "$tool" ] || [ -z "$version" ]; then
        command echo "$SCRIPT_NAME: skip $row_file (no .tool/.version)" >&2
        skipped=$((skipped + 1))
        continue
    fi
    file="$DB_PATH/tools/$tool/versions/$version.json"
    if [ ! -f "$file" ]; then
        command echo "$SCRIPT_NAME: skip $row_file ($tool@$version not in containers-db)" >&2
        skipped=$((skipped + 1))
        continue
    fi
    # The TestEntry is the row minus the routing fields.
    entry="$(command jq -c 'del(.tool, .version)' <<<"$row")"
    merge_evidence_row "$file" "$entry" || die "failed to merge $row_file into $file"
    merged=$((merged + 1))
    summary="${summary}| ${tool}@${version} | $(evidence_tuple_slug "$entry") | $(command jq -r '.result' <<<"$entry") |"$'\n'
done < <(command find "$ROWS_DIR" -type f -name '*.json' -print0 | command sort -z)

command echo "$SCRIPT_NAME: merged $merged row(s), skipped $skipped" >&2

# Rows already recorded (modulo volatile fields) leave files untouched,
# except a repeated fail row, which refreshes tested_at (#1326).
if git -C "$DB_PATH" diff --quiet -- tools; then
    command echo "$SCRIPT_NAME: nothing new to ingest" >&2
    exit 0
fi

# --- Validate once ----------------------------------------------------------

if ! $NO_VALIDATE; then
    command -v just >/dev/null 2>&1 ||
        die "just(1) is required for schema validation; pass --no-validate to skip (testing only)"
    CONTAINERS_DB="$DB_PATH" just --justfile "$PROJECT_ROOT/justfile" db-validate >&2
fi

# --- One branch, one commit -------------------------------------------------

BRANCH="evidence/batch/$RUN_ID"
changed="$(git -C "$DB_PATH" diff --name-only -- tools | command wc -l | command tr -d ' ')"
SUBJECT="feat(evidence): record $merged evidence row(s) across $changed version file(s)"
MSG_FILE="$(command mktemp)"
trap 'command rm -f "$MSG_FILE"' EXIT
command printf '%s\n\nBatched evidence from joshjhall/containers evidence-run %s.\n' \
    "$SUBJECT" "${RUN_URL:-$RUN_ID}" >"$MSG_FILE"

if $DRY_RUN; then
    # A local commit exercises the whole merge without touching the remote.
    git -C "$DB_PATH" checkout -B "$BRANCH" >&2
    git -C "$DB_PATH" add tools
    git -C "$DB_PATH" -c user.name=dry-run -c user.email=dry-run@localhost \
        commit -q -F "$MSG_FILE" >&2
    command echo "Dry-run: $SUBJECT on $BRANCH in $DB_PATH; API commit and PR skipped." >&2
    command echo "$BRANCH"
    exit 0
fi

[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || die "GH_TOKEN or GITHUB_TOKEN must be set (use --dry-run locally)"

# Commit through the GitHub API, not git push: containers-db main requires
# signed commits, and only an API-created commit is signed by GitHub (#1573).
# The branch starts at the checkout's HEAD, which is on the remote's main.
gh_api_ensure_branch "$DB_REPO" "$BRANCH" "$(git -C "$DB_PATH" rev-parse HEAD)" ||
    die "could not create $BRANCH on $DB_REPO"
gh_api_commit_worktree "$DB_REPO" "$BRANCH" "$DB_PATH" "$MSG_FILE" tools >/dev/null ||
    die "could not commit evidence to $DB_REPO:$BRANCH"

BODY="$(
    command cat <<EOF
Batched evidence from one [evidence run](${RUN_URL:-}) ($merged row(s), $changed version file(s)).

| tool@version | tuple | result |
|---|---|---|
${summary}
Machine-produced and schema-validated; auto-merges when validation passes.
Ingestion contract: [\`docs/operations/evidence-runs.md\`](https://github.com/joshjhall/containers/blob/main/docs/operations/evidence-runs.md).
EOF
)"

pr_url="$(gh_api_retry gh pr create --repo "$DB_REPO" --base main --head "$BRANCH" --title "$SUBJECT" --body "$BODY")"
command echo "$SCRIPT_NAME: opened $pr_url" >&2
# Squash + delete branch once the required check passes. Best-effort: if
# auto-merge is unavailable the PR is still open and correct.
gh_api_retry gh pr merge "$pr_url" --repo "$DB_REPO" --auto --squash --delete-branch >&2 ||
    command echo "::warning::could not enable auto-merge on $pr_url; merge it manually" >&2
command echo "$BRANCH"
