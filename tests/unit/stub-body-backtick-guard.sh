#!/usr/bin/env bash
# Guard: no backtick in a luggage-stub body under tests/unit/ (issue #1597).
#
# THE BUG. run_version_block (tests/unit/features/{node,golang}.sh) writes its
# stub_body argument into an executable luggage-stub. A body like
#   'echo "error: no version of <BT>node<BT> matches ..."'
# is safe at the single-quoted call site, but when the stub RUNS, the backticks
# inside its double-quoted echo are command substitutions: <BT>node<BT> started
# the real node binary, which opened its REPL on a socket stdin and hung the
# pre-push suite for 1h52m. (<BT> = backtick; this file builds the forbidden
# shape from pieces so it never contains it.)
#
# TWO LAYERS.
#   1. Runtime: every run_version_block refuses a body with a backtick before
#      writing the stub (rc 2 + a message naming #1597). That covers multi-line
#      bodies a line scan cannot parse, and turns a regression into a fast
#      failure instead of a hang. test_helpers_refuse_backticks keeps every
#      definition carrying that refusal, so a new language port cannot drop it.
#   2. Static: test_no_backtick_call_sites reports any non-comment line that
#      calls run_version_block and carries a backtick, as file:line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "luggage-stub body backtick guard"

UNIT_DIR="$PROJECT_ROOT/tests/unit"
BT='`'

# backtick_call_sites ROOT — prints "relpath:line" for every non-comment line
# under ROOT that calls run_version_block and contains a backtick.
backtick_call_sites() {
    local root="$1"
    (cd "$root" && command find . -name '*.sh' -type f -exec /usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /run_version_block[[:space:]]+["\047]/ && index($0, "`") {
            f = FILENAME; sub(/^\.\//, "", f); print f ":" FNR
        }
    ' {} + | LC_ALL=C command sort)
}

# helpers_missing_refusal ROOT — prints "relpath" for every file under ROOT
# that defines run_version_block() without the backtick refusal case arm.
helpers_missing_refusal() {
    local root="$1" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! command grep -qF "*'${BT}'*)" "$root/$f"; then
            printf '%s\n' "$f"
        fi
    done < <(cd "$root" && command grep -rlE --include='*.sh' '^[[:space:]]*run_version_block\(\)' . | command sed 's|^\./||' | LC_ALL=C command sort)
}

# ---------------------------------------------------------------------------
# Self-tests: the scanners on fixtures built in a scratch dir
# ---------------------------------------------------------------------------
test_scanner_detects_backtick_body() {
    local dir out
    dir=$(command mktemp -d)
    printf '%s\n' \
        "    out=\$(run_version_block \"27\" 'echo \"no ${BT}node${BT} here\" >&2; exit 1') || rc=\$?" \
        >"$dir/bad.sh"
    printf '%s\n' \
        "    out=\$(run_version_block \"27\" 'echo \"no node here\" >&2; exit 1') || rc=\$?" \
        "    # run_version_block \"27\" 'a ${BT}comment${BT}'" \
        "    echo \"unrelated ${BT}id${BT}\"" \
        >"$dir/good.sh"
    out=$(backtick_call_sites "$dir")
    command rm -rf "$dir"
    assert_equals "bad.sh:1" "$out" "only the backtick-bearing call site is flagged"
}

test_helper_check_detects_missing_refusal() {
    local dir out
    dir=$(command mktemp -d)
    printf '%s\n' 'run_version_block() {' '    local stub_body="$2"' '}' >"$dir/bare.sh"
    printf '%s\n' 'run_version_block() {' \
        "    case \"\$stub_body\" in *'${BT}'*) return 2 ;; esac" '}' >"$dir/guarded.sh"
    out=$(helpers_missing_refusal "$dir")
    command rm -rf "$dir"
    assert_equals "bare.sh" "$out" "only the helper without the refusal is flagged"
}

# ---------------------------------------------------------------------------
# The real tree
# ---------------------------------------------------------------------------
test_no_backtick_call_sites() {
    local out
    out=$(backtick_call_sites "$UNIT_DIR")
    if [ -n "$out" ]; then
        tf_fail_assertion \
            "run_version_block stub body with a backtick (a command substitution when the stub runs, #1597):" \
            "$out" \
            "Drop the backticks or use plain quotes in the message."
        return 1
    fi
    return 0
}

test_helpers_refuse_backticks() {
    local defs missing
    # Non-vacuous: the known definitions must be found, or a broken scan
    # would report "nothing missing" over nothing.
    defs=$(cd "$UNIT_DIR" && command grep -rlE --include='*.sh' '^[[:space:]]*run_version_block\(\)' . || true)
    assert_contains "$defs" "features/node.sh" "scan finds node.sh's run_version_block"
    assert_contains "$defs" "features/golang.sh" "scan finds golang.sh's run_version_block"
    missing=$(helpers_missing_refusal "$UNIT_DIR")
    if [ -n "$missing" ]; then
        tf_fail_assertion \
            "run_version_block defined without the backtick refusal (#1597):" \
            "$missing"
        return 1
    fi
    return 0
}

run_test "test_scanner_detects_backtick_body" "Scanner flags only a backtick-bearing run_version_block call"
run_test "test_helper_check_detects_missing_refusal" "Helper check flags only a definition without the refusal"
run_test "test_no_backtick_call_sites" "No run_version_block call under tests/unit carries a backtick"
run_test "test_helpers_refuse_backticks" "Every run_version_block refuses a backtick-bearing body"

generate_report
