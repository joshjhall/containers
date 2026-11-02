#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-ccache-entry.sh (#1594).
#
# The entry script wraps a source-build evidence cell's `luggage install`. It
# must opt luggage into ccache ONLY once ccache is actually installed, pass the
# wrapped command's exit status through unchanged, and never let cache
# plumbing decide the evidence verdict. Every external command is a PATH stub
# in a mktemp dir; nothing is installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "evidence-ccache-entry.sh"

ENTRY="$PROJECT_ROOT/bin/lib/evidence-ccache-entry.sh"

# _sandbox — a scratch dir with stub bin/ and an out/ for stats. The wrapped
# command is a `luggage` stub that records the launcher env it saw and exits
# with $LUGGAGE_STUB_RC.
_sandbox() {
    local d
    d="$(/usr/bin/mktemp -d)"
    /usr/bin/mkdir -p "$d/bin" "$d/out" "$d/sys"
    # PATH gets only these, never all of /bin: a host /bin/apt-get would
    # otherwise shadow the dnf/microdnf stubs and the no-manager case.
    local t
    for t in sh cp printf cat; do
        /usr/bin/ln -s "$(command -v "$t")" "$d/sys/$t"
    done
    /usr/bin/cat >"$d/bin/luggage" <<'STUB'
#!/bin/sh
printf '%s\n' "${LUGGAGE_COMPILER_LAUNCHER-<unset>}" >"$SANDBOX/launcher-seen"
exit "${LUGGAGE_STUB_RC:-0}"
STUB
    /usr/bin/chmod +x "$d/bin/luggage"
    printf '%s\n' "$d"
}

# _stub_ccache <dir> — a working ccache that logs its calls.
_stub_ccache() {
    /usr/bin/cat >"$1/bin/ccache" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SANDBOX/ccache-calls"
[ "$1" = "-s" ] && printf 'Hits: 42 / 50 (84.00 %%)\n'
exit 0
STUB
    /usr/bin/chmod +x "$1/bin/ccache"
}

# _run <dir> [env...] — run the entry with ONLY the sandbox stubs + a few
# symlinked core tools on PATH (so the host's real apk/apt-get/ccache are
# invisible), under env -i so BASH_ENV cannot rebuild PATH.
_run() {
    local d="$1"
    shift
    /usr/bin/env -i PATH="$d/bin:$d/sys" SANDBOX="$d" CCACHE_STATS_OUT="$d/out/stats.txt" "$@" \
        /bin/sh "$ENTRY" luggage install node@22.22.3
}

test_opts_in_when_ccache_is_present() {
    local d rc=0
    d="$(_sandbox)"
    _stub_ccache "$d"
    _run "$d" || rc=$?
    assert_equals "0" "$rc" "wrapped success passes through"
    assert_equals "ccache" "$(/usr/bin/cat "$d/launcher-seen")" "luggage sees LUGGAGE_COMPILER_LAUNCHER=ccache"
    assert_equals $'-z\n-s' "$(/usr/bin/cat "$d/ccache-calls")" "stats zeroed before, read after"
    assert_contains "$(/usr/bin/cat "$d/out/stats.txt")" "Hits: 42" "stats written for the summary"
    /usr/bin/rm -rf "$d"
}

test_failure_status_passes_through() {
    local d rc=0
    d="$(_sandbox)"
    _stub_ccache "$d"
    _run "$d" LUGGAGE_STUB_RC=3 || rc=$?
    assert_equals "3" "$rc" "luggage's exit status is the script's"
    assert_contains "$(/usr/bin/cat "$d/out/stats.txt")" "Hits: 42" "stats still written after a failed build"
    /usr/bin/rm -rf "$d"
}

test_installs_ccache_via_apk() {
    local d rc=0
    d="$(_sandbox)"
    # apk "installs" ccache by dropping the stub into place.
    /usr/bin/cat >"$d/bin/apk" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >"\$SANDBOX/apk-args"
/bin/cp "$d/ccache.pending" "$d/bin/ccache"
STUB
    /usr/bin/chmod +x "$d/bin/apk"
    _stub_ccache "$d"
    /usr/bin/mv "$d/bin/ccache" "$d/ccache.pending"
    _run "$d" || rc=$?
    assert_equals "0" "$rc" "install + build succeed"
    assert_equals "add --no-cache ccache" "$(/usr/bin/cat "$d/apk-args")" "alpine installs via apk"
    assert_equals "ccache" "$(/usr/bin/cat "$d/launcher-seen")" "launcher set after a fresh install"
    /usr/bin/rm -rf "$d"
}

