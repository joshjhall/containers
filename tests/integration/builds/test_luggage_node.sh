#!/usr/bin/env bash
# @tier: weekly
# @ci: scheduled — builds its own luggage fixture image and downloads node (#812)
# Smoke test: `luggage install node@<NODE_VERSION>` end-state.
#
# Issue #812 — lib/features/node.sh delegates to luggage's binary-tarball
# method. This single-image build verifies the luggage path produces a
# working node toolchain in isolation from lib/base/* and lib/features/*, so a
# catalog-format regression or installer-engine bug (the per-arch install
# methods, tier-3 SHASUMS256.txt manifest verification, xz decompression,
# `strip_components: 1` into the shared /usr/local) fails here before it
# reaches the production-path test (test_node_current.sh).
#
# See docs/architecture/luggage-migration.md for the migration playbook.
#
# This build touches the network (nodejs.org download). Run via:
#   just test-integration-one luggage_node

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

# This suite builds and runs containers (#831).
require_docker

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

LUGGAGE_FIXTURE="$SCRIPT_DIR/luggage_node/Dockerfile.luggage-node"
NODE_VERSION="22.23.4"
# A major-only pin — node.sh's own default form ("22") — must resolve to the
# newest patch the vendored catalog holds for that line, exactly as node.sh's
# `luggage resolve node` does.
NODE_PARTIAL="22"

test_suite "luggage install node@${NODE_VERSION} smoke"

LUGGAGE_IMAGE="test-luggage-node-$$"
LUGGAGE_PARTIAL_IMAGE="test-luggage-node-partial-$$"

build_luggage_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        LUGGAGE_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg NODE_VERSION="$NODE_VERSION" \
        -t "$LUGGAGE_IMAGE"
}

# Newest 22.x in the vendored catalog — the answer the partial build must
# land on. Read from the catalog itself rather than hard-coded, so a catalog
# refresh does not turn this into a stale-literal failure.
newest_vendored_patch() {
    local line="$1"
    command find "$CONTAINERS_DIR/crates/luggage/testdata/catalog/tools/node/versions" \
        -name "${line}.*.json" -printf '%f\n' |
        command sed 's/\.json$//' |
        command sort -V |
        command tail -n 1
}

assert_node_endstate() {
    local image="$1" version="$2"
    # Non-login PATH: strip_components 1 lands the binaries straight in
    # /usr/local/bin; a wrong strip depth leaves them under
    # /usr/local/node-v<version>-linux-<arch>/bin instead.
    assert_executable_in_base_path "$image" "node"
    assert_executable_in_base_path "$image" "npm"
    assert_executable_in_base_path "$image" "npx"
    assert_command_in_container "$image" "node --version" "v${version}"
    # npm/npx ship as symlinks into lib/node_modules. The catalog lists no
    # `binaries` on purpose: luggage's link step would replace them with
    # self-referential links (source dir == bin root). Pin the tarball's own
    # targets so that regression fails here.
    assert_command_in_container "$image" "readlink /usr/local/bin/npm" \
        "../lib/node_modules/npm/bin/npm-cli.js"
    assert_command_in_container "$image" "readlink /usr/local/bin/npx" \
        "../lib/node_modules/npm/bin/npx-cli.js"
    # Exit 0 is the assertion: npm runs through its symlink under node.
    assert_command_in_container "$image" "npm --version" ""
    # The binary matches the host arch: the per-arch install method picked
    # the right tarball (amd64 -> x64, arm64 -> arm64). A swapped method
    # would fail `node --version` above with an exec-format error anyway;
    # this names the cause.
    assert_command_in_container "$image" \
        "a=\$(dpkg --print-architecture); n=\$(node -p process.arch); [ \"\$a\" = amd64 ] && [ \"\$n\" = x64 ] || [ \"\$a\" = \"\$n\" ] && echo arch-match" \
        "arch-match"
    # No versioned root left behind: the strip flattened it into the prefix.
    assert_command_in_container "$image" \
        "ls -d /usr/local/node-v* 2>/dev/null | command wc -l" "0"
}

test_luggage_path_endstate() {
    build_luggage_image
    assert_node_endstate "$LUGGAGE_IMAGE" "$NODE_VERSION"
}

test_partial_version_resolves_to_newest_patch() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        skip_test "IMAGE_TO_TEST pins one image; partial-version build skipped"
        return 0
    fi
    local expected
    expected=$(newest_vendored_patch "$NODE_PARTIAL")
    if [ -z "$expected" ]; then
        assert_true false "No ${NODE_PARTIAL}.x entry in the vendored node catalog"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg NODE_VERSION="$NODE_PARTIAL" \
        -t "$LUGGAGE_PARTIAL_IMAGE"
    assert_command_in_container "$LUGGAGE_PARTIAL_IMAGE" \
        "cat /etc/node-resolved-version" "$expected"
    assert_node_endstate "$LUGGAGE_PARTIAL_IMAGE" "$expected"
}

run_test test_luggage_path_endstate "luggage install produces a working node toolchain"
run_test test_partial_version_resolves_to_newest_patch \
    "NODE_VERSION=${NODE_PARTIAL} resolves to the newest vendored ${NODE_PARTIAL}.x"

generate_report
