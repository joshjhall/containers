#!/usr/bin/env bash
# Unit tests: Rust toolchain version must stay in sync across the repo.
#
# The Dockerfile `ARG RUST_VERSION` is the single source of truth for the Rust
# toolchain. Several other places pin the same toolchain and MUST agree, or the
# dev environment, CI, and the built image silently drift onto different
# compilers (the exact drift #736 fixed: Dockerfile on 1.97, CI on 1.94,
# luggage-builder on 1.95). This test fails the build when any of them diverge,
# so a future bump has to touch all of them together.
#
# Two granularities are checked against the Dockerfile ARG:
#   - full  "X.Y.Z"  — devcontainer build arg, rust.sh fallback (already guarded
#                      for drift by version-drift.sh, re-asserted here for a
#                      single failure surface)
#   - X.Y            — CI `toolchain:` pins, Cargo.toml MSRV, clippy.toml msrv,
#                      and the luggage-builder base image tag (`rust:X.Y-...`),
#                      none of which carry the patch component
#
# When you bump Rust: change the Dockerfile ARG, then run this test — it names
# every straggler that still needs updating.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Rust version sync tests"

DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# Source of truth: full X.Y.Z from the Dockerfile ARG, plus its X.Y prefix.
RUST_FULL="$(command grep -E '^ARG RUST_VERSION=' "$DOCKERFILE" | command sed 's/^ARG RUST_VERSION=//' | command tr -d '"')"
RUST_MINOR="$(printf '%s' "$RUST_FULL" | command grep -oE '^[0-9]+\.[0-9]+')"

# _minor_pins_in <file> <regex-with-capture-marker>
# Prints each X.Y toolchain pin found in a file for the given extraction regex.
# Used to assert every CI `toolchain:` pin equals RUST_MINOR.

test_source_of_truth_parses() {
    assert_matches "$RUST_FULL" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        "Dockerfile ARG RUST_VERSION must be a full X.Y.Z version (got '$RUST_FULL')"
    assert_not_empty "$RUST_MINOR" "Failed to derive X.Y from '$RUST_FULL'"
}

test_luggage_builder_base_image() {
    # FROM rust:X.Y-slim-trixie AS luggage-builder
    local tag
    tag="$(command grep -E '^FROM rust:[0-9.]+.* AS luggage-builder' "$DOCKERFILE" |
        command sed -E 's/^FROM rust:([0-9]+\.[0-9]+).*/\1/')"
    assert_equals "$RUST_MINOR" "$tag" \
        "luggage-builder base image (rust:$tag) must match Dockerfile RUST_VERSION X.Y ($RUST_MINOR)"
}

test_devcontainer_compose_pin() {
    local compose="$PROJECT_ROOT/.devcontainer/docker-compose.yml"
    local val
    val="$(command grep -E '^\s*RUST_VERSION:' "$compose" | command sed -E 's/.*RUST_VERSION:\s*//' | command tr -d '"' | command tr -d ' ')"
    assert_equals "$RUST_FULL" "$val" \
        ".devcontainer/docker-compose.yml RUST_VERSION ($val) must match Dockerfile ARG ($RUST_FULL)"
}

test_cargo_msrv() {
    local val
    val="$(command grep -E '^rust-version = ' "$PROJECT_ROOT/Cargo.toml" | command sed -E 's/.*= *"([^"]+)".*/\1/')"
    assert_equals "$RUST_MINOR" "$val" \
        "Cargo.toml rust-version ($val) must match Dockerfile RUST_VERSION X.Y ($RUST_MINOR)"
}

test_clippy_msrv() {
    local val
    val="$(command grep -E '^msrv = ' "$PROJECT_ROOT/clippy.toml" | command sed -E 's/.*= *"([^"]+)".*/\1/')"
    assert_equals "$RUST_MINOR" "$val" \
        "clippy.toml msrv ($val) must match Dockerfile RUST_VERSION X.Y ($RUST_MINOR)"
}

test_ci_toolchain_pins() {
    # Every `toolchain: "X.Y"` under .github/workflows must equal RUST_MINOR.
    # dtolnay/rust-toolchain steps that intentionally float (no `toolchain:`)
    # are out of scope — this only guards explicit pins.
    local violations=0 file val
    while IFS= read -r line; do
        file="${line%%:*}"
        val="$(printf '%s' "${line#*:}" | command sed -E 's/.*toolchain: *"?([0-9]+\.[0-9]+)"?.*/\1/')"
        if [ "$val" != "$RUST_MINOR" ]; then
            echo "  DRIFT: $file pins toolchain '$val' (expected '$RUST_MINOR')"
            violations=$((violations + 1))
        fi
    done < <(command grep -rnE '^\s*toolchain: *"?[0-9]+\.[0-9]+' "$PROJECT_ROOT/.github/workflows/" 2>/dev/null || true)

    assert_equals "0" "$violations" \
        "All CI toolchain: pins must equal Dockerfile RUST_VERSION X.Y ($RUST_MINOR)"
}

run_test "test_source_of_truth_parses" "Dockerfile RUST_VERSION parses as X.Y.Z"
run_test "test_luggage_builder_base_image" "luggage-builder base image matches"
run_test "test_devcontainer_compose_pin" "devcontainer compose pin matches"
run_test "test_cargo_msrv" "Cargo.toml MSRV matches"
run_test "test_clippy_msrv" "clippy.toml msrv matches"
run_test "test_ci_toolchain_pins" "CI toolchain pins match"

generate_report
