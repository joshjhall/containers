#!/usr/bin/env bash
# Open a containers-db PR that appends an evidence-row to a tool's
# versions/<v>.json `tested[]`. Sub-issue C of #473 (evidence-runs design
# tracker); transport contract documented in
# docs/operations/evidence-runs.md.
#
# Inputs: a TestEntry-shaped JSON row as emitted by record-evidence (see
# crates/record-evidence/), the containers-db checkout path, and the tool
# + version coordinates that identify the target file.
#
# Steps: dedup-merge into the target file → validate via the same ajv
# invocation the contributor flow uses (just db-validate-tool) → branch +
# commit → push + `gh pr create`. The script never pushes when --dry-run
# is set; that mode is for local development and CI smoke tests.
#
# Per CLAUDE.md, all bare external commands use `command` to bypass any
# user-shell aliases.

set -euo pipefail

SCRIPT_NAME="$(command basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(command cd "$(command dirname "${BASH_SOURCE[0]}")" && command pwd)"
PROJECT_ROOT="$(command dirname "$SCRIPT_DIR")"

usage() {
    command cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Append an evidence-row to a containers-db tool/version file and open a PR.

Required:
  --row PATH            Path to a record-evidence JSON row (or '-' for stdin)
  --db-path DIR         containers-db checkout to operate on
  --tool TOOL           Tool slug (e.g. rust)
  --version VERSION     Tool version (e.g. 1.95.0)

Optional:
  --dry-run             Stage the change locally; skip push and PR open
  --no-validate         Skip ajv pre-flight (testing only)
  --remote URL          containers-db origin URL when --db-path is empty
                        (default: https://github.com/joshjhall/containers-db.git)
  --branch-suffix STR   Disambiguator appended to the branch name
                        (default: \$GITHUB_RUN_ID or a UTC timestamp)
  -h, --help            Show this help

Environment:
  GH_TOKEN / GITHUB_TOKEN   Required for push + PR open (skipped with --dry-run).
                            Must have contents:write + pull_requests:write
                            on the containers-db repo.

Exit codes:
  0  PR opened (or, in --dry-run, local commit ready)
  1  Generic failure (validation, git, gh)
  2  Bad input (missing flag, malformed row, file-not-found)
EOF
}

die() {
    command echo "$SCRIPT_NAME: $*" >&2
    exit "${2:-1}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1" 2
}

# --- Argument parsing -------------------------------------------------------

ROW_PATH=""
DB_PATH=""
TOOL=""
VERSION=""
DRY_RUN=false
NO_VALIDATE=false
REMOTE_URL="https://github.com/joshjhall/containers-db.git"
BRANCH_SUFFIX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --row)
            ROW_PATH="$2"
            shift 2
            ;;
        --db-path)
            DB_PATH="$2"
            shift 2
            ;;
        --tool)
            TOOL="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
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
        --remote)
            REMOTE_URL="$2"
            shift 2
            ;;
        --branch-suffix)
            BRANCH_SUFFIX="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$ROW_PATH" ] || {
    usage >&2
    die "missing --row" 2
}
[ -n "$DB_PATH" ] || {
    usage >&2
    die "missing --db-path" 2
}
[ -n "$TOOL" ] || {
    usage >&2
    die "missing --tool" 2
}
[ -n "$VERSION" ] || {
    usage >&2
    die "missing --version" 2
}

require_cmd jq
require_cmd git
$DRY_RUN || require_cmd gh

# --- Load row --------------------------------------------------------------

if [ "$ROW_PATH" = "-" ]; then
    ROW_JSON="$(command cat)"
else
    [ -f "$ROW_PATH" ] || die "row file not found: $ROW_PATH" 2
    ROW_JSON="$(command cat "$ROW_PATH")"
fi

command echo "$ROW_JSON" | jq -e . >/dev/null 2>&1 || die "row is not valid JSON" 2

# Coordinates the dedup key cares about (image_digest is the tie-breaker
# inside a single tuple; absent image_digest is treated as empty string,
# matching the schema's `dependentRequired` (image_ref ↔ image_digest)).
NEW_OS="$(command echo "$ROW_JSON" | jq -r '.os // ""')"
NEW_OS_VERSION="$(command echo "$ROW_JSON" | jq -r '.os_version // ""')"
NEW_ARCH="$(command echo "$ROW_JSON" | jq -r '.arch // ""')"
NEW_DIGEST="$(command echo "$ROW_JSON" | jq -r '.image_digest // ""')"
NEW_RESULT="$(command echo "$ROW_JSON" | jq -r '.result // ""')"

[ -n "$NEW_OS" ] || die "row missing required .os" 2
[ -n "$NEW_ARCH" ] || die "row missing required .arch" 2
[ -n "$NEW_RESULT" ] || die "row missing required .result" 2

# --- Locate / prepare the containers-db checkout ---------------------------

if [ ! -d "$DB_PATH/.git" ]; then
    if [ -e "$DB_PATH" ] && [ ! -d "$DB_PATH" ]; then
        die "--db-path exists but is not a directory: $DB_PATH" 2
    fi
    command echo "Cloning $REMOTE_URL into $DB_PATH"
    git clone --depth=1 "$REMOTE_URL" "$DB_PATH" >&2
