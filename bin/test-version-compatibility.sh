#!/usr/bin/env bash
# Test Version Compatibility
#
# Description:
#   Tests different version combinations to ensure compatibility.
#   Updates the version compatibility matrix with test results.
#
# Usage:
#   ./test-version-compatibility.sh [OPTIONS]
#
# Options:
#   --variant <name>         Test specific variant only
#   --python-version <ver>   Override Python version
#   --node-version <ver>     Override Node version
#   --rust-version <ver>     Override Rust version
#   --go-version <ver>       Override Go version
#   --ruby-version <ver>     Override Ruby version
#   --java-version <ver>     Override Java version
#   --r-version <ver>        Override R version
#   --base-image <image>     Override base Debian image
#   --update-matrix          Update compatibility matrix with results
#   --dry-run                Show what would be tested without building
#   --help                   Show this help message
#
# Examples:
#   # Test python-dev with Python 3.13.0
#   ./test-version-compatibility.sh --variant python-dev --python-version 3.13.0
#
#   # Test polyglot with custom versions
#   ./test-version-compatibility.sh \
#       --variant polyglot \
#       --python-version 3.13.0 \
#       --node-version 20 \
#       --update-matrix
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Usage error
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Compatibility matrix file
MATRIX_FILE="$PROJECT_ROOT/version-compatibility-matrix.json"

# Test configuration
VARIANT=""
PYTHON_VERSION=""
NODE_VERSION=""
RUST_VERSION=""
GO_VERSION=""
RUBY_VERSION=""
JAVA_VERSION=""
R_VERSION=""
BASE_IMAGE=""
UPDATE_MATRIX=false
DRY_RUN=false

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Helper Functions
# ============================================================================

show_help() {
    head -n 40 "$0" | grep '^#' | command sed 's/^# \?//'
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

usage_error() {
    echo "ERROR: $*" >&2
    echo
    show_help
    exit 2
}

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "[SUCCESS] $*"
}

log_failure() {
    echo "[FAILURE] $*"
}

# Get current timestamp
timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ============================================================================
# Build Functions
# ============================================================================

# Build a variant with specific versions
build_variant() {
    local variant="$1"
    shift
    local build_args=("$@")

    log_info "Building variant: $variant"
    log_info "Build args: ${build_args[*]}"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would build $variant with args: ${build_args[*]}"
        return 0
    fi

    local image_name="test:${variant}-version-compat"

    # Build the image
    if docker build \
        -f "$PROJECT_ROOT/Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        "${build_args[@]}" \
        -t "$image_name" \
        "$PROJECT_ROOT" 2>&1 | tee /tmp/version-compat-build.log; then
        return 0
    else
        return 1
    fi
}

