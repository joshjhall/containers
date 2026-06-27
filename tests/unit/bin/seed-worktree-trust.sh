#!/usr/bin/env bash
# Unit tests for bin/seed-worktree-trust.sh (#585)
# Exercises the trust-seeding helper against synthetic ~/.claude.json fixtures
# in TEST_TEMP_DIR (no Docker, no real host config touched). Covers every
# observable branch: seed (config present, with/without a projects key),
# idempotent re-seed, both skip halves (config absent, jq absent), malformed
# config (skip without corruption), atomic write (no temp leftover), and the
# missing-argument error.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "Bin Seed Worktree Trust Tests"

# Resolve the script under test relative to this test file so the suite runs
# from any cwd.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$PROJECT_ROOT_REAL/bin/seed-worktree-trust.sh"

# A minimal but realistic ~/.claude.json with an existing trusted project, so
# we can also assert the seed does not clobber unrelated entries.
write_base_config() {
    /usr/bin/cat >"$1" <<'EOF'
{
  "projects": {
    "/workspace/containers": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
}

# Run the script capturing BOTH stdout/stderr (into TRUST_OUT) and the real exit
# code (into TRUST_RC). The exit code must be captured directly from the call —
# `out="$(cmd)"; assert_exit_code_success "msg"` does NOT work: the framework's
# assert_exit_code_success treats a lone message as the command, runs an empty
# command array (always 0), and the assertion becomes vacuous.
run_seed() {
    TRUST_RC=0
    TRUST_OUT="$("$SCRIPT" "$@" 2>&1)" || TRUST_RC=$?
}

test_script_exists_and_executable() {
    assert_file_exists "$SCRIPT" "seed-worktree-trust.sh exists"
    assert_executable "$SCRIPT" "seed-worktree-trust.sh is executable"
}

test_seeds_trust_for_new_path() {
    local cfg="$TEST_TEMP_DIR/.claude.json"
    write_base_config "$cfg"
    local wt="/workspace/containers/.worktrees/issue-585"

    run_seed "$wt" "$cfg"
    assert_equals "0" "$TRUST_RC" "Seeding exits 0"
    assert_contains "$TRUST_OUT" "seeded workspace trust for $wt" \
        "Reports the seeded path"

    # The new path is now trusted...
    local val
    val="$(command jq -r --arg p "$wt" '.projects[$p].hasTrustDialogAccepted' "$cfg")"
    assert_equals "true" "$val" "New worktree path is marked trusted"

    # ...and the pre-existing entry is untouched.
    local existing
    existing="$(command jq -r '.projects["/workspace/containers"].hasTrustDialogAccepted' "$cfg")"
    assert_equals "true" "$existing" "Pre-existing trust entry is preserved"
}

test_seeds_when_no_projects_key() {
    # A user who has never trusted any project has no `projects` key at all.
    # The jq filter must create the full nested path and preserve other keys.
    local cfg="$TEST_TEMP_DIR/.claude.json"
    printf '{"theme":"dark"}\n' >"$cfg"
    local wt="/workspace/containers/.worktrees/issue-585"

    run_seed "$wt" "$cfg"
    assert_equals "0" "$TRUST_RC" "Seeding exits 0 with no projects key"
    local val
    val="$(command jq -r --arg p "$wt" '.projects[$p].hasTrustDialogAccepted' "$cfg")"
    assert_equals "true" "$val" "Trust entry created when projects key absent"
    local theme
    theme="$(command jq -r '.theme' "$cfg")"
    assert_equals "dark" "$theme" "Unrelated keys preserved"
}

test_seeding_is_idempotent() {
    local cfg="$TEST_TEMP_DIR/.claude.json"
    write_base_config "$cfg"
    local wt="/workspace/containers/.worktrees/issue-585"

    run_seed "$wt" "$cfg" # first seed
    run_seed "$wt" "$cfg" # second seed
    assert_equals "0" "$TRUST_RC" "Re-seeding exits 0"
    local val
    val="$(command jq -r --arg p "$wt" '.projects[$p].hasTrustDialogAccepted' "$cfg")"
    assert_equals "true" "$val" "Trust entry unchanged after second seed"
}

test_atomic_write_leaves_no_temp_file() {
    local cfg="$TEST_TEMP_DIR/.claude.json"
    write_base_config "$cfg"

    run_seed "/some/worktree" "$cfg"

    # The adjacent-temp + atomic-mv pattern must not leave a ".claude.json.XXXXXX"
    # behind in the config's directory.
    local leftovers
    leftovers="$(command find "$TEST_TEMP_DIR" -maxdepth 1 -name '.claude.json.*' | command wc -l | command tr -d ' ')"
    assert_equals "0" "$leftovers" "No temp file is left after an atomic write"
}

test_skips_when_config_absent() {
    local cfg="$TEST_TEMP_DIR/does-not-exist.json"

    run_seed "/some/worktree" "$cfg"
    assert_equals "0" "$TRUST_RC" "Absent config still exits 0 (best-effort)"
    assert_contains "$TRUST_OUT" "skipped trust seed" "Reports the skip"
    assert_file_not_exists "$cfg" "Absent config is not created"
}

test_skips_when_jq_absent() {
    # The skip condition is an OR: jq absent is a distinct half from config
    # absent. Shadow jq with an empty PATH dir so `command -v jq` fails while a
    # valid config is present.
    local cfg="$TEST_TEMP_DIR/.claude.json"
    write_base_config "$cfg"
    local emptybin="$TEST_TEMP_DIR/emptybin"
    command mkdir -p "$emptybin"

    # Run with a PATH that contains no jq so `command -v jq` fails. Use `env -i`
    # to start from a clean environment (a plain `PATH=... cmd` is undone by the
    # inherited BASH_ENV, which re-exports the full PATH). Invoke the interpreter
    # directly since the minimal PATH would break the `#!/usr/bin/env bash`
    # shebang; the script's own commands are full-path (/usr/bin/...) or builtins,
    # so only jq detection is affected. HOME is preserved so the cfg default and
    # any HOME-relative logic behave normally.
    TRUST_RC=0
    TRUST_OUT="$(env -i PATH="$emptybin" HOME="$HOME" "$BASH" "$SCRIPT" "/some/worktree" "$cfg" 2>&1)" || TRUST_RC=$?
    assert_equals "0" "$TRUST_RC" "jq-absent still exits 0 (best-effort)"
    assert_contains "$TRUST_OUT" "skipped trust seed" "Reports the skip when jq is absent"
}

test_malformed_config_is_not_corrupted() {
    local cfg="$TEST_TEMP_DIR/.claude.json"
    # Not valid JSON — jq will fail; the original bytes must survive.
    printf '{ this is not json' >"$cfg"
    local before
    before="$(command cat "$cfg")"

    run_seed "/some/worktree" "$cfg"
    assert_equals "0" "$TRUST_RC" "Malformed config still exits 0"
    assert_contains "$TRUST_OUT" "skipped trust seed" "Reports the skip on jq failure"

    local after
    after="$(command cat "$cfg")"
    assert_equals "$before" "$after" "Malformed config is left byte-for-byte intact"
}

test_missing_path_argument_errors() {
    local rc=0
    "$SCRIPT" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "Missing worktree-path argument exits 2"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_seeds_trust_for_new_path "Seeds trust for a new worktree path"
run_test test_seeds_when_no_projects_key "Seeds when config has no projects key"
run_test test_seeding_is_idempotent "Re-seeding is idempotent"
run_test test_atomic_write_leaves_no_temp_file "Atomic write leaves no temp file"
run_test test_skips_when_config_absent "Skips cleanly when config is absent"
run_test test_skips_when_jq_absent "Skips cleanly when jq is absent"
run_test test_malformed_config_is_not_corrupted "Malformed config is not corrupted"
run_test test_missing_path_argument_errors "Missing path argument exits 2"

generate_report
