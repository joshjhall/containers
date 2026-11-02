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
        # shellcheck disable=SC2034 # read by the sourced repo-baseline.sh
        BLUE='' RED='' NC=''
        # shellcheck source=bin/lib/update-versions/repo-baseline.sh
        source "$HOOK_LIB"
        # shellcheck disable=SC2030,SC2034 # consumed by sync_repo_baseline
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

# _arm_fixture <root> — a project tree the librarian updater arm can rewrite.
_arm_fixture() {
    command mkdir -p "$1/lib/features"
    command printf 'ARG LIBRARIAN_REF=v9.9.8\n' >"$1/Dockerfile"
    command printf 'LIBRARIAN_REF="${LIBRARIAN_REF:-v9.9.8}"\n' \
        >"$1/lib/features/claude-code-setup.sh"
}

# _arm <root> <librarian-src> — run update_version for librarian 9.9.8 -> 9.9.9
# against <root>; prints its exit code.
_arm() {
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$UPDATERS"
        # shellcheck disable=SC2030,SC2034 # consumed by update_version()
        PROJECT_ROOT="$1" DRY_RUN=false LIBRARIAN_SRC="$2"
        update_version librarian 9.9.8 9.9.9 Dockerfile
    ) >/dev/null 2>&1 || rc=$?
    command echo "$rc"
}

test_librarian_arm_revendors() {
    # Behavioural, not a grep: the real arm bumps the pin AND re-vendors.
    local src root
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    _arm_fixture "$root"
    assert_equals "0" "$(_arm "$root" "$src")" "librarian bump succeeds"
    assert_equals "ARG LIBRARIAN_REF=v9.9.9" "$(command cat "$root/Dockerfile")" "pin bumped"
    assert_equals "librarian 9.9.9 +pygments-pin" \
        "$(command cat "$root/crates/stibbons/assets/repo-baseline/SOURCE" 2>/dev/null)" \
        "templates re-vendored from the new librarian"
    command rm -rf "$src" "$root"
}

test_librarian_arm_failed_revendor_is_update_failed() {
    # A pin bumped without its templates must be RC_UPDATE_FAILED (auto-patch
    # exit 3, fatal), never a clean bump that reaches auto-merge.
    local src root expected
    expected="$(command sed -nE 's/^RC_UPDATE_FAILED=([0-9]+).*/\1/p' "$UPDATERS")"
    src="$(command mktemp -d)"
    root="$(command mktemp -d)"
    _fixture "$src" 9.9.8 $'pytest==9.1.1\n' # wrong release
    _arm_fixture "$root"
    assert_not_equals "" "$expected" "RC_UPDATE_FAILED read from updaters.sh"
    assert_equals "$expected" "$(_arm "$root" "$src")" \
        "a failed re-vendor returns RC_UPDATE_FAILED"
    command rm -rf "$src" "$root"
}

# _clone_hook <stub-mode> <root> <argfile> — run sync_repo_baseline down the
# real clone path with a stub `git` first on PATH. The stub records its args
# and either fails or lays down a fixture tree at the clone destination.
_clone_hook() {
    local bindir rc=0
    bindir="$(command mktemp -d)"
    command cat >"$bindir/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$3"
[ "$1" = fail ] && exit 128
dest="\${@: -1}"
t="\$dest/plugins/dev-core/skills/repo-baseline/templates"
mkdir -p "\$t/python"
printf '9.9.9\\n' >"\$dest/VERSION"
printf 'requirements.txt\\tpython\\talways\\tpython/requirements.txt\\n' >"\$t/manifest.tsv"
printf 'pytest==9.1.1\\n' >"\$t/python/requirements.txt"
EOF
    command chmod +x "$bindir/git"
    (
        # shellcheck disable=SC2034 # read by the sourced repo-baseline.sh
        BLUE='' RED='' NC=''
        # shellcheck source=bin/lib/update-versions/repo-baseline.sh
        source "$HOOK_LIB"
        unset LIBRARIAN_SRC
        # shellcheck disable=SC2030,SC2034 # consumed by sync_repo_baseline
        PATH="$bindir:$PATH" PROJECT_ROOT="$2" DRY_RUN=false
        export TMPDIR="$bindir"
        sync_repo_baseline 9.9.9
    ) >/dev/null 2>&1 || rc=$?
    # Anything left in bindir besides the stub is a leaked clone dir.
    command echo "$rc $(command find "$bindir" -mindepth 1 -maxdepth 1 ! -name git | command wc -l)"
    command rm -rf "$bindir"
}

