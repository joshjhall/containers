#!/usr/bin/env bash
# Tests for pre-review-gates.sh test-skip policy and missing-test detection
#
# Validates:
# - Default skip patterns suppress .gitkeep, .mdx, .css, etc.
# - Known source extensions without tests → HIGH
# - Unknown extensions not in skip policy → MEDIUM
# - Project override via .claude/pre-review.yml
# - Negation patterns (! syntax)
# - Path-based glob patterns (e.g. db/schema.rb, config/**/*.rb)
# - Edge cases: empty file list, missing policy file, binary files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

PRE_REVIEW="$CONTAINERS_DIR/lib/features/templates/claude/skills/next-issue-ship/pre-review-gates.sh"

test_suite "Pre-Review Gates Test-Skip Policy"

# ---------------------------------------------------------------------------
# Helper: create a project directory with git init and optional config
# Returns the tmpdir path via stdout
# ---------------------------------------------------------------------------
setup_project() {
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)
    /usr/bin/git init -q "$tmpdir" 2>/dev/null
    echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Helper: run pre-review-gates on a file list within a project dir
# Sets TEST_OUTPUT and TEST_EXIT_CODE for assertions
# ---------------------------------------------------------------------------
run_gates() {
    local project_dir="$1"
    local file_list="$2"
    TEST_OUTPUT=$(cd "$project_dir" && "$PRE_REVIEW" "$file_list" 2>/dev/null) && TEST_EXIT_CODE=0 || TEST_EXIT_CODE=$?
}

# ---------------------------------------------------------------------------
# Helper: extract categories from TSV output
# ---------------------------------------------------------------------------
output_categories() {
    /usr/bin/printf '%s' "$TEST_OUTPUT" | /usr/bin/awk -F'\t' '{print $3}' | /usr/bin/sort -u
}

# ---------------------------------------------------------------------------
# Helper: extract certainty for a specific file from TSV output
# ---------------------------------------------------------------------------
certainty_for_file() {
    local pattern="$1"
    /usr/bin/printf '%s' "$TEST_OUTPUT" | /usr/bin/grep "$pattern" | /usr/bin/awk -F'\t' '{print $5}' | /usr/bin/head -1
}

# ===========================================================================
# Default skip patterns: .gitkeep, .mdx, .css should produce no output
# ===========================================================================
test_default_skips_gitkeep() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/drafts"
    /usr/bin/touch "${proj}/src/drafts/.gitkeep"
    /usr/bin/printf '%s\n' "${proj}/src/drafts/.gitkeep" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".gitkeep should be silently skipped"

    /usr/bin/rm -rf "$proj"
}
run_test test_default_skips_gitkeep ".gitkeep files are skipped by default policy"

test_default_skips_mdx() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/content"
    /usr/bin/touch "${proj}/src/content/post.mdx"
    /usr/bin/printf '%s\n' "${proj}/src/content/post.mdx" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".mdx should be silently skipped"

    /usr/bin/rm -rf "$proj"
}
run_test test_default_skips_mdx ".mdx files are skipped by default policy"

test_default_skips_css() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/printf 'body {}' >"${proj}/src/style.css"
    /usr/bin/printf '%s\n' "${proj}/src/style.css" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".css should be silently skipped"

    /usr/bin/rm -rf "$proj"
}
run_test test_default_skips_css ".css files are skipped by default policy"

test_default_skips_json() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/printf '{}' >"${proj}/src/config.json"
    /usr/bin/printf '%s\n' "${proj}/src/config.json" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".json should be silently skipped"

    /usr/bin/rm -rf "$proj"
}
run_test test_default_skips_json ".json files are skipped by default policy"

# ===========================================================================
# Known source extension without tests → HIGH
# ===========================================================================
test_python_missing_test_high() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/printf 'def hello():\n    return "world"\n' >"${proj}/src/app.py"
    /usr/bin/printf '%s\n' "${proj}/src/app.py" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_not_empty "$TEST_OUTPUT" "should flag missing tests for .py"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "HIGH" "$cert" ".py missing test should be HIGH"

    /usr/bin/rm -rf "$proj"
}
run_test test_python_missing_test_high "Python file without tests is HIGH severity"

# ===========================================================================
# Python: repo-rooted tests/ tree (pytest / Django / SciPy convention)
# Source at <root>/scripts/arch_check/checks/unwrapped_fn.py with test at
# <root>/tests/arch_check/test_unwrapped_fn.py — segments don't align with
# the four near-source paths, so this only passes via the find-under-root.
# ===========================================================================
test_python_repo_rooted_tests_tree() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/scripts/arch_check/checks" "${proj}/tests/arch_check"
    # Private helper (`_check`) so `scan_untested_public_api` (separate
    # scanner, out of scope for this fix) doesn't fire on the fixture.
    /usr/bin/printf 'def _check():\n    pass\n' >"${proj}/scripts/arch_check/checks/unwrapped_fn.py"
    /usr/bin/printf 'def test_check():\n    pass\n' >"${proj}/tests/arch_check/test_unwrapped_fn.py"
    /usr/bin/printf '%s\n' "${proj}/scripts/arch_check/checks/unwrapped_fn.py" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" "test under <root>/tests/<mirror>/ should be discovered"

    /usr/bin/rm -rf "$proj"
}
run_test test_python_repo_rooted_tests_tree "Python test under <root>/tests tree (cross-tree mirror) is found"

