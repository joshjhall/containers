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
# WHAT IS COUNTED: PRODUCTION LOC, NOT TOTAL LINES (#873).
#
# This check originally measured `wc -l`, which counts a file's own tests and
# comments against its budget. That is the wrong unit, and the evidence was
# unambiguous: every one of the eight files grandfathered under the total-line
# ceiling was under 900 PRODUCTION LOC, most by an order of magnitude
# (update-versions.sh: 1,615 total, 38 production). The allowlist was not
# tracking oversized files. It was tracking files with thorough test suites and
# thorough comments — the two things a ratchet should never penalize.
#
# The failure mode that made it concrete: #845 assessed resolver.rs and declined
# the split (271 production LOC, comfortably inside budget), and #843 genuinely
# split worktree.rs (437 -> 287 production LOC, clearing both audit findings).
# Neither could retire its entry, because both files were still over 900 TOTAL.
# A check that cannot register success is measuring the wrong thing.
#
# So a line is counted only if it is not blank, not a comment, and not inside a
# co-located test region. Co-located `#[cfg(test)]` tests are idiomatic Rust and
# this repo's dominant convention; extracting them to satisfy a line count was
# explicitly rejected in #845, and this check no longer asks anyone to.
#
# THE DESIGN: A FORWARD-LOOKING CAP WITH A RATCHET STILL AVAILABLE.
#
#   - A file NOT in the allowlist may not cross CEILING_LINES. Full stop.
#   - A file IN the allowlist carries its production LOC at the time of
#     grandfathering as its personal maximum. It may shrink freely; growing past
#     that number fails. The population can only get smaller.
#   - A file in the allowlist that drops BELOW the ceiling fails with
#     "remove from the allowlist". Without this arm the allowlist would rot —
#     entries would outlive the problem and quietly re-authorise regrowth up to
#     a stale number. With it, the list is self-emptying.
#
# THE ALLOWLIST IS EMPTY. All eight total-line entries are gone (#873) — none
# was ever a real offender. The one entry #873 added in their place (617
# production LOC) turned out to be a counting artifact too: a test module gated
# `#[cfg(all(test, unix))]` that the metric did not recognise as tests (#874).
# The check stops penalizing well-tested, well-commented files and catches
# genuinely large ones; an entry here is a real debt with a tracked issue, and
# should stay rare.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "File size ceiling tests"

# The hard ceiling, in PRODUCTION LOC (see the header for why not total lines).
#
# 500 is not a new number: it is `size_thresholds.production_loc.high` from
# check-decomposition/thresholds.yml — the audit lens's existing high bar, which
# check-decomposition/patterns.py already applies repo-wide. Reusing it keeps one
# number with one meaning, instead of a second unrelated threshold that drifts.
#
# The measurement is ported into awk below rather than shelling out to that
# engine, deliberately: this check must stay cheap, dependency-free, and
# trivially auditable by a human reading the failure message. It runs in CI paths
# where neither python3 nor /opt/librarian is guaranteed.
CEILING_LINES=500

# Grandfathered files: "path:max_production_loc". See the header for the rules.
#
# All EIGHT total-line entries are gone (#873) — every one measured under 900
# production LOC once its own tests and comments stopped counting against it, so
# none was ever a real offender.
#
# The one entry #873 added — script_installer.rs at "617 production LOC" — was
# also a measurement artifact, not an offender: its test module is gated
# `#[cfg(all(test, unix))]`, which neither this port nor the engine recognised
# as test code. Counted correctly it is 45 (#874), so the list is empty again.
#
# Add an entry only for a genuine offender with a tracked issue, in the form
# "path:N" where N is its production LOC at the time of grandfathering.
GRANDFATHERED=()

# Directories swept, and the extensions swept within them.
SCAN_DIRS=("tests" "lib" "bin" "crates")

# _allowed_max — echo the grandfathered maximum for a repo-relative path, or
# empty when the path is not grandfathered.
_allowed_max() {
    local path="$1" entry
    for entry in ${GRANDFATHERED[@]+"${GRANDFATHERED[@]}"}; do
        if [ "${entry%%:*}" = "$path" ]; then
            command printf '%s\n' "${entry##*:}"
            return 0
        fi
    done
    return 0
}

