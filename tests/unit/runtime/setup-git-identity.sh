#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/setup-git — repo-local identities that
# shadow the global one (issue #1533, warn only).
#
# Split out of tests/unit/runtime/setup-git.sh in issue #1733, which had grown
# past 1300 lines. The section is self-contained: it depends only on the shared
# fixtures in tests/framework/helpers/setup-git.sh (setup/teardown,
# _run_setup_git, _gitcfg) and nothing in the suite left behind references it.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup-Git Identity Shadowing Tests (#1533)"

# Shared fixtures: SETUP_GIT_SCRIPT, setup/teardown, run_test_with_setup,
# _stub_ssh_tools, _run_setup_git, _gitcfg.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/setup-git.sh"

# ---------------------------------------------------------------------------
# #1533: repo-local identity shadowing the global one (warn only)
# ---------------------------------------------------------------------------
# Scratch workspace under $TEST_TEMP_DIR/ws (the WORKSPACE_ROOT _run_setup_git
# passes); the global identity is a real address so only the local one varies.
REAL_EMAIL="josh@yaplabs.com"

# _ws_repo NAME [EMAIL] — init a workspace repo, optionally with a local email.
_ws_repo() {
    local repo="$TEST_TEMP_DIR/ws/$1"
    command mkdir -p "$repo"
    git -C "$repo" init -q
    if [ -n "${2:-}" ]; then
        git -C "$repo" config --local user.name "t"
        git -C "$repo" config --local user.email "$2"
    fi
}

# Run setup-git with ssh/signing out of the way and a real global identity.
# Extra NAME=value args override (env takes the last assignment).
_run_identity() {
    _run_setup_git SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true \
        GIT_USER_EMAIL="$REAL_EMAIL" "$@"
}

test_local_placeholder_warns() {
    _ws_repo proj "t@t.t"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 (warn-only)"
    assert_contains "$out" "WARN: $TEST_TEMP_DIR/ws/proj: local user.email <t@t.t> is a placeholder" \
        "Placeholder local email is named as a placeholder"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/proj/.git/config" \
        "Warning names the overriding .git/config"
    local qproj
    printf -v qproj '%q' "$TEST_TEMP_DIR/ws/proj"
    assert_contains "$out" "git -C $qproj config --local --unset user.name; git -C $qproj config --local --unset user.email" \
        "Warning prints the unset remedy"
    assert_equals "t@t.t" "$(git -C "$TEST_TEMP_DIR/ws/proj" config --local user.email)" \
        "Local identity is left in place (never auto-unset)"
}

test_local_real_differing_warns_not_placeholder() {
    _ws_repo work "me@work-corp.io"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 (warn-only)"
    assert_contains "$out" "local user.email <me@work-corp.io> differs from global <$REAL_EMAIL>" \
        "Differing real local email warns"
    assert_not_contains "$out" "placeholder" "A real address is not called a placeholder"
    assert_contains "$out" "--unset user.email" "Remedy still printed"
}

test_no_local_identity_is_silent() {
    _ws_repo clean
    _ws_repo same "$REAL_EMAIL"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0"
    assert_not_contains "$out" "WARN" "No local identity (or same as global) → no new output"
}

test_worktree_config_reported_once() {
    _ws_repo proj "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/proj" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/proj" worktree add -q .worktrees/issue-1
    # Without the worktree the count below is trivially 1 — prove it exists
    # and that git sees the shared local identity from inside it.
    assert_dir_exists "$TEST_TEMP_DIR/ws/proj/.worktrees/issue-1" "Worktree was created"
    assert_equals "t@t.t" \
        "$(git -C "$TEST_TEMP_DIR/ws/proj/.worktrees/issue-1" config --local user.email)" \
        "Worktree resolves the parent's local identity"
    local out
    out=$(_run_identity)
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "A .worktrees/* checkout sharing the repo config is reported once"
}

