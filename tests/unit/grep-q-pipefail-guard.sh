#!/usr/bin/env bash
# Guard: no `producer | grep -q` in tests/unit/ (issue #1097).
#
# THE BUG. Under `set -o pipefail`, `producer | grep -q P` races: grep -q exits
# on its first match, and a producer with output still unwritten takes SIGPIPE.
# The pipeline returns 141 and the assertion fails — or, behind `if !` or an
# error-detecting `if`, silently inverts. #1092 hit it in
# integration-ci-coverage.sh, and it surfaced only under scheduler load (the
# pre-push hook), never in an idle loop: 200 clean idle runs wrongly cleared it.
#
# WHY A BLANKET RULE, NOT A RISK JUDGMENT. Whether a given producer can exceed
# one pipe write depends on output it captures at run time; "small output, one
# write" is exactly the reasoning that cleared #1092. A rule with no exceptions
# is a one-line lint; a rule for "risky" sites needs a maintained exception
# list. The fix is mechanical and behavior-preserving:
#
#   command grep -q 'P' <<<"$x"                       # builtin echo/printf
#   body=$(producer || true); command grep -q 'P' <<<"$body"   # external
#
# THE ALLOWLIST IS A PHASE TRACKER, AND IT EMPTIES ITSELF. The 180-odd existing
# sites are converted one directory per PR (#1097 phases 2-6). Directories not
# yet converted are listed below; a site anywhere else fails. An allowlisted
# directory that reaches zero sites ALSO fails ("remove it"), so an entry cannot
# outlive its conversion and quietly re-authorize regrowth. Phase 7 deletes the
# empty array.
#
# Not matched: `grep -q X f || grep -q Y f` (no pipe, just `||`), comment lines,
# and the herestring idiom itself. This file builds its scanner fixtures from
# pieces, so it never contains the shape it rejects.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "grep -q pipefail guard"

UNIT_DIR="$PROJECT_ROOT/tests/unit"

# Directories under tests/unit/ not yet converted, keyed by first path segment;
# "." is the top-level tests/unit/*.sh files. Remove an entry in the PR that
# converts it — test_allowlist_is_not_stale fails until you do.
UNCONVERTED_DIRS=(. host observability runtime)