# _production_loc — echo a file's production LOC: total lines minus blanks,
# comments, and any co-located test region.
#
# Transcribed from check-decomposition/loc_engine.py's `measure()` so the two
# lenses agree on what a "line" means, but implemented in awk so this check keeps
# no python3 / librarian dependency.
#
# Rules, in the order awk applies them per line:
#
#   1. TRAILING TEST REGION (rs). A column-zero `#[cfg(test)]` introducing a
#      `mod` BLOCK excludes everything to EOF — the conventional trailing
#      placement. Two traps, both found by differential-testing this port
#      against the engine over all 610 swept files:
#        - Column zero matters. An INDENTED `#[cfg(test)]` is a nested test
#          module already inside a production item; treating it as a whole-file
#          marker swallows every production item after it (#727 upstream).
#        - It must introduce a BLOCK, not a one-line `#[cfg(test)] mod foo;`
#          declaration. crates/stibbons/src/main.rs has exactly that on line 18;
#          a naive to-EOF rule scored the file 6 production LOC instead of 111.
#   2. PER-UNIT TEST ATTRIBUTES (rs). A standalone `tests/*.rs` integration file
#      has no trailing region at all — every fn carries its own `#[test]`. Such
#      a unit is excluded from its attribute to the line before the next
#      column-zero item. Without this arm crates/luggage/tests/cli.rs scored 456
#      instead of 42. The two attributes differ on their OWN line, because the
#      engine reaches them by different paths: a `#[test]` line counts (spans
#      start at the fn header, so it belongs to the preceding unit), while a
#      column-zero `#[cfg(test)]` does not (it also matches the whole-file
#      region regex, whose span starts at the marker).
#   3. PER-UNIT TEST FUNCTIONS (sh). A shell suite likewise has no trailing
#      region: its `test_foo()` functions are interleaved with helpers all the
#      way down, so a banner rule alone excludes nothing. Each column-zero
#      `test_*()` is excluded to the line before the next column-zero unit
#      header. Without this arm tests/unit/bin/update-versions.sh scored 1151
#      instead of 38.
#   4. TEST BANNER (sh). A `# --- tests ---` banner excludes to EOF.
#   5. BLANK. Whitespace-only.
#   6. COMMENT. A leading `//`, `/*` or `*` for rs; a leading `#` for sh.
#
# Matching is pinned to [ \t] rather than awk's locale-dependent whitespace
# classes so the count is stable regardless of LC_ALL, matching the upstream
# engine's own reasoning about exotic whitespace.
#
# KNOWN FALSE NEGATIVE, inherited from the engine and accepted: a PRODUCTION
# function literally named `test_*()` is excluded as if it were a test. Three
# files do this (bin/test-version-compatibility.sh, bin/test-completions.sh,
# bin/lib/validate-backups/checks.sh); loc_engine.py excludes exactly the same
# lines, so this port matches rather than diverges, and all three sit far under
# the ceiling either way. The exposure is that such a file could hide production
# bulk behind the naming convention. Accepted because matching the audit lens is
# worth more than a stricter private rule — but if a `test_*`-heavy production
# file ever approaches the ceiling, revisit this.
#
# PARITY: differential-tested against loc_engine.py over all 610 swept files.
# 2 files still differ — template/mod.rs (6 vs 3) and luggage/tests/install_rust.rs
# (84 vs 85) — both on the engine's unit-span model for a `#[cfg(test)] mod foo;`
# declaration, which cannot be reproduced line-at-a-time without reimplementing
# that model; every approximation tried traded these two for a different pair.
# Both files sit 400+ LOC under the ceiling, so neither gap can flip a verdict.
#
# ONE DELIBERATE DIVERGENCE (#874): wherever a rule above says `#[cfg(test)]`,
# this port also accepts `#[cfg(all(…, test, …))]` (see `cfg_test` in the awk).
# The engine matches only the literal `#[cfg(test)]`, so it scores the 4 files
# that gate their tests `#[cfg(all(test, unix))]` higher than this port does —
# script_installer.rs most of all (engine 617, here 45). The engine is wrong
# there, not this port; the upstream fix is joshjhall/librarian#1221 — once it
# lands, this divergence (and this paragraph) goes away.
# Two accepted limits, both erring toward OVER-counting (never hiding code): a
# sibling conjunct nested two levels deep (`all(test, any(unix, not(x)))`) and
# an attribute rustfmt has wrapped across lines are scored as production.
# The synthetic-fixture test at the bottom of this file pins each rule above with
# values taken from the engine, so a future edit cannot silently regress them.
_production_loc() {
    local path="$1" lang
    case "$path" in
        # Quoted because `sh` is also a command name: an unquoted `lang=sh`
        # reads to shellcheck as a mistaken command substitution (SC2209).
        *.rs) lang="rs" ;;
        *) lang="sh" ;;
    esac

    command awk -v lang="$lang" '
        # A test-only cfg: `#[cfg(test)]`, or `#[cfg(all(…, test, …))]` with
        # `test` as a top-level conjunct — `all` with `test` in it compiles only
        # under test, so it is test code too (#874). A test module gated
        # `#[cfg(all(test, unix))]` was counted as production in full: 617 LOC
        # for a file whose production code is 45. `any(test, …)` and
        # `not(test)` are deliberately NOT matched — both compile into non-test
        # builds, so they stay production. Defined once, here, so the region
        # arm and the per-unit arm below cannot drift apart.
        # A sibling conjunct (`sib`) may hold one level of parens, so
        # `all(test, not(windows))` matches; `test` must be a WHOLE conjunct,
        # so `all(unix, not(test))` and `all(unix, any(test, x))` do not.
        BEGIN {
            sib = "([^(),]|\\([^()]*\\))*"
            cfg_test = "^#\\[cfg\\((test|all\\((" sib ",)*[ \t]*test[ \t]*(," sib ")*\\))\\)\\]"
        }

        # --- rs: trailing `#[cfg(test)] mod … {` region, to EOF -------------
        # Armed by a column-zero `#[cfg(test)]`, but only fires once the next
        # line proves it introduces a `mod … {` BLOCK — the conventional
        # trailing placement — rather than a `mod foo;` one-line declaration.
        # crates/stibbons/src/main.rs:18 is exactly that declaration, and a
        # naive to-EOF rule scored the file 6 production LOC instead of 111.
        #
        # A `#[cfg(test)] mod foo;` DECLARATION is therefore not treated as a
        # region at all. The engine does extend such a unit to the next item,
        # which is the single accepted residual below (template/mod.rs, 5 vs 3);
        # matching it exactly needs the engine'"'"'s full unit-span model, and
        # every attempt to approximate it here traded that 2-line gap for a new
        # one elsewhere. Both files sit ~500 LOC under the ceiling.
        lang == "rs" && cfg_armed {
            cfg_armed = 0
            if ($0 ~ /^mod[ \t]+[A-Za-z0-9_]+[ \t]*\{/) { in_tests = 1 }
        }
        lang == "rs" && !in_tests && $0 ~ cfg_test { cfg_armed = 1 }

        # --- sh: `# --- tests ---` banner, to EOF ---------------------------
        lang == "sh" && !in_tests && /^#[ \t]*-+[ \t]*[Tt]ests?[ \t]*-+/ { in_tests = 1 }
        in_tests { next }

        # --- rs: per-unit `#[test]` / `#[cfg(test)]` attributes -------------
        # A test attribute marks the unit that FOLLOWS it, so the exclusion must
        # survive that unit'"'"'s own header line and end only at the NEXT
        # column-zero item. `just_marked` carries the flag across the header the
        # attribute introduced; without it the header itself cleared the flag and
        # every test body was counted (agent_integration.rs: 42 vs 3).
        # The attribute LINE itself is NOT part of the unit it marks: the
        # engine'"'"'s spans start at the `fn`/`mod` header, so an attribute
        # belongs to whatever unit PRECEDES it and counts as production when
        # that one is production. So the exclusion is armed here and only takes
        # effect from the next line (`pending_test`), rather than set directly —
        # setting it here skipped the attribute line itself and undercounted
        # every production-to-test boundary (luggage/tests/cli.rs: 40 vs 42).
        # ...with one asymmetry between the two attributes, which the engine
        # creates by handling them on different code paths:
        #   `#[test]`      — no region rule matches it, so the line counts
        #                    (it belongs to the preceding unit).
        #   `#[cfg(test)]` — a COLUMN-ZERO one also matches the engine'"'"'s
        #                    whole-file region regex, whose span starts at the
        #                    MARKER, so the line is excluded.
        # Hence `#[cfg(test)]` skips its own line and `#[test]` does not.
        lang == "rs" && $0 ~ cfg_test { pending_test = 1; next }
        lang == "rs" && /^#\[test\]/ { pending_test = 1 }
        lang == "rs" && pending_test && !/^#\[(test|cfg\(test\))/ && $0 !~ cfg_test {
            pending_test = 0; in_test_unit = 1; just_marked = 1
        }
        lang == "rs" && /^(pub[ \t]|pub\(|async[ \t]|unsafe[ \t]|extern[ \t]|fn[ \t]|mod[ \t]|struct[ \t]|enum[ \t]|impl[ \t<]|trait[ \t]|const[ \t]|static[ \t]|type[ \t]|use[ \t]|macro_rules!)/ {
            if (just_marked) { just_marked = 0 } else { in_test_unit = 0 }
        }
        lang == "rs" && in_test_unit { next }

        # --- sh: per-unit `test_*()` functions ------------------------------
        lang == "sh" && /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*\)/ {
            in_test_fn = /^test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)/ ? 1 : 0
        }
        lang == "sh" && /^function[ \t]+test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)/ { in_test_fn = 1 }
        in_test_fn { next }

        /^[ \t]*$/ { next }                                   # blank
        lang == "rs" && /^[ \t]*(\/\/|\/\*|\*)/ { next }      # rust comment
        lang == "sh" && /^[ \t]*#/ { next }                   # shell comment

        { n++ }
        END { print n + 0 }
    ' "$path"
}