# Test a variant with integration tests
test_variant() {
    local variant="$1"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would test $variant"
        return 0
    fi

    local test_script="$PROJECT_ROOT/tests/integration/builds/test_${variant}.sh"

    if [ ! -f "$test_script" ]; then
        log_info "No integration test found for $variant, skipping validation"
        return 0
    fi

    log_info "Running integration test for $variant"

    # Run the integration test
    if "$test_script" 2>&1 | tee /tmp/version-compat-test.log; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Variant Configuration
# ============================================================================

# Get build arguments for variant
get_variant_build_args() {
    local variant="$1"
    local args=()

    # Base image
    if [ -n "$BASE_IMAGE" ]; then
        args+=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
    fi

    # Common args based on variant
    case "$variant" in
        minimal)
            # No additional features
            ;;
        python-dev)
            args+=(--build-arg INCLUDE_PYTHON=true)
            args+=(--build-arg INCLUDE_PYTHON_DEV=true)
            if [ -n "$PYTHON_VERSION" ]; then
                args+=(--build-arg "PYTHON_VERSION=$PYTHON_VERSION")
            fi
            ;;
        node-dev)
            args+=(--build-arg INCLUDE_NODE=true)
            args+=(--build-arg INCLUDE_NODE_DEV=true)
            if [ -n "$NODE_VERSION" ]; then
                args+=(--build-arg "NODE_VERSION=$NODE_VERSION")
            fi
            ;;
        rust-dev)
            args+=(--build-arg INCLUDE_RUST=true)
            args+=(--build-arg INCLUDE_RUST_DEV=true)
            if [ -n "$RUST_VERSION" ]; then
                args+=(--build-arg "RUST_VERSION=$RUST_VERSION")
            fi
            ;;
        golang-dev)
            args+=(--build-arg INCLUDE_GOLANG=true)
            args+=(--build-arg INCLUDE_GOLANG_DEV=true)
            if [ -n "$GO_VERSION" ]; then
                args+=(--build-arg "GO_VERSION=$GO_VERSION")
            fi
            ;;
        ruby-dev)
            args+=(--build-arg INCLUDE_RUBY=true)
            args+=(--build-arg INCLUDE_RUBY_DEV=true)
            if [ -n "$RUBY_VERSION" ]; then
                args+=(--build-arg "RUBY_VERSION=$RUBY_VERSION")
            fi
            ;;
        java-dev)
            args+=(--build-arg INCLUDE_JAVA=true)
            args+=(--build-arg INCLUDE_JAVA_DEV=true)
            if [ -n "$JAVA_VERSION" ]; then
                args+=(--build-arg "JAVA_VERSION=$JAVA_VERSION")
            fi
            ;;
        r-dev)
            args+=(--build-arg INCLUDE_R=true)
            args+=(--build-arg INCLUDE_R_DEV=true)
            if [ -n "$R_VERSION" ]; then
                args+=(--build-arg "R_VERSION=$R_VERSION")
            fi
            ;;
        rust-golang)
            args+=(--build-arg INCLUDE_RUST=true)
            args+=(--build-arg INCLUDE_GOLANG=true)
            if [ -n "$RUST_VERSION" ]; then
                args+=(--build-arg "RUST_VERSION=$RUST_VERSION")
            fi
            if [ -n "$GO_VERSION" ]; then
                args+=(--build-arg "GO_VERSION=$GO_VERSION")
            fi
            ;;
        cloud-ops)
            args+=(--build-arg INCLUDE_DOCKER=true)
            args+=(--build-arg INCLUDE_KUBERNETES=true)
            args+=(--build-arg INCLUDE_TERRAFORM=true)
            args+=(--build-arg INCLUDE_AWS=true)
            ;;
        polyglot)
            args+=(--build-arg INCLUDE_PYTHON=true)
            args+=(--build-arg INCLUDE_NODE=true)
            args+=(--build-arg INCLUDE_RUST=true)
            args+=(--build-arg INCLUDE_GOLANG=true)
            if [ -n "$PYTHON_VERSION" ]; then
                args+=(--build-arg "PYTHON_VERSION=$PYTHON_VERSION")
            fi
            if [ -n "$NODE_VERSION" ]; then
                args+=(--build-arg "NODE_VERSION=$NODE_VERSION")
            fi
            if [ -n "$RUST_VERSION" ]; then
                args+=(--build-arg "RUST_VERSION=$RUST_VERSION")
            fi
            if [ -n "$GO_VERSION" ]; then
                args+=(--build-arg "GO_VERSION=$GO_VERSION")
            fi
            ;;
        *)
            error "Unknown variant: $variant"
            ;;
    esac

    echo "${args[@]}"
}

# ============================================================================
# Matrix Update Functions
# ============================================================================

