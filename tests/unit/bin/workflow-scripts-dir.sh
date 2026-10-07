#!/usr/bin/env bash
# Unit tests for bin/workflow-scripts-dir.sh — resolution of the librarian
# `workflow` plugin's bundled scripts/ dir for the just-side golem recipes (#609).
#
# `just` runs outside Claude Code, where ${CLAUDE_PLUGIN_ROOT} is unset, so the
# thin-wrapper recipes resolve the bundled scripts through this helper. The
# resolution order (override > CLAUDE_PLUGIN_ROOT > /opt/librarian > newest
# installed cache > dev mount), the "must actually contain config.sh" validity
# rule, and the #667/#1020 trust rule (owned by root or the invoking user, never
# group/world-writable — for the dir AND every entry in it, #1026) are the
# contract these tests pin.

set -euo pipefail

# Hermetic: a pushing git hook can export GIT_* into this env (#599); irrelevant
# here, but cleared for parity with the sibling bin tests.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

init_test_framework

test_suite "workflow-scripts-dir.sh — bundled-scripts resolution"

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/workflow-scripts-dir.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        command rm -rf "$TEST_DIR"
    fi
}

# Make $1 look like a real bundled scripts dir (config.sh is the validity marker).
# chmod 0755/0644 explicitly so a group-writable CI umask can't leave the dir or
# config.sh group/world-writable and trip the #667/#1026 trust gate (which
# refuses such dirs, and dirs holding such entries).
make_scripts_dir() {
    command mkdir -p "$1"
    command chmod 0755 "$1"
    command touch "$1/config.sh"
    command chmod 0644 "$1/config.sh"
}

# Run the resolver with a clean, fully-controlled environment so a real
# CLAUDE_PLUGIN_ROOT / dev mount / HOME on the test machine never leaks in.
# Pass `VAR=value` assignments as args; HOME defaults to an empty TEST_DIR subdir
# so the installed-cache probe finds nothing, and WORKFLOW_DEV_MOUNT /
# WORKFLOW_OPT_LIBRARIAN are pointed at non-existent paths so neither a real
# /workspace/librarian checkout nor the baked /opt/librarian install on the test
# machine can match — unless a test opts in.
run_resolver() {
    env -i \
        PATH="$PATH" \
        HOME="$TEST_DIR/empty-home" \
        WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" \
        WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" \
        "$@" \
        bash "$SCRIPT"
}

# Assert the resolver's stderr names $1 as refused — proof the trust gate (not
# some unrelated rejection, e.g. a missing config.sh) is what turned it away.
assert_refusing() {
    local err
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$1" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing $1" "stderr names the dir refused for its $2"
}

# ---------------------------------------------------------------------------
# 1. Explicit override wins and must be a valid scripts dir.
# ---------------------------------------------------------------------------
test_override_wins() {
    setup
    local d="$TEST_DIR/override"
    make_scripts_dir "$d"

    local got
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d")"
    assert_equals "$d" "$got" "explicit WORKFLOW_SCRIPTS_DIR is returned verbatim"
    teardown
}

# ---------------------------------------------------------------------------
# 2. An override pointing at a dir WITHOUT config.sh is rejected (falls through);
#    with nothing else available, the resolver fails non-zero.
# ---------------------------------------------------------------------------
test_invalid_override_falls_through() {
    setup
    local d="$TEST_DIR/empty"
    command mkdir -p "$d" # no config.sh

    local rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "override without config.sh is not accepted"
    teardown
}

# ---------------------------------------------------------------------------
# 3. CLAUDE_PLUGIN_ROOT/scripts is used when no override is set.
# ---------------------------------------------------------------------------
test_plugin_root() {
    setup
    local root="$TEST_DIR/plugin"
    make_scripts_dir "$root/scripts"

    local got
    got="$(run_resolver "CLAUDE_PLUGIN_ROOT=$root")"
    assert_equals "$root/scripts" "$got" "CLAUDE_PLUGIN_ROOT/scripts is resolved"
    teardown
}

# ---------------------------------------------------------------------------
# 3b. CLAUDE_PLUGIN_ROOT whose scripts/ lacks config.sh is rejected and the
#     resolver falls through (mirrors the override fall-through, step 2 branch).
# ---------------------------------------------------------------------------
test_invalid_plugin_root_falls_through() {
    setup
    local root="$TEST_DIR/plugin"
    command mkdir -p "$root/scripts" # scripts/ exists but no config.sh

    local rc=0
    run_resolver "CLAUDE_PLUGIN_ROOT=$root" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "CLAUDE_PLUGIN_ROOT without config.sh is not accepted"
    teardown
}

