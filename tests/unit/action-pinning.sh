#!/usr/bin/env bash
# Unit tests for GitHub Actions supply-chain pinning policy (issue #650).
#
# Background: GitHub Actions referenced by mutable tags (`@v3`, `@v0.36.0`,
# `@stable`) can be silently re-pointed by a force-pushed tag — accidentally,
# or via an upstream account/repo compromise — so a workflow starts running
# different code with NO diff in this repository. `evidence-run.yml` is the
# sharpest case because its runs carry `secrets.CONTAINERS_DB_PAT`.
#
# Policy (see docs/security/action-pinning.md):
#   - THIRD-PARTY actions (anyone other than github-owned `actions/*` and
#     `github/*`) MUST be pinned to a full 40-hex commit SHA, with a trailing
#     `# <version>` comment for human readability.
#   - FIRST-PARTY actions (`actions/*`, `github/*`) MAY stay on major tags —
#     they are GitHub-owned and share the platform's trust boundary.
#
# This test is the CI guard from the issue's acceptance criteria: a new
# unpinned third-party action fails here before it can land.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "GitHub Actions pinning policy"

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"

# Owners whose actions are allowed to remain on mutable major tags. These are
# GitHub-operated and share the runner's trust boundary; pinning them buys
# little and churns constantly. Everything else is "third-party" and must be
# SHA-pinned.
FIRST_PARTY_OWNERS_RE='^(actions|github)/'

# Collect every `uses:` reference that points at a remote action (owner/repo),
# excluding local (`./…`) and docker (`docker://…`) references which are not
# tag-mutable in the same way.
collect_uses() {
    # Match both the block form (`  uses: …`) and the inline sequence form
    # (`  - uses: …`) so a `- uses:` entry can't smuggle an unpinned action past
    # the guard.
    /usr/bin/grep -rhnE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' "$WORKFLOWS_DIR" 2>/dev/null |
        /usr/bin/sed -E 's/^[0-9]+:[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//' |
        /usr/bin/sed -E 's/[[:space:]]*#.*$//' |
        /usr/bin/grep -vE '^\.?/' |
        /usr/bin/grep -vE '^docker://' |
        /usr/bin/sort -u
}

test_workflows_dir_exists() {
    assert_true [ -d "$WORKFLOWS_DIR" ] ".github/workflows/ must exist"
}

# The core guard: every third-party `uses:` must carry an @<40-hex-sha> ref.
test_third_party_actions_are_sha_pinned() {
    local violations=0 ref owner_repo gitref
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        owner_repo="${ref%@*}"
        gitref="${ref##*@}"
        # First-party owners are exempt.
        if /usr/bin/printf '%s\n' "$owner_repo" | /usr/bin/grep -qE "$FIRST_PARTY_OWNERS_RE"; then
            continue
        fi
        # Third-party: the ref after @ must be a full 40-char hex SHA.
        if ! /usr/bin/printf '%s\n' "$gitref" | /usr/bin/grep -qE '^[0-9a-f]{40}$'; then
            /usr/bin/echo "  unpinned third-party action: $ref"
            violations=$((violations + 1))
        fi
    done < <(collect_uses)

    if [ "$violations" -eq 0 ]; then
        assert_true true "all third-party actions are SHA-pinned"
    else
        assert_true false "$violations third-party action(s) not SHA-pinned (see above)"
    fi
}

# Each SHA-pinned action should carry a trailing `# version` comment so a human
# can read the intended version without resolving the SHA. This is a soft
# readability invariant, but the issue's proposed format mandates it.
test_pinned_actions_have_version_comment() {
    local violations=0 line ref
    # Look at raw lines so we can see whether a comment is present.
    while IFS= read -r line; do
        # Strip the leading `<indent>uses: `.
        ref=$(/usr/bin/printf '%s\n' "$line" | /usr/bin/sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//')
        # Only SHA-pinned refs are in scope here.
        /usr/bin/printf '%s\n' "$ref" | /usr/bin/grep -qE '@[0-9a-f]{40}' || continue
        if ! /usr/bin/printf '%s\n' "$ref" | /usr/bin/grep -qE '@[0-9a-f]{40}[[:space:]]+#[[:space:]]*'; then
            /usr/bin/echo "  SHA-pinned without version comment: $ref"
            violations=$((violations + 1))
        fi
    done < <(/usr/bin/grep -rhE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]].*@[0-9a-f]{40}' "$WORKFLOWS_DIR" 2>/dev/null)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every SHA-pinned action carries a # version comment"
    else
        assert_true false "$violations SHA-pinned action(s) missing a version comment"
    fi
}

run_test test_workflows_dir_exists ".github/workflows directory exists"
run_test test_third_party_actions_are_sha_pinned "third-party actions are SHA-pinned"
run_test test_pinned_actions_have_version_comment "pinned actions carry version comments"

generate_report
