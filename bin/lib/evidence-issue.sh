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
#   validate_issue_inputs <tool> <version> <tuple> [action]
#       Validate the three free-text coordinates against tight slugs; the
#       primary injection defense for the gh --search title and issue body.
#       [action] names the refused operation in the stderr message
#       (default "file issue").
#   open_or_update_tracking_issue <tool> <version> <tuple> <error_class> <run_url>
#       Search-or-create the per-cell regression tracking issue.
#   annotate_fail_verdict <result> <error_class> <tool> <version> <tuple>
#       On a `fail` verdict, print an `::error` workflow annotation and append
#       a line to $GITHUB_STEP_SUMMARY, so a fail cell is visible in the
#       Actions UI while its job stays green (#1549).
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
    # An empty string is normalized too: `// "unknown"` only replaces
    # null/false, and an empty class would fail annotate_fail_verdict's slug
    # check and silently drop the fail annotation (#1549).
    case "$ERROR_CLASS" in
        '' | *[!a-z_]*) ERROR_CLASS="unknown" ;;
    esac
    printf '%s\n' "result=$RESULT" "error_class=$ERROR_CLASS"
}

# _quote_rejected_value - Render a rejected input for a one-line log message.
#
# Arguments:
#   $1 - the raw rejected value
#
# Output (stdout):
#   `'value'` when the value has no control characters (keeps the #1568
#   messages byte-identical); otherwise bash's `printf %q` form (e.g.
#   `$'x\n::stop-commands::t'`), which renders CR/LF/ESC as escapes so the
#   message can never break onto a new line that begins with `::`.
_quote_rejected_value() {
    local v="$1"
    if [[ "$v" == *[[:cntrl:]]* ]]; then
        command printf '%q' "$v"
    else
        command printf "'%s'" "$v"
    fi
}