# ---------------------------------------------------------------------------
# 4. Installed marketplace cache: newest version dir wins (sort -V), and the
#    override / plugin-root both take precedence over it.
# ---------------------------------------------------------------------------
test_installed_cache_newest_wins() {
    setup
    local home="$TEST_DIR/home"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    make_scripts_dir "$base/0.1.0/scripts"
    make_scripts_dir "$base/0.10.0/scripts" # newer; 0.10 > 0.2 only under -V
    make_scripts_dir "$base/0.2.0/scripts"

    # Pin WORKFLOW_DEV_MOUNT to a nonexistent path here too: this test bypasses
    # run_resolver's env -i, and a real /workspace/librarian dev mount would
    # otherwise satisfy the step-4 fallback if the cache probe failed (e.g. a
    # platform lacking `sort -V`), masking the assertion.
    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$home" WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.10.0/scripts" "$got" \
        "newest installed version is selected"
    teardown
}

# ---------------------------------------------------------------------------
# 4b. Cache loop skips a version whose scripts/ lacks config.sh and falls
#     through to the next-highest valid version (the is_scripts_dir guard).
# ---------------------------------------------------------------------------
test_installed_cache_skips_invalid_version() {
    setup
    local home="$TEST_DIR/home2"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    command mkdir -p "$base/0.10.0/scripts" # highest, but NO config.sh -> skip
    make_scripts_dir "$base/0.2.0/scripts"  # next-highest, valid

    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$home" WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.2.0/scripts" "$got" \
        "a version dir without config.sh is skipped for the next valid one"
    teardown
}

# ---------------------------------------------------------------------------
# 4c. Dev-mount fallback (resolution step 4): a valid WORKFLOW_DEV_MOUNT is
#     accepted when no override / plugin-root / cache resolves. This is the
#     only path available when librarian is a compose dev mount, not installed.
# ---------------------------------------------------------------------------
test_dev_mount_fallback() {
    setup
    local d="$TEST_DIR/devmount"
    make_scripts_dir "$d"

    # Empty HOME so the cache probe finds nothing; no override, no plugin root.
    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$TEST_DIR/empty-home" WORKFLOW_DEV_MOUNT="$d" bash "$SCRIPT")"
    assert_equals "$d" "$got" "valid WORKFLOW_DEV_MOUNT is accepted as the last resort"
    teardown
}

# ---------------------------------------------------------------------------
# 4d. Trust gate (#667): a valid override that is group- OR world-writable is
#     refused and the resolver falls through. With nothing trusted left, it
#     fails non-zero — a distrusted dir must never be exec'd by the justfile.
# ---------------------------------------------------------------------------
test_group_writable_override_refused() {
    setup
    local d="$TEST_DIR/gw-override"
    make_scripts_dir "$d"
    command chmod 0775 "$d" # group-writable -> distrusted

    local rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "group-writable override is refused"

    local err
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing" "stderr warns that the distrusted dir was skipped"
    teardown
}

test_world_writable_override_refused() {
    setup
    local d="$TEST_DIR/ww-override"
    make_scripts_dir "$d"
    command chmod 0707 "$d" # world-writable, not group -> still distrusted

    local rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "world-writable override is refused"
    teardown
}

# ---------------------------------------------------------------------------
# 4e. Trust gate falls THROUGH: a distrusted higher-priority source does not
#     hard-fail — a trusted lower-priority source still wins. Here a
#     world-writable CLAUDE_PLUGIN_ROOT/scripts is skipped in favour of a
#     trusted installed-cache dir.
# ---------------------------------------------------------------------------
test_distrusted_source_falls_through_to_trusted() {
    setup
    local home="$TEST_DIR/home-ft"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    make_scripts_dir "$base/0.3.0/scripts" # trusted (0755)

    local root="$TEST_DIR/plugin-ft"
    make_scripts_dir "$root/scripts"
    command chmod 0777 "$root/scripts" # distrusted -> must be skipped

    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$home" \
        CLAUDE_PLUGIN_ROOT="$root" \
        WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.3.0/scripts" "$got" \
        "distrusted plugin-root is skipped for the trusted installed cache"
    teardown
}

