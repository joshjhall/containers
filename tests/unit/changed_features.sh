#!/usr/bin/env bash
# Unit tests for tests/changed_features.sh.
#
# Validates the change-detection mapping used by the PR-tier CI workflow
# (.github/workflows/test-pr.yml) to decide which features to rebuild.
# Wrong mapping means either wasted CI time (overbuilding) or missing
# coverage (underbuilding) on PRs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "tests/changed_features.sh — change detection"

SCRIPT="$PROJECT_ROOT/tests/changed_features.sh"

# Pipe a list of "changed" file paths to the script and capture stdout.
run_with() {
    command printf '%s\n' "$@" | "$SCRIPT" --files=- 2>/dev/null
}

test_empty_input_emits_nothing() {
    local out
    out=$(/usr/bin/printf '' | "$SCRIPT" --files=- 2>/dev/null || true)
    if [ -z "$out" ]; then
        assert_true true "empty stdin → no output"
    else
        assert_true false "empty stdin should emit nothing, got: $out"
    fi
}

test_dockerfile_emits_all() {
    local out
    out=$(run_with "Dockerfile")
    if [ "$out" = "ALL" ]; then
        assert_true true "Dockerfile → ALL"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_lib_base_emits_all() {
    local out
    out=$(run_with "lib/base/setup-user.sh")
    if [ "$out" = "ALL" ]; then
        assert_true true "lib/base/* → ALL (foundational)"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_lib_runtime_emits_all() {
    local out
    out=$(run_with "lib/runtime/entrypoint.sh")
    if [ "$out" = "ALL" ]; then
        assert_true true "lib/runtime/* → ALL (foundational)"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_tests_framework_emits_all() {
    local out
    out=$(run_with "tests/framework/assertions/docker.sh")
    if [ "$out" = "ALL" ]; then
        assert_true true "tests/framework/* → ALL (test infra)"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_crates_emits_all() {
    local out
    out=$(run_with "crates/luggage/src/main.rs")
    if [ "$out" = "ALL" ]; then
        assert_true true "crates/* → ALL (luggage build engine)"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_single_feature() {
    local out
    out=$(run_with "lib/features/python.sh")
    if [ "$out" = "python" ]; then
        assert_true true "lib/features/python.sh → python"
    else
        assert_true false "expected 'python', got: $out"
    fi
}

test_two_features_sorted() {
    local out
    out=$(run_with "lib/features/rust.sh" "lib/features/node.sh")
    local expected
    expected=$(/usr/bin/printf 'node\nrust\n')
    if [ "$out" = "$expected" ]; then
        assert_true true "two features → deduplicated and sorted"
    else
        assert_true false "expected sorted node/rust, got: $out"
    fi
}

test_unknown_feature_emits_all() {
    # `lib/features/totally-fake.sh` doesn't exist in FEATURE_MAP. Defensive
    # behavior: fall back to ALL rather than silently producing a feature
    # name the workflow can't build.
    local out
    out=$(run_with "lib/features/totally-fake-feature.sh")
    if [ "$out" = "ALL" ]; then
        assert_true true "unknown feature script → ALL (defensive)"
    else
        assert_true false "expected ALL for unknown feature, got: $out"
    fi
}

test_helper_subdir_matching_feature() {
    # lib/features/lib/python/pyenv-helper.sh → parent feature "python"
    local out
    out=$(run_with "lib/features/lib/python/pyenv-helper.sh")
    if [ "$out" = "python" ]; then
        assert_true true "lib/features/lib/python/* → python (parent feature)"
    else
        assert_true false "expected 'python', got: $out"
    fi
}

test_helper_subdir_unknown_emits_all() {
    # "claude" is a helper subdir, not a buildable feature. Defensive: ALL.
    local out
    out=$(run_with "lib/features/lib/claude/claude-setup")
    if [ "$out" = "ALL" ]; then
        assert_true true "lib/features/lib/<unknown-subdir>/* → ALL"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_integration_test_for_known_feature() {
    # tests/integration/builds/test_python_dev.sh → "python-dev"
    local out
    out=$(run_with "tests/integration/builds/test_python_dev.sh")
    if [ "$out" = "python-dev" ]; then
        assert_true true "test_python_dev.sh → python-dev"
    else
        assert_true false "expected 'python-dev', got: $out"
    fi
}

test_integration_test_for_unknown_variant() {
    # test_polyglot is a multi-feature variant — no single feature mapping.
    # Should emit nothing (merge tier covers it).
    local out
    out=$(run_with "tests/integration/builds/test_polyglot.sh")
    if [ -z "$out" ]; then
        assert_true true "test_polyglot.sh (multi-feature variant) → no mapping (merge tier covers it)"
    else
        assert_true false "expected empty, got: $out"
    fi
}

test_docs_only_change_emits_nothing() {
    local out
    out=$(run_with "docs/operations/ci-tiers.md" "README.md")
    if [ -z "$out" ]; then
        assert_true true "docs-only changes → no container build"
    else
        assert_true false "expected empty, got: $out"
    fi
}

# Regression: prior to the SEEN-emptiness fix, the script exited 1 with
# `SEEN: unbound variable` when no changed file mapped to a feature. The
# previous tests caught only stdout shape (empty) — they used `|| true`
# and never asserted the exit code, so the bug rode along silently and
# broke PR-tier CI on docs/workflow-only PRs.
test_no_feature_match_exits_zero() {
    /usr/bin/printf 'docs/foo.md\n.github/workflows/ci.yml\nbase-images/debian/12/amd64/Dockerfile\n' |
        "$SCRIPT" --files=- >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        assert_true true "non-feature-only input → exit 0"
    else
        assert_true false "non-feature-only input should exit 0, got: $rc"
    fi
}

test_mixed_with_dockerfile_short_circuits_to_all() {
    local out
    out=$(run_with "lib/features/python.sh" "Dockerfile" "docs/foo.md")
    if [ "$out" = "ALL" ]; then
        assert_true true "ALL short-circuits on foundational + feature mix"
    else
        assert_true false "expected ALL, got: $out"
    fi
}

test_dedup_same_feature_twice() {
    local out
    out=$(run_with "lib/features/python.sh" "lib/features/lib/python/helper.sh")
    if [ "$out" = "python" ]; then
        assert_true true "feature script + its helper dir → deduplicated to one"
    else
        assert_true false "expected single 'python', got: $out"
    fi
}

test_known_features_extractable() {
    # Sanity: the FEATURE_MAP grep must find a reasonable set of features.
    # If test_feature.sh's FEATURE_MAP format ever changes, this catches it.
    local count
    count=$(/usr/bin/grep -oE '^[[:space:]]*\["[^"]+"\]=' "$PROJECT_ROOT/tests/test_feature.sh" | command wc -l)
    if [ "$count" -ge 20 ]; then
        assert_true true "FEATURE_MAP has $count entries (expected >=20)"
    else
        assert_true false "FEATURE_MAP extraction found only $count entries — has the format changed?"
    fi
}

run_test test_empty_input_emits_nothing "empty input → no output"
run_test test_dockerfile_emits_all "Dockerfile → ALL"
run_test test_lib_base_emits_all "lib/base/* → ALL"
run_test test_lib_runtime_emits_all "lib/runtime/* → ALL"
run_test test_tests_framework_emits_all "tests/framework/* → ALL"
run_test test_crates_emits_all "crates/* → ALL"
run_test test_single_feature "single feature script → feature name"
run_test test_two_features_sorted "multiple features → sorted, deduplicated"
run_test test_unknown_feature_emits_all "unknown feature script → ALL"
run_test test_helper_subdir_matching_feature "feature helper subdir → parent feature"
run_test test_helper_subdir_unknown_emits_all "unknown helper subdir → ALL"
run_test test_integration_test_for_known_feature "integration test → matching feature"
run_test test_integration_test_for_unknown_variant "variant integration test → no mapping"
run_test test_docs_only_change_emits_nothing "docs-only changes → nothing"
run_test test_no_feature_match_exits_zero "non-feature-only input → exit 0"
run_test test_mixed_with_dockerfile_short_circuits_to_all "ALL short-circuits"
run_test test_dedup_same_feature_twice "feature + its helper → deduplicated"
run_test test_known_features_extractable "FEATURE_MAP extractable from test_feature.sh"

generate_report