# _scan_files — emit every swept file as a repo-relative path.
#
# Enumeration comes from git's index, not from a filesystem walk, because the
# index is the only CASE-EXACT view of the tree.
#
# On a case-insensitive mount (macOS/Windows hosts — see
# docs/troubleshooting/case-sensitive-filesystems.md) a single directory can
# surface under two spellings that share one inode: `crates/luggage/src/installer`
# and `crates/luggage/src/Installer` are the same 36 files, listed twice. `find`
# walks both spellings and emits each file twice, and the phantom capital-letter
# path then misses its GRANDFATHERED entry — which keys on the real, lowercase
# path — so the ceiling arm failed on a file that is correctly catalogued. The
# shadow cannot be deleted to fix this: it IS the tracked file, same inode, so
# removing it removes the real one.
#
# `git ls-files` reports the one spelling git actually tracks, identically on
# every platform, which is also the spelling CI sees. It additionally drops the
# ~4,800 ignored scratch files under tests/results/ that the walk was silently
# measuring.
#
# -z, and `read -d ""`, because git quotes unusual paths in its default output
# and this check must not care what a filename contains.
#
# The `find` fallback is retained for a non-git checkout (a source tarball, or a
# fixture directory in this suite's own tests). There is no case-shadow risk
# there: the shadow is a property of the host mount, and a tree with no index to
# disagree with has no second spelling to prefer.
_scan_files() {
    local dir path
    if command git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r -d '' path; do
            case "$path" in
                *.sh | *.rs) ;;
                *) continue ;;
            esac
            command printf '%s\n' "$path"
        done < <(command git -C "$PROJECT_ROOT" ls-files -z -- "${SCAN_DIRS[@]}") | command sort
        return 0
    fi

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
    local violations=0 path lines allowed scanned=0
    while IFS= read -r path; do
        scanned=$((scanned + 1))
        lines=$(_production_loc "$PROJECT_ROOT/$path")
        [ "$lines" -le "$CEILING_LINES" ] && continue

        allowed=$(_allowed_max "$path")
        if [ -z "$allowed" ]; then
            assert_true false \
                "$path is $lines production LOC (excluding comments and co-located tests), over the $CEILING_LINES ceiling. Split it, or add it to GRANDFATHERED with a tracked issue."
            violations=$((violations + 1))
        fi
    done < <(_scan_files)

    # An enumeration that returns nothing would make every arm above vacuously
    # true — the check would report a clean sweep having measured no files at
    # all. The repo has hundreds of swept files, so anything near zero means the
    # enumerator broke, not that the tree shrank.
    if [ "$scanned" -lt 100 ]; then
        assert_true false \
            "_scan_files enumerated only $scanned files; the sweep is broken, not clean."
        return
    fi

    if [ "$violations" -eq 0 ]; then
        assert_true true "no un-grandfathered file exceeds $CEILING_LINES production LOC"
    fi
}

