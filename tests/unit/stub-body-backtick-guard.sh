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
#      failure instead of a hang. test_helpers_refuse_backticks CALLS every
#      definition found under tests/unit with a backtick body and requires
#      rc 2, the #1597 message, and no stub written — so a new language port
#      cannot drop the refusal, comment it out, or move it after the write.
#   2. Static: test_no_backtick_call_sites reports any non-comment line that
#      calls run_version_block and carries a backtick, as file:line. It only
#      sees a body written inline on the call line; a body passed through a
#      variable or a multi-line string is left to layer 1, which every call
#      goes through regardless of how its body was built.

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

# helper_defs ROOT — prints "relpath" for every file under ROOT defining
# run_version_block().
helper_defs() {
    local root="$1"
    (cd "$root" && command grep -rlE --include='*.sh' '^[[:space:]]*run_version_block\(\)' . || true) |
        command sed 's|^\./||' | LC_ALL=C command sort
}

# helper_refusal_failure FILE — extract FILE's run_version_block, call it in a
# scratch subshell with a backtick-bearing body, and print why it did NOT
# refuse (empty output = refused correctly). Behavioral, not textual: a
# refusal that is commented out, does not return, or sits after the stub
# write all fail here. PROJECT_ROOT points into the scratch dir, so a helper
# that does not refuse fails fast on a missing extractor instead of reaching
# lib/features. The backtick body runs `true`, never a real tool.
helper_refusal_failure() {
    local file="$1" scratch rc=0 err
    scratch=$(command mktemp -d)
    /usr/bin/awk '/^[[:space:]]*run_version_block\(\)/ { on = 1 } on { print } on && /^}/ { exit }' \
        "$file" >"$scratch/helper.sh"
    err=$(
        PROJECT_ROOT="$scratch/no-project" TEST_TEMP_DIR="$scratch"
        export PROJECT_ROOT TEST_TEMP_DIR
        # shellcheck disable=SC1091  # generated above
        source "$scratch/helper.sh"
        # stdin from /dev/null: a helper that does not refuse goes on to run
        # its stub and bash children; none may read the caller's stdin (the
        # #1597 hang was a stray process blocked on stdin).
        run_version_block "1" "echo \"x ${BT}true${BT}\"" 2>&1 >/dev/null </dev/null
    ) || rc=$?
    if [ ! -s "$scratch/helper.sh" ]; then
        printf 'no run_version_block definition extracted\n'
    elif [ "$rc" != "2" ]; then
        printf 'returned %s, not 2\n' "$rc"
    elif [[ "$err" != *"#1597"* ]]; then
        printf 'refusal message does not name #1597: %s\n' "$err"
    elif [ -e "$scratch/luggage-stub" ]; then
        printf 'wrote the stub before refusing\n'
    fi
    command rm -rf "$scratch"
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
    local dir refusal
    dir=$(command mktemp -d)
    refusal="    case \"\$stub_body\" in *'${BT}'*) echo 'see #1597' >&2; return 2 ;; esac"
    local write='    printf "%s\n" "$stub_body" >"$TEST_TEMP_DIR/luggage-stub"; return 1'
    printf '%s\n' 'run_version_block() {' '    local stub_body="$2"' "$refusal" "$write" '}' >"$dir/good.sh"
    printf '%s\n' 'run_version_block() {' '    local stub_body="$2"' "$write" '}' >"$dir/bare.sh"
    printf '%s\n' 'run_version_block() {' '    local stub_body="$2"' "#$refusal" "$write" '}' >"$dir/commented.sh"
    printf '%s\n' 'run_version_block() {' '    local stub_body="$2"' \
        '    printf "%s\n" "$stub_body" >"$TEST_TEMP_DIR/luggage-stub"' "$refusal" '    return 1' '}' >"$dir/late.sh"
    assert_equals "" "$(helper_refusal_failure "$dir/good.sh")" "a helper that refuses first passes"
    assert_contains "$(helper_refusal_failure "$dir/bare.sh")" "not 2" "a helper with no refusal is flagged"
    assert_contains "$(helper_refusal_failure "$dir/commented.sh")" "not 2" "a commented-out refusal is flagged"
    assert_contains "$(helper_refusal_failure "$dir/late.sh")" "wrote the stub" "a refusal after the stub write is flagged"
    command rm -rf "$dir"
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
    local defs f why
    local -a bad=()
    defs=$(helper_defs "$UNIT_DIR")
    # Non-vacuous: the known definitions must be found, or a broken scan
    # would report "nothing wrong" over nothing.
    assert_contains "$defs" "features/node.sh" "scan finds node.sh's run_version_block"
    assert_contains "$defs" "features/golang.sh" "scan finds golang.sh's run_version_block"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        why=$(helper_refusal_failure "$UNIT_DIR/$f")
        [ -z "$why" ] || bad+=("  $f: $why")
    done <<<"$defs"
    if [ "${#bad[@]}" -gt 0 ]; then
        tf_fail_assertion \
            "run_version_block does not refuse a backtick-bearing body before writing the stub (#1597):" \
            "${bad[@]}"
        return 1
    fi
    return 0
}

run_test "test_scanner_detects_backtick_body" "Scanner flags only a backtick-bearing run_version_block call"
run_test "test_helper_check_detects_missing_refusal" "Behavioral helper check flags missing, commented-out, and late refusals"
run_test "test_no_backtick_call_sites" "No run_version_block call under tests/unit carries a backtick"
run_test "test_helpers_refuse_backticks" "Every run_version_block refuses a backtick body before writing the stub"

generate_report
