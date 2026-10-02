#!/usr/bin/env bash
# Unit tests: every verification command a feature advertises is installed.
#
# A feature's summary tells users "Run 'test-<x>' to verify installation" (via
# --next-steps and log_feature_instructions). #1001 found three features naming
# a test-<x> script that nothing installed: test-python-dev, test-ruby-dev and
# test-rust. This suite fails if any feature advertises a test-<x> it does not
# itself install: either to the literal /usr/local/bin/test-<x> (by `install`,
# `cp` or `cat >`) or via install_feature_test_script ... test-<x>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Feature test-* script install tests"

# Print "<feature>\t<test-name>" for every test-<x> a feature advertises.
#
# A feature that advertises nothing makes grep exit 1; under the suite's
# `set -o pipefail` that failed pipeline would end the walk early (it did:
# 3 of 34 entries). Capture per feature and treat no-match as empty.
advertised_test_scripts() {
    local f names name
    for f in "$PROJECT_ROOT"/lib/features/*.sh; do
        names=$(command grep -ohE "Run '(test-[a-z0-9-]+)'|log_feature_instructions \"(test-[a-z0-9-]+)\"" "$f" |
            command grep -oE "test-[a-z0-9-]+" | command sort -u) || names=""
        for name in $names; do
            command printf '%s\t%s\n' "$f" "$name"
        done
    done
}

# Test: the scan actually finds advertised scripts (guards a regex that rots
# into matching nothing, which would make the install check vacuous).
test_scan_finds_advertised_scripts() {
    local count
    count=$(advertised_test_scripts | command wc -l)
    if [ "$count" -ge 20 ]; then
        pass_test "Found $count advertised test-* scripts"
    else
        fail_test "Expected at least 20 advertised test-* scripts, found $count"
    fi
}

# Test: every advertised test-<x> is installed by the feature that names it.
#
# The list is materialized into an array first and each check uses `grep -c`,
# not `grep -q`, inside the loop. A process-substitution loop whose body runs
# `grep -q` let an early match SIGPIPE the producer under `set -o pipefail`,
# silently ending the walk after three features -- a vacuous pass on the exact
# features this suite exists to catch.
test_every_advertised_script_is_installed() {
    local missing="" checked=0 entry f name hits
    local -a entries
    mapfile -t entries < <(advertised_test_scripts)
    for entry in "${entries[@]}"; do
        f="${entry%%$'\t'*}"
        name="${entry#*$'\t'}"
        # Join backslash-continued lines so a wrapped install call still matches.
        hits=$(command sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$f" |
            command grep -cE "/usr/local/bin/${name}([^a-z0-9-]|$)|install_feature_test_script [^ ]+ +${name}([^a-z0-9-]|$)" || true)
        if [ "${hits:-0}" -eq 0 ]; then
            missing="${missing} $(basename "$f"):${name}"
        fi
        checked=$((checked + 1))
    done

    # Every scanned entry must have been checked; a short walk is a test bug.
    if [ "$checked" -ne "${#entries[@]}" ] || [ "$checked" -lt 20 ]; then
        fail_test "Checked only $checked of ${#entries[@]} advertised scripts"
        return
    fi

    if [ -z "$missing" ]; then
        pass_test "All $checked advertised test-* scripts are installed by their features"
    else
        fail_test "Advertised but never installed:${missing}"
    fi
}

# Test: each installed test-* source file under lib/features/lib exists.
test_installed_sources_exist() {
    local missing="" src
    while read -r src; do
        [ -f "$PROJECT_ROOT/lib/features/lib/${src}" ] || missing="${missing} ${src}"
    done < <(command grep -ohE "/tmp/build-scripts/features/lib/[a-z0-9-]+/test-[a-z0-9-]+\.sh" \
        "$PROJECT_ROOT"/lib/features/*.sh | command sed 's|/tmp/build-scripts/features/lib/||' | command sort -u)

    if [ -z "$missing" ]; then
        pass_test "Every installed test-* source file exists"
    else
        fail_test "Install source missing:${missing}"
    fi
}

run_test test_scan_finds_advertised_scripts "Scan finds advertised test-* scripts"
run_test test_every_advertised_script_is_installed "Every advertised test-* script is installed (#1001)"
run_test test_installed_sources_exist "Every installed test-* source file exists"

generate_report
