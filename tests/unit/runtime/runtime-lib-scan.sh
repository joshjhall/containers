#!/usr/bin/env bash
# Unit tests for tests/lib/runtime-lib-scan.sh, the installed-fragment
# reference scan that test_runtime_lib_installed runs in the image (#1095).
#
# The integration test only ever feeds the scan a healthy image, so it can show
# the scan accepting good input but never rejecting bad input (#1262). This
# suite runs the same script against a fixture tree (--root) and pins, by exact
# output, that each typo class is reported -- so an edit to its regexes or its
# resolution logic that quietly stops seeing one turns this suite red.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Lib Reference Scan Tests"

# Overridable so a mutated scratch copy can be checked against this suite.
SCAN_SCRIPT="${RUNTIME_LIB_SCAN_SCRIPT:-$CONTAINERS_DIR/tests/lib/runtime-lib-scan.sh}"

# Seed the fixture root with the installed lib dir holding one real fragment.
make_lib() {
    command mkdir -p "$TEST_TEMP_DIR/opt/container-runtime/lib" "$TEST_TEMP_DIR/usr/local/bin"
    command printf '# fragment\n' >"$TEST_TEMP_DIR/opt/container-runtime/lib/good.sh"
}

# Write stdin to a consumer at the given installed path under the fixture root.
consumer() {
    command mkdir -p "$(dirname "$TEST_TEMP_DIR$1")"
    command cat >"$TEST_TEMP_DIR$1"
}

# Run the scan over the fixture root, expecting the given consumer(s).
scan() {
    local args=(--root "$TEST_TEMP_DIR") want
    for want in "$@"; do
        args+=(--expect "$want")
    done
    bash "$SCAN_SCRIPT" "${args[@]}" 2>&1
}

# Control: every resolvable shape at once yields the sentinel. Without it, the
# typo tests below could pass because the fixture itself is broken.
test_good_consumer_is_ok() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
[ -f /opt/container-runtime/lib/good.sh ] && source /opt/container-runtime/lib/good.sh
_RUNTIME_LIB="/opt/container-runtime/lib"
[ -f "$_RUNTIME_LIB/good.sh" ] && source "$_RUNTIME_LIB/good.sh"
EOF
    assert_equals "consumers-ok" "$(scan /usr/local/bin/c)" \
        "A consumer whose every reference resolves must pass"
}

test_typo_fragment_basename() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
[ -f /opt/container-runtime/lib/goood.sh ] && source /opt/container-runtime/lib/goood.sh
EOF
    assert_equals "missing: /usr/local/bin/c:/opt/container-runtime/lib/goood.sh unseen: errors: " \
        "$(scan /usr/local/bin/c)" \
        "A typo'd fragment basename must be reported"
}

test_typo_literal_directory() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
[ -f /opt/container-runtim/lib/good.sh ] && source /opt/container-runtim/lib/good.sh
EOF
    assert_equals "missing: /usr/local/bin/c:/opt/container-runtim/lib/good.sh unseen: errors: " \
        "$(scan /usr/local/bin/c)" \
        "A typo in a literal path's directory must be reported, not just the basename"
}

test_typo_var_assignment() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
_RUNTIME_LIB="/opt/container-runtim/lib"
[ -f "$_RUNTIME_LIB/good.sh" ] && source "$_RUNTIME_LIB/good.sh"
EOF
    assert_equals "missing: /usr/local/bin/c:\$_RUNTIME_LIB/good.sh@/opt/container-runtim/lib unseen: errors: " \
        "$(scan /usr/local/bin/c)" \
        "A \$VAR ref must resolve through its file's assignment, so a typo'd assignment is reported"
}

test_misspelled_use_site_var() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
_RUNTIME_LIB="/opt/container-runtime/lib"
[ -f "$_RUNTIME_LIBS/good.sh" ] && source "$_RUNTIME_LIBS/good.sh"
EOF
    assert_equals "missing: /usr/local/bin/c:\$_RUNTIME_LIBS/good.sh unseen: errors: " \
        "$(scan /usr/local/bin/c)" \
        "A use-site variable with no assignment in its file must be reported"
}

# healthcheck's shape: the variable is computed, so the scan falls back to every
# lib-dir literal in the file. One of the two is typo'd and must be caught.
test_typo_computed_var_literal() {
    make_lib
    consumer /usr/local/bin/c <<'EOF'
pick_lib() {
    if [ -d /workspace ]; then
        echo "/opt/container-runtime/lib"
    else
        echo "${C_RUNTIME_LIB:-/opt/container-runtim/lib}"
    fi
}
RUNTIME_LIB=$(pick_lib)
[ -f "$RUNTIME_LIB/good.sh" ] && source "$RUNTIME_LIB/good.sh"
EOF
    assert_equals "missing: /usr/local/bin/c:\$RUNTIME_LIB/good.sh@/opt/container-runtim/lib unseen: errors: " \
        "$(scan /usr/local/bin/c)" \
        "A computed variable's typo'd lib-dir literal must be reported"
}