# The ratchet's verdicts, as pure functions of (root, ceiling, entries) so they
# can be driven against fixtures. With GRANDFATHERED empty (#874) the arms below
# loop over nothing and pass vacuously, so these helpers are the only place the
# grow / retire / stale / duplicate logic is actually exercised — see
# test_ratchet_helpers_on_fixtures. Each prints one line per violation.

# _ratchet_grown ROOT ENTRY... — "missing:PATH" or "grew:PATH:LINES:ALLOWED".
_ratchet_grown() {
    local root="$1" entry path allowed lines
    shift
    for entry in "$@"; do
        path="${entry%%:*}"
        allowed="${entry##*:}"
        if [ ! -f "$root/$path" ]; then
            command printf 'missing:%s\n' "$path"
            continue
        fi
        lines=$(_production_loc "$root/$path")
        if [ "$lines" -gt "$allowed" ]; then
            command printf 'grew:%s:%s:%s\n' "$path" "$lines" "$allowed"
        fi
    done
}

# _ratchet_retired ROOT CEILING ENTRY... — "PATH:LINES:ALLOWED" per entry that
# has come back under the ceiling. A missing file is _ratchet_grown's verdict.
_ratchet_retired() {
    local root="$1" ceiling="$2" entry path allowed lines
    shift 2
    for entry in "$@"; do
        path="${entry%%:*}"
        allowed="${entry##*:}"
        [ -f "$root/$path" ] || continue
        lines=$(_production_loc "$root/$path")
        if [ "$lines" -le "$ceiling" ]; then
            command printf '%s:%s:%s\n' "$path" "$lines" "$allowed"
        fi
    done
}