# _pm_installs <manager> <expected argv> — a stub <manager> that records its
# argv and "installs" ccache; asserts the exact argv and the opt-in.
_pm_installs() {
    local pm="$1" want="$2" d rc=0
    d="$(_sandbox)"
    _stub_ccache "$d"
    /usr/bin/mv "$d/bin/ccache" "$d/ccache.pending"
    /usr/bin/cat >"$d/bin/$pm" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"\$SANDBOX/pm-args"
/bin/cp "$d/ccache.pending" "$d/bin/ccache"
STUB
    /usr/bin/chmod +x "$d/bin/$pm"
    _run "$d" || rc=$?
    assert_equals "0" "$rc" "$pm: install + build succeed"
    assert_equals "$want" "$(/usr/bin/cat "$d/pm-args")" "$pm argv"
    assert_equals "ccache" "$(/usr/bin/cat "$d/launcher-seen")" "$pm: launcher set after install"
    /usr/bin/rm -rf "$d"
}

test_installs_ccache_via_apt_get() {
    _pm_installs apt-get $'update\ninstall -y --no-install-recommends ccache'
}

test_installs_ccache_via_dnf() {
    _pm_installs dnf "install -y ccache"
}

test_installs_ccache_via_microdnf() {
    _pm_installs microdnf "install -y ccache"
}

test_no_package_manager_falls_back() {
    local d rc=0 err
    d="$(_sandbox)"
    err="$(_run "$d" 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "no package manager never fails the cell"
    assert_contains "$err" "no known package manager" "the missing manager is named"
    assert_equals "<unset>" "$(/usr/bin/cat "$d/launcher-seen")" "luggage builds without a launcher"
    /usr/bin/rm -rf "$d"
}

test_falls_back_uncached_when_install_fails() {
    local d rc=0 err
    d="$(_sandbox)"
    printf '#!/bin/sh\nexit 1\n' >"$d/bin/apk"
    /usr/bin/chmod +x "$d/bin/apk"
    # Even a launcher inherited from the caller is dropped: luggage would
    # otherwise spawn a `ccache` that does not exist and fail the cell.
    err="$(_run "$d" LUGGAGE_COMPILER_LAUNCHER=ccache 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "cache plumbing never fails the cell"
    assert_equals "<unset>" "$(/usr/bin/cat "$d/launcher-seen")" "luggage builds without a launcher"
    assert_contains "$err" "::warning::" "the fallback is surfaced as a warning"
    if [ -e "$d/out/stats.txt" ]; then
        assert_true false "no stats file when ccache never ran"
    else
        assert_true true "no stats file when ccache never ran"
    fi
    /usr/bin/rm -rf "$d"
}

test_install_success_without_ccache_falls_back() {
    # A package manager can exit 0 yet leave no `ccache` on PATH. Opting
    # luggage in then would make it spawn a missing launcher and fail the
    # cell, so the post-install `command -v ccache` check must hold.
    local d rc=0 err
    d="$(_sandbox)"
    printf '#!/bin/sh\nexit 0\n' >"$d/bin/apk"
    /usr/bin/chmod +x "$d/bin/apk"
    err="$(_run "$d" 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "a no-op install never fails the cell"
    assert_equals "<unset>" "$(/usr/bin/cat "$d/launcher-seen")" "luggage builds without a launcher"
    assert_contains "$err" "::warning::" "the fallback is surfaced as a warning"
    /usr/bin/rm -rf "$d"
}

test_stats_write_failure_keeps_the_build_status() {
    # Stats plumbing must never change the verdict: an unwritable stats path
    # is reported, and luggage's own exit status still comes back.
    local d rc=0 err
    d="$(_sandbox)"
    _stub_ccache "$d"
    err="$(/usr/bin/env -i PATH="$d/bin:$d/sys" SANDBOX="$d" LUGGAGE_STUB_RC=3 \
        CCACHE_STATS_OUT="$d/missing-dir/stats.txt" \
        /bin/sh "$ENTRY" luggage install node@22.22.3 2>&1 >/dev/null)" || rc=$?
    assert_equals "3" "$rc" "luggage's status survives a failed stats write"
    assert_contains "$err" "could not write ccache stats" "the stats failure is reported"
    /usr/bin/rm -rf "$d"
}

test_requires_a_command() {
    local rc=0
    /usr/bin/env -i PATH=/bin /bin/sh "$ENTRY" >/dev/null 2>&1 || rc=$?
    assert_equals "64" "$rc" "no command is a usage error"
}

run_test test_opts_in_when_ccache_is_present "opts luggage into ccache when it is present"
run_test test_failure_status_passes_through "a failed build's exit status passes through"
run_test test_installs_ccache_via_apk "installs ccache with apk on alpine"
run_test test_installs_ccache_via_apt_get "installs ccache with apt-get on debian/ubuntu"
run_test test_installs_ccache_via_dnf "installs ccache with dnf on rhel"
run_test test_installs_ccache_via_microdnf "installs ccache with microdnf on ubi-minimal"
run_test test_no_package_manager_falls_back "falls back uncached when no package manager exists"
run_test test_falls_back_uncached_when_install_fails "falls back to an uncached build when ccache cannot install"
run_test test_install_success_without_ccache_falls_back "falls back when an install exits 0 but leaves no ccache"
run_test test_stats_write_failure_keeps_the_build_status "a failed stats write keeps luggage's exit status"
run_test test_requires_a_command "refuses to run with no command"

generate_report