# The unseen guard: an expected consumer the scan never matched means the regex
# went blind, which must not print the sentinel.
test_expected_consumer_unseen() {
    make_lib
    assert_equals "missing: unseen: /usr/local/bin/c errors: " \
        "$(scan /usr/local/bin/c)" \
        "An expected consumer that was not scanned must be reported"
}

# Consumers are read one per line, so a path with a space is one consumer --
# split on whitespace, its typo would surface as grep errors on two halves.
test_consumer_path_with_space() {
    make_lib
    consumer "/usr/local/bin/my tool" <<'EOF'
[ -f /opt/container-runtime/lib/goood.sh ] && source /opt/container-runtime/lib/goood.sh
EOF
    assert_equals "missing: /usr/local/bin/my tool:/opt/container-runtime/lib/goood.sh unseen: errors: " \
        "$(scan "/usr/local/bin/my tool")" \
        "A consumer path containing a space must be scanned as one file"
}

# A grep error must fail rather than silently shrink the scan. An unreadable
# consumer is the error a typo'd path cannot produce: grep -l skips it with a
# message on stderr, which must land in errors: and withhold the sentinel.
test_grep_error_is_reported() {
    if [ "$(id -u)" -eq 0 ]; then
        skip_test "root reads a mode-000 file, so no grep error can be induced"
        return 0
    fi
    make_lib
    consumer /usr/local/bin/c <<'EOF'
[ -f /opt/container-runtime/lib/good.sh ] && source /opt/container-runtime/lib/good.sh
EOF
    consumer /usr/local/bin/locked <<'EOF'
[ -f /opt/container-runtime/lib/good.sh ] && source /opt/container-runtime/lib/good.sh
EOF
    command chmod 000 "$TEST_TEMP_DIR/usr/local/bin/locked"
    local out
    # C locale so the pinned message is grep's untranslated wording.
    out=$(LC_ALL=C scan /usr/local/bin/c)
    command chmod 644 "$TEST_TEMP_DIR/usr/local/bin/locked"
    assert_equals "missing: unseen: errors: grep: $TEST_TEMP_DIR/usr/local/bin/locked: Permission denied" "$out" \
        "A grep error must be reported in errors:, not swallowed"
}

# The integration test passes no --expect, so the default consumer list is the
# one that guards the real image; every other test here replaces it.
test_default_expect_list() {
    make_lib
    assert_equals "missing: unseen: /usr/local/bin/entrypoint /usr/local/bin/workspace-fs-health-cron /usr/local/bin/healthcheck /etc/container/startup/42-workspace-fs-health.sh errors: " \
        "$(bash "$SCAN_SCRIPT" --root "$TEST_TEMP_DIR" 2>&1)" \
        "With no --expect, all four installed consumers must be required"
}

# A trailing flag with no value must fail fast, not hang the suite. The timeout
# turns a regression into a failure rather than a stuck run.
test_valueless_flag_fails() {
    local flag rc
    for flag in --root --expect; do
        rc=0
        command timeout 10 bash "$SCAN_SCRIPT" "$flag" >/dev/null 2>&1 || rc=$?
        assert_equals "2" "$rc" "A trailing $flag with no value must exit 2 (124 = hung)"
    done
}

# Run tests
run_test test_good_consumer_is_ok "Resolvable consumer yields consumers-ok"
run_test test_typo_fragment_basename "Typo'd fragment basename is reported"
run_test test_typo_literal_directory "Typo'd literal directory is reported"
run_test test_typo_var_assignment "Typo'd \$_RUNTIME_LIB assignment is reported"
run_test test_misspelled_use_site_var "Misspelled use-site variable is reported"
run_test test_typo_computed_var_literal "Typo'd computed-variable literal is reported"
run_test test_expected_consumer_unseen "Unscanned expected consumer is reported"
run_test test_consumer_path_with_space "Consumer path with a space is one file"
run_test test_grep_error_is_reported "Grep error lands in errors:"
run_test test_default_expect_list "Default --expect list requires the four installed consumers"
run_test test_valueless_flag_fails "Valueless trailing flag exits 2 instead of hanging"

# Generate test report
generate_report
