#!/usr/bin/env bash
# Unit tests for bin/lib/triage-gem.sh (issue #989)
#
# The one reader for the gitlab-triage pin in .gitlab/triage/Gemfile and
# Gemfile.lock, shared by regen-triage-lock.sh, check-versions.sh and the
# Gemfile/lock sync test. Fixtures carry DIFFERENT versions in each place a
# reader could wrongly look, so a reader that picked the wrong line returns a
# wrong value instead of an accidentally-right one.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

init_test_framework

test_suite "Bin Lib triage-gem Tests"

LIB="$PROJECT_ROOT/bin/lib/triage-gem.sh"
# shellcheck source=bin/lib/triage-gem.sh
source "$LIB"

FIXTURE_DIR=""

setup_fixtures() {
    FIXTURE_DIR=$(command mktemp -d)
    # A commented-out pin and a similarly named gem precede the real one.
    command cat >"$FIXTURE_DIR/Gemfile" <<'EOF'
# frozen_string_literal: true
source "https://rubygems.org"

# gem "gitlab-triage", "0.0.1"
gem "gitlab-triage-extras", "9.9.9"
gem "gitlab-triage", "1.54.0"
gem "racc"
EOF
    # The DEPENDENCIES requirement deliberately differs from the resolution in
    # specs, and a dependent gem mentions gitlab-triage without a version.
    command cat >"$FIXTURE_DIR/Gemfile.lock" <<'EOF'
GEM
  remote: https://rubygems.org/
  specs:
    gitlab-triage (1.54.0)
      activesupport (>= 5.1)
    triage-plugin (0.1.0)
      gitlab-triage

PLATFORMS
  ruby

DEPENDENCIES
  gitlab-triage (= 1.50.0)
EOF
    command printf 'source "https://rubygems.org"\ngem "racc"\n' >"$FIXTURE_DIR/Gemfile.nogem"
    command printf 'GEM\n  specs:\n    racc (1.8.1)\n' >"$FIXTURE_DIR/Gemfile.lock.nogem"
}

teardown_fixtures() {
    [ -n "$FIXTURE_DIR" ] && command rm -rf "$FIXTURE_DIR"
    FIXTURE_DIR=""
}

test_gemfile_version_reads_real_pin() {
    setup_fixtures
    local got
    got=$(triage_gemfile_version "$FIXTURE_DIR/Gemfile")
    teardown_fixtures
    assert_equals "1.54.0" "$got" "reads the active pin, not the comment or a prefixed gem"
}

test_lock_version_reads_specs_resolution() {
    setup_fixtures
    local got
    got=$(triage_lock_version "$FIXTURE_DIR/Gemfile.lock")
    teardown_fixtures
    assert_equals "1.54.0" "$got" "reads the specs resolution, not the DEPENDENCIES requirement"
}

# Each miss case runs in a SEPARATE bash under `set -euo pipefail` and must reach
# the line after the assignment — the #988 bug was an assignment aborting the
# script silently. A separate process, not a `$( ... ) || true` subshell: the
# `||` context disables errexit inside the subshell, so the abort could never
# happen there and the test would pass against a reader that has the bug.
assert_miss_is_empty_and_safe() {
    local fn="$1" file="$2" label="$3" out
    out=$(
        env -u BASH_ENV bash -c '
            set -euo pipefail
            source "$1"
            v=$("$2" "$3")
            printf "reached:[%s]" "$v"
        ' _ "$LIB" "$fn" "$file" 2>/dev/null
    ) || true
    assert_equals "reached:[]" "$out" "$label"
}

test_gemfile_miss_is_empty() {
    setup_fixtures
    assert_miss_is_empty_and_safe triage_gemfile_version "$FIXTURE_DIR/Gemfile.nogem" \
        "Gemfile without the gem yields empty under pipefail"
    teardown_fixtures
}

test_lock_miss_is_empty() {
    setup_fixtures
    assert_miss_is_empty_and_safe triage_lock_version "$FIXTURE_DIR/Gemfile.lock.nogem" \
        "lock without the gem yields empty under pipefail"
    teardown_fixtures
}

test_missing_file_is_empty() {
    assert_miss_is_empty_and_safe triage_gemfile_version "/nonexistent/Gemfile" \
        "missing Gemfile yields empty under pipefail"
    assert_miss_is_empty_and_safe triage_lock_version "/nonexistent/Gemfile.lock" \
        "missing lock yields empty under pipefail"
}

test_repo_gemfile_and_lock_readable() {
    # The committed files must parse — an empty result here would make the
    # gitlab-templates sync test compare two empties.
    local pin locked
    pin=$(triage_gemfile_version "$PROJECT_ROOT/.gitlab/triage/Gemfile")
    locked=$(triage_lock_version "$PROJECT_ROOT/.gitlab/triage/Gemfile.lock")
    if [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$locked" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "committed Gemfile ($pin) and lock ($locked) parse"
    else
        assert_true false "committed Gemfile/lock did not parse: pin='$pin' lock='$locked'"
    fi
}

run_test test_gemfile_version_reads_real_pin "Gemfile reader takes the real pin"
run_test test_lock_version_reads_specs_resolution "Lock reader takes the specs resolution"
run_test test_gemfile_miss_is_empty "Gemfile miss is empty and pipefail-safe"
run_test test_lock_miss_is_empty "Lock miss is empty and pipefail-safe"
run_test test_missing_file_is_empty "Missing files are empty and pipefail-safe"
run_test test_repo_gemfile_and_lock_readable "Committed Gemfile and lock parse"

generate_report
