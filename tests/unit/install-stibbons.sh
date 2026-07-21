#!/usr/bin/env bash
# Unit tests for bin/install-stibbons.sh — the stibbons host-CLI installer
# shipped by #286 / PR #690, previously untested (#697).
#
# Covers the pieces that can be exercised in isolation:
#   - detect_target():   every uname OS/arch combination the script maps, plus
#                        the unsupported-OS and unsupported-arch error paths
#   - resolve_version(): explicit-tag passthrough, the `gh` happy path, and the
#                        curl-redirect fallback when `gh` is absent
#   - the checksum-verification failure path of the full install flow (a corrupt
#                        asset must abort with a non-zero exit BEFORE installing)
#
# Strategy: the script guards its main flow behind STIBBONS_INSTALL_LIB=1, so we
# source it to unit-test detect_target()/resolve_version() directly. External
# commands are reached through overridable vars (UNAME/CURL/SED/GH) that default
# to absolute paths — the same injection seam as the GH= var in
# tests/unit/dispatch-evidence-for-tuple.sh — so tests point them at stubs
# without touching PATH or violating the repo's full-path command policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "install-stibbons.sh tests"

INSTALL_SCRIPT="$PROJECT_ROOT/bin/install-stibbons.sh"

# ---------------------------------------------------------------------------
# Stub helpers
# ---------------------------------------------------------------------------

# new_stub <name> <body...>: write an executable stub into a fresh temp dir and
# echo its absolute path. The body is the script after the shebang.
new_stub() {
    local name="$1"
    shift
    local dir path
    dir="$(mktemp -d "$TEST_TEMP_DIR/stub-XXXXXX")"
    path="$dir/$name"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$@"
    } >"$path"
    command chmod +x "$path"
    printf '%s' "$path"
}

# uname_stub <sysname> <machine>: a fake `uname` emitting fixed -s / -m values.
uname_stub() {
    new_stub uname \
        "case \"\$1\" in" \
        "  -s) printf '%s\\n' '$1' ;;" \
        "  -m) printf '%s\\n' '$2' ;;" \
        "esac"
}