# _ratchet_duplicates ENTRY... — each path listed more than once.
_ratchet_duplicates() {
    [ "$#" -eq 0 ] && return 0
    command printf '%s\n' "$@" | command cut -d: -f1 | command sort | command uniq -d
}

# A grandfathered file may shrink but never grow. This is the ratchet itself.
test_grandfathered_files_do_not_grow() {
    local violations=0 row kind path lines allowed
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        kind="${row%%:*}"
        row="${row#*:}"
        path="${row%%:*}"
        if [ "$kind" = "missing" ]; then
            assert_true false \
                "GRANDFATHERED lists $path, which does not exist. Remove the stale entry."
        else
            row="${row#*:}"
            lines="${row%%:*}"
            allowed="${row##*:}"
            assert_true false \
                "$path grew to $lines production LOC, past its grandfathered maximum of $allowed. Split it rather than raising the number."
        fi
        violations=$((violations + 1))
    done <<<"$(_ratchet_grown "$PROJECT_ROOT" ${GRANDFATHERED[@]+"${GRANDFATHERED[@]}"})"

    if [ "$violations" -eq 0 ]; then
        assert_true true "no grandfathered file has grown past its recorded maximum"
    fi
}

# A file that has come back under the ceiling must leave the allowlist, so the
# list cannot outlive the debt it records.
test_grandfathered_entries_retire_when_fixed() {
    local violations=0 row path lines allowed
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        path="${row%%:*}"
        row="${row#*:}"
        lines="${row%%:*}"
        allowed="${row##*:}"
        assert_true false \
            "$path is now $lines production LOC, under the $CEILING_LINES ceiling. Remove it from GRANDFATHERED (recorded max was $allowed)."
        violations=$((violations + 1))
    done <<<"$(_ratchet_retired "$PROJECT_ROOT" "$CEILING_LINES" ${GRANDFATHERED[@]+"${GRANDFATHERED[@]}"})"

    if [ "$violations" -eq 0 ]; then
        assert_true true "every grandfathered entry still exceeds the ceiling"
    fi
}

