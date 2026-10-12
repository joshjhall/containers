#!/usr/bin/env bash
# Unit tests for base-images structure invariants.
#
# Issue #422 mandates that every published base image carries the same
# hardening posture. These tests are the cheap, fast guardrail that catches
# obvious regressions before a Dockerfile lands — for example, a new tuple
# that forgets to invoke hardening.sh, or an existing tuple losing its
# `USER ${USERNAME}` directive.
#
# Tested invariants:
#   - The pilot tuple (debian/12/amd64) exists and is wired correctly
#   - Every tuple registered in the workflow matrix has a Dockerfile
#   - Every base-images Dockerfile ends with a USER directive
#   - Every distro hardening.sh exports the four-function interface
#   - base-images/VERSION is a clean semver
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Base images structure tests"

BASE_IMAGES_DIR="$PROJECT_ROOT/base-images"
WORKFLOW_FILE="$PROJECT_ROOT/.github/workflows/build-base-images.yml"

# The supported platform set (docs/reference/supported-platforms.md). Each
# must exist as a Dockerfile; test_workflow_matrix_matches_dockerfiles then
# holds the build matrix and the on-disk Dockerfiles to exactly this set, so
# adding or retiring a tuple in one place without the others fails.
REQUIRED_TUPLES=(
    "debian/12/amd64"
    "debian/12/arm64"
    "debian/13/amd64"
    "debian/13/arm64"
    "ubuntu/24.04/amd64"
    "ubuntu/24.04/arm64"
    "ubuntu/26.04/amd64"
    "ubuntu/26.04/arm64"
    "alpine/3.22/amd64"
    "alpine/3.22/arm64"
    "alpine/3.23/amd64"
    "alpine/3.23/arm64"
    "alpine/3.24/amd64"
    "alpine/3.24/arm64"
    "rhel/9/amd64"
    "rhel/9/arm64"
    "rhel/10/amd64"
    "rhel/10/arm64"
)

# Per-distro hardening libraries that must exist with the standard interface.
REQUIRED_DISTROS=(
    "debian"
    "ubuntu"
    "alpine"
    "rhel"
)

