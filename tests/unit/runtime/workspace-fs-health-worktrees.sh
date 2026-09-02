#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — linked worktree
# traversal (issue #882).
#
# A linked worktree is a third root class, invisible to both existing
# enumerations: it is not in the superproject's index (so `ls-files` never names
# it) and it is not a gitlink (so the submodule walk never descends into it).
# Every fresh golem worktree therefore arrived with its tracked symlinks already
# reading as modified.
#
# Sibling-file shape follows the precedent set by
# workspace-fs-health-submodules.sh and workspace-fs-health-cron-entry.sh.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Linked Worktree Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health,
# run_fs_health_stderr, get_ignorecase, seed_symlinks, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# ============================================================================
# Fixtures
# ============================================================================

# Install a stat stub that reports "$1" for every symlink it is asked about and
# defers to the real stat otherwise. Sets FS_HEALTH_STAT.
#
# nlink=0 and st_size=0 are filesystem cache artifacts that cannot be produced
# on demand, so substituting the probe is the only way to exercise the repair
# rather than just its inaction. Same seam the submodule suite uses.
# Args: $1 = the "%h %s" string to report (e.g. "0 7", "1 0")
stub_stat() {
    local reported="$1"
    local stub="$TEST_TEMP_DIR/stat-stub"

    command cat >"$stub" <<STAT_STUB_EOF
#!/bin/bash
# Only intercept the exact '-c %h %s' probe on a symlink; everything else
# falls through, so an unrelated stat call in the script under test is not
# silently given fabricated numbers.
if [ "\$1" = "-c" ] && [ "\$2" = '%h %s' ] && [ -L "\$3" ]; then
    command printf '%s\n' "$reported"
    exit 0
fi
exec /usr/bin/stat "\$@"
STAT_STUB_EOF
    command chmod +x "$stub"
    export FS_HEALTH_STAT="$stub"
}

# Install a git stub that FAILS one specific `rev-parse` probe (or the
# `worktree list` call) and defers to the real git for everything else. Sets
# FS_HEALTH_GIT (issue #886).
#
# The four resolution fallbacks in repair_linked_worktrees are `|| return 0` by
# design — this script must never be why a container fails to start — so their
# failure path is invisible from the outside. That is precisely how the
# git-2.31 `--path-format=absolute` regression no-opped the entire #882 feature
# on Debian 11 (git 2.30.2) with no diagnostic at all. These tests make each
# fallback observable.
#
# A PATH-shadowed stub cannot be used: /etc/bash_env rebuilds PATH for
# non-interactive bash, so the stub is silently ignored inside the script's own
# bash invocation (.claude/memory/bash-env-breaks-path-stubs.md). Hence the
# FS_HEALTH_GIT seam, mirroring stub_stat's use of FS_HEALTH_STAT.
#
# Args: $1 = the rev-parse flag to fail (e.g. "--show-toplevel"), or the
#            literal "worktree" to fail `worktree list`
stub_git_failing() {
    local failing="$1"
    local stub="$TEST_TEMP_DIR/git-stub"

    # Resolve the real git ONCE, here, rather than hardcoding a path: this image
    # has both /usr/local/bin/git and /usr/bin/git, and PATH picks the former.
    # Baking in the wrong one would make the stub defer to a different git than
    # the rest of the suite uses.
    local real_git
    real_git=$(command -v git)

    command cat >"$stub" <<GIT_STUB_EOF
#!/bin/bash
# Scan the whole argv: the script calls \`git -C <dir> rev-parse <flag>\`, so the
# flag is never at a fixed position. Everything not matched falls through to the
# real git, so the fixture repo keeps working normally.
for _arg in "\$@"; do
    if [ "\$_arg" = "$failing" ]; then
        exit 128
    fi
done
exec "$real_git" "\$@"
GIT_STUB_EOF
    command chmod +x "$stub"
    export FS_HEALTH_GIT="$stub"
}

