#!/usr/bin/env bash
# Unit tests for bin/lib/update-versions/ccache-pin.sh (#1611)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "ccache Pin Updater Tests"

# ============================================================================
# Tests: bump_ccache_pin (evidence-run.yml static ccache, #1611)
# ============================================================================
# Hermetic: ccache_asset_sha256 is stubbed per arch, and the bump runs on a
# scratch copy of the REAL workflow, so a reshaped pin step fails here.

# _ccache_scratch NAME — copy evidence-run.yml into scratch; echo the path.
_ccache_scratch() {
    local wf="$TEST_SCRATCH_BASE/$1.yml"
    command cp "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf"
    echo "$wf"
}

_ccache_source() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
}

test_ccache_bump_rewrites_version_and_both_digests() {
    _ccache_source
    local x86 arm
    x86=$(printf '1%.0s' {1..64})
    arm=$(printf '2%.0s' {1..64})
    ccache_asset_sha256() {
        case "$2" in
            x86_64) printf '1%.0s' {1..64} ;;
            aarch64) printf '2%.0s' {1..64} ;;
            *) return 1 ;;
        esac
    }
    local wf
    wf=$(_ccache_scratch ccache_bump)
    local rc=0
    bump_ccache_pin "$wf" "9.8.7" >/dev/null 2>&1 || rc=$?

    local ok=true
    [ "$rc" -eq 0 ] || ok=false
    command grep -qE '^ +CCACHE_VERSION: 9\.8\.7$' "$wf" || ok=false
    # Each arch gets ITS digest, in the 64-hex shape evidence-run-shape.sh pins.
    command grep -qE "^ +CCACHE_SHA256_X86_64: ${x86}\$" "$wf" || ok=false
    command grep -qE "^ +CCACHE_SHA256_AARCH64: ${arm}\$" "$wf" || ok=false
    # Exactly three lines changed — nothing else in the workflow moved.
    local changed
    changed=$(command diff "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf" | command grep -c '^>' || true)
    [ "$changed" = "3" ] || ok=false
    command rm -f "$wf"
    assert_true "$ok" "bump_ccache_pin rewrites version + each arch's digest (rc=$rc, changed=$changed)"
}

test_ccache_bump_failed_digest_writes_nothing() {
    _ccache_source
    # x86_64 succeeds, aarch64 fails: a half-bump would leave a version whose
    # aarch64 digest can never verify. The file must stay byte-identical.
    ccache_asset_sha256() {
        [ "$2" = x86_64 ] && printf '1%.0s' {1..64} && return 0
        return 1
    }
    local wf
    wf=$(_ccache_scratch ccache_fail)
    local rc=0
    bump_ccache_pin "$wf" "9.8.7" >/dev/null 2>&1 || rc=$?

    local ok=true
    [ "$rc" -eq "$RC_UPDATE_FAILED" ] || ok=false
    command cmp -s "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf" || ok=false
    command rm -f "$wf"
    assert_true "$ok" "a failed digest returns RC_UPDATE_FAILED ($rc) and leaves the workflow byte-identical"
}

test_ccache_bump_refuses_before_any_fetch() {
    _ccache_source
    local fetched="$TEST_SCRATCH_BASE/ccache_fetched"
    command rm -f "$fetched"
    ccache_asset_sha256() {
        : >"$fetched"
        printf '1%.0s' {1..64}
    }
    local wf rc ok=true
    wf=$(_ccache_scratch ccache_refuse)
    rc=0
    bump_ccache_pin "$wf" "4.15.0-rc1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$RC_INVALID_VERSION" ] || ok=false
    command cmp -s "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf" || ok=false

    # Each pin line, reformatted (quoted), must be refused — not silently
    # skipped by a sed that matched nothing.
    local key bad=""
    for key in CCACHE_VERSION CCACHE_SHA256_X86_64 CCACHE_SHA256_AARCH64; do
        command cp "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf"
        command sed -i "s/^\\( *${key}: \\)\\(.*\\)\$/\\1\"\\2\"/" "$wf"
        command grep -qE "^ +${key}: \"" "$wf" || bad+=" $key(not-reshaped)"
        local before
        before=$(command cat "$wf")
        rc=0
        bump_ccache_pin "$wf" "9.8.7" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq "$RC_PIN_UNREWRITABLE" ] || bad+=" $key(rc=$rc)"
        [ "$(command cat "$wf")" = "$before" ] || bad+=" $key(written)"
    done
    [ -z "$bad" ] || ok=false
    [ ! -e "$fetched" ] || ok=false
    command rm -f "$wf" "$fetched"
    assert_true "$ok" "non-X.Y.Z and each reshaped pin line are refused with no fetch and no write${bad:+ —$bad}"
}

