#!/usr/bin/env bash
# Unit tests: the .claude/memory/ bundle stays recallable, conformant, and lean.
#
# The memory bundle is written by every session, and every way it rots is
# silent at write time: a concept no index names is written but never recalled,
# a renamed slug leaves an index line pointing at nothing, a concept claimed by
# two indexes is ambiguous about which owns it, and an index that grows past
# what a session can afford to read gets truncated. None of those produce a
# symptom in the PR that caused them. This gate does.
#
# THE SCANNER IS librarian's check-okf-conformance (review-audit plugin), not a
# copy. It is resolved from $OKF_SCANNER, else the pinned container install at
# /opt/librarian (LIBRARIAN_REF in the Dockerfile). CI checks librarian out at
# that same pinned ref and exports OKF_SCANNER (.github/workflows/ci.yml), the
# way it already checks out containers-db for tests/unit/vendored-catalog.sh.
# Skip locally when it is missing; FAIL in CI, where a skip would render as a
# pass and leave the gate inert (the require_upstream_in_ci rule, #768/#815).
#
# WHAT IS ENFORCED, and how:
#
# 1. Graph health is a HARD ZERO, not a baseline: memory-orphan,
#    memory-dangling-index, memory-multi-index. The bundle has none, and any
#    one of them means a memory is unrecallable or ambiguously owned.
#
# 2. Every other finding category is a RATCHET against
#    tests/unit/okf-memory-bundle.baseline (librarian's #697 pattern): a count
#    above its entry fails; an unlisted category has an implicit baseline of 0.
#    That freezes the pre-OKF frontmatter shape (`type` nested under
#    `metadata:`, missing **Why:** sections) without blocking on it -- the
#    okf-author skill says that migration is a separate, mechanized job -- while
#    one NEW non-conformant memory still fails. A count that DROPS also fails
#    until `--regen` lowers the entry, so a fix cannot become silent headroom.
#
# 3. Index SIZE budgets, in bytes, because the cost is context a session pays
#    to read the index before it can recall anything:
#      MEMORY.md (root)      MEMORY_ROOT_MAX_BYTES  (default 6144)
#      index-*.md (each)     MEMORY_SUBINDEX_MAX_BYTES (default 8192)
#    The root holds only proactive memories plus one pointer per topic index
#    (#1528); a topic-specific memory belongs behind a sub-index.
#
# The scanner's EVIDENCE column is never printed: it can echo a memory's own
# text, and a CI log is a wider audience than the bundle. File + category is
# enough to act on.
#
# Usage:
#   tests/unit/okf-memory-bundle.sh            enforce
#   tests/unit/okf-memory-bundle.sh --regen    rewrite the ratchet baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "OKF memory bundle (.claude/memory/)"

BUNDLE="${OKF_MEMORY_BUNDLE:-$PROJECT_ROOT/.claude/memory}"
BASELINE="${OKF_MEMORY_BASELINE:-$SCRIPT_DIR/okf-memory-bundle.baseline}"
SCANNER="${OKF_SCANNER:-/opt/librarian/plugins/review-audit/skills/check-okf-conformance/patterns.sh}"
ROOT_MAX="${MEMORY_ROOT_MAX_BYTES:-6144}"
SUB_MAX="${MEMORY_SUBINDEX_MAX_BYTES:-8192}"

# Graph-health categories: never baselined, always zero.
readonly HARD_ZERO="memory-orphan memory-dangling-index memory-multi-index"

REGEN=false
if [ "${1:-}" = "--regen" ]; then
    REGEN=true
fi

# Skip locally, FAIL in CI (see header).
require_scanner_in_ci() {
    if [ "${CI:-false}" = "true" ]; then
        fail_test "$1 — required in CI, cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "$1"
    fi
}

SCAN_OUT=""
SCAN_RC=0

# run_scan — scan every tracked .md in the bundle once; results reused by tests.
run_scan() {
    [ -n "$SCAN_OUT" ] && return 0
    SCAN_OUT="$(command mktemp)"
    local list
    list="$(command mktemp)"
    # Tracked files only: .claude/memory/tmp/ is gitignored per-session scratch.
    command git -C "$BUNDLE" ls-files -z -- '*.md' |
        while IFS= read -r -d '' rel; do
            command printf '%s\n' "$BUNDLE/$rel"
        done >"$list"
    MEMORY_BUNDLE_ROOT="$BUNDLE" command bash "$SCANNER" "$list" >"$SCAN_OUT" 2>/dev/null ||
        SCAN_RC=$?
    command rm -f "$list"
}

# count_of CATEGORY — findings of that category in the last scan.
count_of() {
    command awk -F'\t' -v c="$1" '$3 == c' "$SCAN_OUT" | command wc -l | command tr -d '[:space:]'
}

# baseline_for CATEGORY — the frozen count, or 0 when unlisted.
baseline_for() {
    local value
    value="$(command awk -v c="$1" '$1 == c { print $2 }' "$BASELINE" 2>/dev/null)"
    command printf '%s\n' "${value:-0}"
}

scanner_ready() {
    if [ ! -f "$SCANNER" ]; then
        require_scanner_in_ci "check-okf-conformance scanner not found at $SCANNER (set OKF_SCANNER)"
        return 1
    fi
    run_scan
    if [ "$SCAN_RC" -ne 0 ]; then
        # A non-zero is a TOOL failure, never a clean bundle.
        fail_test "OKF scanner failed (exit $SCAN_RC) — nothing was checked"
        return 1
    fi
    return 0
}

