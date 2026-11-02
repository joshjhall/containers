#!/usr/bin/env bash
# Unit tests: bin/sync-repo-baseline.sh and the auto-patch hook that runs it
# on a LIBRARIAN_REF bump (#1543).
#
# stibbons embeds librarian's repo-baseline templates. Auto-patch used to bump
# the pin without re-vendoring, so the embedded copy silently lagged. The
# re-vendor must also keep the local pygments patch until librarian ships it
# (joshjhall/librarian#1261), and drop it — suffix included — once it does.
#
# Offline: every librarian tree is a fixture (LIBRARIAN_SRC), except the
# tracked-copy round trip, which uses /opt/librarian and skips without it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "sync-repo-baseline"

SYNC="$PROJECT_ROOT/bin/sync-repo-baseline.sh"
HOOK_LIB="$PROJECT_ROOT/bin/lib/update-versions/repo-baseline.sh"
UPDATERS="$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
TRACKED="$PROJECT_ROOT/crates/stibbons/assets/repo-baseline"

# _fixture <root> <version> <requirements-content>
# A minimal librarian tree: VERSION + a manifest naming two sources.
_fixture() {
    local t="$1/plugins/dev-core/skills/repo-baseline/templates"
    command mkdir -p "$t/core" "$t/python"
    command printf '%s\n' "$2" >"$1/VERSION"
    command printf 'a.txt\tcore\talways\tcore/a.txt\nrequirements.txt\tpython\talways\tpython/requirements.txt\n' \
        >"$t/manifest.tsv"
    command printf 'core\n' >"$t/core/a.txt"
    command printf '%s' "$3" >"$t/python/requirements.txt"
}

test_reapplies_pygments_pin_when_upstream_lacks_it() {
    local src dest
    src="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    REPO_BASELINE_DEST="$dest" "$SYNC" "$src" >/dev/null
    assert_equals $'pytest==9.1.1\npygments>=2.20.0' "$(command cat "$dest/python/requirements.txt")" \
        "pygments pin appended after upstream's requirements"
    assert_equals "librarian 9.9.9 +pygments-pin" "$(command cat "$dest/SOURCE")" \
        "SOURCE records the local patch"
    command rm -rf "$src" "$(command dirname "$dest")"
}

test_pin_not_glued_onto_unterminated_last_line() {
    local src dest
    src="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$src" 9.9.9 'pytest==9.1.1'
    REPO_BASELINE_DEST="$dest" "$SYNC" "$src" >/dev/null
    assert_equals $'pytest==9.1.1\npygments>=2.20.0' "$(command cat "$dest/python/requirements.txt")" \
        "a missing trailing newline upstream does not merge two requirements"
    command rm -rf "$src" "$(command dirname "$dest")"
}

test_drops_patch_once_upstream_pins_pygments() {
    local src dest
    src="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\nPygments>=2.21\n'
    REPO_BASELINE_DEST="$dest" "$SYNC" "$src" >/dev/null
    assert_equals $'pytest==9.1.1\nPygments>=2.21' "$(command cat "$dest/python/requirements.txt")" \
        "upstream's own pygments requirement is kept verbatim, not duplicated"
    assert_equals "librarian 9.9.9" "$(command cat "$dest/SOURCE")" \
        "SOURCE carries no suffix once librarian ships the pin"
    command rm -rf "$src" "$(command dirname "$dest")"
}

test_dropped_fragment_does_not_linger() {
    local src dest
    src="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    command mkdir -p "$dest/core"
    command printf 'stale\n' >"$dest/core/gone.txt"
    REPO_BASELINE_DEST="$dest" "$SYNC" "$src" >/dev/null
    assert_file_not_exists "$dest/core/gone.txt" "a fragment the manifest no longer names is removed"
    assert_file_exists "$dest/core/a.txt" "manifest sources are vendored"
    command rm -rf "$src" "$(command dirname "$dest")"
}