test_python_repo_rooted_tests_tree_negative() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/scripts/arch_check/checks" "${proj}/tests/arch_check"
    /usr/bin/printf 'def _check():\n    pass\n' >"${proj}/scripts/arch_check/checks/unwrapped_fn.py"
    # Test exists but for a DIFFERENT source basename — must not match
    /usr/bin/printf 'def test_other():\n    pass\n' >"${proj}/tests/arch_check/test_other_thing.py"
    /usr/bin/printf '%s\n' "${proj}/scripts/arch_check/checks/unwrapped_fn.py" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "HIGH" "$cert" "missing test under <root>/tests should still be HIGH"

    /usr/bin/rm -rf "$proj"
}
run_test test_python_repo_rooted_tests_tree_negative "Python find-under-root does not match wrong basename"

# ===========================================================================
# Rust: mod.rs aggregator (only mod/pub use lines) is skipped
# ===========================================================================
test_rust_mod_rs_aggregator_skipped() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/foo"
    /usr/bin/cat >"${proj}/src/foo/mod.rs" <<'EOF'
//! foo aggregator
pub mod bar;
pub mod baz;
pub use bar::*;
pub use baz::*;
EOF
    /usr/bin/printf '%s\n' "${proj}/src/foo/mod.rs" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" "pure-aggregator mod.rs should produce no findings"

    /usr/bin/rm -rf "$proj"
}
run_test test_rust_mod_rs_aggregator_skipped "Rust mod.rs aggregator (no fn/impl/struct/enum/trait/macro) is skipped"

# ===========================================================================
# Rust: mod.rs with a `pub fn` is still flagged (regression on heuristic)
# ===========================================================================
test_rust_mod_rs_with_fn_flagged() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/foo"
    /usr/bin/cat >"${proj}/src/foo/mod.rs" <<'EOF'
pub mod bar;
pub fn helper() -> u32 { 42 }
EOF
    /usr/bin/printf '%s\n' "${proj}/src/foo/mod.rs" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "HIGH" "$cert" "mod.rs with pub fn should still be HIGH"

    /usr/bin/rm -rf "$proj"
}
run_test test_rust_mod_rs_with_fn_flagged "Rust mod.rs with pub fn is still flagged"

# ===========================================================================
# Rust: mod.rs with macro_rules! is still flagged (testable code)
# ===========================================================================
test_rust_mod_rs_with_macro_flagged() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/foo"
    /usr/bin/cat >"${proj}/src/foo/mod.rs" <<'EOF'
pub mod bar;
macro_rules! greet { () => { println!("hi") }; }
EOF
    /usr/bin/printf '%s\n' "${proj}/src/foo/mod.rs" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "HIGH" "$cert" "mod.rs with macro_rules! should still be HIGH"

    /usr/bin/rm -rf "$proj"
}
run_test test_rust_mod_rs_with_macro_flagged "Rust mod.rs with macro_rules! is still flagged"

# ===========================================================================
# Rust: aggregator heuristic must not bleed onto non-mod.rs files.
# A lib.rs with no definitions and no inline tests should still be flagged.
# ===========================================================================
test_rust_non_mod_rs_unaffected() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/cat >"${proj}/src/lib.rs" <<'EOF'
//! crate root with no definitions yet
pub mod foo;
EOF
    /usr/bin/printf '%s\n' "${proj}/src/lib.rs" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "HIGH" "$cert" "non-mod.rs Rust file must still be flagged"

    /usr/bin/rm -rf "$proj"
}
run_test test_rust_non_mod_rs_unaffected "Aggregator heuristic does not affect non-mod.rs files"

# ===========================================================================
# Unknown extension not in skip policy → MEDIUM
# ===========================================================================
test_unknown_extension_medium() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/printf 'content' >"${proj}/src/data.xyz"
    /usr/bin/printf '%s\n' "${proj}/src/data.xyz" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_not_empty "$TEST_OUTPUT" "unknown extension should produce output"
    local cert
    cert=$(certainty_for_file "missing-test-file")
    assert_equals "MEDIUM" "$cert" "unknown extension should be MEDIUM"

    /usr/bin/rm -rf "$proj"
}
run_test test_unknown_extension_medium "Unknown extension gets MEDIUM warning"

