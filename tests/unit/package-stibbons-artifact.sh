#!/usr/bin/env bash
# Unit tests for bin/package-stibbons-artifact.sh — the release packaging /
# size-gate / checksum / 7z-guard logic extracted from release-binaries.yml so
# it can be tested outside a release run (#697, AC4 + AC5).
#
# Each test builds a fake "dist" dir with a stub binary of a chosen size, runs
# the packaging script against it (non-Windows tar.gz path by default), and
# asserts on asset naming, the 15 MB size gate boundary, checksum production,
# and the Windows 7z presence guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "package-stibbons-artifact.sh tests"

PKG_SCRIPT="$PROJECT_ROOT/bin/package-stibbons-artifact.sh"

# make_dist <size_bytes> [binname]: create a DIST_DIR containing a stub binary
# of the given size and echo the dir path.
make_dist() {
    local size="$1" binname="${2:-stibbons}" d
    d="$(mktemp -d "$TEST_TEMP_DIR/dist-XXXXXX")"
    /usr/bin/truncate -s "$size" "$d/$binname"
    printf '%s' "$d"
}

# run_pkg: invoke the packaging script with the given env, capturing combined
# output; propagates the exit code. Usage: run_pkg VAR=val ...
run_pkg() {
    local out_file="$TEST_TEMP_DIR/pkg-out.txt" ec=0
    env "$@" bash "$PKG_SCRIPT" >"$out_file" 2>&1 || ec=$?
    command cat "$out_file"
    return "$ec"
}

# ---------------------------------------------------------------------------
# Happy path: naming, archive, checksum
# ---------------------------------------------------------------------------

test_packages_tar_gz_with_expected_name() {
    local dist out outdir
    dist="$(make_dist 1024)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    out="$(run_pkg \
        TARGET=x86_64-unknown-linux-musl \
        VERSION=1.2.3 \
        DIST_DIR="$dist" \
        OUT_DIR="$outdir")"

    local asset="stibbons-1.2.3-x86_64-unknown-linux-musl.tar.gz"
    assert_file_exists "$outdir/$asset" "the tar.gz asset is created with the expected name"
    assert_file_exists "$outdir/$asset.sha256" "a .sha256 checksum accompanies the asset"
    assert_contains "$out" "$outdir/$asset" "the asset path is printed on stdout"
}

test_checksum_verifies() {
    local dist outdir asset
    dist="$(make_dist 2048)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    run_pkg TARGET=aarch64-apple-darwin VERSION=9.9.9 DIST_DIR="$dist" OUT_DIR="$outdir" >/dev/null
    asset="stibbons-9.9.9-aarch64-apple-darwin.tar.gz"
    local ec=0
    (cd "$outdir" && /usr/bin/sha256sum -c "$asset.sha256") >/dev/null 2>&1 || ec=$?
    assert_exit_code 0 "$ec" "the generated checksum verifies against the asset"
}

test_version_defaults_to_version_file() {
    # With no VERSION env, the script reads the repo-root VERSION file.
    local dist outdir out expected
    dist="$(make_dist 1024)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    expected="$(/usr/bin/tr -d '[:space:]' <"$PROJECT_ROOT/VERSION")"
    out="$(run_pkg TARGET=x86_64-unknown-linux-musl DIST_DIR="$dist" OUT_DIR="$outdir")"
    assert_contains "$out" "stibbons-${expected}-x86_64-unknown-linux-musl.tar.gz" \
        "VERSION defaults to the repo-root VERSION file contents"
}

# ---------------------------------------------------------------------------
# AC4: size gate boundary
# ---------------------------------------------------------------------------

test_size_gate_passes_at_limit() {
    # Exactly at the limit is allowed ( > limit trips, == does not ).
    local dist outdir ec=0
    dist="$(make_dist 100)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    run_pkg TARGET=t VERSION=1.0.0 DIST_DIR="$dist" OUT_DIR="$outdir" \
        SIZE_LIMIT_BYTES=100 >/dev/null 2>&1 || ec=$?
    assert_exit_code 0 "$ec" "a binary exactly at the size limit passes the gate"
}

test_size_gate_trips_one_byte_over() {
    local dist outdir out ec=0
    dist="$(make_dist 101)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    out="$(run_pkg TARGET=t VERSION=1.0.0 DIST_DIR="$dist" OUT_DIR="$outdir" \
        SIZE_LIMIT_BYTES=100)" || ec=$?
    assert_not_equals "0" "$ec" "a binary one byte over the limit trips the gate"
    assert_contains "$out" "exceeding" "the size-gate failure is reported with ::error::"
}

# ---------------------------------------------------------------------------
# AC5: Windows 7z presence guard
# ---------------------------------------------------------------------------

test_windows_missing_7z_fails_fast() {
    local dist outdir out ec=0
    dist="$(make_dist 1024 stibbons.exe)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    # Point SEVENZIP at a nonexistent command so the presence check fails.
    out="$(run_pkg RUNNER_OS=Windows TARGET=x86_64-pc-windows-msvc VERSION=1.0.0 \
        DIST_DIR="$dist" OUT_DIR="$outdir" SEVENZIP=/nonexistent/7z)" || ec=$?
    assert_not_equals "0" "$ec" "missing 7z makes the Windows packaging path fail"
    assert_contains "$out" "7z not found" "the failure names the missing 7z tool"
}

test_windows_present_7z_packages() {
    # A stub 7z that just creates the requested archive file lets the Windows
    # path run to the size gate + checksum without a real 7-Zip.
    local dist outdir stubdir out
    dist="$(make_dist 1024 stibbons.exe)"
    outdir="$(mktemp -d "$TEST_TEMP_DIR/out-XXXXXX")"
    stubdir="$(mktemp -d "$TEST_TEMP_DIR/7zstub-XXXXXX")"
    # Mimic `7z a <archive> <source>` (arg1=a, arg2=archive, arg3=source) AND
    # validate that the source path actually exists — so a regression that
    # corrupts the source arg (e.g. a stray "./" prefix on an absolute DIST_DIR)
    # fails here instead of silently "packaging" nothing.
    command cat >"$stubdir/7z" <<'STUB'
#!/usr/bin/env bash
[ -f "$3" ] || { echo "7z stub: source not found: $3" >&2; exit 2; }
printf 'stub-zip' >"$2"
STUB
    command chmod +x "$stubdir/7z"

    local ec=0
    out="$(run_pkg RUNNER_OS=Windows TARGET=x86_64-pc-windows-msvc VERSION=2.0.0 \
        DIST_DIR="$dist" OUT_DIR="$outdir" SEVENZIP="$stubdir/7z")" || ec=$?
    assert_exit_code 0 "$ec" "with 7z present the Windows path packages successfully"
    assert_file_exists "$outdir/stibbons-2.0.0-x86_64-pc-windows-msvc.zip" \
        "the .zip asset is produced on the Windows path"
}

run_test test_packages_tar_gz_with_expected_name "packages tar.gz with expected name"
run_test test_checksum_verifies "generated checksum verifies"
run_test test_version_defaults_to_version_file "VERSION defaults to VERSION file"
run_test test_size_gate_passes_at_limit "size gate passes at the limit"
run_test test_size_gate_trips_one_byte_over "size gate trips one byte over"
run_test test_windows_missing_7z_fails_fast "Windows: missing 7z fails fast"
run_test test_windows_present_7z_packages "Windows: present 7z packages"

generate_report
