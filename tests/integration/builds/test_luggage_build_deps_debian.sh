#!/usr/bin/env bash
# @tier: weekly
# @ci: scheduled — builds its own luggage fixture images and downloads node (#1632)
# luggage build-dep removal on debian: `dpkg --purge`, refuse-don't-cascade (#1632).
#
# Happy path: node's tarball method declares make + patch `purpose: build`;
# both are installed for the method and removed after it. Refusal: `libmagic1t64`
# is declared `purpose: build` while `file` (default purpose) depends on it,
# so the manager must refuse, luggage must fail loudly, and nothing cascades.
# Shared body: luggage_build_deps/suite.sh.
#
# This build touches the network (nodejs.org + distro mirrors). Run via:
#   just test-integration-one luggage_build_deps_debian

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../framework.sh
source "$SCRIPT_DIR/../../framework.sh"

init_test_framework

# This suite builds and runs containers.
require_docker

CONTAINERS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export BUILD_CONTEXT="$CONTAINERS_DIR"

# shellcheck source=luggage_build_deps/suite.sh
source "$SCRIPT_DIR/luggage_build_deps/suite.sh"

test_suite "luggage build-dep removal on debian (dpkg --purge)"

#           distro  dependent  refused (purpose: build)  manager refusal text
bd_run_suite debian file libmagic1t64 'dependency problems prevent removal of libmagic1t64'

generate_report