# Add a linked worktree containing a tracked symlink, mirroring the real
# .worktrees/issue-N layout the golem flow creates.
#
# The symlink is committed on the NEW BRANCH rather than seeded in the parent,
# so the fixture does not depend on seed_symlinks having run and the worktree
# has content of its own.
#
# Args: $1 = path within the project (e.g. ".worktrees/issue-882")
# Echoes the worktree's absolute path.
add_worktree() {
    local rel="$1"
    local wt="$PROJECT_ROOT/$rel"
    local branch="wt-${rel//\//-}"

    # A worktree cannot be added from a repo with no commits.
    if ! git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        command echo "base" >"$PROJECT_ROOT/base.txt"
        git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
        git -C "$PROJECT_ROOT" commit -qm "base commit" >/dev/null 2>&1
    fi

    git -C "$PROJECT_ROOT" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1

    command echo "wt content" >"$wt/CLAUDE.md"
    command ln -s CLAUDE.md "$wt/AGENTS.md"
    git -C "$wt" add -A >/dev/null 2>&1
    git -C "$wt" commit -qm "seed worktree symlink" >/dev/null 2>&1

    command printf '%s\n' "$wt"
}

# ============================================================================
# Premise
# ============================================================================

test_superproject_index_hides_worktree_links() {
    # The bug itself, pinned: this is what the existing enumerations see. If it
    # ever stops holding, the traversal below is solving a problem that moved.
    add_worktree ".worktrees/issue-882" >/dev/null

    local matches
    matches=$(git -C "$PROJECT_ROOT" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^(120000|160000) / { print $2 }' |
        /usr/bin/grep -c ".worktrees/" || true)

    assert_equals "0" "$matches" \
        "Superproject ls-files must not enumerate a linked worktree (the #882 premise)"
}

# ============================================================================
# Repair
# ============================================================================

test_worktree_symlink_repaired() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue-882/AGENTS.md" \
        "A stale symlink inside a linked worktree should be found and reported"
    assert_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "A stale symlink inside a linked worktree should be repaired"
    assert_equals "CLAUDE.md" "$(command readlink "$wt/AGENTS.md")" \
        "Worktree symlink target must be preserved"
}

test_multiple_worktrees_all_reached() {
    # The list is flat, so every entry must be visited — not just the first.
    add_worktree ".worktrees/issue-100" >/dev/null
    add_worktree ".worktrees/issue-200" >/dev/null
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed .worktrees/issue-100/AGENTS.md" \
        "The first linked worktree should be repaired"
    assert_contains "$output" "refreshed .worktrees/issue-200/AGENTS.md" \
        "The second linked worktree should be repaired too"
}

test_superproject_still_repaired_alongside() {
    # The worktree pass is additive: it must not displace the main root's own
    # repair.
    seed_symlinks
    add_worktree ".worktrees/issue-882" >/dev/null
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed good.link" \
        "The superproject's own symlinks must still be repaired"
    assert_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "The linked worktree must be repaired in the same pass"
}

test_healthy_worktree_leaves_tree_clean() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")

    local output
    output=$(run_fs_health_stderr sensitive)
    assert_empty "$output" \
        "A healthy linked worktree should produce no output"

    local wt_status
    wt_status=$(git -C "$wt" status --porcelain 2>/dev/null)
    assert_empty "$wt_status" \
        "The worktree should stay clean after a no-op pass"
}

