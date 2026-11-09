#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-ccache-entry.sh (#1594).
#
# The entry script wraps a source-build evidence cell's `luggage install`. It
# must opt luggage into ccache ONLY once the mounted static binary runs, never
# install anything into the image under test, pass the
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
command -v ccache >"$SANDBOX/ccache-on-path" || :
exit "${LUGGAGE_STUB_RC:-0}"
STUB
    /usr/bin/chmod +x "$d/bin/luggage"
    printf '%s\n' "$d"
}

# _stub_ccache <dir> — a working static ccache, mounted (as the workflow
# does) OUTSIDE PATH at <dir>/mnt/ccache; it logs its calls.
_stub_ccache() {
    /usr/bin/mkdir -p "$1/mnt"
    /usr/bin/cat >"$1/mnt/ccache" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SANDBOX/ccache-calls"
[ "$1" = "-s" ] && printf 'Hits: 42 / 50 (84.00 %%)\n'
exit 0
STUB
    /usr/bin/chmod +x "$1/mnt/ccache"
}

# _stub_package_managers <dir> — every package manager the old entry script
# used, each recording that it was called. The image under test must never
# gain packages from cache plumbing (they could mask a missing catalog dep).
_stub_package_managers() {
    local pm
    for pm in apk apt-get dnf microdnf; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >>"$SANDBOX/pm-calls"\n' "$pm" >"$1/bin/$pm"
        /usr/bin/chmod +x "$1/bin/$pm"
    done
}

# _run <dir> [env...] — run the entry with ONLY the sandbox stubs + a few
# symlinked core tools on PATH (so the host's real apk/apt-get/ccache are
# invisible), under env -i so BASH_ENV cannot rebuild PATH. The stub luggage
# also records whether `ccache` resolves on the PATH it was given.
_run() {
    local d="$1"
    shift
    /usr/bin/env -i PATH="$d/bin:$d/sys" SANDBOX="$d" CCACHE_STATS_OUT="$d/out/stats.txt" \
        EVIDENCE_CCACHE_BIN="$d/mnt/ccache" "$@" \
        /bin/sh "$ENTRY" luggage install node@22.22.3
}

test_opts_in_when_ccache_is_mounted() {
    local d rc=0
    d="$(_sandbox)"
    _stub_ccache "$d"
    _stub_package_managers "$d"
    _run "$d" || rc=$?
    assert_equals "0" "$rc" "wrapped success passes through"
    assert_equals "ccache" "$(/usr/bin/cat "$d/launcher-seen")" "luggage sees LUGGAGE_COMPILER_LAUNCHER=ccache"
    assert_equals "$d/mnt/ccache" "$(/usr/bin/cat "$d/ccache-on-path")" "the mounted binary is what luggage's PATH resolves"
    assert_equals $'--version\n-z\n-s' "$(/usr/bin/cat "$d/ccache-calls")" "probed, stats zeroed before, read after"
    assert_contains "$(/usr/bin/cat "$d/out/stats.txt")" "Hits: 42" "stats written for the summary"
    if [ -e "$d/pm-calls" ]; then
        assert_true false "no package manager may run: $(/usr/bin/cat "$d/pm-calls")"
    else
        assert_true true "nothing is installed into the image under test"
    fi
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

test_missing_binary_falls_back_without_installing() {
    # No mount (the fetch failed): build uncached, and still never reach for
    # a package manager — even one that would happily "install" ccache.
    local d rc=0 err
    d="$(_sandbox)"
    _stub_package_managers "$d"
    # Even a launcher inherited from the caller is dropped: luggage would
    # otherwise spawn a `ccache` that does not exist and fail the cell.
    err="$(_run "$d" LUGGAGE_COMPILER_LAUNCHER=ccache 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "cache plumbing never fails the cell"
    assert_equals "<unset>" "$(/usr/bin/cat "$d/launcher-seen")" "luggage builds without a launcher"
    assert_contains "$err" "::warning::" "the fallback is surfaced as a warning"
    if [ -e "$d/pm-calls" ]; then
        assert_true false "fallback must not install: $(/usr/bin/cat "$d/pm-calls")"
    else
        assert_true true "fallback installs nothing"
    fi
    if [ -e "$d/out/stats.txt" ]; then
        assert_true false "no stats file when ccache never ran"
    else
        assert_true true "no stats file when ccache never ran"
    fi
    /usr/bin/rm -rf "$d"
}

test_unrunnable_binary_falls_back() {
    # A mounted binary that will not execute (wrong arch, corrupt) must not
    # opt luggage in, or every compile would fail the cell.
    local d rc=0 err
    d="$(_sandbox)"
    /usr/bin/mkdir -p "$d/mnt"
    printf '#!/bin/sh\nexit 126\n' >"$d/mnt/ccache"
    /usr/bin/chmod +x "$d/mnt/ccache"
    err="$(_run "$d" 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "an unrunnable binary never fails the cell"
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
        CCACHE_STATS_OUT="$d/missing-dir/stats.txt" EVIDENCE_CCACHE_BIN="$d/mnt/ccache" \
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

run_test test_opts_in_when_ccache_is_mounted "opts luggage into the mounted static ccache, installing nothing"
run_test test_failure_status_passes_through "a failed build's exit status passes through"
run_test test_missing_binary_falls_back_without_installing "no mounted ccache builds uncached and installs nothing"
run_test test_unrunnable_binary_falls_back "an unrunnable mounted ccache builds uncached"
run_test test_stats_write_failure_keeps_the_build_status "a failed stats write keeps luggage's exit status"
run_test test_requires_a_command "refuses to run with no command"

generate_report
