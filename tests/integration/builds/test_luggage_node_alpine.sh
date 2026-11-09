#!/usr/bin/env bash
# @tier: weekly
# @ci: scheduled — compiles node from source on alpine (~1h+ on hosted runners)
# Smoke test: `luggage install node@<NODE_VERSION>` on alpine removes the
# `purpose: build` toolchain once the source build is done (#1524).
#
# The catalog's alpine node method builds from source with g++, make,
# linux-headers and python3 declared `purpose: build`, and libstdc++/libgcc
# `purpose: runtime`. After the install the build packages must be gone, the
# runtime ones kept, and node/npm must still run on what is left.
#
# This build touches the network (nodejs.org + alpine mirrors). Run via:
#   just test-integration-one luggage_node_alpine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

# This suite builds and runs containers.
require_docker

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

LUGGAGE_FIXTURE="$SCRIPT_DIR/luggage_node_alpine/Dockerfile.luggage-node-alpine"
NODE_VERSION="26.13.0"

test_suite "luggage install node@${NODE_VERSION} on alpine (source build)"

LUGGAGE_IMAGE="test-luggage-node-alpine-$$"

build_luggage_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        LUGGAGE_IMAGE="$IMAGE_TO_TEST"
        return 0
    fi
    assert_build_succeeds "$LUGGAGE_FIXTURE" \
        --build-arg NODE_VERSION="$NODE_VERSION" \
        -t "$LUGGAGE_IMAGE"
}

test_node_runs_without_build_deps() {
    build_luggage_image
    assert_command_in_container "$LUGGAGE_IMAGE" "node --version" "v${NODE_VERSION}"
    # npm runs under node and reports a semver; a bare exit-0 check would
    # pass on any output.
    assert_command_in_container "$LUGGAGE_IMAGE" \
        "v=\$(npm --version) && [[ \$v =~ ^[0-9]+\.[0-9]+\.[0-9]+\$ ]] && echo npm-ok" \
        "npm-ok"
}

test_build_deps_removed_runtime_kept() {
    build_luggage_image
    # Each build package checked on its own so a failure names the one left
    # behind. `apk info -e` exits 0 iff the package is installed.
    local pkg
    for pkg in g++ make linux-headers python3; do
        assert_command_in_container "$LUGGAGE_IMAGE" \
            "apk info -e $pkg >/dev/null && echo present-$pkg || echo absent-$pkg" \
            "absent-$pkg"
    done
    for pkg in libstdc++ libgcc; do
        assert_command_in_container "$LUGGAGE_IMAGE" \
            "apk info -e $pkg >/dev/null && echo present-$pkg || echo absent-$pkg" \
            "present-$pkg"
    done
    # The compiler binaries themselves are gone, not just the package records.
    # Checked one at a time: `command -v a b c` succeeds if any one resolves,
    # and a bare count would match "0" as a substring of "10".
    for pkg in g++ make python3; do
        assert_command_in_container "$LUGGAGE_IMAGE" \
            "command -v $pkg >/dev/null && echo bin-present-$pkg || echo bin-absent-$pkg" \
            "bin-absent-$pkg"
    done
}

test_report_records_removed_build_deps() {
    build_luggage_image
    # The report lists exactly the four removed packages, in catalog order.
    assert_command_in_container "$LUGGAGE_IMAGE" \
        "command tr -d ' \n' < /var/log/luggage/node-report.json | command grep -o '\"removed_build_dependencies\":\[[^]]*\]'" \
        '"removed_build_dependencies":["g++","make","linux-headers","python3"]'
}

run_test test_node_runs_without_build_deps "node and npm run with only runtime deps installed"
run_test test_build_deps_removed_runtime_kept "purpose: build packages removed, purpose: runtime kept"
run_test test_report_records_removed_build_deps "InstallReport records the removed build deps"

generate_report