test_worktree_ignorecase_reported_once() {
    # core.ignorecase is SHARED repo-wide config, and the superproject's own
    # repair runs first — so by the time the worktree root is reached the value
    # is already correct. A bare `assert_equals true "$(get_ignorecase)"` would
    # therefore pass whether the worktree pass ran, was skipped, or was broken:
    # it re-confirms what the superproject suite already covers.
    #
    # What IS observable, and what actually matters, is that the second visit
    # takes check_ignorecase's "already correct — say nothing" branch. So assert
    # on the REPORT: exactly one "case-insensitive mount" line for the whole run.
    # A worktree pass that re-reported (or, worse, re-wrote) the shared config
    # would emit a second line naming the worktree root, and that is the noise a
    # user would actually see.
    add_worktree ".worktrees/issue-882" >/dev/null
    git -C "$PROJECT_ROOT" config --unset core.ignorecase 2>/dev/null || true

    local output mount_lines
    output=$(run_fs_health_stderr insensitive)

    assert_equals "true" "$(get_ignorecase)" \
        "core.ignorecase should be aligned with a linked worktree present"

    mount_lines=$(command printf '%s\n' "$output" |
        /usr/bin/grep -c "is on a case-insensitive mount" || true)
    assert_equals "1" "$mount_lines" \
        "The shared config must be reported once, not again for the worktree root"
    assert_not_contains "$output" ".worktrees/issue-882 is on a case-insensitive mount" \
        "The worktree root must not re-report an already-correct shared config"
}

# Add a worktree at an absolute path OUTSIDE the project root, with a tracked
# symlink. `git worktree add` can place one anywhere, not just under
# .worktrees/ — that entry has no useful relative form and exercises the
# absolute-label branch every in-tree fixture skips.
# Args: $1 = absolute path for the worktree
seed_outside_worktree() {
    local outside="$1"

    if ! git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        command echo "base" >"$PROJECT_ROOT/base.txt"
        git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
        git -C "$PROJECT_ROOT" commit -qm "base commit" >/dev/null 2>&1
    fi

    git -C "$PROJECT_ROOT" worktree add -q -b wt-outside "$outside" >/dev/null 2>&1

    command echo "wt content" >"$outside/CLAUDE.md"
    command ln -s CLAUDE.md "$outside/AGENTS.md"
    git -C "$outside" add -A >/dev/null 2>&1
    git -C "$outside" commit -qm "seed outside worktree" >/dev/null 2>&1
}

test_worktree_path_with_spaces_is_reached() {
    # The porcelain parse cuts after the first space rather than splitting on
    # whitespace, specifically so a path containing spaces survives. Without a
    # fixture that has one, a later "simplification" to `awk '{print $2}'` would
    # truncate such paths and still pass the whole suite.
    # Built inline rather than via add_worktree: that helper derives the branch
    # name from the path, and git rejects a branch name containing spaces. The
    # PATH is what is under test here, so the branch gets a separate valid name.
    local wt="$PROJECT_ROOT/.worktrees/issue 882 with spaces"

    command echo "base" >"$PROJECT_ROOT/base.txt"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "base commit" >/dev/null 2>&1
    git -C "$PROJECT_ROOT" worktree add -q -b wt-spaced "$wt" >/dev/null 2>&1

    command echo "wt content" >"$wt/CLAUDE.md"
    command ln -s CLAUDE.md "$wt/AGENTS.md"
    git -C "$wt" add -A >/dev/null 2>&1
    git -C "$wt" commit -qm "seed spaced worktree" >/dev/null 2>&1

    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue 882 with spaces/AGENTS.md" \
        "A worktree path containing spaces must survive the porcelain parse"
    assert_equals "CLAUDE.md" "$(command readlink "$wt/AGENTS.md")" \
        "Its symlink target must be preserved"
}

test_submodule_inside_worktree_reached() {
    # Both the script comment and the docs claim a worktree's own submodules are
    # walked (it is handed to repair_repo_tree at depth 0). Pin that end to end,
    # rather than trusting the claim.
    local wt sub_origin
    wt=$(add_worktree ".worktrees/issue-882")

    sub_origin="$TEST_TEMP_DIR/origin-wt-sub"
    command mkdir -p "$sub_origin"
    git -C "$sub_origin" init -q .
    git -C "$sub_origin" config user.email "test@example.com"
    git -C "$sub_origin" config user.name "Test User"
    command echo "sub content" >"$sub_origin/CLAUDE.md"
    command ln -s CLAUDE.md "$sub_origin/AGENTS.md"
    git -C "$sub_origin" add -A >/dev/null 2>&1
    git -C "$sub_origin" commit -qm "seed wt submodule" >/dev/null 2>&1

    git -C "$wt" -c protocol.file.allow=always \
        submodule add -q "$sub_origin" "vendor" >/dev/null 2>&1
    git -C "$wt" commit -qm "add submodule" >/dev/null 2>&1

    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue-882/vendor/AGENTS.md" \
        "A submodule INSIDE a linked worktree should be walked and labeled by full path"
    assert_equals "CLAUDE.md" "$(command readlink "$wt/vendor/AGENTS.md")" \
        "The nested submodule's symlink target must be preserved"
}