# Update compatibility matrix with test result
update_matrix() {
    local variant="$1"
    local status="$2"  # "passing" or "failing"
    local notes="${3:-}"

    if [ ! -f "$MATRIX_FILE" ]; then
        log_info "Matrix file not found, skipping update"
        return
    fi

    log_info "Updating compatibility matrix for $variant (status: $status)"

    # Build version info
    local versions_json="{"
    local first=true

    for lang in python node rust go ruby java r mojo; do
        local version_var="${lang^^}_VERSION"
        local version="${!version_var:-}"
        if [ -n "$version" ]; then
            if [ "$first" = false ]; then
                versions_json+=","
            fi
            versions_json+="\"$lang\": \"$version\""
            first=false
        fi
    done

    versions_json+="}"

    # Create new entry
    local new_entry
    new_entry=$(cat << EOF
{
  "variant": "$variant",
  "base_image": "${BASE_IMAGE:-debian:13-slim}",
  "versions": $versions_json,
  "status": "$status",
  "tested_at": "$(timestamp)"$([ -n "$notes" ] && echo ",
  \"notes\": \"$notes\"" || echo "")
}
EOF
)

    log_info "New compatibility entry:"
    echo "$new_entry"

    # Update the matrix JSON file using jq
    if ! command -v jq &> /dev/null; then
        log_info "jq not available, falling back to JSONL append"
        echo "$new_entry" >> "$PROJECT_ROOT/version-compat-results.jsonl"
        return
    fi

    # Update tested_combinations: replace existing entry or add new one
    local updated_matrix
    updated_matrix=$(jq \
        --argjson new_entry "$new_entry" \
        --arg timestamp "$(timestamp)" \
        '
        .last_updated = $timestamp |
        # Check if variant exists in tested_combinations
        if (.tested_combinations | map(.variant) | index($new_entry.variant)) then
            # Update existing entry
            .tested_combinations = [
                .tested_combinations[] |
                if .variant == $new_entry.variant then
                    $new_entry
                else
                    .
                end
            ]
        else
            # Add new entry
            .tested_combinations += [$new_entry]
        end |
        # Update language_versions.*.current with tested versions
        reduce ($new_entry.versions | to_entries[]) as $ver (
            .;
            if .language_versions[$ver.key] then
                .language_versions[$ver.key].current = $ver.value |
                # Add to tested array if not present
                if (.language_versions[$ver.key].tested | index($ver.value) | not) then
                    .language_versions[$ver.key].tested += [$ver.value]
                else
                    .
                end
            else
                .
            end
        )
        ' "$MATRIX_FILE")

    if [ -n "$updated_matrix" ]; then
        echo "$updated_matrix" > "$MATRIX_FILE"
        log_success "Matrix file updated"
    else
        log_failure "Failed to update matrix file"
        # Fallback to JSONL
        echo "$new_entry" >> "$PROJECT_ROOT/version-compat-results.jsonl"
    fi
}

# ============================================================================
# Test Execution
# ============================================================================

# Test a single variant
run_variant_test() {
    local variant="$1"

    TESTS_RUN=$((TESTS_RUN + 1))

    log_info "=================================================="
    log_info "Testing variant: $variant"
    log_info "=================================================="

    # Get build args
    local build_args
    build_args=$(get_variant_build_args "$variant")

    # Build the variant
    # shellcheck disable=SC2086  # build_args intentionally word-splits to multiple args
    if build_variant "$variant" $build_args; then
        log_success "Build succeeded for $variant"

        # Test the variant
        if test_variant "$variant"; then
            log_success "Tests passed for $variant"
            TESTS_PASSED=$((TESTS_PASSED + 1))

            if [ "$UPDATE_MATRIX" = true ]; then
                update_matrix "$variant" "passing"
            fi
        else
            log_failure "Tests failed for $variant"
            TESTS_FAILED=$((TESTS_FAILED + 1))

            if [ "$UPDATE_MATRIX" = true ]; then
                update_matrix "$variant" "failing" "Integration tests failed"
            fi
        fi
    else
        log_failure "Build failed for $variant"
        TESTS_FAILED=$((TESTS_FAILED + 1))

        if [ "$UPDATE_MATRIX" = true ]; then
            update_matrix "$variant" "failing" "Build failed"
        fi
    fi

    echo
}

# ============================================================================
# Main Logic
# ============================================================================

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --python-version)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        --node-version)
            NODE_VERSION="$2"
            shift 2
            ;;
        --rust-version)
            RUST_VERSION="$2"
            shift 2
            ;;
        --go-version)
            GO_VERSION="$2"
            shift 2
            ;;
        --ruby-version)
            RUBY_VERSION="$2"
            shift 2
            ;;
        --java-version)
            JAVA_VERSION="$2"
            shift 2
            ;;
        --r-version)
            R_VERSION="$2"
            shift 2
            ;;
        --base-image)
            BASE_IMAGE="$2"
            shift 2
            ;;
        --update-matrix)
            UPDATE_MATRIX=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            usage_error "Unknown option: $1"
            ;;
        *)
            usage_error "Unexpected argument: $1"
            ;;
    esac
done

# Determine which variants to test
if [ -n "$VARIANT" ]; then
    variants=("$VARIANT")
else
    # Default: test common variants
    variants=(minimal python-dev node-dev rust-golang cloud-ops polyglot)
fi

# Run tests
echo "=========================================="
echo "Version Compatibility Testing"
echo "=========================================="
echo "Variants: ${variants[*]}"
echo "Update matrix: $UPDATE_MATRIX"
echo "Dry run: $DRY_RUN"
echo "=========================================="
echo

for variant in "${variants[@]}"; do
    run_variant_test "$variant"
done

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total tests: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "=========================================="

# Exit with failure if any tests failed
[ $TESTS_FAILED -eq 0 ]