test_graph_health_is_clean() {
    scanner_ready || return 0
    local category count
    for category in $HARD_ZERO; do
        count="$(count_of "$category")"
        if [ "$count" -ne 0 ]; then
            fail_test "$count $category finding(s) — every memory must be named by exactly one index:"$'\n'"$(
                command awk -F'\t' -v c="$category" '$3 == c { print "  " $1 ":" $2 }' "$SCAN_OUT"
            )"
            return 0
        fi
    done
}

test_no_new_conformance_findings() {
    scanner_ready || return 0
    local violations="" category count base
    while read -r category; do
        [ -n "$category" ] || continue
        case " $HARD_ZERO " in *" $category "*) continue ;; esac
        count="$(count_of "$category")"
        base="$(baseline_for "$category")"
        if [ "$count" -gt "$base" ]; then
            violations="${violations}  $category: $count > $base (baseline)"$'\n'
        fi
    done < <(command cut -f3 "$SCAN_OUT" | command sort -u)
    if [ -n "$violations" ]; then
        fail_test "new OKF findings beyond $BASELINE:"$'\n'"${violations}Fix the new memory, or raise the entry with a reason in the commit message."
    fi
}

# A count BELOW its baseline is fixed headroom: left in place, it would let the
# same number of new findings back in unnoticed. Fail so the fix is banked —
# `--regen` lowers the entry in the same commit that earned it.
test_baseline_is_tight() {
    scanner_ready || return 0
    local slack="" category base count
    while read -r category base; do
        case "$category" in '' | '#'*) continue ;; esac
        count="$(count_of "$category")"
        if [ "$count" -lt "$base" ]; then
            slack="${slack}  $category: $count < $base (baseline)"$'\n'
        fi
    done <"$BASELINE"
    if [ -n "$slack" ]; then
        fail_test "baseline is looser than the bundle — run tests/unit/okf-memory-bundle.sh --regen:"$'\n'"$slack"
    fi
}

# index_bytes FILE
index_bytes() {
    command wc -c <"$1" | command tr -d '[:space:]'
}

test_root_index_within_budget() {
    local bytes
    bytes="$(index_bytes "$BUNDLE/MEMORY.md")"
    if [ "$bytes" -gt "$ROOT_MAX" ]; then
        fail_test "MEMORY.md is $bytes bytes (budget $ROOT_MAX) — move topic-specific entries behind an index-<topic>.md"
    fi
}

test_subindexes_within_budget() {
    local f bytes over=""
    for f in "$BUNDLE"/index-*.md; do
        [ -f "$f" ] || continue
        bytes="$(index_bytes "$f")"
        if [ "$bytes" -gt "$SUB_MAX" ]; then
            over="${over}  $(command basename "$f"): $bytes bytes"$'\n'
        fi
    done
    if [ -n "$over" ]; then
        fail_test "sub-index(es) over $SUB_MAX bytes — split by topic:"$'\n'"$over"
    fi
}

# Every sub-index is reachable from the root. The scanner's orphan check covers
# CONCEPTS, but an index-<topic>.md that MEMORY.md never links is itself an
# island: its concepts are "indexed" and still never recalled.
test_every_subindex_linked_from_root() {
    local f name missing=""
    for f in "$BUNDLE"/index-*.md; do
        [ -f "$f" ] || continue
        name="$(command basename "$f")"
        command grep -qF "]($name)" "$BUNDLE/MEMORY.md" || missing="$missing $name"
    done
    if [ -n "$missing" ]; then
        fail_test "sub-index(es) not linked from MEMORY.md:$missing"
    fi
}

if [ "$REGEN" = true ]; then
    if [ ! -f "$SCANNER" ]; then
        command echo "okf-memory-bundle: scanner not found at $SCANNER" >&2
        exit 2
    fi
    run_scan
    [ "$SCAN_RC" -eq 0 ] || {
        command echo "okf-memory-bundle: scanner failed (exit $SCAN_RC)" >&2
        exit 2
    }
    {
        command echo "# OKF memory-bundle finding ratchet (tests/unit/okf-memory-bundle.sh)."
        command echo "#"
        command echo "# Per-category counts frozen at their present value: a count ABOVE its entry"
        command echo "# fails, an unlisted category is an implicit 0. RAISING an entry is a"
        command echo "# deliberate, reviewable diff that wants a reason in the commit message."
        command echo "# Graph-health categories are never listed here -- they are a hard zero."
        command echo "#"
        command echo "# Regenerate with: tests/unit/okf-memory-bundle.sh --regen"
        command echo ""
        command cut -f3 "$SCAN_OUT" | command sort | command uniq -c |
            command awk -v hz=" $HARD_ZERO " 'index(hz, " " $2 " ") == 0 { print $2, $1 }'
    } >"$BASELINE"
    command rm -f "$SCAN_OUT"
    command echo "Baseline regenerated: $BASELINE"
    exit 0
fi

run_test test_graph_health_is_clean "every memory is named by exactly one index, and every index line resolves"
run_test test_no_new_conformance_findings "no OKF findings beyond the frozen baseline"
run_test test_baseline_is_tight "the baseline is not looser than the bundle (fixes are banked)"
run_test test_root_index_within_budget "MEMORY.md stays within its byte budget"
run_test test_subindexes_within_budget "each index-<topic>.md stays within its byte budget"
run_test test_every_subindex_linked_from_root "every index-<topic>.md is linked from MEMORY.md"

[ -n "$SCAN_OUT" ] && command rm -f "$SCAN_OUT"
generate_report