test_worktree_outside_project_root_uses_absolute_label() {
    # The absolute-label else-branch: a worktree outside the project root keeps
    # its full path in the log line.
    local outside="$TEST_TEMP_DIR/outside-wt"
    seed_outside_worktree "$outside"

    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "${outside}/AGENTS.md" \
        "A worktree outside the project root should be labeled by absolute path"
    assert_equals "CLAUDE.md" "$(command readlink "$outside/AGENTS.md")" \
        "Its symlink target must be preserved"
}

test_outside_worktree_does_not_write_shared_config() {
    # An out-of-tree worktree can sit on a DIFFERENT mount, so the project's
    # case-sensitivity verdict does not describe it — unlike a submodule, which
    # is inside the project's worktree by construction.
    #
    # But core.ignorecase is NOT per-worktree: every worktree shares the single
    # .git/config, so there is no "align just this one" to perform. Writing it
    # from an out-of-tree worktree's pass would rewrite the setting for the
    # superproject and every sibling. The pass must therefore leave the config
    # alone and let the project's own mount stay the authority — while still
    # doing the symlink repair, which IS per-worktree.
    local outside="$TEST_TEMP_DIR/outside-wt"
    seed_outside_worktree "$outside"
    git -C "$PROJECT_ROOT" config --unset core.ignorecase 2>/dev/null || true

    stub_stat "0 7"

    # insensitive: the superproject's own alignment SHOULD happen, so this pins
    # that the suppression is scoped to the worktree pass and does not disable
    # the repair the script exists to do.
    local output
    output=$(run_fs_health_stderr insensitive)

    assert_equals "true" "$(get_ignorecase)" \
        "The superproject's own core.ignorecase must still be aligned"
    assert_contains "$output" "${outside}/AGENTS.md" \
        "The out-of-tree worktree's symlink repair must still run"
    assert_not_contains "$output" "$outside is on a case-insensitive mount" \
        "The out-of-tree worktree must not report a case-sensitivity verdict of its own"
}

test_outside_worktree_never_flips_shared_config() {
    # The inverse, and the one that would actually corrupt state: with the
    # PROJECT itself on a case-sensitive mount, the out-of-tree worktree's pass
    # must not set core.ignorecase=true on the shared config.
    local outside="$TEST_TEMP_DIR/outside-wt"
    seed_outside_worktree "$outside"
    git -C "$PROJECT_ROOT" config --unset core.ignorecase 2>/dev/null || true

    stub_stat "0 7"
    run_fs_health sensitive >/dev/null

    assert_equals "unset" "$(get_ignorecase)" \
        "An out-of-tree worktree must never write the repo's shared core.ignorecase"
}

# ============================================================================
# Anti-recursion gate
# ============================================================================

