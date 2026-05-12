#!/usr/bin/env bash
# Map changed files to the container features they affect.
#
# Drives the PR-tier CI matrix in .github/workflows/test-pr.yml: a PR that
# only touches `lib/features/python.sh` should only rebuild the python
# image, not the full 8-variant matrix.
#
# Output contract (stdout):
#   - Newline-separated feature names matching tests/test_feature.sh's
#     FEATURE_MAP keys (python, python-dev, node, …)
#   - "ALL" on its own line: fall back to the full merge-tier matrix
#     (foundational file changed — Dockerfile, lib/base, lib/runtime,
#     tests/framework, crates/*, or an unrecognized feature subtree)
#   - Empty stdout: nothing relevant changed, no container build needed
#
# Exit code: 0 on success (regardless of what was emitted)
#
# Usage:
#   ./tests/changed_features.sh                    # diff vs origin/HEAD
#   ./tests/changed_features.sh --base=main        # diff vs explicit ref
#   ./tests/changed_features.sh --files=- < list   # read paths from stdin
#
# The --files=- mode lets the GitHub Actions workflow feed `git diff`
# output directly without re-running git inside this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
BASE_REF=""
READ_FROM_STDIN=false

for arg in "$@"; do
    case "$arg" in
        --base=*) BASE_REF="${arg#--base=}" ;;
        --files=-) READ_FROM_STDIN=true ;;
        -h | --help)
            command sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | command sed '$d' | command sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Source of truth for "buildable" feature names: the FEATURE_MAP keys in
# tests/test_feature.sh. Grepping the file keeps a single source of truth
# without sourcing (test_feature.sh runs main logic on source).
# ---------------------------------------------------------------------------
get_known_features() {
    /usr/bin/grep -oE '^[[:space:]]*\["[^"]+"\]=' "$PROJECT_ROOT/tests/test_feature.sh" |
        /usr/bin/grep -oE '"[^"]+"' |
        /usr/bin/tr -d '"' |
        command sort -u
}

is_known_feature() {
    local candidate="$1"
    local known
    known=$(get_known_features)
    echo "$known" | command grep -Fxq "$candidate"
}

# ---------------------------------------------------------------------------
# Discover changed files. Mirrors tests/run_changed_tests.sh:20-37 so the
# two stay in sync; we don't source it because it has a `main` body.
# ---------------------------------------------------------------------------
get_changed_files() {
    if [ -n "$BASE_REF" ]; then
        git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || true
        git diff --name-only HEAD 2>/dev/null || true
        return
    fi

    local remote_head
    remote_head=$(git rev-parse --verify "origin/HEAD" 2>/dev/null ||
        git rev-parse --verify "origin/main" 2>/dev/null ||
        git rev-parse --verify "origin/master" 2>/dev/null || true)

    if [ -n "$remote_head" ]; then
        git diff --name-only "$remote_head"...HEAD 2>/dev/null || true
    else
        git diff --name-only HEAD~1 HEAD 2>/dev/null || true
    fi
    git diff --name-only HEAD 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Map one changed file to a feature name, "ALL", or nothing.
# ---------------------------------------------------------------------------
map_to_feature() {
    local file="$1"

    case "$file" in
        # Foundational — invalidate every cache, rebuild everything.
        Dockerfile | .dockerignore)
            echo "ALL"
            return
            ;;
        lib/base/* | lib/runtime/* | lib/shared/*)
            echo "ALL"
            return
            ;;
        tests/framework.sh | tests/framework/*)
            echo "ALL"
            return
            ;;
        # Rust crates can change feature-installation behavior via luggage.
        crates/*)
            echo "ALL"
            return
            ;;

        # Feature helper directory: lib/features/lib/<subdir>/<file>.
        # IMPORTANT: must come before the `lib/features/*.sh` arm — bash
        # case-glob `*` matches `/`, so the broader pattern would otherwise
        # claim helper-subdir paths first.
        lib/features/lib/*)
            local subdir
            subdir=$(echo "$file" | command sed 's|lib/features/lib/\([^/]*\)/.*|\1|')
            if is_known_feature "$subdir"; then
                echo "$subdir"
            else
                # Subdir name doesn't match a known feature (e.g. "claude",
                # which is shared infra). Be defensive.
                echo "ALL"
            fi
            return
            ;;

        # Top-level feature script.
        lib/features/*.sh)
            local name
            name=$(basename "$file" .sh)
            if is_known_feature "$name"; then
                echo "$name"
            else
                # Unknown feature script (helper or new feature not yet in
                # FEATURE_MAP). Defensive: rebuild the full matrix rather
                # than silently skip.
                echo "ALL"
            fi
            return
            ;;

        # Integration test for a specific build — rebuild + retest that build.
        tests/integration/builds/test_*.sh)
            local name
            name=$(basename "$file" .sh)
            name="${name#test_}"
            name="${name//_/-}"
            if is_known_feature "$name"; then
                echo "$name"
            fi
            # Unknown variant test (e.g. test_polyglot covers multiple
            # features) — no single feature to map; let merge tier cover it.
            return
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$READ_FROM_STDIN" = true ]; then
    CHANGED_FILES=$(cat)
else
    CHANGED_FILES=$(get_changed_files)
fi

if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

declare -A SEEN
RUN_ALL=false

while IFS= read -r file; do
    [ -z "$file" ] && continue
    result=$(map_to_feature "$file")
    [ -z "$result" ] && continue
    if [ "$result" = "ALL" ]; then
        RUN_ALL=true
        break
    fi
    SEEN["$result"]=1
done < <(echo "$CHANGED_FILES" | command sort -u)

if [ "$RUN_ALL" = true ]; then
    echo "ALL"
    exit 0
fi

# Emit deduplicated, sorted feature list.
if [ ${#SEEN[@]} -gt 0 ]; then
    command printf '%s\n' "${!SEEN[@]}" | command sort -u
fi
