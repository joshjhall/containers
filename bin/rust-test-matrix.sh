#!/usr/bin/env bash
# rust-test-matrix.sh — decide whether and where ci.yml's rust-test job runs
# (#1593, #1653).
#
# Usage: bin/rust-test-matrix.sh EVENT_NAME [BASE_REF]
#
# Prints two `key=value` lines, appended verbatim to $GITHUB_OUTPUT:
#   run=<true|false>   whether rust-test (and rust-latest-stable) run at all
#   matrix=<json>      the OS list for `fromJSON()` in rust-test's matrix
#
#   - pull_request whose diff against origin/BASE_REF touches no Rust input
#     → run=false. The matrix stays a valid one-entry list so `fromJSON()`
#     never sees `[]`. "Rust input" is everything rust-test's outcome can
#     depend on, not just crate sources (#1653):
#       crates/, Cargo.toml, Cargo.lock, rust-toolchain*  — the code + toolchain
#       .cargo/, clippy.toml, .rustfmt.toml               — fmt/clippy/build config
#       VERSION             — stamped into stibbons by build.rs (version_stamp.rs)
#       .github/workflows/ci.yml, bin/read-librarian-pin.sh — the job itself
#       Dockerfile, only when an `LIBRARIAN_REF` line changes — the render.sh
#                           parity test checks librarian out at that pin
#   - any other pull_request, and every other event (push to main, tags,
#     schedule, workflow_dispatch) → run=true, ubuntu + macOS + Windows.
#
# Fails SAFE: a missing base ref or a failing `git diff` yields run=true and
# the full matrix — never the skip on doubt. The `Rust Tests` aggregator
# accepts a skipped rust-test ONLY when this detector succeeded and said
# run=false (#904); any other skip fails closed.
set -euo pipefail

readonly FULL='["ubuntu-26.04","macos-26","windows-2025"]'
readonly SKIP_MATRIX='["ubuntu-26.04"]'

emit() {
    printf 'run=%s\n' "$1"
    printf 'matrix=%s\n' "$2"
}

event="${1:-}"
base_ref="${2:-}"

if [ "$event" != "pull_request" ] || [ -z "$base_ref" ]; then
    emit true "$FULL"
    exit 0
fi

diff_failed() {
    printf '::warning::rust-test-matrix: git diff against origin/%s failed; running the full OS matrix\n' "$base_ref" >&2
    emit true "$FULL"
    exit 0
}

range="origin/${base_ref}...HEAD"

changed="$(git diff --name-only "$range" -- \
    crates/ Cargo.toml Cargo.lock 'rust-toolchain*' \
    .cargo/ clippy.toml .rustfmt.toml VERSION \
    .github/workflows/ci.yml bin/read-librarian-pin.sh 2>/dev/null)" || diff_failed

# A Dockerfile edit matters only when it moves the librarian pin; -G keeps
# the file in the list only if an added/removed line mentions LIBRARIAN_REF.
pin_changed="$(git diff --name-only -G 'LIBRARIAN_REF' "$range" -- \
    Dockerfile 2>/dev/null)" || diff_failed

if [ -n "$changed" ] || [ -n "$pin_changed" ]; then
    emit true "$FULL"
else
    emit false "$SKIP_MATRIX"
fi