test_run_from_worktree_does_not_enumerate_siblings() {
    # `git worktree list` is repo-GLOBAL: asked from inside a linked worktree it
    # returns the whole set, including the caller. Without the
    # main-worktree-only gate this run would repair its own root twice and sweep
    # in every sibling. Pins that gate.
    local wt_a
    wt_a=$(add_worktree ".worktrees/issue-100")
    add_worktree ".worktrees/issue-200" >/dev/null
    stub_stat "0 7"

    local output
    output=$(PROJECT_ROOT="$wt_a" run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed AGENTS.md" \
        "Running against a worktree should repair that worktree's own links"
    assert_not_contains "$output" "issue-200" \
        "Running against a worktree must not enumerate its siblings"
    assert_not_contains "$output" ".worktrees/issue-100" \
        "Running against a worktree must not re-enter itself as a linked worktree"
}

# ============================================================================
# Git environment leak immunity (issue #886, AC1)
# ============================================================================

test_git_dir_leak_does_not_defeat_the_gate() {
    # git reads GIT_DIR/GIT_WORK_TREE BEFORE honoring `-C`, so a caller that
    # exported either would point all three rev-parse probes at a different
    # repository — while the code still reads as if scoped to PROJECT_ROOT. The
    # gate those probes feed is what keeps the walk loop-free, so a skewed
    # answer either silently disables the #882 repair or enumerates the wrong
    # repo's worktrees.
    local wt
    wt=$(add_worktree ".worktrees/issue-886")

    # A second, unrelated repo for the environment to point at.
    local foreign="$TEST_TEMP_DIR/foreign"
    command mkdir -p "$foreign"
    git -C "$foreign" init -q .
    git -C "$foreign" config user.email "test@example.com"
    git -C "$foreign" config user.name "Test User"
    command echo "foreign" >"$foreign/f.txt"
    git -C "$foreign" add -A >/dev/null 2>&1
    git -C "$foreign" commit -qm "foreign base" >/dev/null 2>&1

    stub_stat "0 7"

    local output
    output=$(GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign" \
        run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed .worktrees/issue-886/AGENTS.md" \
        "A leaked GIT_DIR/GIT_WORK_TREE must not stop PROJECT_ROOT's worktree from being repaired"
    assert_equals "CLAUDE.md" "$(command readlink "$wt/AGENTS.md")" \
        "The repaired symlink's target must be preserved under a leaked git environment"
}

test_git_common_dir_leak_does_not_defeat_the_gate() {
    # The OTHER half of the gate's equality. The issue named only GIT_DIR and
    # GIT_WORK_TREE; GIT_COMMON_DIR overrides --git-common-dir the same way, so
    # leaking it alone could make git_dir != common_dir and silently classify
    # the main checkout as a linked worktree — disabling the whole pass.
    local wt
    wt=$(add_worktree ".worktrees/issue-886")

    local foreign="$TEST_TEMP_DIR/foreign-common"
    command mkdir -p "$foreign"
    git -C "$foreign" init -q .

    stub_stat "0 7"

    local output
    output=$(GIT_COMMON_DIR="$foreign/.git" run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed .worktrees/issue-886/AGENTS.md" \
        "A leaked GIT_COMMON_DIR must not disable the linked-worktree pass"
}

test_git_index_file_leak_does_not_hide_symlinks() {
    # Reaches PAST the worktree pass into the two original repairs: ls-files is
    # what check_symlinks and the submodule walk iterate, and GIT_INDEX_FILE
    # makes it enumerate a foreign index — so every tracked symlink would look
    # like it does not exist.
    seed_symlinks

    local foreign="$TEST_TEMP_DIR/foreign-index"
    command mkdir -p "$foreign"
    git -C "$foreign" init -q .
    command echo "unrelated" >"$foreign/other.txt"
    git -C "$foreign" add -A >/dev/null 2>&1

    stub_stat "0 7"

    local output
    output=$(GIT_INDEX_FILE="$foreign/.git/index" run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed good.link" \
        "A leaked GIT_INDEX_FILE must not hide the superproject's own tracked symlinks"
}

# ============================================================================
# Resolution fail-safes (issue #886, AC2)
# ============================================================================
#
# Every probe below is guarded by `|| return 0`: the pass is designed to fail
# silent-and-safe so it can never be why a container fails to start. That makes
# the failure path invisible from outside — exactly how the git-2.31
# `--path-format=absolute` regression no-opped the whole #882 feature on Debian
# 11 with no diagnostic. These pin the no-op as OBSERVABLE BEHAVIOR (worktree
# left unrepaired, run still succeeds) rather than as a code comment.

test_git_dir_probe_failure_is_a_silent_noop() {
    local wt
    wt=$(add_worktree ".worktrees/issue-886")
    stub_stat "0 7"
    stub_git_failing "--git-dir"

    local before output status=0
    before=$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A failed --git-dir probe must never make the run fail"
    assert_not_contains "$output" ".worktrees/issue-886" \
        "A failed --git-dir probe must skip the worktree pass silently"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)" \
        "A failed --git-dir probe must leave the worktree symlink untouched"
}

test_git_common_dir_probe_failure_is_a_silent_noop() {
    local wt
    wt=$(add_worktree ".worktrees/issue-886")
    stub_stat "0 7"
    stub_git_failing "--git-common-dir"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A failed --git-common-dir probe must never make the run fail"
    assert_not_contains "$output" ".worktrees/issue-886" \
        "A failed --git-common-dir probe must skip the worktree pass silently"
}

test_show_toplevel_probe_failure_is_a_silent_noop() {
    local wt
    wt=$(add_worktree ".worktrees/issue-886")
    stub_stat "0 7"
    stub_git_failing "--show-toplevel"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A failed --show-toplevel probe must never make the run fail"
    assert_not_contains "$output" ".worktrees/issue-886" \
        "A failed --show-toplevel probe must skip the worktree pass silently"
}

test_unsupported_flag_noops_without_killing_the_superproject_repair() {
    # The #884 regression in miniature: a probe git does not understand (there,
    # --path-format=absolute against Debian 11's git 2.30.2) makes the pass
    # vanish. The load-bearing half is the SECOND assertion — the superproject's
    # own repair must survive, so the failure is scoped to the worktree pass and
    # does not take the whole script down with it.
    seed_symlinks
    add_worktree ".worktrees/issue-886" >/dev/null
    stub_stat "0 7"
    stub_git_failing "--git-dir"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "An unsupported probe must not fail the run"
    assert_not_contains "$output" ".worktrees/issue-886" \
        "An unsupported probe silently disables the worktree pass"
    assert_contains "$output" "refreshed good.link" \
        "The superproject's own repair must survive a failed worktree probe"
}

test_worktree_list_failure_is_a_silent_noop() {
    # BEHAVIOR PIN, not a fail-safe proof — and the distinction is the point of
    # this issue, so it is recorded rather than glossed.
    #
    # The other four tests in this section are demonstrably red/green: strip the
    # matching `|| return 0` and each one fails (verified during #886). This one
    # cannot be, because the enumeration has no removable guard to strip — a
    # failed `worktree list` yields an empty pipe, so the `while read` body
    # simply never executes. There is no code path here that could be deleted to
    # turn it red.
    #
    # It is kept because the property is still worth pinning: if the enumeration
    # is ever restructured (a `set -o pipefail` added, the pipe replaced by a
    # temp file, the awk filter given a fallback), a failure could start
    # producing entries or a non-zero exit, and this test would catch that.
    # Labeled honestly so nobody later reads it as evidence the fail-safe chain
    # is covered here — that evidence is in the four tests above.
    local wt
    wt=$(add_worktree ".worktrees/issue-886")
    stub_stat "0 7"
    stub_git_failing "worktree"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A failed worktree enumeration must never make the run fail"
    assert_not_contains "$output" ".worktrees/issue-886" \
        "A failed worktree enumeration must repair nothing"
}

# ============================================================================
# Out-of-tree reach (issue #886, AC3)
# ============================================================================

test_outside_worktree_is_announced() {
    # DECISION (AC3): warn, keep repairing. `git worktree add` accepts any
    # writable path and this pass follows every registered entry at each boot
    # and hourly from cron. An allowlist would silently stop repairing a
    # legitimate other-volume worktree — reintroducing the #882 symptom for the
    # user who most needs the fix — so the reach is intended and only its
    # invisibility was the defect.
    local outside="$TEST_TEMP_DIR/outside-wt"
    seed_outside_worktree "$outside"
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "is outside the project root" \
        "Repairing a worktree outside the project root must be announced"
    assert_contains "$output" "refreshed ${outside}/AGENTS.md" \
        "The out-of-tree worktree must still be repaired after the warning"
}

test_in_tree_worktree_is_not_announced() {
    # The warning must DISTINGUISH — an in-tree worktree is the ordinary case
    # and stays quiet, so the line means something when it appears.
    add_worktree ".worktrees/issue-886" >/dev/null
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_not_contains "$output" "is outside the project root" \
        "An in-tree worktree must not be announced as out-of-tree"
}

test_outside_worktree_announced_under_skip_fix() {
    # Report-only mode is exactly when an operator is reading the output, so the
    # reach notice must survive SKIP_CASE_FIX rather than be gated on repairing.
    local outside="$TEST_TEMP_DIR/outside-wt"
    seed_outside_worktree "$outside"
    stub_stat "0 7"
    export SKIP_CASE_FIX=true

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "is outside the project root" \
        "SKIP_CASE_FIX must still announce an out-of-tree worktree"
    assert_not_contains "$output" "refreshed ${outside}/AGENTS.md" \
        "SKIP_CASE_FIX must not actually repair it"
}

# ============================================================================
# Degenerate entries
# ============================================================================

test_deleted_worktree_dir_is_silent() {
    # A worktree whose directory was removed but not pruned stays in the list.
    # It must be a silent non-event, not a warning and not a failure — the same
    # treatment an uninitialized submodule gets.
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    command rm -rf "$wt"
    stub_stat "0 7"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A pruned-but-registered worktree must never make the run fail"
    assert_empty "$output" \
        "A pruned-but-registered worktree should produce no output"
}

test_deleted_worktree_dropped_without_disturbing_siblings() {
    # An unenterable worktree path (deleted but still registered) must drop out
    # of the walk without failing the run or eating its siblings.
    #
    # SCOPE, stated honestly: this does NOT discriminate the
    # `wt_listed="$wt"; ... || wt="$wt_listed"` spelling from the naive
    # `wt=$(...) || wt="$wt"` one that self-clobbers to the empty string. Both
    # reach `[ -e "/.git" ]`, which is false on any sane host, so both drop the
    # entry and pass here. Telling them apart would need a real /.git, which a
    # test cannot create. The correctness argument for the fix lives in the
    # source comment and its commit message; this test pins the surrounding
    # BEHAVIOR (silent, non-fatal, siblings still repaired) and is not a
    # regression guard for that spelling.
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    add_worktree ".worktrees/issue-200" >/dev/null
    command rm -rf "$wt"
    stub_stat "0 7"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "An unenterable worktree path must never make the run fail"
    assert_not_contains "$output" " /.git" \
        "No log line should name a root-anchored path"
    assert_not_contains "$output" "issue-882/AGENTS.md" \
        "The deleted worktree must be dropped, not repaired"
    assert_contains "$output" "refreshed .worktrees/issue-200/AGENTS.md" \
        "A sibling worktree must still be repaired in the same pass"
}

test_no_worktrees_is_silent() {
    # The overwhelmingly common case: a project with no linked worktrees at all
    # must be unchanged by this pass.
    seed_symlinks

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A project with no linked worktrees must not fail"
    assert_empty "$output" \
        "A project with no linked worktrees should produce no output"
}

# ============================================================================
# Opt-outs
# ============================================================================

test_skip_fix_reports_worktree_without_writing() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"
    export SKIP_CASE_FIX=true

    local before output
    before=$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue-882/AGENTS.md" \
        "SKIP_CASE_FIX should still REPORT a linked-worktree finding"
    assert_contains "$output" "not repairing" \
        "SKIP_CASE_FIX should say it is not repairing"
    assert_not_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "SKIP_CASE_FIX must not relink a worktree symlink"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)" \
        "SKIP_CASE_FIX must leave the worktree link's mtime untouched"
}

test_skip_check_does_nothing_with_worktree() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"
    export SKIP_CASE_CHECK=true

    local before output
    before=$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr insensitive)

    assert_empty "$output" \
        "SKIP_CASE_CHECK must silence the linked-worktree pass entirely"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)" \
        "SKIP_CASE_CHECK must not touch a worktree symlink"

    local result
    result=$(get_ignorecase)
    assert_equals "unset" "$result" \
        "SKIP_CASE_CHECK must not write core.ignorecase"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_superproject_index_hides_worktree_links "Superproject index hides linked worktrees"
