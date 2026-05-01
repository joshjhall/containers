#!/usr/bin/env bash
# Parity test: `luggage install rust@1.95.0` vs `lib/features/rust.sh`.
#
# Issue #405 — verifies the new Rust executor produces the same observable
# end-state (rustc/cargo/rustup on PATH, matching version, CARGO_HOME and
# RUSTUP_HOME pinned to /cache) as the bash feature script. Closes the
# acceptance criterion: "integration test compares luggage-installed vs
# bash-installed rust toolchain".
#
# Strategy:
#  - Image A is built via the main `Dockerfile` with INCLUDE_RUST=true.
#    This is the same path lefthook & CI exercise; it proves the bash
#    feature script's end-state without us re-creating `lib/base/*`.
#  - Image B is built via a minimal fixture Dockerfile next to this test.
#    It compiles luggage from source, then runs `luggage install rust@1.95.0`.
#  - The same assertion suite runs against both images. Any drift fails.
#
# Both builds touch the network (rustup-init download). Run via:
#   just test-integration-one luggage_rust

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

LUGGAGE_FIXTURE="$SCRIPT_DIR/luggage_rust/Dockerfile.luggage-rust"
RUST_VERSION="1.95.0"

test_suite "luggage install rust@${RUST_VERSION} parity"

LUGGAGE_IMAGE="test-luggage-rust-$$"
BASH_IMAGE="test-bash-rust-$$"

# Build image A — production Dockerfile with INCLUDE_RUST=true.
build_bash_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        BASH_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=parity-bash \
        --build-arg INCLUDE_RUST=true \
        --build-arg RUST_VERSION="$RUST_VERSION" \
        -t "$BASH_IMAGE"
}

# Build image B — minimal fixture that runs `luggage install`.
build_luggage_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        LUGGAGE_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg RUST_VERSION="$RUST_VERSION" \
        -t "$LUGGAGE_IMAGE"
}

# Same assertion bundle runs against both images. Any drift surfaces here.
assert_rust_endstate() {
    local image="$1"
    assert_executable_in_path "$image" "rustc"
    assert_executable_in_path "$image" "cargo"
    assert_executable_in_path "$image" "rustup"
    assert_command_in_container "$image" "rustc --version" "$RUST_VERSION"
    assert_command_in_container "$image" "cargo --version" "cargo"
    # CARGO_HOME / RUSTUP_HOME pinned to /cache in both paths.
    assert_command_in_container "$image" \
        'rustup show home 2>/dev/null || echo "${RUSTUP_HOME:-not-set}"' "/cache/rustup"
}

test_bash_path_endstate() {
    build_bash_image
    assert_rust_endstate "$BASH_IMAGE"
}

test_luggage_path_endstate() {
    build_luggage_image
    assert_rust_endstate "$LUGGAGE_IMAGE"
}

# Compare the X.Y.Z version literal across both images. Catalog and
# RUST_VERSION build-arg both pin "1.95.0"; if either path drifts, the
# diff shows up here rather than in a downstream consumer.
test_versions_match() {
    local bash_v luggage_v
    bash_v=$(docker run --rm "$BASH_IMAGE" rustc --version 2>/dev/null | command awk '{print $2}')
    luggage_v=$(docker run --rm "$LUGGAGE_IMAGE" rustc --version 2>/dev/null | command awk '{print $2}')
    if [ "$bash_v" = "$luggage_v" ]; then
        return 0
    fi
    tf_fail_assertion "rustc versions should match across installers" \
        "bash:    $bash_v" \
        "luggage: $luggage_v"
}

run_test test_bash_path_endstate "lib/features/rust.sh produces a working rust toolchain"
run_test test_luggage_path_endstate "luggage install produces a working rust toolchain"
run_test test_versions_match "rustc version matches across both installers"

generate_report