# pipe_grep_q_sites ROOT — prints "relpath:line" for every pipe into a grep
# whose short-option cluster carries q (or --quiet), optionally prefixed by
# `command` or a /usr/bin/ or /bin/ path. A line ending in `|` continues the
# pipe onto the next line, which is checked as the consumer.
pipe_grep_q_sites() {
    local root="$1"
    (cd "$root" && command find . -name '*.sh' -type f -exec /usr/bin/awk '
            function is_comment(s) { return s ~ /^[[:space:]]*#/ }
            # GREP_Q: a grep invocation whose flags include q, anchored where a
            # pipe consumer starts. No `|` precedes it in this regex; callers
            # supply that context. Any tokens may sit between grep and the q
            # flag (value-taking flags like -m1, -A 2, -e P), stopping at a
            # shell separator so a later command on the line is not blamed.
            BEGIN {
                grep_q = "(command[[:space:]]+|/usr/bin/|/bin/)?grep([[:space:]]+[^|;&[:space:]]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet)([[:space:]]|$)"
            }
            FNR == 1 { pending = 0 }
            {
                line = $0
                if (is_comment(line)) { pending = 0; next }
                if (pending && line ~ ("^[[:space:]]*" grep_q)) {
                    print substr(FILENAME, 3) ":" FNR
                    pending = 0
                    next
                }
                pending = 0
                # Same-line: a single | (not ||) followed by the consumer.
                if (line ~ ("(^|[^|])[|][[:space:]]*" grep_q)) {
                    print substr(FILENAME, 3) ":" FNR
                }
                # Trailing single | continues the pipe onto the next line.
                if (line ~ /(^|[^|])[|][[:space:]]*$/) { pending = 1 }
            }
        ' {} + || true)
}

# site_bucket RELPATH — first path segment under tests/unit, or "." for a
# top-level file.
site_bucket() {
    case "$1" in
        */*) command echo "${1%%/*}" ;;
        *) command echo "." ;;
    esac
}

is_unconverted() {
    local d
    for d in "${UNCONVERTED_DIRS[@]}"; do
        [ "$d" = "$1" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Test: the scanner flags each known shape and nothing else
#
# Guards the two real-tree tests from passing vacuously: if the regex stops
# matching, they would compare empty lists and report a clean tree forever.
# Fixture lines are assembled from pieces so this file holds no literal site.
# ---------------------------------------------------------------------------
test_scanner_detects_known_shapes() {
    local dir got p g
    dir=$(command mktemp -d)
    p='|'
    g='grep'
    {
        command printf 'echo "$x" %s command %s -q foo\n' "$p" "$g"                     # 1 flag
        command printf 'producer %s /usr/bin/%s -qxF foo\n' "$p" "$g"                   # 2 flag
        command printf 'producer %s %s -E -q foo\n' "$p" "$g"                           # 3 flag
        command printf 'producer %s %s --quiet foo\n' "$p" "$g"                         # 4 flag
        command printf 'if producer %s\n' "$p"                                          # 5
        command printf '    command %s -Fxq foo; then\n' "$g"                           # 6 flag
        command printf 'command %s -q a f %s%s command %s -q b f\n' "$g" "$p" "$p" "$g" # 7
        command printf '# echo x %s %s -q foo\n' "$p" "$g"                              # 8
        command printf 'command %s -q foo <<<"$x"\n' "$g"                               # 9
        command printf 'producer %s command %s -c foo\n' "$p" "$g"                      # 10
        command printf 'producer %s command %s -v foo\n' "$p" "$g"                      # 11
        command printf 'producer %s command %s -m1 -q foo\n' "$p" "$g"                  # 12 flag
        command printf 'producer %s command %s -A 2 -q foo\n' "$p" "$g"                 # 13 flag
        command printf 'producer %s command %s -e foo -q\n' "$p" "$g"                   # 14 flag
        command printf 'producer %s command %s -v "x -q"; y -q\n' "$p" "$g"             # 15
    } >"$dir/fixture.sh"
    got=$(pipe_grep_q_sites "$dir" | command tr '\n' ' ')
    command rm -rf "$dir"
    assert_equals "fixture.sh:1 fixture.sh:2 fixture.sh:3 fixture.sh:4 fixture.sh:6 fixture.sh:12 fixture.sh:13 fixture.sh:14 " "$got" \
        "scanner flags same-line, prefixed, --quiet, value-flag and line-continued pipes into grep -q; ignores ||, comments, herestrings, quoted -q, a later command's -q, and non-q greps"
}

# ---------------------------------------------------------------------------
# Test: the real tree still yields sites (until Phase 7)
# ---------------------------------------------------------------------------
test_scanner_not_vacuous() {
    local count
    count=$(pipe_grep_q_sites "$UNIT_DIR" | command wc -l)
    if [ "${#UNCONVERTED_DIRS[@]}" -eq 0 ]; then
        assert_equals "0" "$((count))" "allowlist is empty, so tests/unit has no sites"
        return
    fi
    assert_greater_than "$count" 0 \
        "scanner should find the not-yet-converted sites (found $count) — if this fails with directories still allowlisted, the scanner broke"
}

# ---------------------------------------------------------------------------
# Test: no site outside the allowlisted (unconverted) directories
# ---------------------------------------------------------------------------
test_no_sites_outside_allowlist() {
    local site bad=""
    while IFS= read -r site; do
        [ -n "$site" ] || continue
        is_unconverted "$(site_bucket "$site")" || bad+="  tests/unit/$site"$'\n'
    done < <(pipe_grep_q_sites "$UNIT_DIR")

    if [ -n "$bad" ]; then
        tf_fail_assertion \
            "Pipe into grep -q in a converted directory (SIGPIPE race under pipefail, #1092):" \
            "$bad" \
            "Capture, then match via a herestring:" \
            "  command grep -q 'P' <<<\"\$x\"" \
            "  body=\$(producer || true); command grep -q 'P' <<<\"\$body\""
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Test: every allowlisted directory still has a site
# ---------------------------------------------------------------------------
test_allowlist_is_not_stale() {
    local sites d stale=""
    sites=$(pipe_grep_q_sites "$UNIT_DIR")
    for d in "${UNCONVERTED_DIRS[@]}"; do
        local found=false site
        while IFS= read -r site; do
            [ -n "$site" ] || continue
            if [ "$(site_bucket "$site")" = "$d" ]; then
                found=true
                break
            fi
        done <<<"$sites"
        [ "$found" = true ] || stale+=" $d"
    done

    if [ -n "$stale" ]; then
        tf_fail_assertion \
            "Directories in UNCONVERTED_DIRS with no remaining sites:$stale" \
            "Remove them from UNCONVERTED_DIRS in tests/unit/grep-q-pipefail-guard.sh" \
            "so the guard protects them from regrowth (#1097)."
        return 1
    fi
    return 0
}

run_test "test_scanner_detects_known_shapes" "Scanner flags each pipe-into-grep-q shape and nothing else"
run_test "test_scanner_not_vacuous" "Scanner finds the not-yet-converted sites"
run_test "test_no_sites_outside_allowlist" "No pipe into grep -q outside unconverted directories"
run_test "test_allowlist_is_not_stale" "Every unconverted directory still has a site"

# Generate report
generate_report