# _hook <src> <version> <project-root> [DRY_RUN] — run sync_repo_baseline in a
# subshell; prints its exit code.
_hook() {
    local rc=0
    (
        BLUE='' RED='' NC=''
        # shellcheck source=bin/lib/update-versions/repo-baseline.sh
        source "$HOOK_LIB"
        # shellcheck disable=SC2034 # consumed by sync_repo_baseline
        PROJECT_ROOT="$3" DRY_RUN="${4:-false}" LIBRARIAN_SRC="$1" \
            sync_repo_baseline "$2"
    ) >/dev/null 2>&1 || rc=$?
    command echo "$rc"
}

test_hook_vendors_into_project_root() {
    local src root
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    assert_equals "0" "$(_hook "$src" 9.9.9 "$root")" "hook succeeds on a matching source"
    assert_equals "librarian 9.9.9 +pygments-pin" \
        "$(command cat "$root/crates/stibbons/assets/repo-baseline/SOURCE" 2>/dev/null)" \
        "hook vendors under PROJECT_ROOT, not the tracked tree"
    command rm -rf "$src" "$root"
}

test_hook_dry_run_writes_nothing() {
    local src root
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    assert_equals "0" "$(_hook "$src" 9.9.9 "$root" true)" "dry run succeeds"
    assert_dir_not_exists "$root/crates" "dry run writes nothing"
    command rm -rf "$src" "$root"
}

test_hook_rejects_version_mismatch() {
    local src root
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    _fixture "$src" 9.9.8 $'pytest==9.1.1\n'
    assert_equals "1" "$(_hook "$src" 9.9.9 "$root")" \
        "a source at another release must fail, not vendor under the new pin"
    assert_dir_not_exists "$root/crates" "nothing vendored on mismatch"
    command rm -rf "$src" "$root"
}

test_hook_fails_on_broken_source() {
    local src root
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    command printf '9.9.9\n' >"$src/VERSION" # no manifest
    assert_equals "1" "$(_hook "$src" 9.9.9 "$root")" "a sync failure propagates"
    command rm -rf "$src" "$root"
}

test_librarian_arm_calls_hook() {
    # The re-vendor only helps if the auto-patch path reaches it, guarded so a
    # failure becomes RC_UPDATE_FAILED (exit 3) instead of a half-updated branch.
    assert_file_contains "$UPDATERS" \
        'sync_repo_baseline "$latest" || return "$RC_UPDATE_FAILED"' \
        "librarian updater arm re-vendors the templates"
}

test_tracked_copy_round_trips() {
    # Re-vendoring from the pinned librarian must reproduce the committed copy
    # byte for byte — proves the patch logic matches what is checked in.
    local src="/opt/librarian" out diffout
    if [ ! -f "$src/plugins/dev-core/skills/repo-baseline/templates/manifest.tsv" ]; then
        skip_test "no librarian checkout at $src"
        return 0
    fi
    if [ "librarian $(command tr -d '[:space:]' <"$src/VERSION")" != \
        "$(command sed 's/ +.*//' "$TRACKED/SOURCE")" ]; then
        skip_test "$src is not the vendored librarian release"
        return 0
    fi
    out="$(command mktemp -d)/out"
    REPO_BASELINE_DEST="$out" "$SYNC" "$src" >/dev/null
    diffout="$(command diff -r "$out" "$TRACKED" 2>&1 || true)"
    assert_equals "" "$diffout" "re-vendor reproduces crates/stibbons/assets/repo-baseline"
    command rm -rf "$(command dirname "$out")"
}

run_test test_reapplies_pygments_pin_when_upstream_lacks_it "re-applies pygments pin while upstream lacks it"
run_test test_pin_not_glued_onto_unterminated_last_line "pin not glued onto an unterminated last line"
run_test test_drops_patch_once_upstream_pins_pygments "drops the patch once upstream pins pygments"
run_test test_dropped_fragment_does_not_linger "dropped fragment does not linger"
run_test test_hook_vendors_into_project_root "sync_repo_baseline vendors into PROJECT_ROOT"
run_test test_hook_dry_run_writes_nothing "sync_repo_baseline dry run writes nothing"
run_test test_hook_rejects_version_mismatch "sync_repo_baseline rejects a version mismatch"
run_test test_hook_fails_on_broken_source "sync_repo_baseline fails on a broken source"
run_test test_librarian_arm_calls_hook "librarian updater arm calls sync_repo_baseline"
run_test test_tracked_copy_round_trips "re-vendor reproduces the tracked copy"

generate_report