fi

VERSIONS_FILE="$DB_PATH/tools/$TOOL/versions/$VERSION.json"
[ -f "$VERSIONS_FILE" ] || die "version file not found in containers-db: $VERSIONS_FILE" 2

# --- Compute tuple slug + branch name --------------------------------------

if [ -n "$NEW_OS_VERSION" ]; then
    TUPLE_SLUG="$NEW_OS-$NEW_OS_VERSION-$NEW_ARCH"
else
    TUPLE_SLUG="$NEW_OS-$NEW_ARCH"
fi

if [ -z "$BRANCH_SUFFIX" ]; then
    BRANCH_SUFFIX="${GITHUB_RUN_ID:-$(command date -u +%Y%m%d-%H%M%S)}"
fi

BRANCH_NAME="evidence/$TOOL/$VERSION/$TUPLE_SLUG/$BRANCH_SUFFIX"

# --- Dedup-merge row into the tested[] array -------------------------------

# Policy: rows with the same (os, os_version, arch, image_digest) are
# replaced by the new row; everything else is preserved. Rationale lives
# in docs/operations/evidence-runs.md (Merge policy).
TMP_FILE="$(command mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

jq \
    --argjson new "$ROW_JSON" \
    --arg os "$NEW_OS" \
    --arg ov "$NEW_OS_VERSION" \
    --arg arch "$NEW_ARCH" \
    --arg digest "$NEW_DIGEST" \
    '.tested = (
        ((.tested // []) | map(select(
            (.os // "") != $os
            or (.os_version // "") != $ov
            or (.arch // "") != $arch
            or (.image_digest // "") != $digest
        ))) + [$new]
    )' \
    "$VERSIONS_FILE" >"$TMP_FILE"

# Trailing newline keeps `git diff` and POSIX text-tool output clean.
command cp "$TMP_FILE" "$VERSIONS_FILE"
command echo "" >>"$VERSIONS_FILE"

# --- Validate via the existing contributor flow ----------------------------

if ! $NO_VALIDATE; then
    if ! command -v just >/dev/null 2>&1; then
        die "just(1) is required for schema validation; pass --no-validate to skip (testing only)"
    fi
    CONTAINERS_DB="$DB_PATH" just --justfile "$PROJECT_ROOT/justfile" db-validate-tool "$TOOL" >&2
fi

# --- Commit ----------------------------------------------------------------

git -C "$DB_PATH" config --local user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "$DB_PATH" config --local user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

git -C "$DB_PATH" checkout -b "$BRANCH_NAME" >&2

git -C "$DB_PATH" add "tools/$TOOL/versions/$VERSION.json"

COMMIT_SUBJECT="feat($TOOL): record $TOOL@$VERSION evidence on $TUPLE_SLUG ($NEW_RESULT)"
COMMIT_BODY="Auto-generated from joshjhall/containers evidence-run.

tuple: $TUPLE_SLUG
result: $NEW_RESULT
image_digest: ${NEW_DIGEST:-<absent>}

See docs/operations/evidence-runs.md in joshjhall/containers for the
ingestion contract (sub-issue C of joshjhall/containers#473)."

git -C "$DB_PATH" commit -m "$COMMIT_SUBJECT" -m "$COMMIT_BODY" >&2

if $DRY_RUN; then
    command echo "Dry-run: commit prepared on $BRANCH_NAME in $DB_PATH; push and PR-open skipped." >&2
    command echo "$BRANCH_NAME"
    exit 0
fi

# --- Push + open PR --------------------------------------------------------

if [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    die "GH_TOKEN or GITHUB_TOKEN must be set for non-dry-run push (use --dry-run for local testing)"
fi

# Retry the network steps a small number of times to ride out transient
# GitHub flakes. Each failure surfaces stderr from the underlying tool.
retry() {
    local attempts=3
    local i=1
    local delay=2
    while [ $i -le $attempts ]; do
        if "$@"; then
            return 0
        fi
        if [ $i -lt $attempts ]; then
            command echo "Retry $i/$attempts for: $*" >&2
            command sleep "$delay"
            delay=$((delay * 2))
        fi
        i=$((i + 1))
    done
    return 1
}

retry git -C "$DB_PATH" push --set-upstream origin "$BRANCH_NAME"

PR_BODY="$(
    command cat <<EOF
Auto-generated evidence row from \`joshjhall/containers\` CI.

| field | value |
|---|---|
| tuple | \`$TUPLE_SLUG\` |
| tool | \`$TOOL@$VERSION\` |
| result | \`$NEW_RESULT\` |
| image_digest | \`${NEW_DIGEST:-<absent>}\` |
| ci_run | $(command echo "$ROW_JSON" | jq -r '.ci_run // "<absent>"') |

Ingestion contract:
[\`docs/operations/evidence-runs.md\`](https://github.com/joshjhall/containers/blob/main/docs/operations/evidence-runs.md)
(sub-issue C of joshjhall/containers#473).
EOF
)"

retry gh pr create \
    --repo joshjhall/containers-db \
    --base main \
    --head "$BRANCH_NAME" \
    --title "$COMMIT_SUBJECT" \
    --body "$PR_BODY"

command echo "$BRANCH_NAME"
