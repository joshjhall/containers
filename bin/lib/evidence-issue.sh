#!/bin/bash
# Evidence fail-row verdict + tracking-issue helpers
#
# Description:
#   Sourced helper extracting the non-trivial shell logic of the
#   `.github/workflows/evidence-run.yml` fail-row steps so it can be unit
#   tested offline (the workflow steps now `source` this file and call the
#   functions). Behavior is byte-for-byte identical to the inline workflow
#   logic added in #652 — the regexes and CR/LF strip are the injection
#   defense this module locks down, so they are preserved exactly.
#
# Functions:
#   read_evidence_verdict <row-file>
#       Read+sanitize result/error_class from an evidence row and print
#       `result=` / `error_class=` lines to stdout (the workflow redirects
#       these into $GITHUB_OUTPUT). Exits 1 on an unexpected result enum.
#   validate_issue_inputs <tool> <version> <tuple>
#       Validate the three free-text coordinates against tight slugs; the
#       primary injection defense for the gh --search title and issue body.
#   open_or_update_tracking_issue <tool> <version> <tuple> <error_class> <run_url>
#       Search-or-create the per-cell regression tracking issue.
#
# Usage:
#   source "$GITHUB_WORKSPACE/bin/lib/evidence-issue.sh"
#   read_evidence_verdict out/evidence-row.json >> "$GITHUB_OUTPUT"
#   open_or_update_tracking_issue "$TOOL" "$VERSION" "$TUPLE" "$EC" "$URL"
#
# Tests stub `gh` via the GH override (see tests/unit/evidence-issue.sh and the
# dispatch-evidence.sh override pattern); production leaves GH unset so it
# defaults to the real `gh`.

# Header guard to prevent multiple sourcing
if [ -n "${_BIN_LIB_EVIDENCE_ISSUE_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BIN_LIB_EVIDENCE_ISSUE_SH_INCLUDED=1

set -euo pipefail

# Route all GitHub CLI calls through "$GH" so tests can inject a stub by
# absolute path (PATH-shadowing is unreliable — the shell re-initializes PATH
# from the profile on each bash startup). Production leaves GH unset → `gh`.
GH="${GH:-gh}"

# read_evidence_verdict - Read and sanitize the recorded verdict from a row.
#
# Arguments:
#   $1 - path to the evidence row JSON
#
# Output (stdout):
#   result=<pass|fail|skip>
#   error_class=<bare [a-z_] slug | unknown>
#
# Returns:
#   1 (no stdout) if result is not one of the pass|fail|skip enum.
#
# record-evidence emits `result` as a fixed enum (pass|fail|skip) and
# `error_class` as an enum too — but the row is produced INSIDE the base image
# (luggage runs as --user 0), so treat both as untrusted: strip CR/LF (a
# GITHUB_OUTPUT key=value injection vector) and validate result against the
# enum before it gates the tracking-issue step.
read_evidence_verdict() {
    local RESULT ERROR_CLASS
    RESULT=$(command jq -r '.result' "$1" | command tr -d '\r\n')
    ERROR_CLASS=$(command jq -r '.error_class // "unknown"' "$1" | command tr -d '\r\n')
    case "$RESULT" in
        pass | fail | skip) ;;
        *)
            echo "Unexpected result in evidence row: '$RESULT'" >&2
            return 1
            ;;
    esac
    # error_class is informational, not a gate — normalize an unexpected
    # value to "unknown" rather than failing the row (a future luggage
    # ErrorClass variant shouldn't drop a regression). Restricting it to a
    # bare slug also keeps it safe as a literal gh-comment argument later.
    case "$ERROR_CLASS" in
        *[!a-z_]*) ERROR_CLASS="unknown" ;;
    esac
    printf '%s\n' "result=$RESULT" "error_class=$ERROR_CLASS"
}