# ---------------------------------------------------------------------------
# 4f. Cache loop applies the trust gate: the newest version dir being
#     group/world-writable is skipped for the next-highest TRUSTED version
#     (parallels 4b's config.sh skip, but for the ownership/permission check).
# ---------------------------------------------------------------------------
test_installed_cache_skips_untrusted_version() {
    setup
    local home="$TEST_DIR/home-uc"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    make_scripts_dir "$base/0.10.0/scripts"   # highest...
    command chmod 0777 "$base/0.10.0/scripts" # ...but world-writable -> skip
    make_scripts_dir "$base/0.2.0/scripts"    # next-highest, trusted

    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$home" WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.2.0/scripts" "$got" \
        "an untrusted (writable) version dir is skipped for the next trusted one"
    teardown
}

# ---------------------------------------------------------------------------
# 4g. Dev-mount fallback is trust-gated too: a group/world-writable dev mount
#     (the shared multi-tenant case from finding #3) is refused.
# ---------------------------------------------------------------------------
test_untrusted_dev_mount_refused() {
    setup
    local d="$TEST_DIR/ww-devmount"
    make_scripts_dir "$d"
    command chmod 0775 "$d" # group-writable shared mount -> distrusted

    local rc=0
    env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$TEST_DIR/empty-home" WORKFLOW_DEV_MOUNT="$d" \
        bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "group-writable dev mount is refused"
    teardown
}

# ---------------------------------------------------------------------------
# 4h. The pinned container install (/opt/librarian, #608) is a candidate that
#     ranks below CLAUDE_PLUGIN_ROOT and above the installed cache (#1020).
# ---------------------------------------------------------------------------
test_opt_librarian_resolves() {
    setup
    local opt="$TEST_DIR/opt-librarian/scripts"
    make_scripts_dir "$opt"

    local got
    got="$(run_resolver "WORKFLOW_OPT_LIBRARIAN=$opt")"
    assert_equals "$opt" "$got" "/opt/librarian candidate is resolved when nothing ranks above it"
    teardown
}

test_opt_librarian_ranks_between_plugin_root_and_cache() {
    setup
    local opt="$TEST_DIR/opt-librarian/scripts"
    make_scripts_dir "$opt"
    local home="$TEST_DIR/home-rank"
    make_scripts_dir "$home/.claude/plugins/cache/librarian/workflow/9.9.9/scripts"
    local root="$TEST_DIR/plugin-rank"
    make_scripts_dir "$root/scripts"

    local got
    got="$(run_resolver "HOME=$home" "WORKFLOW_OPT_LIBRARIAN=$opt")"
    assert_equals "$opt" "$got" "/opt/librarian beats the installed cache"

    got="$(run_resolver "HOME=$home" "WORKFLOW_OPT_LIBRARIAN=$opt" "CLAUDE_PLUGIN_ROOT=$root")"
    assert_equals "$root/scripts" "$got" "CLAUDE_PLUGIN_ROOT beats /opt/librarian"
    teardown
}

# A distrusted /opt/librarian (the exact pre-#1020 shape: a group-writable baked
# tree) is skipped, and a trusted installed cache further down still wins.
test_distrusted_opt_librarian_falls_through_to_cache() {
    setup
    local opt="$TEST_DIR/opt-librarian-gw/scripts"
    make_scripts_dir "$opt"
    command chmod 0775 "$opt" # group-writable -> distrusted
    local home="$TEST_DIR/home-optft"
    make_scripts_dir "$home/.claude/plugins/cache/librarian/workflow/1.0.0/scripts"

    local got err
    got="$(run_resolver "HOME=$home" "WORKFLOW_OPT_LIBRARIAN=$opt" 2>/dev/null)"
    assert_equals "$home/.claude/plugins/cache/librarian/workflow/1.0.0/scripts" "$got" \
        "a group-writable /opt/librarian is skipped for the trusted cache"
    err="$(run_resolver "HOME=$home" "WORKFLOW_OPT_LIBRARIAN=$opt" 2>&1 >/dev/null)"
    assert_contains "$err" "refusing $opt" "stderr names the refused /opt/librarian dir"
    teardown
}