test_ccache_dry_run_needs_no_network_and_writes_nothing() {
    _ccache_source
    local fetched="$TEST_SCRATCH_BASE/ccache_dry_fetched"
    command rm -f "$fetched"
    ccache_asset_sha256() {
        : >"$fetched"
        printf '1%.0s' {1..64}
    }
    local wf rc=0
    wf=$(_ccache_scratch ccache_dry)
    DRY_RUN=true bump_ccache_pin "$wf" "9.8.7" >/dev/null 2>&1 || rc=$?

    local ok=true
    [ "$rc" -eq 0 ] || ok=false
    [ ! -e "$fetched" ] || ok=false
    command cmp -s "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf" || ok=false
    command rm -f "$wf" "$fetched"
    assert_true "$ok" "DRY_RUN bump returns 0 (rc=$rc), fetches nothing, and leaves the workflow byte-identical"
}

test_ccache_bump_rejects_malformed_digest() {
    _ccache_source
    # A fetcher that "succeeds" with a bad digest must not be trusted: empty,
    # short, and uppercase are all refused, on either arch, with no write.
    local wf bad="" case_ rc
    wf=$(_ccache_scratch ccache_malformed)
    for case_ in "x86_64:" "x86_64:abc" "aarch64:$(printf 'A%.0s' {1..64})"; do
        CCACHE_TEST_ARCH=${case_%%:*} CCACHE_TEST_SUM=${case_#*:}
        ccache_asset_sha256() {
            if [ "$2" = "$CCACHE_TEST_ARCH" ]; then
                printf '%s\n' "$CCACHE_TEST_SUM"
            else
                printf '1%.0s' {1..64}
            fi
        }
        rc=0
        bump_ccache_pin "$wf" "9.8.7" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq "$RC_UPDATE_FAILED" ] || bad+=" ${case_}(rc=$rc)"
        command cmp -s "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$wf" || bad+=" ${case_}(written)"
    done
    command rm -f "$wf"
    assert_true "$([ -z "$bad" ] && echo true || echo false)" \
        "malformed digests are refused with RC_UPDATE_FAILED and no write${bad:+ —$bad}"
}