# The allowlist is a debt register, so a duplicate entry (two maxima for one
# file) would make the ratchet's verdict depend on iteration order.
test_grandfathered_list_has_no_duplicates() {
    assert_empty "$(_ratchet_duplicates ${GRANDFATHERED[@]+"${GRANDFATHERED[@]}"})" \
        "GRANDFATHERED must list each path at most once"
}

# The ratchet helpers on a fixture tree. GRANDFATHERED is empty, so without this
# the three arms above assert nothing about their own logic: an inverted
# comparison or a broken `path:max` split would stay green. Each case is built
# to land on exactly one side of its boundary.
test_ratchet_helpers_on_fixtures() {
    local tmp
    tmp=$(command mktemp -d)
    # shellcheck disable=SC2064  # expand $tmp now, not at trap time
    trap "command rm -rf '$tmp'" RETURN

    # 6 production LOC each (two 3-line fns), in a path with a space so a
    # word-splitting expansion of the entries would be caught.
    command mkdir -p "$tmp/a dir"
    command printf '%s\n' 'fn a() {' '    let x = 1;' '}' 'fn b() {' '    let y = 2;' '}' \
        >"$tmp/a dir/six.rs"
    command cp "$tmp/a dir/six.rs" "$tmp/other.rs"

    # grow: at the recorded max is fine; one over it is a violation.
    assert_empty "$(_ratchet_grown "$tmp" "a dir/six.rs:6")" \
        "a file exactly at its recorded max has not grown"
    assert_equals "grew:a dir/six.rs:6:5" "$(_ratchet_grown "$tmp" "a dir/six.rs:5")" \
        "a file one line past its recorded max is reported as grown"
    assert_equals "missing:gone.rs" "$(_ratchet_grown "$tmp" "gone.rs:9")" \
        "a grandfathered path that does not exist is reported as stale"

    # retire: at or under the ceiling must retire; one over it stays.
    assert_equals "a dir/six.rs:6:9" "$(_ratchet_retired "$tmp" 6 "a dir/six.rs:9")" \
        "a file exactly at the ceiling must leave the allowlist"
    assert_empty "$(_ratchet_retired "$tmp" 5 "a dir/six.rs:9")" \
        "a file still over the ceiling stays grandfathered"
    assert_empty "$(_ratchet_retired "$tmp" 6 "gone.rs:9")" \
        "a missing file is the grow arm's verdict, not the retire arm's"

    # duplicates: same path twice (different maxima) is flagged; distinct
    # paths and the empty list are not.
    assert_equals "a dir/six.rs" "$(_ratchet_duplicates "a dir/six.rs:6" "other.rs:6" "a dir/six.rs:9")" \
        "a path listed twice is a duplicate"
    assert_empty "$(_ratchet_duplicates "a dir/six.rs:6" "other.rs:6")" \
        "distinct paths are not duplicates"
    assert_empty "$(_ratchet_duplicates)" \
        "an empty allowlist has no duplicates"
}

