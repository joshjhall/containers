#!/usr/bin/env bash
# @tier: merge,weekly
# Smoke test: `luggage install rust@<RUST_VERSION>` end-state.
#
# Issue #407 — once lib/features/rust.sh delegates to luggage, the
# previous bash-vs-luggage parity comparison becomes self-comparison.
# What still earns its keep is a single-image build that verifies the
# luggage path produces a working rust toolchain in isolation from
# lib/base/* and lib/features/*. The fixture catches catalog-format
# regressions and installer-engine bugs before they reach the
# production-path test (test_rust_golang.sh).
#
# See docs/architecture/luggage-migration.md for the migration playbook.
#
# This build touches the network (rustup-init download). Run via:
#   just test-integration-one luggage_rust

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

LUGGAGE_FIXTURE="$SCRIPT_DIR/luggage_rust/Dockerfile.luggage-rust"
RUST_VERSION="1.95.0"

test_suite "luggage install rust@${RUST_VERSION} smoke"

LUGGAGE_IMAGE="test-luggage-rust-$$"

# Build the minimal fixture that runs `luggage install` directly.
build_luggage_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        LUGGAGE_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg RUST_VERSION="$RUST_VERSION" \
        -t "$LUGGAGE_IMAGE"
}

assert_rust_endstate() {
    local image="$1"
    assert_executable_in_path "$image" "rustc"
    assert_executable_in_path "$image" "cargo"
    assert_executable_in_path "$image" "rustup"
    assert_command_in_container "$image" "rustc --version" "$RUST_VERSION"
    assert_command_in_container "$image" "cargo --version" "cargo"
    # CARGO_HOME / RUSTUP_HOME pinned to /cache.
    assert_command_in_container "$image" \
        'rustup show home 2>/dev/null || echo "${RUSTUP_HOME:-not-set}"' "/cache/rustup"
}

test_luggage_path_endstate() {
    build_luggage_image
    assert_rust_endstate "$LUGGAGE_IMAGE"
}

run_test test_luggage_path_endstate "luggage install produces a working rust toolchain"

generate_report
