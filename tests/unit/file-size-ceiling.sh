#!/usr/bin/env bash
# Unit tests for the file-size ratchet policy (issue #832).
#
# THE PROBLEM THIS EXISTS TO SOLVE. The adversarial pre-PR review's
# decomposition dimension is GROWTH-GRADED by design
# (check-decomposition/thresholds.yml → review_size_thresholds.growth_min_added:
# 50): a file already 4x over threshold that a PR touches lightly is reported
# LOW/informational forever. That is the right call for a per-PR gate — one that
# fires on a large share of PRs gets turned off, and then catches nothing — but
# it means files ratchet UPWARD and never come back down. Ten files on main
# reached 900-2,545 lines that way, and PR #829 raised one of them in two
# separate review cycles, correctly non-blocking both times.
#
# A growth-graded lens structurally cannot serve as the ceiling. This check is
# the ceiling, and it is deliberately NOT growth-graded.
#
# THE DESIGN: A GRANDFATHERED RATCHET, NOT A FLAT CAP. A bare "no file over 900"
# either fails on day one against every known offender, or has to be set above
# 2,545 and catches nothing. So:
#
#   - A file NOT in the allowlist may not cross CEILING_LINES. Full stop.
#   - A file IN the allowlist carries its line count at the time of grandfathering
#     as its personal maximum. It may shrink freely; growing past that number
#     fails. This is the ratchet: the population can only get smaller.
#   - A file in the allowlist that drops BELOW the ceiling fails with
#     "remove from the allowlist". Without this arm the allowlist would rot —
#     entries would outlive the problem and quietly re-authorise regrowth up to
#     a stale number. With it, the list is self-emptying: each split PR that
#     lands takes its own entry with it, and the list reaches zero on its own.
#
# The allowlist is expected to SHRINK to empty as issue #832's follow-up PRs
# land. It is not a permanent exemption list; every entry is a tracked debt —
# with one deliberate exception class. A file that is ASSESSED AND DECLINED
# (measured under the audit lens's production-LOC budget, but still over this
# check's TOTAL-line ceiling) stays listed permanently as a measurement
# artifact, not as debt. It cannot reach the self-emptying arm without
# extracting its own tests, which is not a change worth making to satisfy a
# line count. See the crates/luggage/src/resolver.rs entry (#845) for the
# worked example.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "File size ceiling tests"

# The hard ceiling, in total lines. Matches issue #832's own "over 900" framing.
#
# Measured on TOTAL lines rather than the production-LOC engine the audit lens
# uses, deliberately: this check must be cheap, dependency-free, and trivially
# auditable by a human reading the failure message. Production LOC is the right
# unit for "is this file well-decomposed?"; total lines is the right unit for
# "did this file grow?", which is the only question here.
CEILING_LINES=900

# Grandfathered files: "path:max_lines". Each entry is the file's line count
# when issue #832 catalogued it. See the header for the three rules.
#
# tests/unit/runtime/workspace-fs-health.sh is deliberately ABSENT — #832 split
# it below the ceiling, which is what every entry below is expected to become.
GRANDFATHERED=(
    "tests/unit/features/claude-code-setup.sh:2545"
    "tests/unit/bin/update-versions.sh:1615"
    # SPLIT AND RATCHETED DOWN (#843). Was worktree.rs:1600; the module became a
    # directory (worktree/mod.rs + worktree/sync.rs) with the git CLI layer
    # lifted out to agent/git.rs, so the path changed and the max drops 1600 ->
    # 996. The split did its real job on the audit lens: 437 -> 287 production
    # LOC (under the 300 warning bar) and 29 -> 20 top-level units, clearing both
    # the file-length and god-module findings.
    #
    # It stays listed only because CEILING_LINES counts TOTAL lines, and 996 is
    # still over 900 — the remainder is a co-located `#[cfg(test)] mod tests`,
    # which is idiomatic Rust and not worth extracting to chase this number
    # (same reasoning as the resolver.rs entry below). Genuine further
    # decomposition would have to come from splitting production concerns, and
    # the audit lens no longer asks for any.
    "crates/stibbons/src/agent/worktree/mod.rs:996"
    "tests/unit/features/dev-tools.sh:1457"
    "tests/unit/runtime/entrypoint.sh:1309"
    "crates/stibbons/src/agent/commands.rs:955"
    # ASSESSED AND DECLINED (#845) — NOT a pending split. This entry is
    # retained for a measurement reason only, and is the one entry below that
    # is not tracked debt.
    #
    # The #832 sweep ranked candidates by TOTAL lines. Measured the way the
    # audit lens actually measures (check-decomposition/loc_engine.py), this
    # file is 271 PRODUCTION LOC against that lens's budget of 300 warning /
    # 500 high (thresholds.yml § size_thresholds.production_loc, which has no
    # per-language override) — under the warning bar, and
    # check-decomposition/patterns.py emits no file-length finding for it at
    # all. The 958 is a 541-line co-located `#[cfg(test)] mod tests` counted
    # against the production body.
    #
    # It stays listed because CEILING_LINES is measured on TOTAL lines by
    # deliberate design (see the header above): at 958 total it is over the
    # 900 ceiling, so removing this entry would fail
    # test_no_ungrandfathered_file_over_ceiling. The self-emptying arm only
    # fires below 900, which this file cannot reach without extracting its
    # tests — rejected in #845, since co-located tests are idiomatic Rust and
    # this repo's dominant convention. Do not "fix" that by moving the tests.
    "crates/luggage/src/resolver.rs:958"
    "tests/unit/gitlab-templates.sh:943"
)