# The measurement engine itself, on synthetic fixtures.
#
# The three arms above only exercise _production_loc against whatever real files
# happen to be in the tree, which is incidental coverage: it moves when the repo
# moves, and it cannot pin a specific rule. Each case below is a trap that was
# ACTUALLY WRONG at some point while porting the awk from loc_engine.py, with
# the expected value taken from that engine. They are the regression net for the
# rules documented above _production_loc.
test_production_loc_edge_cases() {
    local tmp
    tmp=$(command mktemp -d)
    # shellcheck disable=SC2064  # expand $tmp now, not at trap time
    trap "command rm -rf '$tmp'" RETURN

    # A trailing `#[cfg(test)] mod tests { … }` block excludes to EOF.
    command printf '%s\n' \
        'pub fn real() {' '    let a = 1;' '}' \
        '#[cfg(test)]' 'mod tests {' '    fn t() {}' '}' >"$tmp/trailing.rs"
    assert_equals "3" "$(_production_loc "$tmp/trailing.rs")" \
        "a trailing #[cfg(test)] mod block is excluded to EOF"

    # An INDENTED #[cfg(test)] is a nested module, not a whole-file marker: it
    # must not swallow the production items that follow (#727 upstream).
    command printf '%s\n' \
        'mod outer {' '    #[cfg(test)]' '    mod inner {}' '}' \
        'pub fn after() {' '    let b = 2;' '}' >"$tmp/nested.rs"
    assert_equals "7" "$(_production_loc "$tmp/nested.rs")" \
        "an indented #[cfg(test)] does not trigger whole-file exclusion"

    # A one-line `#[cfg(test)] mod foo;` DECLARATION is not a trailing region.
    # Getting this wrong scored crates/stibbons/src/main.rs 6 LOC instead of 111.
    command printf '%s\n' \
        '#[cfg(test)]' 'mod test_support;' 'mod wizard;' \
        'fn main() {' '    let c = 3;' '}' >"$tmp/decl.rs"
    assert_equals "4" "$(_production_loc "$tmp/decl.rs")" \
        "a one-line #[cfg(test)] mod declaration does not exclude to EOF"

    # A per-unit #[test] excludes its fn, but the ATTRIBUTE line itself counts:
    # the engine's unit spans start at the fn header, so the attribute belongs
    # to the preceding (production) unit. Missing this undercounted every
    # production-to-test boundary.
    command printf '%s\n' \
        'fn helper() {' '    let a = 1;' '}' \
        '#[test]' 'fn t1() {' '    assert!(true);' '}' >"$tmp/attr.rs"
    assert_equals "4" "$(_production_loc "$tmp/attr.rs")" \
        "#[test] excludes its fn but the attribute line still counts"

    # A standalone `#[cfg(test)] fn` (no mod block) is excluded per-unit — and
    # unlike #[test], its attribute line does NOT count, because a column-zero
    # #[cfg(test)] also matches the engine's whole-file region regex.
    command printf '%s\n' \
        '#[cfg(test)]' 'fn helper() {' '    let x = 1;' '}' \
        'pub fn real() {' '    let y = 2;' '}' >"$tmp/cfgfn.rs"
    assert_equals "3" "$(_production_loc "$tmp/cfgfn.rs")" \
        "a cfg-gated test helper fn is excluded, attribute line included"

    # A compound `#[cfg(all(test, …))]` is test-only too, in either conjunct
    # order (#874). Missing this scored script_installer.rs 617 instead of 45.
    command printf '%s\n' \
        'pub fn real() {' '    let a = 1;' '}' \
        '#[cfg(all(test, unix))]' 'mod tests {' '    fn t() {}' '}' >"$tmp/all_test.rs"
    assert_equals "3" "$(_production_loc "$tmp/all_test.rs")" \
        "a trailing #[cfg(all(test, unix))] mod block is excluded to EOF"
    command printf '%s\n' \
        'pub fn real() {' '    let a = 1;' '}' \
        '#[cfg(all(unix, test))]' 'mod tests {' '    fn t() {}' '}' >"$tmp/all_test_rev.rs"
    assert_equals "3" "$(_production_loc "$tmp/all_test_rev.rs")" \
        "#[cfg(all(unix, test))] is excluded regardless of conjunct order"

    # ...but a one-line compound DECLARATION is still not a trailing region.
    command printf '%s\n' \
        '#[cfg(all(test, unix))]' 'mod test_support;' 'mod wizard;' \
        'fn main() {' '    let c = 3;' '}' >"$tmp/all_decl.rs"
    assert_equals "4" "$(_production_loc "$tmp/all_decl.rs")" \
        "a one-line #[cfg(all(test, unix))] mod declaration does not exclude to EOF"

    # `any(test, …)` and `not(test)` compile into NON-test builds, so they are
    # production: every line below counts, attribute lines included.
    command printf '%s\n' \
        '#[cfg(any(test, feature = "x"))]' 'mod m {' '    fn f() {}' '}' >"$tmp/any_test.rs"
    assert_equals "4" "$(_production_loc "$tmp/any_test.rs")" \
        "#[cfg(any(test, ...))] is production, not test code"
    command printf '%s\n' \
        '#[cfg(not(test))]' 'mod m {' '    fn f() {}' '}' >"$tmp/not_test.rs"
    assert_equals "4" "$(_production_loc "$tmp/not_test.rs")" \
        "#[cfg(not(test))] is production, not test code"

    # `test` nested inside a further combinator is not a top-level conjunct:
    # `all(unix, any(test, x))` compiles without test, so it counts.
    command printf '%s\n' \
        '#[cfg(all(unix, any(test, feature = "x")))]' 'mod m {' '    fn f() {}' '}' >"$tmp/nested_any.rs"
    assert_equals "4" "$(_production_loc "$tmp/nested_any.rs")" \
        "test nested under any() inside all() is production"
    command printf '%s\n' \
        '#[cfg(all(unix, not(test)))]' 'mod m {' '    fn f() {}' '}' >"$tmp/all_not_test.rs"
    assert_equals "4" "$(_production_loc "$tmp/all_not_test.rs")" \
        "test negated by not() inside all() is production"

    # A sibling conjunct may itself hold parens, and `test` may sit mid-list:
    # both are still test-only, so both mod blocks exclude (0 LOC).
    command printf '%s\n' \
        '#[cfg(all(test, not(windows)))]' 'mod m {' '    fn f() {}' '}' >"$tmp/all_nested_sib.rs"
    assert_equals "0" "$(_production_loc "$tmp/all_nested_sib.rs")" \
        "#[cfg(all(test, not(windows)))] is excluded despite the nested sibling"
    command printf '%s\n' \
        '#[cfg(all(unix, test, feature = "x"))]' 'mod m {' '    fn f() {}' '}' >"$tmp/all_mid.rs"
    assert_equals "0" "$(_production_loc "$tmp/all_mid.rs")" \
        "test as a middle conjunct of all() is excluded"

    # The per-unit arm takes the compound form too: a cfg-gated helper fn is
    # excluded exactly like the plain #[cfg(test)] case above.
    command printf '%s\n' \
        '#[cfg(all(test, unix))]' 'fn helper() {' '    let x = 1;' '}' \
        'pub fn real() {' '    let y = 2;' '}' >"$tmp/all_cfgfn.rs"
    assert_equals "3" "$(_production_loc "$tmp/all_cfgfn.rs")" \
        "a #[cfg(all(test, unix))] helper fn is excluded per-unit"

    # `test` must be a WHOLE conjunct: an identifier merely starting with it is
    # a production gate, so every line counts.
    command printf '%s\n' \
        '#[cfg(all(test_utils, unix))]' 'mod m {' '    fn f() {}' '}' >"$tmp/all_prefix.rs"
    assert_equals "4" "$(_production_loc "$tmp/all_prefix.rs")" \
        "all(test_utils, ...) is production: test must be a whole conjunct"

    # sh: a `test_*()` function is excluded; the next column-zero function ends
    # it. Missing this scored tests/unit/bin/update-versions.sh 1151 vs 38.
    command printf '%s\n' \
        'helper() {' '    echo hi' '}' \
        'test_thing() {' '    assert_true true' '}' \
        'another() {' '    echo bye' '}' >"$tmp/suite.sh"
    assert_equals "6" "$(_production_loc "$tmp/suite.sh")" \
        "sh test_*() bodies are excluded and end at the next function"

    # Blanks and comments never count, in either language.
    command printf '%s\n' \
        '// a comment' '' '   ' 'pub fn only() {' '    let z = 1;' '}' >"$tmp/noise.rs"
    assert_equals "3" "$(_production_loc "$tmp/noise.rs")" \
        "blanks and comments are excluded"
}

run_test test_production_loc_edge_cases "_production_loc handles the documented edge cases"
run_test test_no_ungrandfathered_file_over_ceiling "no un-grandfathered file exceeds the ceiling"
run_test test_grandfathered_files_do_not_grow "grandfathered files do not grow past their recorded maximum"
run_test test_grandfathered_entries_retire_when_fixed "grandfathered entries retire once under the ceiling"
run_test test_grandfathered_list_has_no_duplicates "GRANDFATHERED lists each path at most once"
run_test test_ratchet_helpers_on_fixtures "the ratchet's grow/retire/stale/duplicate logic, on fixtures"

generate_report