# The shipped default candidate path must be where the build actually extracts
# librarian. Every other test overrides WORKFLOW_OPT_LIBRARIAN, so this one runs
# the resolver with it UNSET and reads the path it really probed, then ties it
# to LIBRARIAN_DIR as claude-code-setup.sh extracts it.
test_opt_librarian_default_matches_build_install() {
    setup
    local repo_root librarian_dir err
    repo_root="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
    librarian_dir="$(command sed -n 's/^LIBRARIAN_DIR="\(.*\)"$/\1/p' \
        "$repo_root/lib/features/claude-code-setup.sh")"
    assert_not_empty "$librarian_dir" "claude-code-setup.sh defines LIBRARIAN_DIR"

    local out rc=0
    out="$(env -i PATH="$PATH" HOME="$TEST_DIR/empty-home" \
        WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" \
        WORKFLOW_SCRIPTS_DIR="$TEST_DIR/no-override" \
        bash "$SCRIPT" 2>"$TEST_DIR/stderr")" || rc=$?
    err="$(command cat "$TEST_DIR/stderr")"
    # Every other source is neutralized, so the default candidate is the only
    # thing that can resolve. Either branch exposes the path it probed: on a
    # machine where the real install is trusted (a fixed image) it is the
    # resolved stdout; elsewhere it is named in the "Looked in" guidance.
    if [ "$rc" -eq 0 ]; then
        assert_equals "$librarian_dir/plugins/workflow/scripts" "$out" \
            "the resolved default /opt/librarian candidate is the build's extracted scripts dir"
    else
        assert_contains "$err" "\$CLAUDE_PLUGIN_ROOT/scripts, $librarian_dir/plugins/workflow/scripts," \
            "the default /opt/librarian candidate is the build's extracted scripts dir"
    fi
    teardown
}

# ---------------------------------------------------------------------------
# 4i. Ownership half of the trust rule (#1020). These need a fixture owned by
#     ANOTHER uid, which only root can create: they run as root or via
#     passwordless `sudo -n` (GitHub-hosted runners have it, so CI exercises
#     them) and otherwise SKIP visibly — never pass silently.
#
# Root-owned fixtures live under $TEST_SCRATCH_BASE (not the suite's mktemp
# TEST_DIR) so the privileged cleanup can be fenced to the framework's scratch
# tree: guarded_privileged_rm refuses any path that is empty, contains a `..`
# component, or does not sit strictly under $TEST_SCRATCH_BASE (#746).
# ---------------------------------------------------------------------------
as_root=()
have_root() {
    if [ "$(/usr/bin/id -u)" = "0" ]; then
        as_root=()
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        as_root=(sudo -n)
        return 0
    fi
    return 1
}