# validate_issue_inputs - Validate the three free-text coordinates.
#
# Arguments:
#   $1 - tool slug
#   $2 - tool version
#   $3 - tuple slug
#   $4 - action named in the rejection message (optional, default
#        "file issue"); annotate_fail_verdict passes "annotate" and
#        open_run_tracking_issue "include fail row", so neither log misreports
#        what was refused as issue filing (#1568)
#
# Returns:
#   0 if all three pass their anchored regexes, 1 (with a message to stderr)
#   on the first failure.
#
# The rejected value is echoed via _quote_rejected_value, never raw: the
# workflow steps that call this leave stderr on the step log, where the runner
# parses `::` workflow commands at the start of any line. A value carrying a
# newline then `::stop-commands::` would otherwise forge one (#1589).
#
# INPUT_TOOL/INPUT_TOOL_VERSION are free-text workflow_dispatch inputs. They
# flow into TITLE (a gh --search query) and the issue body, so validate them
# against tight slugs first — this blocks a dispatcher from smuggling gh-search
# operators or shell metacharacters through. INPUT_TUPLE is a `type: choice`
# input but is split+rechecked anyway.
validate_issue_inputs() {
    local INPUT_TOOL="$1" INPUT_TOOL_VERSION="$2" INPUT_TUPLE="$3"
    local action="${4:-file issue}"
    if [[ ! "$INPUT_TOOL" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        command printf 'Refusing to %s: unexpected tool slug %s\n' \
            "$action" "$(_quote_rejected_value "$INPUT_TOOL")" >&2
        return 1
    fi
    if [[ ! "$INPUT_TOOL_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]]; then
        command printf 'Refusing to %s: unexpected version %s\n' \
            "$action" "$(_quote_rejected_value "$INPUT_TOOL_VERSION")" >&2
        return 1
    fi
    if [[ ! "$INPUT_TUPLE" =~ ^[a-z0-9]+-[a-z0-9.]+-[a-z0-9]+$ ]]; then
        command printf 'Refusing to %s: unexpected tuple %s\n' \
            "$action" "$(_quote_rejected_value "$INPUT_TUPLE")" >&2
        return 1
    fi
    return 0
}

# annotate_fail_verdict - Make a `fail` cell visible without failing its job.
#
# Arguments:
#   $1 - result (pass|fail|skip, from read_evidence_verdict)
#   $2 - error_class (bare slug, from read_evidence_verdict)
#   $3 - tool slug
#   $4 - tool version
#   $5 - tuple slug
#
# Output (stdout):
#   On `fail`: one `::error title=...::...` workflow command. Nothing otherwise.
#   Also appends one markdown line to the file named by $GITHUB_STEP_SUMMARY
#   when that variable is set.
#
# Returns:
#   0 on success or a non-fail result; 1 (nothing emitted) when a coordinate
#   or the error_class fails validation.
#
# The cell job deliberately concludes `success` on an install failure —
# recording the fail row is the point of an evidence run — so without this a
# failing cell is green in the UI. Stdout is parsed by the runner as workflow
# commands, so every interpolated value is re-validated against a tight slug
# first: a `::` or newline smuggled through a free-text dispatch input could
# otherwise inject an arbitrary command (e.g. `::add-mask::`, `::stop-commands::`).
annotate_fail_verdict() {
    local result="$1" error_class="$2" tool="$3" version="$4" tuple="$5"
    [ "$result" = "fail" ] || return 0
    validate_issue_inputs "$tool" "$version" "$tuple" annotate || return 1
    if [[ ! "$error_class" =~ ^[a-z_]+$ ]]; then
        echo "Refusing to annotate: unexpected error_class '$error_class'" >&2
        return 1
    fi
    printf '::error title=Evidence fail: %s@%s on %s::install failed (error_class=%s); a fail row was recorded and the job stays green by design\n' \
        "$tool" "$version" "$tuple" "$error_class"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf -- '- :x: `%s@%s` on `%s` recorded **fail** (`error_class: %s`)\n' \
            "$tool" "$version" "$tuple" "$error_class" >>"$GITHUB_STEP_SUMMARY"
    fi
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

# open_run_tracking_issue - File ONE issue for a whole evidence run's fail rows.
#
# Arguments:
#   $1 - directory of the run's evidence envelopes (*.json, any depth)
#   $2 - run URL
#
# Returns 0 without filing anything when no row failed. The per-cell
# open_or_update_tracking_issue opened one issue per failing cell, so a single
# luggage bug that broke every cell filed dozens (47, then 83). A run's
# failures almost always share one cause; one issue listing them all is what
# a maintainer triages. Every envelope field reaching the body is validated
# with validate_issue_inputs first; rows that fail validation are dropped.
open_run_tracking_issue() {
    local rows_dir="$1" RUN_URL="$2"
    local table="" count=0 f tool version tuple ec
    while IFS= read -r -d '' f; do
        [ "$(command jq -r '.result // empty' "$f" 2>/dev/null)" = "fail" ] || continue
        tool="$(command jq -r '.tool // empty' "$f")"
        version="$(command jq -r '.version // empty' "$f")"
        tuple="$(command jq -r 'if (.os_version // "") != "" then "\(.os)-\(.os_version)-\(.arch)" else "" end' "$f")"
        ec="$(command jq -r '.error_class // "unknown"' "$f")"
        # Name the real action: a bad row is dropped, but the issue for the
        # remaining rows is still filed, so "file issue" would mislead (#1568).
        validate_issue_inputs "$tool" "$version" "$tuple" "include fail row" || continue
        [[ "$ec" =~ ^[a-z_]+$ ]] || ec="unknown"
        table="${table}| \`${tool}@${version}\` | \`${tuple}\` | \`${ec}\` |"$'\n'
        count=$((count + 1))
    done < <(command find "$rows_dir" -type f -name '*.json' -print0 | command sort -z)

    if [ "$count" -eq 0 ]; then
        echo "No fail rows in this run; no tracking issue."
        return 0
    fi

    "$GH" label create "audit/regression" --description "Automated regression finding" --color "B60205" --force
    "$GH" label create "severity/high" --description "High severity" --color "D93F0B" 2>/dev/null || true
    "$GH" label create "type/bug" --description "Bug" --color "D73A4A" 2>/dev/null || true

    local TODAY BODY_FILE
    TODAY="$(command date -u +%Y-%m-%d)"
    BODY_FILE="$(command mktemp)"
    command cat >"$BODY_FILE" <<BODY
## Evidence run recorded ${count} \`fail\` row(s)

The rows were recorded in containers-db as evidence (one batched PR); this
issue tracks the failures. When every row shares an \`error_class\`, the cause
is usually one luggage or catalog problem, not one per cell.

**Run:** ${RUN_URL}
**Recorded:** ${TODAY}

| tool@version | tuple | error_class |
|---|---|---|
${table}
<!-- managed-by: evidence-run.yml collect -->
BODY
    "$GH" issue create --title "Evidence run: ${count} failing cell(s) (${TODAY})" --body-file "$BODY_FILE" \
        --label "severity/high" --label "type/bug" --label "audit/regression"
    command rm -f "$BODY_FILE"
}
