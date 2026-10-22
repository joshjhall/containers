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
# Usage:
#   bin/ingest-evidence-batch.sh --rows-dir DIR --db-path DIR --run-id ID
#                                [--run-url URL] [--dry-run] [--no-validate]
#
#   --rows-dir   directory holding the run's rows (*.json, any depth; e.g. the
#                merged download of every evidence-row-* artifact)
#   --db-path    containers-db checkout (cloned when absent)
#   --run-id     identifies the run; the branch is evidence/batch/<run-id>
#
# Prints the branch name on success, nothing when there was nothing to ingest.
# Exit: 0 ok (incl. nothing to ingest), 1 runtime error, 2 usage/input error.
#
# Per CLAUDE.md, bare external commands use `command` to bypass aliases.

set -euo pipefail

SCRIPT_NAME="$(command basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(command cd "$(command dirname "${BASH_SOURCE[0]}")" && command pwd)"
PROJECT_ROOT="$(command dirname "$SCRIPT_DIR")"

# shellcheck source=bin/lib/evidence-merge.sh
source "$SCRIPT_DIR/lib/evidence-merge.sh"

die() {
    command echo "$SCRIPT_NAME: $*" >&2
    exit "${2:-1}"
}

ROWS_DIR=""
DB_PATH=""
RUN_ID=""
RUN_URL=""
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
            command sed -n '2,26p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$ROWS_DIR" ] || die "--rows-dir is required" 2
[ -n "$DB_PATH" ] || die "--db-path is required" 2
[ -n "$RUN_ID" ] || die "--run-id is required" 2
[ -d "$ROWS_DIR" ] || die "--rows-dir is not a directory: $ROWS_DIR" 2
# The run id becomes a branch name component: keep it to a safe shape.
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "--run-id has unsafe characters: $RUN_ID" 2

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
git -C "$DB_PATH" config --local user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "$DB_PATH" config --local user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
git -C "$DB_PATH" checkout -B "$BRANCH" >&2
git -C "$DB_PATH" add tools
SUBJECT="feat(evidence): record $merged evidence row(s) across $changed version file(s)"
git -C "$DB_PATH" commit -m "$SUBJECT" -m "Batched evidence from joshjhall/containers evidence-run ${RUN_URL:-$RUN_ID}." >&2

if $DRY_RUN; then
    command echo "Dry-run: $SUBJECT on $BRANCH in $DB_PATH; push and PR skipped." >&2
    command echo "$BRANCH"
    exit 0
fi

[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || die "GH_TOKEN or GITHUB_TOKEN must be set (use --dry-run locally)"

retry() {
    local i=1 delay=2
    while [ $i -le 3 ]; do
        "$@" && return 0
        [ $i -lt 3 ] && {
            command echo "Retry $i/3: $*" >&2
            command sleep "$delay"
            delay=$((delay * 2))
        }
        i=$((i + 1))
    done
    return 1
}

retry git -C "$DB_PATH" push --force-with-lease="refs/heads/$BRANCH:" origin "$BRANCH" >&2

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

pr_url="$(retry gh pr create --repo "$DB_REPO" --base main --head "$BRANCH" --title "$SUBJECT" --body "$BODY")"
command echo "$SCRIPT_NAME: opened $pr_url" >&2
# Squash + delete branch once the required check passes. Best-effort: if
# auto-merge is unavailable the PR is still open and correct.
retry gh pr merge "$pr_url" --repo "$DB_REPO" --auto --squash --delete-branch >&2 ||
    command echo "::warning::could not enable auto-merge on $pr_url; merge it manually" >&2
command echo "$BRANCH"