# Directories swept, and the extensions swept within them.
SCAN_DIRS=("tests" "lib" "bin" "crates")

# _allowed_max — echo the grandfathered maximum for a repo-relative path, or
# empty when the path is not grandfathered.
_allowed_max() {
    local path="$1" entry
    for entry in "${GRANDFATHERED[@]}"; do
        if [ "${entry%%:*}" = "$path" ]; then
            command printf '%s\n' "${entry##*:}"
            return 0
        fi
    done
    return 0
}

# _scan_files — emit every swept file as a repo-relative path.
_scan_files() {
    local dir
    for dir in "${SCAN_DIRS[@]}"; do
        [ -d "$PROJECT_ROOT/$dir" ] || continue
        command find "$PROJECT_ROOT/$dir" \
            -type f \( -name '*.sh' -o -name '*.rs' \) \
            -not -path '*/target/*' \
            -not -path '*/.git/*' \
            -print
    done | command sed "s|^$PROJECT_ROOT/||" | command sort
}

# A file over the ceiling must be either split or grandfathered. This is the
# arm that stops the ratchet resuming on a file nobody has catalogued.
test_no_ungrandfathered_file_over_ceiling() {
    local violations=0 path lines allowed
    while IFS= read -r path; do
        lines=$(command wc -l <"$PROJECT_ROOT/$path")
        lines=$((lines))
        [ "$lines" -le "$CEILING_LINES" ] && continue

        allowed=$(_allowed_max "$path")
        if [ -z "$allowed" ]; then
            assert_true false \
                "$path is $lines lines, over the $CEILING_LINES-line ceiling. Split it, or add it to GRANDFATHERED with a tracked issue."
            violations=$((violations + 1))
        fi
    done < <(_scan_files)

    if [ "$violations" -eq 0 ]; then
        assert_true true "no un-grandfathered file exceeds $CEILING_LINES lines"
    fi
}

# A grandfathered file may shrink but never grow. This is the ratchet itself.
test_grandfathered_files_do_not_grow() {
    local violations=0 entry path allowed lines
    for entry in "${GRANDFATHERED[@]}"; do
        path="${entry%%:*}"
        allowed="${entry##*:}"

        if [ ! -f "$PROJECT_ROOT/$path" ]; then
            assert_true false \
                "GRANDFATHERED lists $path, which does not exist. Remove the stale entry."
            violations=$((violations + 1))
            continue
        fi

        lines=$(command wc -l <"$PROJECT_ROOT/$path")
        lines=$((lines))
        if [ "$lines" -gt "$allowed" ]; then
            assert_true false \
                "$path grew to $lines lines, past its grandfathered maximum of $allowed. Split it rather than raising the number."
            violations=$((violations + 1))
        fi
    done

    if [ "$violations" -eq 0 ]; then
        assert_true true "no grandfathered file has grown past its recorded maximum"
    fi
}

# A file that has come back under the ceiling must leave the allowlist, so the
# list cannot outlive the debt it records.
test_grandfathered_entries_retire_when_fixed() {
    local violations=0 entry path allowed lines
    for entry in "${GRANDFATHERED[@]}"; do
        path="${entry%%:*}"
        allowed="${entry##*:}"
        [ -f "$PROJECT_ROOT/$path" ] || continue

        lines=$(command wc -l <"$PROJECT_ROOT/$path")
        lines=$((lines))
        if [ "$lines" -le "$CEILING_LINES" ]; then
            assert_true false \
                "$path is now $lines lines, under the $CEILING_LINES-line ceiling. Remove it from GRANDFATHERED (recorded max was $allowed)."
            violations=$((violations + 1))
        fi
    done

    if [ "$violations" -eq 0 ]; then
        assert_true true "every grandfathered entry still exceeds the ceiling"
    fi
}

# The allowlist is a debt register, so a duplicate entry (two maxima for one
# file) would make the ratchet's verdict depend on iteration order.
test_grandfathered_list_has_no_duplicates() {
    local paths dupes
    paths=$(command printf '%s\n' "${GRANDFATHERED[@]}" | command cut -d: -f1 | command sort)
    dupes=$(command printf '%s\n' "$paths" | command uniq -d)

    assert_empty "$dupes" "GRANDFATHERED must list each path at most once"
}

run_test test_no_ungrandfathered_file_over_ceiling "no un-grandfathered file exceeds the ceiling"
run_test test_grandfathered_files_do_not_grow "grandfathered files do not grow past their recorded maximum"
run_test test_grandfathered_entries_retire_when_fixed "grandfathered entries retire once under the ceiling"
run_test test_grandfathered_list_has_no_duplicates "GRANDFATHERED lists each path at most once"

generate_report
