#!/bin/bash
# Package a built stibbons binary into a release asset (archive + .sha256) and
# enforce the binary-size budget. Extracted from the "Package artifact" step of
# .github/workflows/release-binaries.yml (#286 / PR #690) so the naming, the
# 15 MB size gate, the checksum, and the Windows 7z presence check can be
# unit-tested outside of a release run (#697).
#
# Inputs (environment):
#   TARGET      Rust target triple (e.g. x86_64-unknown-linux-musl). Required.
#   RUNNER_OS   "Windows" selects the .zip/7z path; anything else uses tar.gz.
#   VERSION     Product version for the asset name. Defaults to the trimmed
#               contents of the repo-root VERSION file (the same source build.rs
#               stamps into the binary, so the asset name matches --version).
#   DIST_DIR    Directory holding the built binary. Defaults to
#               target/<TARGET>/dist (where `cargo build --profile dist` lands).
#   OUT_DIR     Directory to write the asset + checksum into. Defaults to "dist".
#   SIZE_LIMIT_BYTES  Override the 15 MB gate (for tests). Defaults to 15 MiB.
#   SEVENZIP    7z command for the Windows path (overridable for tests).
#               Defaults to "7z".
#
# Output:
#   Writes "asset=<path>" to $GITHUB_OUTPUT when that variable is set (CI), and
#   always prints the asset path on stdout as the last line.
#
# Exit codes:
#   0  packaged successfully
#   1  missing input, binary over budget, or (Windows) 7z not on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 7z is referenced through an overridable var so a test can point it at a stub
# or force the not-found path; production uses the real `7z` on PATH.
SEVENZIP="${SEVENZIP:-7z}"

fail() {
    echo "::error::$*" >&2
    exit 1
}

TARGET="${TARGET:-}"
[ -n "$TARGET" ] || fail "TARGET (Rust target triple) is required"

# Version defaults to the repo-root VERSION file (matches the build.rs stamp).
if [ -z "${VERSION:-}" ]; then
    [ -f "$REPO_ROOT/VERSION" ] || fail "VERSION not set and $REPO_ROOT/VERSION not found"
    VERSION="$(/usr/bin/tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
fi

DIST_DIR="${DIST_DIR:-target/${TARGET}/dist}"
OUT_DIR="${OUT_DIR:-dist}"
SIZE_LIMIT_BYTES="${SIZE_LIMIT_BYTES:-$((15 * 1024 * 1024))}"

stem="stibbons-${VERSION}-${TARGET}"
/bin/mkdir -p "$OUT_DIR"

if [ "${RUNNER_OS:-}" = "Windows" ]; then
    bin="${DIST_DIR}/stibbons.exe"
    asset="${stem}.zip"
    # Verify 7z is present before invoking it — on windows-latest runners a
    # missing 7z would otherwise fail deep inside packaging with an opaque
    # error. Fail fast with a clear message instead (#697 AC5).
    command -v "$SEVENZIP" >/dev/null 2>&1 ||
        fail "7z not found on PATH (needed to build the Windows .zip asset); install it before packaging"
    [ -f "$bin" ] || fail "built binary not found: $bin"
    # Pass $bin directly (not "./$bin"): DIST_DIR is an overridable input and may
    # be absolute, in which case a "./" prefix would corrupt the path.
    "$SEVENZIP" a "${OUT_DIR}/${asset}" "$bin" >/dev/null
else
    bin="${DIST_DIR}/stibbons"
    asset="${stem}.tar.gz"
    [ -f "$bin" ] || fail "built binary not found: $bin"
    /usr/bin/tar -czf "${OUT_DIR}/${asset}" -C "$DIST_DIR" stibbons
fi

# Size gate: the shipped (stripped) binary must stay under the budget.
bytes="$(/usr/bin/wc -c <"$bin")"
echo "Binary $bin is $bytes bytes (limit $SIZE_LIMIT_BYTES)."
if [ "$bytes" -gt "$SIZE_LIMIT_BYTES" ]; then
    fail "stibbons binary for $TARGET is $bytes bytes, exceeding the $((SIZE_LIMIT_BYTES / 1024 / 1024)) MB budget."
fi

# Checksum alongside the archive for the install script to verify.
(cd "$OUT_DIR" && { /usr/bin/sha256sum "$asset" || /usr/bin/shasum -a 256 "$asset"; } >"${asset}.sha256")

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "asset=${OUT_DIR}/${asset}" >>"$GITHUB_OUTPUT"
fi
echo "${OUT_DIR}/${asset}"