# target_for <sysname> <machine>: source the script as a library with a uname
# stub injected via UNAME= and print detect_target()'s output (exit propagated).
target_for() {
    local stub
    stub="$(uname_stub "$1" "$2")"
    STIBBONS_INSTALL_LIB=1 UNAME="$stub" bash -c '
        source "$1"
        detect_target
    ' _ "$INSTALL_SCRIPT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# detect_target()
# ---------------------------------------------------------------------------

test_detect_linux_x86_64() {
    assert_equals "x86_64-unknown-linux-musl" "$(target_for Linux x86_64)" \
        "Linux/x86_64 maps to the musl triple"
}

test_detect_linux_aarch64() {
    assert_equals "aarch64-unknown-linux-musl" "$(target_for Linux aarch64)" \
        "Linux/aarch64 maps to the musl triple"
}

test_detect_linux_amd64_alias() {
    assert_equals "x86_64-unknown-linux-musl" "$(target_for Linux amd64)" \
        "amd64 is treated as an x86_64 alias"
}

test_detect_darwin_arm64_alias() {
    assert_equals "aarch64-apple-darwin" "$(target_for Darwin arm64)" \
        "Darwin/arm64 maps to the aarch64 apple triple"
}

test_detect_darwin_x86_64() {
    assert_equals "x86_64-apple-darwin" "$(target_for Darwin x86_64)" \
        "Darwin/x86_64 maps to the x86_64 apple triple"
}

test_detect_windows_mingw() {
    assert_equals "x86_64-pc-windows-msvc" "$(target_for MINGW64_NT-10.0 x86_64)" \
        "MINGW* is treated as Windows and maps to the msvc triple"
}

test_detect_unsupported_os() {
    local ec=0
    target_for Plan9 x86_64 >/dev/null 2>&1 || ec=$?
    assert_exit_code 1 "$ec" "an unsupported OS makes detect_target fail"
}

test_detect_unsupported_arch() {
    local ec=0
    target_for Linux mips64 >/dev/null 2>&1 || ec=$?
    assert_exit_code 1 "$ec" "an unsupported architecture makes detect_target fail"
}

# ---------------------------------------------------------------------------
# resolve_version()
# ---------------------------------------------------------------------------

# resolve_with <version> [GH=path] [CURL=path]: source as library, then set
# VERSION/REPO and print resolve_version()'s output. VERSION/REPO are assigned
# AFTER sourcing on purpose — the script hard-assigns `VERSION="latest"` /
# `REPO=...` at load time, so an inherited env var would be clobbered; the real
# script sets them from argv, which for a library test we emulate post-source.
# Extra "VAR=val" pairs (e.g. GH=, CURL=) ARE consumed at load time by the
# overridable-command block, so those stay in the env prefix.
resolve_with() {
    local version="$1"
    shift
    env STIBBONS_INSTALL_LIB=1 "$@" TEST_VERSION="$version" bash -c '
        source "$1"
        VERSION="$TEST_VERSION"
        REPO="acme/widget"
        resolve_version
    ' _ "$INSTALL_SCRIPT" 2>/dev/null
}

test_resolve_explicit_tag_passthrough() {
    # A missing gh guarantees no network is consulted for an explicit tag.
    assert_equals "v4.19.12" "$(resolve_with v4.19.12 GH=/nonexistent/gh)" \
        "an explicit --version tag is echoed back verbatim (no network)"
}

test_resolve_latest_via_gh() {
    local gh
    gh="$(new_stub gh "printf 'v7.7.7\\n'")"
    assert_equals "v7.7.7" "$(resolve_with latest "GH=$gh")" \
        "with gh present, latest resolves to the release's tagName"
}

test_resolve_latest_via_curl_redirect() {
    # gh absent (GH points at a nonexistent path so `command -v` fails) → the
    # curl-redirect fallback runs; stub curl to emit the effective tag URL.
    local curl
    curl="$(new_stub curl "printf 'https://github.com/acme/widget/releases/tag/v9.1.0'")"
    assert_equals "v9.1.0" "$(resolve_with latest GH=/nonexistent/gh "CURL=$curl")" \
        "without gh, latest is parsed from the /releases/latest redirect URL"
}

# ---------------------------------------------------------------------------
# Checksum verification failure (full install flow, end to end)
# ---------------------------------------------------------------------------

# Runs the REAL installer with CURL stubbed to serve a local asset + a
# deliberately wrong .sha256. The verify step must fail non-zero and leave the
# install dir empty.
test_checksum_mismatch_aborts_before_install() {
    local server installdir target ext asset
    server="$(mktemp -d "$TEST_TEMP_DIR/server-XXXXXX")"
    installdir="$(mktemp -d "$TEST_TEMP_DIR/install-XXXXXX")"

    target="$(bash "$INSTALL_SCRIPT" --print-target)"
    case "$target" in *windows*) ext="zip" ;; *) ext="tar.gz" ;; esac
    asset="stibbons-1.2.3-${target}.${ext}"

    printf 'not-a-real-binary' >"$server/asset.bin"
    # A .sha256 line whose digest cannot match the asset (all zeros).
    printf '%s  %s\n' \
        "0000000000000000000000000000000000000000000000000000000000000000" "$asset" \
        >"$server/wrong.sha256"

    # curl stub: copy the local asset / .sha256 to the requested -o destination,
    # keyed off the URL suffix. Mirrors the two download() calls.
    local curl
    curl="$(new_stub curl \
        "dest=''" \
        "url=''" \
        "while [ \$# -gt 0 ]; do case \"\$1\" in" \
        "  -o) dest=\"\$2\"; shift 2 ;;" \
        "  http*|https*) url=\"\$1\"; shift ;;" \
        "  *) shift ;;" \
        "esac; done" \
        "case \"\$url\" in" \
        "  *.sha256) command cp '$server/wrong.sha256' \"\$dest\" ;;" \
        "  *) command cp '$server/asset.bin' \"\$dest\" ;;" \
        "esac")"

    local ec=0 out
    out="$(CURL="$curl" bash "$INSTALL_SCRIPT" \
        --version v1.2.3 --dir "$installdir" 2>&1)" || ec=$?

    assert_not_equals "0" "$ec" "a mismatched checksum makes the installer exit non-zero"
    assert_file_not_exists "$installdir/stibbons" \
        "no binary is installed when checksum verification fails"
    assert_contains "$out" "Verifying checksum" \
        "the failure occurs at the verification step"
}