# ===========================================================================
# Project override: .claude/pre-review.yml adds *.xyz to skip
# ===========================================================================
test_project_override_skip() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src" "${proj}/.claude"
    /usr/bin/printf 'content' >"${proj}/src/data.xyz"

    /usr/bin/cat >"${proj}/.claude/pre-review.yml" <<'EOF'
test_skip_patterns:
  - "*.xyz"
EOF

    /usr/bin/printf '%s\n' "${proj}/src/data.xyz" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".xyz should be skipped after project override"

    /usr/bin/rm -rf "$proj"
}
run_test test_project_override_skip "Project override adds extension to skip list"

# ===========================================================================
# Negation: default skips *.css, project override un-skips src/critical/*.css
# ===========================================================================
test_negation_override() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src/normal" "${proj}/src/critical" "${proj}/.claude"

    /usr/bin/printf 'body {}' >"${proj}/src/normal/style.css"
    /usr/bin/printf 'body {}' >"${proj}/src/critical/app.css"

    /usr/bin/cat >"${proj}/.claude/pre-review.yml" <<'EOF'
test_skip_patterns:
  - "!src/critical/*.css"
EOF

    /usr/bin/printf '%s\n' "${proj}/src/normal/style.css" "${proj}/src/critical/app.css" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"

    # normal/style.css should be skipped (default *.css)
    if /usr/bin/printf '%s' "$TEST_OUTPUT" | /usr/bin/grep -q "normal/style.css"; then
        fail_test "normal/style.css should be skipped by default *.css pattern"
    else
        pass_test
    fi

    # critical/app.css should be flagged (negation un-skips it)
    assert_contains "$TEST_OUTPUT" "critical/app.css" "critical/app.css should be un-skipped by negation"
}
run_test test_negation_override "Negation patterns un-skip specific paths"

# ===========================================================================
# Path-based glob: db/schema.rb skipped, app/models/user.rb flagged HIGH
# ===========================================================================
test_path_glob_skip() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/db" "${proj}/app/models"

    /usr/bin/printf 'ActiveRecord::Schema.define {}' >"${proj}/db/schema.rb"
    /usr/bin/printf 'class User; end' >"${proj}/app/models/user.rb"

    /usr/bin/printf '%s\n' "${proj}/db/schema.rb" "${proj}/app/models/user.rb" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"

    # db/schema.rb should be skipped (default pattern)
    if /usr/bin/printf '%s' "$TEST_OUTPUT" | /usr/bin/grep -q "schema.rb"; then
        fail_test "db/schema.rb should be skipped by default path pattern"
    else
        pass_test
    fi

    # app/models/user.rb should be flagged
    assert_contains "$TEST_OUTPUT" "user.rb" "app/models/user.rb should be flagged"
}
run_test test_path_glob_skip "Path-based globs skip framework files"

# ===========================================================================
# Migration files skipped by default
# ===========================================================================
test_migration_skip() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/app/migrations"

    /usr/bin/printf 'class Migration: pass' >"${proj}/app/migrations/001_init.py"
    /usr/bin/printf '%s\n' "${proj}/app/migrations/001_init.py" >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" "migration files should be skipped by default"

    /usr/bin/rm -rf "$proj"
}
run_test test_migration_skip "Migration files are skipped by default"

# ===========================================================================
# Edge case: empty file list
# ===========================================================================
test_edge_empty_file_list() {
    local proj
    proj=$(setup_project)
    /usr/bin/touch "${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" "empty file list should produce no output"

    /usr/bin/rm -rf "$proj"
}
run_test test_edge_empty_file_list "Empty file list produces no output"

# ===========================================================================
# Edge case: no project config file (defaults only)
# ===========================================================================
test_edge_no_project_config() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/touch "${proj}/src/.gitkeep"
    /usr/bin/printf '%s\n' "${proj}/src/.gitkeep" >"${proj}/filelist.txt"

    # No .claude/pre-review.yml exists
    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" ".gitkeep should be skipped by defaults alone"

    /usr/bin/rm -rf "$proj"
}
run_test test_edge_no_project_config "Works with defaults when no project config exists"

# ===========================================================================
# Edge case: config file skipped by default patterns
# ===========================================================================
test_default_skips_config_files() {
    local proj
    proj=$(setup_project)
    /usr/bin/mkdir -p "${proj}/src"
    /usr/bin/touch "${proj}/src/app.yml"
    /usr/bin/touch "${proj}/src/data.toml"
    /usr/bin/touch "${proj}/src/notes.txt"
    for f in "${proj}/src/app.yml" "${proj}/src/data.toml" "${proj}/src/notes.txt"; do
        echo "$f"
    done >"${proj}/filelist.txt"

    run_gates "$proj" "${proj}/filelist.txt"
    assert_equals "0" "$TEST_EXIT_CODE" "exit code"
    assert_empty "$TEST_OUTPUT" "config/doc files should be silently skipped"

    /usr/bin/rm -rf "$proj"
}
run_test test_default_skips_config_files "Config and doc file extensions are skipped"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
