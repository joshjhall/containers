#!/usr/bin/env bash
# rust-test-matrix.sh — print the OS list ci.yml's rust-test job runs on (#1593).
#
# Usage: bin/rust-test-matrix.sh EVENT_NAME [BASE_REF]
#
# Prints a compact JSON array for `fromJSON()` in the job's matrix:
#   - pull_request whose diff against origin/BASE_REF touches no Rust input
#     (crates/, Cargo.toml, Cargo.lock, rust-toolchain*) → ubuntu only.
#   - any other pull_request, and every other event (push to main, tags,
#     schedule, workflow_dispatch) → ubuntu + macOS + Windows.
#
# Fails SAFE: a missing base ref or a failing `git diff` yields the full
# matrix, never the cheap one. The ubuntu leg is in every answer, so the
# rust-test job is never skipped and the `Rust Tests` aggregator only ever
# has to accept `success` (#904).
set -euo pipefail

readonly FULL='["ubuntu-26.04","macos-26","windows-2025"]'
readonly LINUX_ONLY='["ubuntu-26.04"]'

event="${1:-}"
base_ref="${2:-}"

if [ "$event" != "pull_request" ] || [ -z "$base_ref" ]; then
    printf '%s\n' "$FULL"
    exit 0
fi

if ! changed="$(git diff --name-only "origin/${base_ref}...HEAD" -- \
    crates/ Cargo.toml Cargo.lock 'rust-toolchain*' 2>/dev/null)"; then
    printf '::warning::rust-test-matrix: git diff against origin/%s failed; running the full OS matrix\n' "$base_ref" >&2
    printf '%s\n' "$FULL"
    exit 0
fi

if [ -n "$changed" ]; then
    printf '%s\n' "$FULL"
else
    printf '%s\n' "$LINUX_ONLY"
fi
