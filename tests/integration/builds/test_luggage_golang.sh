#!/usr/bin/env bash
# @tier: weekly
# @ci: scheduled — builds its own luggage fixture image and downloads go (#811)
# Smoke test: `luggage install go@<GO_VERSION>` end-state.
#
# Issue #811 — lib/features/golang.sh delegates to luggage's binary-tarball
# method. This single-image build verifies the luggage path produces a
# working go toolchain in isolation from lib/base/* and lib/features/*, so a
# catalog-format regression or installer-engine bug (the `{arch}` URL
# placeholder, tier-3 `.sha256` verification, extraction, the go/gofmt links,
# `version_args`) fails here before it reaches the production-path test
# (test_rust_golang.sh).
#
# See docs/architecture/luggage-migration.md for the migration playbook.
#
# This build touches the network (dl.google.com download). Run via:
#   just test-integration-one luggage_golang

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

# This suite builds and runs containers (#831).
require_docker

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

LUGGAGE_FIXTURE="$SCRIPT_DIR/luggage_golang/Dockerfile.luggage-golang"
GO_VERSION="1.27.2"
# A major.minor pin must resolve to the newest patch the vendored catalog
# holds for that line, exactly as golang.sh's `luggage resolve go` does.
GO_PARTIAL="1.26"

test_suite "luggage install go@${GO_VERSION} smoke"

LUGGAGE_IMAGE="test-luggage-golang-$$"
LUGGAGE_PARTIAL_IMAGE="test-luggage-golang-partial-$$"

build_luggage_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        LUGGAGE_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg GO_VERSION="$GO_VERSION" \
        -t "$LUGGAGE_IMAGE"
}

# Newest 1.26.x in the vendored catalog — the answer the partial build must
# land on. Read from the catalog itself rather than hard-coded, so a catalog
# refresh does not turn this into a stale-literal failure.
newest_vendored_patch() {
    local line="$1"
    command find "$CONTAINERS_DIR/crates/luggage/testdata/catalog/tools/go/versions" \
        -name "${line}.*.json" -printf '%f\n' |
        command sed 's/\.json$//' |
        command sort -V |
        command tail -n 1
}

assert_go_endstate() {
    local image="$1" version="$2"
    assert_executable_in_path "$image" "go"
    assert_executable_in_path "$image" "gofmt"
    # Non-login PATH: catches a toolchain that extracted but was never linked
    # onto /usr/local/bin.
    assert_executable_in_base_path "$image" "go"
    assert_executable_in_base_path "$image" "gofmt"
    assert_command_in_container "$image" "go version" "go${version} "
    assert_command_in_container "$image" "readlink /usr/local/bin/go" "/usr/local/go/bin/go"
    assert_command_in_container "$image" "go env GOROOT" "/usr/local/go"
    # Cache dirs come from the catalog's cache_dirs: luggage creates and chowns
    # them now, not golang.sh. `go env` only echoes the image ENV, so assert
    # each directory exists and belongs to the install user — a root-owned
    # /cache/go-mod would break `go mod download` for vscode.
    assert_command_in_container "$image" "go env GOPATH" "/cache/go"
    assert_command_in_container "$image" "go env GOMODCACHE" "/cache/go-mod"
    assert_command_in_container "$image" "stat -c %U /cache/go" "vscode"
    assert_command_in_container "$image" "stat -c %U /cache/go-build" "vscode"
    assert_command_in_container "$image" "stat -c %U /cache/go-mod" "vscode"
}

test_luggage_path_endstate() {
    build_luggage_image
    assert_go_endstate "$LUGGAGE_IMAGE" "$GO_VERSION"
}

test_partial_version_resolves_to_newest_patch() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        skip_test "IMAGE_TO_TEST pins one image; partial-version build skipped"
        return 0
    fi
    local expected
    expected=$(newest_vendored_patch "$GO_PARTIAL")
    if [ -z "$expected" ]; then
        assert_true false "No ${GO_PARTIAL}.x entry in the vendored go catalog"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg GO_VERSION="$GO_PARTIAL" \
        -t "$LUGGAGE_PARTIAL_IMAGE"
    assert_command_in_container "$LUGGAGE_PARTIAL_IMAGE" \
        "cat /etc/go-resolved-version" "$expected"
    assert_go_endstate "$LUGGAGE_PARTIAL_IMAGE" "$expected"
}

run_test test_luggage_path_endstate "luggage install produces a working go toolchain"
run_test test_partial_version_resolves_to_newest_patch \
    "GO_VERSION=${GO_PARTIAL} resolves to the newest vendored ${GO_PARTIAL}.x"

generate_report