test_clone_path_success() {
    local root args
    root="$(command mktemp -d)"
    args="$(command mktemp)"
    assert_equals "0 0" "$(_clone_hook ok "$root" "$args")" "clone path succeeds and cleans its temp dir"
    assert_equals "1" "$(command grep -cx -- '--branch' "$args")" "clone passes --branch"
    assert_equals "v9.9.9" "$(command grep -x -A1 -- '--branch' "$args" | command tail -n 1)" \
        "clone checks out tag v<version>"
    assert_equals "librarian 9.9.9 +pygments-pin" \
        "$(command cat "$root/crates/stibbons/assets/repo-baseline/SOURCE" 2>/dev/null)" \
        "cloned tree is vendored"
    command rm -rf "$root" "$args"
}

test_clone_path_failure() {
    local root args
    root="$(command mktemp -d)"
    args="$(command mktemp)"
    assert_equals "1 0" "$(_clone_hook fail "$root" "$args")" "clone failure returns 1 and cleans its temp dir"
    assert_dir_not_exists "$root/crates" "nothing vendored when the clone fails"
    command rm -rf "$root" "$args"
}

# _escape <manifest-source> — sync a fixture whose manifest names <source>;
# prints the exit code.
_escape() {
    local src dest rc=0
    src="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$src" 9.9.9 $'pytest==9.1.1\n'
    command printf 'x\tcore\talways\t%s\n' "$1" \
        >>"$src/plugins/dev-core/skills/repo-baseline/templates/manifest.tsv"
    command printf 'secret\n' >"$src/outside.txt"
    command ln -s "$src/outside.txt" "$src/plugins/dev-core/skills/repo-baseline/templates/core/link.txt"
    command mkdir -p "$src/elsewhere"
    command printf 'secret\n' >"$src/elsewhere/f.txt"
    command ln -s "$src/elsewhere" "$src/plugins/dev-core/skills/repo-baseline/templates/dirlink"
    REPO_BASELINE_DEST="$dest" "$SYNC" "$src" >/dev/null 2>&1 || rc=$?
    command echo "$rc $([ -e "$dest" ] && command echo written || command echo none)"
    command rm -rf "$src" "$(command dirname "$dest")"
}

test_rejects_escaping_sources() {
    assert_equals "2 none" "$(_escape '../../../../../outside.txt')" "a .. source is refused"
    assert_equals "2 none" "$(_escape "$(command mktemp -u)")" "an absolute source is refused"
    assert_equals "2 none" "$(_escape 'core/link.txt')" "a symlinked source is refused"
    assert_equals "2 none" "$(_escape 'dirlink/f.txt')" "a source under a symlinked directory is refused"
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
run_test test_librarian_arm_revendors "librarian updater arm bumps the pin and re-vendors"
run_test test_librarian_arm_failed_revendor_is_update_failed "failed re-vendor is RC_UPDATE_FAILED"
run_test test_clone_path_success "clone path: tag, vendor, temp cleanup"
run_test test_clone_path_failure "clone path: failure returns 1, temp cleanup"
run_test test_rejects_escaping_sources "manifest sources cannot escape the templates dir"
run_test test_tracked_copy_round_trips "re-vendor reproduces the tracked copy"

generate_report
