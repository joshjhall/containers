#!/usr/bin/env bash
# Unit tests: Rust version pins stay consistent within each of their two roles.
#
# Rust is pinned in two roles that move independently (#1111):
#
#   BUILD CHAIN — the toolchain stibbons/luggage/... are compiled with, frozen
#   at the workspace MSRV and moved only by a deliberate PR. Source of truth:
#   Cargo.toml `rust-version` (X.Y). Must agree with it: clippy.toml `msrv`,
#   every CI `toolchain:` pin, and the luggage-builder base image
#   (`FROM rust:X.Y-...`). The drift #736 fixed (Dockerfile on 1.97, CI on
#   1.94, luggage-builder on 1.95) is exactly a broken build chain.
#
#   CONTAINER DEFAULT — the Rust a container installs when the project picks
#   none. Follows the newest stable via auto-patch, with no review hold.
#   Source of truth: Dockerfile `ARG RUST_VERSION` (X.Y.Z). Must agree with
#   it: the rust.sh fallback and the devcontainer build arg.
#
# The two used to be one: every minor Rust release dragged the MSRV along and
# held the release for review (#1110). They are tied only by one inequality:
# the default must not be OLDER than the MSRV, since the dev container (which
# installs the default) is where the workspace gets built.
#
# Bumping the MSRV: change Cargo.toml rust-version, then run this test — it
# names every build-chain pin that still needs updating.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Rust version sync tests"

DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# Build chain source of truth: X.Y from Cargo.toml rust-version.
MSRV="$(command grep -E '^rust-version = ' "$PROJECT_ROOT/Cargo.toml" | command sed -E 's/.*= *"([^"]+)".*/\1/')"
# Container default source of truth: X.Y.Z from the Dockerfile ARG.
DEFAULT_FULL="$(command grep -E '^ARG RUST_VERSION=' "$DOCKERFILE" | command sed 's/^ARG RUST_VERSION=//' | command tr -d '"')"

# _version_ge <a> <b> — succeeds when dotted version a >= b (numeric per part).
_version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | command sort -t. -k1,1n -k2,2n -k3,3n | command head -n1)" = "$2" ]
}

# --- Build chain -------------------------------------------------------------

test_msrv_parses() {
    assert_matches "$MSRV" '^[0-9]+\.[0-9]+$' \
        "Cargo.toml rust-version must be X.Y (got '$MSRV')"
}

test_clippy_msrv() {
    local val
    val="$(command grep -E '^msrv = ' "$PROJECT_ROOT/clippy.toml" | command sed -E 's/.*= *"([^"]+)".*/\1/')"
    assert_equals "$MSRV" "$val" \
        "clippy.toml msrv ($val) must match Cargo.toml rust-version ($MSRV)"
}

test_luggage_builder_base_image() {
    # FROM rust:X.Y-slim-trixie AS luggage-builder
    local tag
    tag="$(command grep -E '^FROM rust:[0-9.]+.* AS luggage-builder' "$DOCKERFILE" |
        command sed -E 's/^FROM rust:([0-9]+\.[0-9]+).*/\1/')"
    assert_equals "$MSRV" "$tag" \
        "luggage-builder base image (rust:$tag) must match Cargo.toml rust-version ($MSRV)"
}

test_ci_toolchain_pins() {
    # Every `toolchain: "X.Y"` under .github/workflows must equal the MSRV.
    # Steps that intentionally float (no `toolchain:`, or `toolchain: stable`
    # for the early-warning lint job) are out of scope — this guards explicit
    # numeric pins only.
    local violations=0 file val
    while IFS= read -r line; do
        file="${line%%:*}"
        val="$(printf '%s' "${line#*:}" | command sed -E 's/.*toolchain: *"?([0-9]+\.[0-9]+)"?.*/\1/')"
        if [ "$val" != "$MSRV" ]; then
            echo "  DRIFT: $file pins toolchain '$val' (expected '$MSRV')"
            violations=$((violations + 1))
        fi
    done < <(command grep -rnE '^\s*toolchain: *"?[0-9]+\.[0-9]+' "$PROJECT_ROOT/.github/workflows/" 2>/dev/null || true)

    assert_equals "0" "$violations" \
        "All CI toolchain: pins must equal Cargo.toml rust-version ($MSRV)"
}

# --- Container default -------------------------------------------------------

test_default_parses() {
    assert_matches "$DEFAULT_FULL" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        "Dockerfile ARG RUST_VERSION must be a full X.Y.Z version (got '$DEFAULT_FULL')"
}

test_devcontainer_compose_pin() {
    local compose="$PROJECT_ROOT/.devcontainer/docker-compose.yml"
    local val
    val="$(command grep -E '^\s*RUST_VERSION:' "$compose" | command sed -E 's/.*RUST_VERSION:\s*//' | command tr -d '"' | command tr -d ' ')"
    assert_equals "$DEFAULT_FULL" "$val" \
        ".devcontainer/docker-compose.yml RUST_VERSION ($val) must match Dockerfile ARG ($DEFAULT_FULL)"
}

test_rust_sh_fallback() {
    local val
    val="$(command grep -E '^RUST_VERSION="\$\{RUST_VERSION:-' "$PROJECT_ROOT/lib/features/rust.sh" |
        command sed -E 's/.*:-([^}]*)}.*/\1/')"
    assert_equals "$DEFAULT_FULL" "$val" \
        "lib/features/rust.sh fallback RUST_VERSION ($val) must match Dockerfile ARG ($DEFAULT_FULL)"
}

# --- The one link between them -----------------------------------------------

test_default_not_below_msrv() {
    # The dev container installs the default and builds the workspace with
    # it, so a default older than the MSRV could not compile our own crates.
    if _version_ge "$DEFAULT_FULL" "$MSRV"; then
        assert_true true "container default $DEFAULT_FULL >= MSRV $MSRV"
    else
        assert_true false "container default ($DEFAULT_FULL) must not be older than the MSRV ($MSRV)"
    fi
}

test_version_ge_discriminates() {
    # Guards the helper itself, so test_default_not_below_msrv cannot pass on
    # a comparison that always succeeds.
    if _version_ge "1.99.0" "1.99"; then
        assert_true true "1.99.0 >= 1.99"
    else
        assert_true false "1.99.0 must be >= 1.99"
    fi
    if _version_ge "1.100.0" "1.99"; then
        assert_true true "1.100.0 >= 1.99 (numeric, not lexical)"
    else
        assert_true false "1.100.0 must be >= 1.99 (numeric, not lexical)"
    fi
    if _version_ge "1.98.1" "1.99"; then
        assert_true false "1.98.1 must not be >= 1.99"
    else
        assert_true true "1.98.1 < 1.99"
    fi
}

run_test "test_msrv_parses" "Cargo.toml rust-version parses as X.Y"
run_test "test_clippy_msrv" "build chain: clippy.toml msrv matches MSRV"
run_test "test_luggage_builder_base_image" "build chain: luggage-builder image matches MSRV"
run_test "test_ci_toolchain_pins" "build chain: CI toolchain pins match MSRV"
run_test "test_default_parses" "default: Dockerfile RUST_VERSION parses as X.Y.Z"
run_test "test_devcontainer_compose_pin" "default: devcontainer compose pin matches"
run_test "test_rust_sh_fallback" "default: rust.sh fallback matches"
run_test "test_default_not_below_msrv" "default is not older than the MSRV"
run_test "test_version_ge_discriminates" "version comparison discriminates"

generate_report