# validate_issue_inputs - Validate the three free-text coordinates.
#
# Arguments:
#   $1 - tool slug
#   $2 - tool version
#   $3 - tuple slug
#
# Returns:
#   0 if all three pass their anchored regexes, 1 (with a message to stderr)
#   on the first failure.
#
# INPUT_TOOL/INPUT_TOOL_VERSION are free-text workflow_dispatch inputs. They
# flow into TITLE (a gh --search query) and the issue body, so validate them
# against tight slugs first — this blocks a dispatcher from smuggling gh-search
# operators or shell metacharacters through. INPUT_TUPLE is a `type: choice`
# input but is split+rechecked anyway.
validate_issue_inputs() {
    local INPUT_TOOL="$1" INPUT_TOOL_VERSION="$2" INPUT_TUPLE="$3"
    if [[ ! "$INPUT_TOOL" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Refusing to file issue: unexpected tool slug '$INPUT_TOOL'" >&2
        return 1
    fi
    if [[ ! "$INPUT_TOOL_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]]; then
        echo "Refusing to file issue: unexpected version '$INPUT_TOOL_VERSION'" >&2
        return 1
    fi
    if [[ ! "$INPUT_TUPLE" =~ ^[a-z0-9]+-[a-z0-9.]+-[a-z0-9]+$ ]]; then
        echo "Refusing to file issue: unexpected tuple '$INPUT_TUPLE'" >&2
        return 1
    fi
    return 0
}

# open_or_update_tracking_issue - Search-or-create the regression issue.
#
# Arguments:
#   $1 - tool slug
#   $2 - tool version
#   $3 - tuple slug
#   $4 - error_class
#   $5 - run URL
#
# Returns:
#   1 on validation failure or a corrupt `gh issue list` number; otherwise the
#   exit status of the gh edit/create branch.
#
# Mirrors the cadence tiers' search-or-create auto-issue convention so a broken
# tool@tuple gets triaged. Pattern: security-scan.yml's tracking-issue step.
open_or_update_tracking_issue() {
    local INPUT_TOOL="$1" INPUT_TOOL_VERSION="$2" INPUT_TUPLE="$3"
    local ERROR_CLASS="$4" RUN_URL="$5"

    # Enforce validation on this path before any value reaches a gh query.
    validate_issue_inputs "$INPUT_TOOL" "$INPUT_TOOL_VERSION" "$INPUT_TUPLE" || return 1

    local TITLE TODAY BODY_FILE EXISTING
    TITLE="Evidence regression: ${INPUT_TOOL}@${INPUT_TOOL_VERSION} on ${INPUT_TUPLE}"
    TODAY="$(command date -u +%Y-%m-%d)"
    # Ensure every label exists before filing so gh issue create can never
    # 422 on a missing one. audit/regression is the cadence-tier vocabulary
    # most likely to be absent — create it idempotently with --force (same
    # pattern as auto-patch.yml). severity/high and type/bug are existing
    # taxonomy labels a maintainer may have recolored, so create-if-absent
    # WITHOUT --force (|| true) rather than resetting their color/desc on
    # every fail row.
    "$GH" label create "audit/regression" --description "Automated regression finding" --color "B60205" --force
    "$GH" label create "severity/high" --description "High severity" --color "D93F0B" 2>/dev/null || true
    "$GH" label create "type/bug" --description "Bug" --color "D73A4A" 2>/dev/null || true
    # Build the body in a temp file via a quoted heredoc so the validated
    # inputs are substituted by the shell (not re-evaluated) and gh reads
    # it with --body-file — no second shell pass over LLM/user content.
    BODY_FILE="$(command mktemp)"
    command cat >"$BODY_FILE" <<EOF
## Evidence run recorded a \`fail\` row

An evidence run installed \`${INPUT_TOOL}@${INPUT_TOOL_VERSION}\`
against base image tuple \`${INPUT_TUPLE}\` and luggage reported a
failure. The row was still recorded in containers-db as evidence;
this issue tracks the regression.

**Run:** ${RUN_URL}
**error_class:** \`${ERROR_CLASS}\`
**Recorded:** ${TODAY}

<!-- managed-by: evidence-run.yml -->
EOF
    # Title keyed on (tool, version, tuple) — INPUT_TUPLE encodes
    # os-os_version-arch — so a re-failure on the same cell updates one
    # issue while a different distro/arch opens its own.
    EXISTING=$("$GH" issue list \
        --label "audit/regression" --state open \
        --search "\"${TITLE}\" in:title" \
        --json number --jq '.[0].number // empty')
    # Guard the captured number: a transient gh/jq hiccup must not fall
    # through to `gh issue create` and open a duplicate. Empty = no match.
    if [ -n "${EXISTING}" ] && [[ ! "${EXISTING}" =~ ^[0-9]+$ ]]; then
        echo "Unexpected issue number from gh issue list: '${EXISTING}'" >&2
        return 1
    fi
    if [ -n "${EXISTING}" ]; then
        echo "Updating existing tracking issue #${EXISTING}"
        "$GH" issue edit "${EXISTING}" --body-file "$BODY_FILE"
        "$GH" issue comment "${EXISTING}" \
            --body "Failed again on ${TODAY} (error_class \`${ERROR_CLASS}\`) — see ${RUN_URL}"
    else
        echo "Opening new tracking issue"
        "$GH" issue create --title "${TITLE}" --body-file "$BODY_FILE" \
            --label "severity/high" --label "type/bug" --label "audit/regression"
    fi
}