test_worktree_local_identity_detected() {
    # The only repo with a local identity sits under .worktrees/ of a parent
    # whose own config is clean — proves .worktrees/* is actually scanned.
    _ws_repo parent
    _ws_repo parent/.worktrees/nested "t@t.t"
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/parent/.worktrees/nested: local user.email <t@t.t>" \
        ".worktrees/* repos are scanned"
}

test_devcontainer_fallback_warns() {
    local out rc=0
    out=$(_run_setup_git SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true \
        GIT_USER_EMAIL=) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with the fallback identity"
    assert_equals "devcontainer@localhost" "$(_gitcfg user.email)" "Fallback identity applied"
    assert_contains "$out" "WARN: global git email <devcontainer@localhost> is a placeholder" \
        "Fallback global email warns"
    assert_contains "$out" "refused by the pre-commit author-identity check" \
        "Warning mentions the pre-commit refusal"
}

test_control_chars_stripped_and_dir_quoted() {
    _ws_repo "it's" "$(printf 'x\033[2Jy@t.t')"
    local out
    out=$(_run_identity)
    assert_not_contains "$out" "$(printf '\033')" "ESC from a repo-local email never reaches the terminal"
    assert_contains "$out" "local user.email <x[2Jy@t.t>" "Email shown with control chars stripped"
    assert_contains "$out" "git -C $(printf '%q' "$TEST_TEMP_DIR/ws/it's") config --local --unset user.email" \
        "Remedy %q-quotes a dir containing a single quote"
}

test_missing_helper_falls_back() {
    # setup-git copied alone (no _git-email-placeholder beside it): it must
    # still exit 0 and still run the differs-from-global check.
    command mkdir -p "$TEST_TEMP_DIR/lone"
    command cp "$SETUP_GIT_SCRIPT" "$TEST_TEMP_DIR/lone/setup-git"
    _ws_repo work "t@t.t"
    local out rc=0
    out=$(SETUP_GIT_SCRIPT="$TEST_TEMP_DIR/lone/setup-git" _run_setup_git \
        SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true GIT_USER_EMAIL=) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 without the helper"
    assert_contains "$out" "local user.email <t@t.t> differs from global <devcontainer@localhost>" \
        "Differs check still runs without the helper"
    assert_not_contains "$out" "placeholder" "Without the helper nothing is called a placeholder"
}

test_root_worktrees_and_non_repos() {
    # WORKSPACE_ROOT is itself a repo; its own .worktrees/* holds the only
    # local identity, and a plain non-git dir sits beside it.
    git -C "$TEST_TEMP_DIR" init -q ws
    command mkdir -p "$TEST_TEMP_DIR/ws/not-a-repo"
    _ws_repo .worktrees/wt "t@t.t"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with a non-repo dir in the workspace"
    assert_contains "$out" "ws/.worktrees/wt: local user.email <t@t.t>" \
        "WORKSPACE_ROOT/.worktrees/* repos are scanned"
    assert_not_contains "$out" "not-a-repo" "Non-repo dirs are skipped silently"
}

test_missing_workspace_root_is_silent() {
    local out rc=0
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/does-not-exist") || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when WORKSPACE_ROOT is absent"
    assert_not_contains "$out" "WARN" "Absent WORKSPACE_ROOT → no new output"
}

test_empty_global_email() {
    # setup_identity always writes a fallback, so drive check_identity_shadowing
    # directly: source a scratch copy without its trailing `main "$@"` call.
    assert_equals 'main "$@"' "$(command tail -n 1 "$SETUP_GIT_SCRIPT")" \
        "setup-git still ends with the main call this test strips"
    command sed '$d' "$SETUP_GIT_SCRIPT" >"$TEST_TEMP_DIR/setup-git-fns"
    command cp "$PROJECT_ROOT/lib/runtime/commands/_git-email-placeholder" "$TEST_TEMP_DIR/"
    _ws_repo work "me@work-corp.io"
    : >"$TEST_HOME/.gitconfig"
    local out rc=0
    out=$(command env -i BASH_ENV= HOME="$TEST_HOME" PATH="/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" WORKSPACE_ROOT="$TEST_TEMP_DIR/ws" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        bash -c '. "$1"; check_identity_shadowing' _ "$TEST_TEMP_DIR/setup-git-fns" 2>&1) || rc=$?
    assert_equals "0" "$rc" "check_identity_shadowing returns 0 with no global email"
    assert_not_contains "$out" "global git email <>" "Empty global email is not called a placeholder"
    assert_not_contains "$out" "differs from global <>" "No 'differs from global <>' message"
    assert_contains "$out" "local user.email <me@work-corp.io> is set but no global user.email is" \
        "Local email with no global says so plainly"
}

test_worktree_scope_identity_detected() {
    # extensions.worktreeConfig + `git config --worktree` writes config.worktree,
    # which `git config --local` never reads — but git commit does.
    _ws_repo wtcfg
    git -C "$TEST_TEMP_DIR/ws/wtcfg" config extensions.worktreeConfig true
    git -C "$TEST_TEMP_DIR/ws/wtcfg" config --worktree user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/wtcfg"
    assert_contains "$out" "ws/wtcfg: worktree user.email <t@t.t> is a placeholder" \
        "A config.worktree identity is detected"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/wtcfg/.git/config.worktree" \
        "Warning names config.worktree"
    assert_contains "$out" "git -C $q config --worktree --unset user.email" \
        "Remedy uses --worktree for a worktree-scoped identity"
}

test_included_identity_detected() {
    # An identity pulled in via include.path still shadows the global one.
    _ws_repo inc
    printf '[user]\n\temail = t@t.t\n' >"$TEST_TEMP_DIR/ws/inc/.git/identity.inc"
    git -C "$TEST_TEMP_DIR/ws/inc" config include.path identity.inc
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/inc: local user.email <t@t.t> is a placeholder" \
        "An included identity is detected"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/inc/.git/identity.inc" \
        "Warning names the included file, not .git/config"
    assert_contains "$out" "remove the [user] entries from $TEST_TEMP_DIR/ws/inc/.git/identity.inc" \
        "Remedy points at the included file (--unset cannot reach it)"
}

test_symlinked_root_dedupes() {
    # WORKSPACE_ROOT reached via a symlink: the parent reports a relative
    # .git/config (prefixed with the symlinked dir) while its worktree reports
    # git's resolved absolute path. Only symlink-resolving normalization makes
    # them the same file, so the repo must still be reported once.
    _ws_repo proj "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/proj" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/proj" worktree add -q .worktrees/w
    command ln -s "$TEST_TEMP_DIR/ws" "$TEST_TEMP_DIR/ws-link"
    local out
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/ws-link")
    assert_contains "$out" "local user.email <t@t.t>" "Repo found through the symlinked root"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Symlinked root + worktree still reported once"
}

test_reason_control_chars_stripped() {
    # The invalid-hostname reason quotes the raw domain; an ESC there must
    # not reach the terminal any more than one in the email itself.
    _ws_repo esc "$(printf 'a@b\033[2Jc.io')"
    local out
    out=$(_run_identity)
    assert_contains "$out" "is a placeholder (domain 'b[2jc.io' is not a valid hostname)" \
        "Invalid-hostname reason is shown with control chars stripped"
    assert_not_contains "$out" "$(printf '\033')" "No ESC from the reason reaches the terminal"
}

test_non_ascii_path_dedupes_with_local_remedy() {
    # git C-quotes non-ASCII --show-origin paths unless -z is used; a quoted
    # path would defeat dedupe and route a plain local identity to the
    # include.path remedy.
    _ws_repo "pé" "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/pé" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/pé" worktree add -q .worktrees/w
    local out
    out=$(_run_identity)
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Non-ASCII repo + worktree reported once"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/pé/.git/config " "Unquoted, real config path shown"
    # %q's rendering of é depends on the locale (setup-git runs under env -i),
    # so assert the remedy form rather than the exact quoting.
    assert_contains "$out" "config --local --unset user.email" \
        "Plain local identity gets the --local --unset remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_root_repo_subdirs_not_scanned() {
    # WORKSPACE_ROOT is a repo with a local placeholder and plain subdirs:
    # the subdirs are not repos of their own and must not each re-report it
    # (with a nonexistent "<subdir>/.git/config" path and the include remedy).
    git -C "$TEST_TEMP_DIR" init -q ws
    git -C "$TEST_TEMP_DIR/ws" config user.email "t@t.t"
    command mkdir -p "$TEST_TEMP_DIR/ws/src" "$TEST_TEMP_DIR/ws/docs"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Root repo reported once, not once per subdirectory"
    assert_not_contains "$out" "ws/src" "Plain subdir src/ is not scanned as a repo"
    assert_not_contains "$out" "ws/docs" "Plain subdir docs/ is not scanned as a repo"
    assert_contains "$out" "git -C $q config --local --unset user.email" \
        "Root repo gets the --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_shared_include_reports_each_repo() {
    # Two unrelated repos include the same identity file: dedupe must not
    # collapse them, since each has its global identity shadowed.
    printf '[user]\n\temail = t@t.t\n' >"$TEST_TEMP_DIR/shared-identity.inc"
    _ws_repo one
    _ws_repo two
    git -C "$TEST_TEMP_DIR/ws/one" config include.path "$TEST_TEMP_DIR/shared-identity.inc"
    git -C "$TEST_TEMP_DIR/ws/two" config include.path "$TEST_TEMP_DIR/shared-identity.inc"
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/one: local user.email <t@t.t>" "First repo sharing the include is reported"
    assert_contains "$out" "ws/two: local user.email <t@t.t>" "Second repo sharing the include is reported"
}

test_bare_repo_reported_with_local_remedy() {
    git init -q --bare "$TEST_TEMP_DIR/ws/bare.git"
    git -C "$TEST_TEMP_DIR/ws/bare.git" config user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/bare.git"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Bare repo reported once"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/bare.git/config " "Bare repo's config named"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Bare repo gets --local remedy"
}

test_submodule_gets_local_remedy() {
    # A submodule's config lives in <super>/.git/modules/<m>/config; it is
    # still that repo's own local config, not an include.
    git -C "$TEST_TEMP_DIR" init -q subsrc
    git -C "$TEST_TEMP_DIR/subsrc" -c user.name=a -c user.email=a@b.co commit -q --allow-empty -m i
    _ws_repo super
    git -C "$TEST_TEMP_DIR/ws/super" -c user.name=a -c user.email=a@b.co commit -q --allow-empty -m i
    git -C "$TEST_TEMP_DIR/ws/super" -c protocol.file.allow=always \
        submodule add -q "$TEST_TEMP_DIR/subsrc" mod 2>/dev/null
    assert_dir_exists "$TEST_TEMP_DIR/ws/super/.git/modules/mod" "Submodule was created"
    git -C "$TEST_TEMP_DIR/ws/super/mod" config user.email "t@t.t"
    local out q
    # The submodule is a grandchild of WORKSPACE_ROOT; point the root at the
    # superproject so the submodule is a direct child candidate.
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/ws/super")
    printf -v q '%q' "$TEST_TEMP_DIR/ws/super/mod"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/super/.git/modules/mod/config " \
        "Submodule's real config path named"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Submodule gets --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_broken_worktree_skipped() {
    _ws_repo proj
    command mkdir -p "$TEST_TEMP_DIR/ws/proj/.worktrees/gone"
    printf 'gitdir: %s\n' "$TEST_TEMP_DIR/nonexistent" >"$TEST_TEMP_DIR/ws/proj/.worktrees/gone/.git"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with a broken worktree in the workspace"
    assert_not_contains "$out" ".worktrees/gone" "Broken worktree produces no output"
}

test_ownership_rejected_repo_says_so() {
    # A host-owned bind mount without safe.directory: git refuses the repo.
    # Say so once instead of skipping silently (and never override the check).
    # Simulated with a git wrapper that refuses only this repo, exactly as
    # git does — portable, unlike git's internal GIT_TEST_ASSUME_DIFFERENT_OWNER
    # (honored only by some git builds; CI's ignores it).
    _ws_repo hostowned "t@t.t"
    local real_git hostowned="$TEST_TEMP_DIR/ws/hostowned"
    real_git=$(command -v git)
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/git" <<STUB
#!/bin/bash
if [ "\$1" = "-C" ] && [ "\$2" = "$hostowned" ]; then
    printf "fatal: detected dubious ownership in repository at '%s'\\n" "\$2" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUB
    command chmod +x "$TEST_TEMP_DIR/bin/git"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when a repo is ownership-rejected"
    assert_contains "$out" "ws/hostowned: cannot check repo-local identity" \
        "Ownership-rejected repo is reported, not skipped silently"
    assert_not_contains "$out" "user.email <t@t.t>" "safe.directory is not overridden to read it"
}

test_symlinked_dot_git_gets_local_remedy() {
    # .git is a symlink to the real git dir. git reports both the origin file
    # and the common dir relative (".git/..."), so both sides resolve the same
    # way; this pins that a symlinked .git keeps the --local remedy.
    git init -q --separate-git-dir="$TEST_TEMP_DIR/real-gitdir" "$TEST_TEMP_DIR/ws/linked"
    command rm -f "$TEST_TEMP_DIR/ws/linked/.git"
    command ln -s "$TEST_TEMP_DIR/real-gitdir" "$TEST_TEMP_DIR/ws/linked/.git"
    git -C "$TEST_TEMP_DIR/ws/linked" config user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/linked"
    assert_contains "$out" "ws/linked: local user.email <t@t.t>" "Repo with a symlinked .git is reported"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Symlinked .git gets --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_old_git_without_path_format() {
    # git < 2.31 rejects --path-format; the scan must not depend on it.
    _ws_repo proj "t@t.t"
    local real_git q
    real_git=$(command -v git)
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/git" <<STUB
#!/bin/bash
for a in "\$@"; do
    case "\$a" in --path-format*) echo "fatal: unknown option" >&2; exit 128 ;; esac
done
exec "$real_git" "\$@"
STUB
    command chmod +x "$TEST_TEMP_DIR/bin/git"
    local out
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/proj"
    assert_contains "$out" "ws/proj: local user.email <t@t.t>" "Detected without --path-format"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Still the --local remedy"
}

test_real_global_no_global_warning() {
    local out
    out=$(_run_identity)
    assert_not_contains "$out" "global git email" "A real global email does not warn"
}

test_placeholder_rules_shared_not_duplicated() {
    local helper="$PROJECT_ROOT/lib/runtime/commands/_git-email-placeholder"
    assert_file_contains "$helper" 'placeholder_reason()' "Shared helper defines placeholder_reason"
    assert_file_not_contains "$PROJECT_ROOT/bin/check-author-identity.sh" 'placeholder_reason()' \
        "Pre-commit hook does not redefine the rules"
    assert_file_contains "$PROJECT_ROOT/bin/check-author-identity.sh" '_git-email-placeholder' \
        "Pre-commit hook sources the shared helper"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_git-email-placeholder' \
        "setup-git sources the shared helper"
    assert_file_contains "$PROJECT_ROOT/Dockerfile" \
        'COPY lib/runtime/commands/_git-email-placeholder /usr/local/bin/_git-email-placeholder' \
        "Dockerfile installs the helper next to setup-git"
}

run_test_with_setup test_local_placeholder_warns "#1533: local t@t.t → WARN names .git/config + unset remedy"
run_test_with_setup test_local_real_differing_warns_not_placeholder "#1533: differing real local email warns, not a placeholder"
run_test_with_setup test_no_local_identity_is_silent "#1533: no local identity → no new output"
run_test_with_setup test_worktree_config_reported_once "#1533: worktree sharing repo config reported once"
run_test_with_setup test_worktree_local_identity_detected "#1533: .worktrees/* repos are scanned"
run_test_with_setup test_devcontainer_fallback_warns "#1533: devcontainer@localhost fallback warns of pre-commit refusal"
run_test_with_setup test_control_chars_stripped_and_dir_quoted "#1533: repo-controlled strings sanitized; remedy %q-quoted"
run_test_with_setup test_missing_helper_falls_back "#1533: missing helper → still exits 0, differs check runs"
run_test_with_setup test_root_worktrees_and_non_repos "#1533: WORKSPACE_ROOT/.worktrees scanned; non-repo dirs skipped"
run_test_with_setup test_missing_workspace_root_is_silent "#1533: absent WORKSPACE_ROOT → silent, exit 0"
run_test_with_setup test_empty_global_email "#1533: no global email → no '<>' placeholder/differs message"
run_test_with_setup test_worktree_scope_identity_detected "#1533: config.worktree identity detected; --worktree remedy"
run_test_with_setup test_included_identity_detected "#1533: include.path identity detected; names the included file"
run_test_with_setup test_symlinked_root_dedupes "#1533: symlinked WORKSPACE_ROOT + worktree reported once"
run_test_with_setup test_reason_control_chars_stripped "#1533: placeholder reason sanitized (no ESC from domain)"
run_test_with_setup test_non_ascii_path_dedupes_with_local_remedy "#1533: non-ASCII path — -z parse dedupes, --local remedy"
run_test_with_setup test_root_repo_subdirs_not_scanned "#1533: root repo's plain subdirs not re-reported"
run_test_with_setup test_shared_include_reports_each_repo "#1533: unrelated repos sharing an include are each reported"
run_test_with_setup test_bare_repo_reported_with_local_remedy "#1533: bare repo reported once with --local remedy"
run_test_with_setup test_submodule_gets_local_remedy "#1533: submodule config path + --local remedy"
run_test_with_setup test_broken_worktree_skipped "#1533: broken worktree skipped, exit 0"
run_test_with_setup test_ownership_rejected_repo_says_so "#1533: ownership-rejected repo → one skip line, exit 0"
run_test_with_setup test_symlinked_dot_git_gets_local_remedy "#1533: symlinked .git → --local remedy"
run_test_with_setup test_old_git_without_path_format "#1533: works on git without --path-format (< 2.31)"
run_test_with_setup test_real_global_no_global_warning "#1533: real global email → no global warning"
run_test_with_setup test_placeholder_rules_shared_not_duplicated "#1533: placeholder rules shared, not duplicated"

# Generate test report
generate_report