run_test_with_setup test_worktree_symlink_repaired "Stale symlink inside a linked worktree is repaired"
run_test_with_setup test_multiple_worktrees_all_reached "Every linked worktree is reached"
run_test_with_setup test_superproject_still_repaired_alongside "Superproject still repaired alongside worktrees"
run_test_with_setup test_healthy_worktree_leaves_tree_clean "Healthy worktree leaves tree clean"
run_test_with_setup test_worktree_ignorecase_reported_once "Shared core.ignorecase reported once, not per worktree"
run_test_with_setup test_worktree_path_with_spaces_is_reached "Worktree path containing spaces is reached"
run_test_with_setup test_submodule_inside_worktree_reached "Submodule inside a linked worktree is walked"
run_test_with_setup test_worktree_outside_project_root_uses_absolute_label "Worktree outside the project root uses an absolute label"
run_test_with_setup test_outside_worktree_does_not_write_shared_config "Out-of-tree worktree does not claim a case verdict"
run_test_with_setup test_outside_worktree_never_flips_shared_config "Out-of-tree worktree never writes shared core.ignorecase"
run_test_with_setup test_run_from_worktree_does_not_enumerate_siblings "Running from a worktree does not enumerate siblings"
run_test_with_setup test_git_dir_leak_does_not_defeat_the_gate "Leaked GIT_DIR/GIT_WORK_TREE does not defeat the main-worktree gate"
run_test_with_setup test_git_common_dir_leak_does_not_defeat_the_gate "Leaked GIT_COMMON_DIR does not defeat the main-worktree gate"
run_test_with_setup test_git_index_file_leak_does_not_hide_symlinks "Leaked GIT_INDEX_FILE does not hide tracked symlinks"
run_test_with_setup test_git_dir_probe_failure_is_a_silent_noop "Failed --git-dir probe is a silent no-op"
run_test_with_setup test_git_common_dir_probe_failure_is_a_silent_noop "Failed --git-common-dir probe is a silent no-op"
run_test_with_setup test_show_toplevel_probe_failure_is_a_silent_noop "Failed --show-toplevel probe is a silent no-op"
run_test_with_setup test_unsupported_flag_noops_without_killing_the_superproject_repair "Unsupported probe no-ops the pass but spares the superproject repair"
run_test_with_setup test_worktree_list_failure_is_a_silent_noop "Failed worktree enumeration is a silent no-op"
run_test_with_setup test_outside_worktree_is_announced "Out-of-tree worktree repair is announced"
run_test_with_setup test_in_tree_worktree_is_not_announced "In-tree worktree is not announced as out-of-tree"
run_test_with_setup test_outside_worktree_announced_under_skip_fix "SKIP_CASE_FIX still announces an out-of-tree worktree"
run_test_with_setup test_deleted_worktree_dir_is_silent "Pruned-but-registered worktree is silent and non-fatal"
run_test_with_setup test_deleted_worktree_dropped_without_disturbing_siblings "Deleted worktree dropped without disturbing siblings"
run_test_with_setup test_no_worktrees_is_silent "Project with no linked worktrees is silent"
run_test_with_setup test_skip_fix_reports_worktree_without_writing "SKIP_CASE_FIX reports worktree without writing"
run_test_with_setup test_skip_check_does_nothing_with_worktree "SKIP_CASE_CHECK skips the worktree pass"

# Generate test report
generate_report