guarded_privileged_rm() {
    local path="${1:-}"
    if [ -z "$path" ] || [ -z "${TEST_SCRATCH_BASE:-}" ]; then
        command echo "guarded_privileged_rm: refusing empty path or unset TEST_SCRATCH_BASE" >&2
        return 1
    fi
    case "/$path/" in
        */../*)
            command echo "guarded_privileged_rm: refusing path with '..': $path" >&2
            return 1
            ;;
    esac
    case "$path" in
        "$TEST_SCRATCH_BASE"/?*) ;;
        *)
            command echo "guarded_privileged_rm: refusing $path — not under $TEST_SCRATCH_BASE" >&2
            return 1
            ;;
    esac
    "${as_root[@]}" /usr/bin/rm -rf -- "$path"
}

# Create a scripts dir under the scratch base owned by $1 with mode $2; prints
# the fixture root (the thing to hand to guarded_privileged_rm).
make_owned_scripts_dir() {
    local owner="$1" mode="$2" fixture
    command mkdir -p "$TEST_SCRATCH_BASE"
    fixture="$(command mktemp -d "$TEST_SCRATCH_BASE/wsd-owned.XXXXXX")"
    command chmod 0755 "$fixture"
    make_scripts_dir "$fixture/scripts"
    "${as_root[@]}" /usr/bin/chown -R "$owner" "$fixture/scripts"
    "${as_root[@]}" /usr/bin/chmod "$mode" "$fixture/scripts"
    command printf '%s\n' "$fixture"
}

test_root_owned_dir_accepted() {
    setup
    # Run as root, the fixture's owner IS the invoking user, so it would be
    # accepted by the owned-by-us clause and never exercise `-user 0`.
    if [ "$(/usr/bin/id -u)" = "0" ]; then
        skip_test "running as root: the root-owner clause is indistinguishable from owned-by-us; needs a non-root user with passwordless sudo"
        teardown
        return 0
    fi
    if ! have_root; then
        skip_test "needs passwordless sudo to create a root-owned fixture"
        teardown
        return 0
    fi
    local fixture got
    fixture="$(make_owned_scripts_dir 0:0 0755)"
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts")"
    assert_equals "$fixture/scripts" "$got" "a root-owned 0755 scripts dir is trusted"
    guarded_privileged_rm "$fixture"
    teardown
}

test_root_owned_writable_refused() {
    setup
    if ! have_root; then
        skip_test "needs a root runner or passwordless sudo to create a root-owned fixture"
        teardown
        return 0
    fi
    local mode fixture rc err
    # Group-write (0775) and world-write-only (0757): the write half of the rule
    # holds for a root owner on each bit independently.
    for mode in 0775 0757; do
        rc=0
        fixture="$(make_owned_scripts_dir 0:0 "$mode")"
        run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" >/dev/null 2>&1 || rc=$?
        assert_not_equals "0" "$rc" "a root-owned $mode dir is still refused"
        err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" 2>&1 >/dev/null || true)"
        assert_contains "$err" "refusing $fixture/scripts" "stderr names the refused root-owned $mode dir"
        guarded_privileged_rm "$fixture"
    done
    teardown
}

test_other_user_owned_dir_refused() {
    setup
    if ! have_root; then
        skip_test "needs a root runner or passwordless sudo to create another user's fixture"
        teardown
        return 0
    fi
    local other
    if /usr/bin/id nobody >/dev/null 2>&1 && [ "$(/usr/bin/id -u nobody)" != "$(/usr/bin/id -u)" ]; then
        other="$(/usr/bin/id -u nobody):$(/usr/bin/id -g nobody)"
    else
        skip_test "no 'nobody' account distinct from the invoking user"
        teardown
        return 0
    fi
    local fixture rc=0 err
    fixture="$(make_owned_scripts_dir "$other" 0755)"
    run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a 0755 dir owned by another non-root user is refused"
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing $fixture/scripts" "stderr names the refused other-user dir"
    guarded_privileged_rm "$fixture"
    teardown
}

# Ownership half of the per-entry rule (#1026): a 0644 (not writable) entry
# owned by another non-root user inside our own 0755 dir is refused — that user
# can rewrite the file the justfile is about to exec.
test_other_user_owned_entry_refused() {
    setup
    if ! have_root; then
        skip_test "needs a root runner or passwordless sudo to create another user's entry"
        teardown
        return 0
    fi
    local other
    if /usr/bin/id nobody >/dev/null 2>&1 && [ "$(/usr/bin/id -u nobody)" != "$(/usr/bin/id -u)" ]; then
        other="$(/usr/bin/id -u nobody):$(/usr/bin/id -g nobody)"
    else
        skip_test "no 'nobody' account distinct from the invoking user"
        teardown
        return 0
    fi
    local fixture rc=0 err
    command mkdir -p "$TEST_SCRATCH_BASE"
    fixture="$(command mktemp -d "$TEST_SCRATCH_BASE/wsd-entry.XXXXXX")"
    command chmod 0755 "$fixture"
    make_scripts_dir "$fixture/scripts"
    "${as_root[@]}" /usr/bin/chown "$other" "$fixture/scripts/config.sh"
    run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a 0644 entry owned by another non-root user is refused"
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$fixture/scripts" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing $fixture/scripts" "stderr names the dir refused for its foreign-owned entry"
    guarded_privileged_rm "$fixture"
    teardown
}

# The cleanup fence itself: it must refuse anything outside the scratch tree
# BEFORE invoking rm, so it is exercised with no privilege at all.
test_guarded_privileged_rm_refuses_outside_scratch() {
    setup
    local victim="$TEST_DIR/outside-scratch"
    command mkdir -p "$victim"
    local rc
    for bad in "" "$victim" "$TEST_SCRATCH_BASE" "$TEST_SCRATCH_BASE/../x" "/"; do
        rc=0
        (
            as_root=()
            guarded_privileged_rm "$bad"
        ) 2>/dev/null || rc=$?
        assert_not_equals "0" "$rc" "guarded_privileged_rm refuses '${bad}'"
    done
    if [ -d "$victim" ]; then
        pass_test "out-of-scratch directory survived the refused removal"
    else
        fail_test "guarded_privileged_rm deleted a directory outside the scratch base"
    fi
    teardown
}

# ---------------------------------------------------------------------------
# 4j. The trust gate covers entries INSIDE the dir (#1026): a trusted 0755 dir
#     holding a group/world-writable config.sh or sibling script is refused with
#     a visible warning — the justfile would exec that writable file.
# ---------------------------------------------------------------------------
test_writable_config_refused() {
    setup
    local d="$TEST_DIR/writable-config" mode rc err
    make_scripts_dir "$d"
    for mode in 0666 0664; do
        command chmod "$mode" "$d/config.sh"
        rc=0
        run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
        assert_not_equals "0" "$rc" "0755 dir with a $mode config.sh is refused"
        err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d" 2>&1 >/dev/null || true)"
        assert_contains "$err" "refusing $d" "stderr names the dir refused for its $mode config.sh"
    done
    teardown
}

test_writable_sibling_script_refused() {
    setup
    local d="$TEST_DIR/writable-sibling" rc=0 err
    make_scripts_dir "$d"
    command touch "$d/golem-status.sh"
    command chmod 0775 "$d/golem-status.sh" # group-writable exec'd sibling
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "0755 dir with a 0775 sibling script is refused"
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing $d" "stderr names the dir refused for its writable sibling"
    teardown
}

# A symlink inode is always 0777 on Linux, so the gate must judge the TARGET:
# a link to a world-writable file outside the dir is refused.
test_symlink_to_writable_target_refused() {
    setup
    local d="$TEST_DIR/symlinked" target="$TEST_DIR/outside-config.sh" rc=0 err
    command mkdir -p "$d"
    command chmod 0755 "$d"
    command touch "$target"
    command chmod 0666 "$target"
    command ln -s "$target" "$d/config.sh"
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "config.sh symlinked to a writable file is refused"
    err="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d" 2>&1 >/dev/null || true)"
    assert_contains "$err" "refusing $d" "stderr names the dir refused for its symlinked writable config.sh"

    # ...while a link to a SAFE (0644, ours) target leaves the dir trusted —
    # judging the target must not mean refusing every symlink.
    command chmod 0644 "$target"
    local got
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d")"
    assert_equals "$d" "$got" "config.sh symlinked to a safe file is still trusted"
    teardown
}

# A dangling link can't be judged by its target, so `find -L` reports the link
# inode itself (0777) and the dir is refused: the gate fails closed.
test_dangling_symlink_refused() {
    setup
    local d="$TEST_DIR/dangling" rc=0
    make_scripts_dir "$d"
    command ln -s "$TEST_DIR/does-not-exist" "$d/golem-status.sh"
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a dangling symlink inside the dir fails closed"
    assert_refusing "$d" "dangling symlink"
    teardown
}

# The entry scan is recursive, not depth-1 only: a writable file inside a
# subdirectory (depth 2) or a group-writable subdirectory refuses the dir.
test_nested_writable_entry_refused() {
    setup
    local d="$TEST_DIR/nested" rc
    make_scripts_dir "$d"
    command mkdir -p "$d/lib"
    command chmod 0755 "$d/lib"
    command touch "$d/lib/helper.sh"
    command chmod 0666 "$d/lib/helper.sh"
    rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a 0666 file in a subdirectory is refused"
    assert_refusing "$d" "0666 nested file"

    command chmod 0644 "$d/lib/helper.sh"
    command chmod 0775 "$d/lib"
    rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a group-writable subdirectory is refused"
    assert_refusing "$d" "group-writable subdirectory"
    teardown
}

# The scan depth is pinned: a writable file at depth 3 (the deepest level
# examined) is refused, and ANY entry at depth 4 refuses the dir even when it is
# safe — the scan never examined it, so it cannot be vouched for.
test_scan_depth_boundary() {
    setup
    local d="$TEST_DIR/deep" rc
    make_scripts_dir "$d"
    command mkdir -p "$d/a/b"
    command chmod 0755 "$d/a" "$d/a/b"
    command touch "$d/a/b/at-depth-3.sh"
    command chmod 0666 "$d/a/b/at-depth-3.sh"
    rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "a 0666 file at depth 3 is refused"
    assert_refusing "$d" "0666 file at depth 3"

    command chmod 0644 "$d/a/b/at-depth-3.sh"
    local got
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d")"
    assert_equals "$d" "$got" "a safe tree exactly 3 levels deep is trusted"

    command mkdir -p "$d/a/b/c"
    command chmod 0755 "$d/a/b/c"
    command touch "$d/a/b/c/at-depth-4.sh"
    command chmod 0644 "$d/a/b/c/at-depth-4.sh"
    rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "an entry beyond the scan depth fails closed"
    assert_refusing "$d" "entry beyond the scan depth"
    teardown
}

# Writable entry ⇒ fall through, not hard-fail: a plugin root whose config.sh is
# world-writable is skipped and a trusted installed-cache dir still wins.
test_writable_entry_falls_through_to_trusted() {
    setup
    local home="$TEST_DIR/home-we"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    make_scripts_dir "$base/0.4.0/scripts" # trusted

    local root="$TEST_DIR/plugin-we"
    make_scripts_dir "$root/scripts"
    command chmod 0666 "$root/scripts/config.sh" # dir is 0755, entry is not

    local got
    got="$(env -i PATH="$PATH" WORKFLOW_OPT_LIBRARIAN="$TEST_DIR/no-opt-librarian" HOME="$home" \
        CLAUDE_PLUGIN_ROOT="$root" \
        WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.4.0/scripts" "$got" \
        "plugin-root with a writable config.sh is skipped for the trusted cache"
    teardown
}

# Guard against over-refusal: safe entries (0644 config, 0755 scripts, a 0755
# subdir with a 0644 file) leave a trusted dir trusted.
test_trusted_dir_with_safe_entries_accepted() {
    setup
    local d="$TEST_DIR/safe-entries" got
    make_scripts_dir "$d"
    command touch "$d/golem-status.sh"
    command chmod 0755 "$d/golem-status.sh"
    command mkdir -p "$d/lib"
    command chmod 0755 "$d/lib"
    command touch "$d/lib/helper.sh"
    command chmod 0644 "$d/lib/helper.sh"
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d")"
    assert_equals "$d" "$got" "a 0755 dir with only safe entries is still trusted"
    teardown
}

# ---------------------------------------------------------------------------
# 5. Nothing resolvable: exit non-zero, print nothing on stdout, guidance on
#    stderr.
# ---------------------------------------------------------------------------
test_not_found() {
    setup
    local out rc=0
    out="$(run_resolver 2>/dev/null)" || rc=$?
    assert_not_equals "0" "$rc" "resolver exits non-zero when nothing is found"
    assert_equals "" "$out" "resolver prints nothing on stdout when not found"

    local err
    err="$(run_resolver 2>&1 >/dev/null || true)"
    assert_contains "$err" "could not locate" "stderr carries guidance on failure"
    teardown
}

run_test test_override_wins
run_test test_invalid_override_falls_through
run_test test_plugin_root
run_test test_invalid_plugin_root_falls_through
run_test test_installed_cache_newest_wins
run_test test_installed_cache_skips_invalid_version
run_test test_dev_mount_fallback
run_test test_group_writable_override_refused
run_test test_world_writable_override_refused
run_test test_distrusted_source_falls_through_to_trusted
run_test test_installed_cache_skips_untrusted_version
run_test test_untrusted_dev_mount_refused
run_test test_writable_config_refused
run_test test_writable_sibling_script_refused
run_test test_symlink_to_writable_target_refused
run_test test_dangling_symlink_refused
run_test test_nested_writable_entry_refused
run_test test_scan_depth_boundary
run_test test_writable_entry_falls_through_to_trusted
run_test test_trusted_dir_with_safe_entries_accepted
run_test test_opt_librarian_resolves
run_test test_opt_librarian_ranks_between_plugin_root_and_cache
run_test test_distrusted_opt_librarian_falls_through_to_cache
run_test test_opt_librarian_default_matches_build_install
run_test test_root_owned_dir_accepted
run_test test_root_owned_writable_refused
run_test test_other_user_owned_dir_refused
run_test test_other_user_owned_entry_refused
run_test test_guarded_privileged_rm_refuses_outside_scratch
run_test test_not_found

generate_report