# _matrix_tuples — print `<distro>/<version>/<arch>` for every include entry
# in the build-base-images matrix, sorted. Plain awk rather than yq: a
# yq-gated check silently skips wherever yq is missing (see the memory note
# on skips rendering as passes), and the matrix is regular enough to parse.
_matrix_tuples() {
    /usr/bin/awk '
        /^[[:space:]]*- distro:/      { d = $3 }
        /^[[:space:]]*distro_version:/ { v = $2; gsub(/"/, "", v) }
        /^[[:space:]]*arch:/          { if (d != "" && v != "") print d "/" v "/" $2; d = ""; v = "" }
    ' "$WORKFLOW_FILE" | /usr/bin/sort -u
}

# _dockerfile_tuples — print `<distro>/<version>/<arch>` for every
# base-images/*/*/*/Dockerfile on disk, sorted.
_dockerfile_tuples() {
    local f
    for f in "$BASE_IMAGES_DIR"/*/*/*/Dockerfile; do
        [ -f "$f" ] || continue
        f="${f#"$BASE_IMAGES_DIR"/}"
        /usr/bin/echo "${f%/Dockerfile}"
    done | /usr/bin/sort -u
}

# Functions every <distro>/hardening.sh must define.
REQUIRED_HARDENING_FUNCTIONS=(
    "create_user"
    "restrict_shells"
    "harden_service_users"
    "configure_sudo"
)

test_base_images_dir_exists() {
    assert_true [ -d "$BASE_IMAGES_DIR" ] "base-images/ directory must exist"
}

test_readme_exists() {
    assert_true [ -f "$BASE_IMAGES_DIR/README.md" ] \
        "base-images/README.md spec must exist"
}

test_version_file_is_semver() {
    local version_file="$BASE_IMAGES_DIR/VERSION"
    assert_true [ -f "$version_file" ] \
        "base-images/VERSION must exist"
    local version
    version=$(/usr/bin/tr -d '[:space:]' <"$version_file")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "base-images/VERSION='$version' is a clean MAJOR.MINOR.PATCH"
    else
        assert_true false "base-images/VERSION='$version' is not MAJOR.MINOR.PATCH"
    fi
}

test_required_tuples_have_dockerfiles() {
    local missing=0 tuple
    for tuple in "${REQUIRED_TUPLES[@]}"; do
        local dockerfile="$BASE_IMAGES_DIR/$tuple/Dockerfile"
        if [ ! -f "$dockerfile" ]; then
            /usr/bin/echo "  missing: $dockerfile"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_true true "all required tuples have Dockerfiles"
    else
        assert_true false "$missing required tuple(s) missing Dockerfile"
    fi
}

test_every_dockerfile_ends_with_user_directive() {
    local violations=0 dockerfile
    while IFS= read -r dockerfile; do
        # Allow the USER directive to be followed by any non-USER instructions
        # (WORKDIR, CMD, ENTRYPOINT, LABEL) — the invariant is that the image
        # ships running as a non-root user, not literally "USER on the last
        # line." Reject only Dockerfiles that have NO USER directive at all.
        if ! /usr/bin/grep -qE '^USER[[:space:]]' "$dockerfile"; then
            /usr/bin/echo "  no USER directive: $dockerfile"
            violations=$((violations + 1))
            continue
        fi
        # Reject `USER root` — final user must be non-root.
        local last_user
        last_user=$(/usr/bin/grep -E '^USER[[:space:]]' "$dockerfile" | /usr/bin/tail -n 1 | /usr/bin/awk '{print $2}')
        if [ "$last_user" = "root" ] || [ "$last_user" = "0" ]; then
            /usr/bin/echo "  final USER is root: $dockerfile"
            violations=$((violations + 1))
        fi
    done < <(/usr/bin/find "$BASE_IMAGES_DIR" -name Dockerfile -type f | /usr/bin/sort)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every base-images Dockerfile ends as a non-root USER"
    else
        assert_true false "$violations Dockerfile(s) violate the non-root USER invariant"
    fi
}

test_every_dockerfile_invokes_hardening() {
    local violations=0 dockerfile
    while IFS= read -r dockerfile; do
        if ! /usr/bin/grep -q "hardening.sh" "$dockerfile"; then
            /usr/bin/echo "  no hardening.sh reference: $dockerfile"
            violations=$((violations + 1))
        fi
    done < <(/usr/bin/find "$BASE_IMAGES_DIR" -name Dockerfile -type f | /usr/bin/sort)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every base-images Dockerfile invokes hardening.sh"
    else
        assert_true false "$violations Dockerfile(s) skip hardening.sh"
    fi
}

test_every_distro_has_hardening_lib() {
    local missing=0 distro
    for distro in "${REQUIRED_DISTROS[@]}"; do
        local lib="$BASE_IMAGES_DIR/$distro/hardening.sh"
        if [ ! -f "$lib" ]; then
            /usr/bin/echo "  missing: $lib"
            missing=$((missing + 1))
        elif [ ! -x "$lib" ]; then
            /usr/bin/echo "  not executable: $lib"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_true true "every required distro has an executable hardening.sh"
    else
        assert_true false "$missing distro(s) missing hardening.sh"
    fi
}

test_hardening_libs_export_required_functions() {
    local violations=0 distro fn
    for distro in "${REQUIRED_DISTROS[@]}"; do
        local lib="$BASE_IMAGES_DIR/$distro/hardening.sh"
        [ -f "$lib" ] || continue
        for fn in "${REQUIRED_HARDENING_FUNCTIONS[@]}"; do
            # Function defined as `name() {` or `name () {`
            if ! /usr/bin/grep -qE "^${fn}[[:space:]]*\(\)[[:space:]]*\{" "$lib"; then
                /usr/bin/echo "  $lib: missing function ${fn}"
                violations=$((violations + 1))
            fi
        done
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "all distro hardening libraries export the required interface"
    else
        assert_true false "$violations function(s) missing from hardening libraries"
    fi
}

test_workflow_matrix_matches_dockerfiles() {
    # The build matrix, the Dockerfiles on disk, and REQUIRED_TUPLES must name
    # exactly the same set. A Dockerfile with no matrix entry is never built
    # (silently unsupported); a matrix entry with no Dockerfile breaks the
    # build; a retired tuple left on disk keeps getting claimed as supported.
    local matrix disk required
    matrix="$(_matrix_tuples)"
    disk="$(_dockerfile_tuples)"
    required="$(/usr/bin/printf '%s\n' "${REQUIRED_TUPLES[@]}" | /usr/bin/sort -u)"
    local n
    n="$(/usr/bin/printf '%s\n' "$matrix" | /usr/bin/grep -c . || true)"
    if [ "$n" -lt "${#REQUIRED_TUPLES[@]}" ]; then
        assert_true false "matrix parse found only $n tuple(s); the awk parser is broken, not the matrix"
        return
    fi
    assert_equals "$required" "$matrix" "build-base-images.yml matrix must equal REQUIRED_TUPLES"
    assert_equals "$required" "$disk" "base-images/*/*/*/Dockerfile set must equal REQUIRED_TUPLES"
}

test_evidence_dispatch_offers_every_tuple() {
    # evidence-run.yml's workflow_dispatch `tuple` choices are how a human
    # records evidence for one cell; a supported tuple missing from them can
    # only get evidence by an image rebuild.
    local evidence="$PROJECT_ROOT/.github/workflows/evidence-run.yml" want got
    want="$(/usr/bin/printf '%s\n' "${REQUIRED_TUPLES[@]}" | /usr/bin/tr '/' '-' | /usr/bin/sort -u)"
    got="$(/usr/bin/awk '/^      tuple:/{f=1} f&&/^      [a-z_]+:/&&!/tuple:/{f=0} f&&/^          - /{print $2}' "$evidence" | /usr/bin/sort -u)"
    assert_equals "$want" "$got" "evidence-run.yml dispatch tuple options must equal the supported set"
}

test_workflow_file_exists() {
    assert_true [ -f "$WORKFLOW_FILE" ] \
        "build-base-images.yml workflow must exist"
}

test_workflow_references_pilot_tuple() {
    [ -f "$WORKFLOW_FILE" ] || {
        assert_true false "workflow file missing — cannot check pilot tuple reference"
        return
    }
    # The pilot tuple (debian-12-amd64) must appear in the matrix block.
    if /usr/bin/grep -q 'distro: debian' "$WORKFLOW_FILE" &&
        /usr/bin/grep -qE 'distro_version:[[:space:]]*"?12"?' "$WORKFLOW_FILE" &&
        /usr/bin/grep -q 'arch: amd64' "$WORKFLOW_FILE"; then
        assert_true true "workflow matrix references pilot tuple debian/12/amd64"
    else
        assert_true false "workflow matrix does not reference pilot tuple debian/12/amd64"
    fi
}

run_test test_base_images_dir_exists "base-images directory exists"
run_test test_readme_exists "base-images/README.md spec exists"
run_test test_version_file_is_semver "base-images/VERSION is clean semver"
run_test test_required_tuples_have_dockerfiles "all required tuples have Dockerfiles"
run_test test_every_dockerfile_ends_with_user_directive "every Dockerfile ends as non-root USER"
run_test test_every_dockerfile_invokes_hardening "every Dockerfile invokes hardening.sh"
run_test test_every_distro_has_hardening_lib "every required distro has hardening.sh"
run_test test_hardening_libs_export_required_functions "hardening libraries export required interface"
run_test test_workflow_file_exists "build-base-images.yml workflow exists"
run_test test_workflow_matrix_matches_dockerfiles "workflow matrix, Dockerfiles, and REQUIRED_TUPLES agree"
run_test test_evidence_dispatch_offers_every_tuple "evidence dispatch offers every supported tuple"
run_test test_workflow_references_pilot_tuple "workflow matrix references pilot tuple"

generate_report