# The real fetcher, hermetically: a PATH-stub curl stands in for the network.
# Called in-process (no child bash), so /etc/bash_env cannot rebuild PATH.
test_ccache_asset_sha256_real_function() {
    _ccache_source
    local stub="$TEST_SCRATCH_BASE/ccache_stub" tmpd="$TEST_SCRATCH_BASE/ccache_tmp"
    command mkdir -p "$stub" "$tmpd"
    command cat >"$stub/curl" <<'STUB'
#!/bin/sh
# Record the args; write fixed bytes to -o, or fail when told to.
printf '%s\n' "$*" >"$CCACHE_STUB_LOG"
[ "$CCACHE_STUB_FAIL" = 1 ] && exit 22
while [ $# -gt 0 ]; do
    [ "$1" = -o ] && { printf 'ccache-bytes' >"$2"; exit 0; }
    shift
done
exit 2
STUB
    command chmod +x "$stub/curl"
    local want out rc ok=true log="$TEST_SCRATCH_BASE/ccache_stub.log"
    want=$(printf 'ccache-bytes' | command sha256sum | command cut -d' ' -f1)

    rc=0
    out=$(PATH="$stub:$PATH" TMPDIR="$tmpd" CCACHE_STUB_LOG="$log" CCACHE_STUB_FAIL=0 \
        ccache_asset_sha256 9.8.7 aarch64 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] && [ "$out" = "$want" ] || ok=false
    # The URL is the musl-static asset for that exact version + arch, https-only.
    command grep -qF 'https://github.com/ccache/ccache/releases/download/v9.8.7/ccache-9.8.7-linux-aarch64-musl-static.tar.xz' "$log" || ok=false
    command grep -qF -- "--proto-redir =https" "$log" || ok=false

    local fail_out
    rc=0
    fail_out=$(PATH="$stub:$PATH" TMPDIR="$tmpd" CCACHE_STUB_LOG="$log" CCACHE_STUB_FAIL=1 \
        ccache_asset_sha256 9.8.7 x86_64 2>/dev/null) || rc=$?
    [ "$rc" -eq 1 ] && [ -z "$fail_out" ] || ok=false
    # A failed hash must fail the function too — not print an empty digest
    # with rc=0. pipefail is OFF for this call: the function must not depend on
    # its caller's shell options (this suite, like common.sh, sets pipefail,
    # which would hide a `sha256sum | cut` status mask).
    command printf '#!/bin/sh\nexit 1\n' >"$stub/sha256sum"
    command chmod +x "$stub/sha256sum"
    rc=0
    fail_out=$(
        set +o pipefail
        PATH="$stub:$PATH" TMPDIR="$tmpd" CCACHE_STUB_LOG="$log" CCACHE_STUB_FAIL=0 \
            ccache_asset_sha256 9.8.7 x86_64 2>/dev/null
    ) || rc=$?
    [ "$rc" -eq 1 ] && [ -z "$fail_out" ] || ok=false
    # Every call cleaned up its temp download.
    [ -z "$(command ls -A "$tmpd")" ] || ok=false

    command rm -rf "$stub" "$tmpd" "$log"
    assert_true "$ok" "real ccache_asset_sha256 hashes the download, fails empty on curl or hash error, and removes its temp file"
}

test_ccache_dispatch_reaches_bump() {
    _ccache_source
    local root="$TEST_SCRATCH_BASE/ccache_root"
    command mkdir -p "$root/.github/workflows"
    command cp "$PROJECT_ROOT/.github/workflows/evidence-run.yml" "$root/.github/workflows/"
    ccache_asset_sha256() { printf '3%.0s' {1..64}; }
    local rc=0 rc_unknown=0
    # A prefix assignment on a function call is scoped to that call.
    PROJECT_ROOT="$root" update_version ccache 4.14.3 9.8.7 evidence-run.yml >/dev/null 2>&1 || rc=$?
    PROJECT_ROOT="$root" update_version nope 1.0.0 1.0.1 evidence-run.yml >/dev/null 2>&1 || rc_unknown=$?

    local ok=true
    [ "$rc" -eq 0 ] || ok=false
    command grep -qE '^ +CCACHE_VERSION: 9\.8\.7$' "$root/.github/workflows/evidence-run.yml" || ok=false
    [ "$rc_unknown" -eq "$RC_NO_UPDATER_CASE" ] || ok=false
    command rm -rf "$root"
    assert_true "$ok" "update_version routes evidence-run.yml ccache to the bump (rc=$rc) and flags unknown tools ($rc_unknown)"
}

run_test test_ccache_bump_rewrites_version_and_both_digests "bump_ccache_pin rewrites CCACHE_VERSION and both per-arch digests"
run_test test_ccache_bump_failed_digest_writes_nothing "bump_ccache_pin writes nothing when a digest can't be computed"
run_test test_ccache_bump_refuses_before_any_fetch "bump_ccache_pin refuses bad versions and reshaped pins before fetching"
run_test test_ccache_dry_run_needs_no_network_and_writes_nothing "bump_ccache_pin under DRY_RUN fetches nothing and writes nothing"
run_test test_ccache_bump_rejects_malformed_digest "bump_ccache_pin refuses empty, short, and uppercase digests"
run_test test_ccache_asset_sha256_real_function "ccache_asset_sha256 (unstubbed) hashes, fails cleanly, and cleans up"
run_test test_ccache_dispatch_reaches_bump "update_version dispatches evidence-run.yml ccache to bump_ccache_pin"

# Generate report
generate_report