# ---------------------------------------------------------------------------
# Successful install (full flow, end to end)
# ---------------------------------------------------------------------------

# Runs the REAL installer against a locally-built tar.gz asset with a MATCHING
# checksum, and asserts the binary is unpacked and installed into --dir with the
# executable bit and the success message. This exercises the download → verify →
# tar extract → install path that the checksum-failure test deliberately stops
# short of (the script's actual purpose).
test_successful_install_end_to_end() {
    local server installdir target ext asset
    server="$(mktemp -d "$TEST_TEMP_DIR/server-XXXXXX")"
    installdir="$(mktemp -d "$TEST_TEMP_DIR/install-XXXXXX")"

    target="$(bash "$INSTALL_SCRIPT" --print-target)"
    case "$target" in
        *windows*)
            # The zip/unzip branch needs a stubbed unzip + .exe; the host here is
            # non-Windows, so skip rather than assert a path we can't build.
            return 0
            ;;
    esac
    ext="tar.gz"
    asset="stibbons-3.2.1-${target}.${ext}"

    # Build a real tar.gz containing an executable `stibbons` the installer will
    # unpack, plus a correct .sha256 over the archive (computed in-place).
    printf '#!/bin/sh\necho stub-stibbons\n' >"$server/stibbons"
    chmod +x "$server/stibbons"
    /usr/bin/tar -czf "$server/$asset" -C "$server" stibbons
    (cd "$server" && sha256sum "$asset" >"$asset.sha256")

    local curl
    curl="$(new_stub curl \
        "dest=''" \
        "url=''" \
        "while [ \$# -gt 0 ]; do case \"\$1\" in" \
        "  -o) dest=\"\$2\"; shift 2 ;;" \
        "  http*|https*) url=\"\$1\"; shift ;;" \
        "  *) shift ;;" \
        "esac; done" \
        "base=\"\${url##*/}\"" \
        "command cp '$server'/\"\$base\" \"\$dest\"")"

    local ec=0 out
    out="$(CURL="$curl" bash "$INSTALL_SCRIPT" \
        --version v3.2.1 --dir "$installdir" 2>&1)" || ec=$?

    assert_exit_code 0 "$ec" "the installer exits 0 on a valid asset + matching checksum"
    assert_file_exists "$installdir/stibbons" "the binary is installed into --dir"
    assert_file_executable "$installdir/stibbons" "the installed binary is executable"
    assert_contains "$out" "Installed stibbons to ${installdir}/stibbons" \
        "the success message reports the install path"
}

# ---------------------------------------------------------------------------
# Argument parsing (early-exit branches, no network)
# ---------------------------------------------------------------------------
#
# These run the REAL script (not the library form): --print-target, --help/-h,
# and the unknown-argument path all exit before any download. --repo/--version/
# --dir are proven to parse by pairing them with --print-target, which runs the
# full arg loop and then exits after printing the target. Deferred coverage gap
# from #749 (the #697/PR#748 review).

# _run_installer <args...>: capture combined output + exit code into globals.
_run_installer() {
    ISB_OUT="$(bash "$INSTALL_SCRIPT" "$@" 2>&1)"
    ISB_CODE=$?
    return 0
}

test_arg_print_target_exits_zero() {
    _run_installer --print-target
    assert_exit_code 0 "$ISB_CODE" "--print-target should exit 0"
    assert_matches "$ISB_OUT" '^[a-z0-9_]+-[a-z0-9-]+$' \
        "--print-target should print a target triple (got '$ISB_OUT')"
}

test_arg_help_long_exits_zero() {
    _run_installer --help
    assert_exit_code 0 "$ISB_CODE" "--help should exit 0"
    assert_contains "$ISB_OUT" "Usage: install-stibbons.sh" "--help prints usage"
}

test_arg_help_short_exits_zero() {
    _run_installer -h
    assert_exit_code 0 "$ISB_CODE" "-h should exit 0 (alias for --help)"
    assert_contains "$ISB_OUT" "Usage: install-stibbons.sh" "-h prints usage"
}

test_arg_unknown_fails_with_usage() {
    _run_installer --definitely-not-a-flag
    assert_exit_code 1 "$ISB_CODE" "an unknown argument should exit 1"
    assert_contains "$ISB_OUT" "unknown argument" "the error names the condition"
    assert_contains "$ISB_OUT" "Usage: install-stibbons.sh" \
        "the error path also prints usage"
}

test_arg_repo_accepted() {
    _run_installer --repo some/other-repo --print-target
    assert_exit_code 0 "$ISB_CODE" "--repo <owner/repo> should be accepted"
    assert_matches "$ISB_OUT" '^[a-z0-9_]+-[a-z0-9-]+$' \
        "--repo should not disturb --print-target output"
}

test_arg_version_accepted() {
    _run_installer --version v4.19.12 --print-target
    assert_exit_code 0 "$ISB_CODE" "--version <tag> should be accepted"
    assert_matches "$ISB_OUT" '^[a-z0-9_]+-[a-z0-9-]+$' \
        "--version should not disturb --print-target output"
}

test_arg_dir_accepted() {
    _run_installer --dir /tmp/stibbons-test-dir --print-target
    assert_exit_code 0 "$ISB_CODE" "--dir <path> should be accepted"
    assert_matches "$ISB_OUT" '^[a-z0-9_]+-[a-z0-9-]+$' \
        "--dir should not disturb --print-target output"
}

run_test test_detect_linux_x86_64 "detect_target: Linux/x86_64"
run_test test_detect_linux_aarch64 "detect_target: Linux/aarch64"
run_test test_detect_linux_amd64_alias "detect_target: amd64 alias"
run_test test_detect_darwin_arm64_alias "detect_target: Darwin/arm64 alias"
run_test test_detect_darwin_x86_64 "detect_target: Darwin/x86_64"
run_test test_detect_windows_mingw "detect_target: MINGW/Windows"
run_test test_detect_unsupported_os "detect_target: unsupported OS fails"
run_test test_detect_unsupported_arch "detect_target: unsupported arch fails"
run_test test_resolve_explicit_tag_passthrough "resolve_version: explicit tag passthrough"
run_test test_resolve_latest_via_gh "resolve_version: latest via gh"
run_test test_resolve_latest_via_curl_redirect "resolve_version: latest via curl redirect"
run_test test_checksum_mismatch_aborts_before_install "checksum mismatch aborts before install"
run_test test_successful_install_end_to_end "successful install (extract + install) end to end"
run_test test_arg_print_target_exits_zero "args: --print-target prints a triple, exits 0"
run_test test_arg_help_long_exits_zero "args: --help prints usage, exits 0"
run_test test_arg_help_short_exits_zero "args: -h prints usage, exits 0"
run_test test_arg_unknown_fails_with_usage "args: unknown flag errors + usage, exits 1"
run_test test_arg_repo_accepted "args: --repo accepted by the arg loop"
run_test test_arg_version_accepted "args: --version accepted by the arg loop"
run_test test_arg_dir_accepted "args: --dir accepted by the arg loop"

generate_report
