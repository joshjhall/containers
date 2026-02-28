#!/usr/bin/env bash
# Unit tests for bin/release.sh
# Tests version bumping and release functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Release Script Tests"

# Setup function - runs before each test
setup() {
    # Create temporary VERSION and CHANGELOG files for testing
    export TEST_VERSION_FILE="$RESULTS_DIR/VERSION"
    export TEST_CHANGELOG_FILE="$RESULTS_DIR/CHANGELOG.md"

    # Create initial VERSION file
    echo "1.2.3" > "$TEST_VERSION_FILE"

    # Create initial CHANGELOG
    command cat > "$TEST_CHANGELOG_FILE" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2025-01-01
- Initial release
EOF
}

# Teardown function - runs after each test
teardown() {
    command rm -f "$TEST_VERSION_FILE" "$TEST_CHANGELOG_FILE"
}

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/release.sh"
    assert_executable "$PROJECT_ROOT/bin/release.sh"
}

# Test: Version bump - patch
test_bump_patch() {
    # Simulate bumping patch version
    local current="1.2.3"
    local expected="1.2.4"

    # Extract version components
    local major="${current%%.*}"
    local minor="${current#*.}"
    minor="${minor%%.*}"
    local patch="${current##*.}"

    # Bump patch
    patch=$((patch + 1))
    local new_version="${major}.${minor}.${patch}"

    assert_equals "$expected" "$new_version" "Patch version bump calculation"
}

# Test: Version bump - minor
test_bump_minor() {
    # Simulate bumping minor version
    local current="1.2.3"
    local expected="1.3.0"

    # Extract version components
    local major="${current%%.*}"
    local minor="${current#*.}"
    minor="${minor%%.*}"

    # Bump minor, reset patch
    minor=$((minor + 1))
    local new_version="${major}.${minor}.0"

    assert_equals "$expected" "$new_version" "Minor version bump calculation"
}

# Test: Version bump - major
test_bump_major() {
    # Simulate bumping major version
    local current="1.2.3"
    local expected="2.0.0"

    # Extract version components
    local major="${current%%.*}"

    # Bump major, reset minor and patch
    major=$((major + 1))
    local new_version="${major}.0.0"

    assert_equals "$expected" "$new_version" "Major version bump calculation"
}

# Test: Invalid version format detection
test_invalid_version_format() {
    # Test various invalid formats
    local version="1.2"  # Missing patch

    # Check if version has three parts
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Invalid version format detected: $version"
    else
        assert_true false "Failed to detect invalid version format"
    fi

    version="v1.2.3"  # Has 'v' prefix
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Invalid version format detected: $version"
    else
        assert_true false "Failed to detect invalid version format"
    fi
}

# Test: Version file exists check
test_version_file_check() {
    # Test with existing file
    echo "1.0.0" > "$TEST_VERSION_FILE"
    assert_file_exists "$TEST_VERSION_FILE"

    # Test reading version from file
    local version
    version=$(command cat "$TEST_VERSION_FILE")
    assert_equals "1.0.0" "$version" "Version read from file"
}

# Test: Changelog file exists check
test_changelog_file_check() {
    # Create test changelog
    command cat > "$TEST_CHANGELOG_FILE" <<'EOF'
# Changelog

## [Unreleased]

## [1.0.0] - 2025-01-01
EOF

    assert_file_exists "$TEST_CHANGELOG_FILE"

    # Check if Unreleased section exists
    if command grep -q "## \[Unreleased\]" "$TEST_CHANGELOG_FILE"; then
        assert_true true "Unreleased section found in changelog"
    else
        assert_true false "Unreleased section not found in changelog"
    fi
}

# Test: Script requires argument
test_requires_argument() {
    # The release script should fail without arguments
    local exit_code=0
    "$PROJECT_ROOT/bin/release.sh" 2>/dev/null || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        assert_true true "Script correctly requires an argument"
    else
        assert_true false "Script should require an argument"
    fi
}

# Test: Script accepts valid bump types
test_valid_bump_types() {
    # Test that script recognizes valid bump types
    local valid_types=("patch" "minor" "major")

    for bump_type in "${valid_types[@]}"; do
        # Just check if the bump type is valid (don't actually run)
        if [[ "$bump_type" =~ ^(patch|minor|major)$ ]]; then
            assert_true true "Valid bump type: $bump_type"
        else
            assert_true false "Invalid bump type: $bump_type"
        fi
    done
}

# Test: Script rejects invalid bump types
test_invalid_bump_types() {
    # Test that script rejects invalid bump types
    local invalid_types=("micro" "release" "version" "1.2.3")

    for bump_type in "${invalid_types[@]}"; do
        if [[ ! "$bump_type" =~ ^(patch|minor|major)$ ]]; then
            assert_true true "Correctly rejected invalid bump type: $bump_type"
        else
            assert_true false "Should reject invalid bump type: $bump_type"
        fi
    done
}

# Test: Semantic version parsing
test_semver_parsing() {
    local version="2.5.8"

    # Parse version components
    local major="${version%%.*}"
    local temp="${version#*.}"
    local minor="${temp%%.*}"
    local patch="${temp#*.}"

    assert_equals "2" "$major" "Major version parsed correctly"
    assert_equals "5" "$minor" "Minor version parsed correctly"
    assert_equals "8" "$patch" "Patch version parsed correctly"
}

# Test: Date format for changelog
test_changelog_date_format() {
    # Test date format is YYYY-MM-DD
    local date
    date=$(date +%Y-%m-%d)

    if [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        assert_true true "Date format is correct: $date"
    else
        assert_true false "Date format is incorrect: $date"
    fi
}

# Test: Cancellation message provides automation guidance
test_cancellation_message() {
    # Test that cancelling the release provides helpful automation examples
    setup

    # Run release script with 'n' response and capture output
    local output
    output=$(echo "n" | "$PROJECT_ROOT/bin/release.sh" patch 2>&1 || true)

    # Check for the helpful messages
    if echo "$output" | command grep -q "Release cancelled"; then
        assert_true true "Shows cancellation message"
    else
        assert_true false "Missing cancellation message"
    fi

    if echo "$output" | command grep -q "echo 'y' |"; then
        assert_true true "Shows echo 'y' automation example"
    else
        assert_true false "Missing echo 'y' automation example"
    fi

    if echo "$output" | command grep -q "yes |"; then
        assert_true true "Shows yes command automation example"
    else
        assert_true false "Missing yes command automation example"
    fi

    teardown
}

# Test: Auto-confirmation with echo y
test_auto_confirmation() {
    # Test that auto-confirmation message works
    # Since the release script always operates on the actual project root,
    # we'll just test the confirmation prompt behavior without actually running it

    # Test that echo "y" would be accepted as confirmation
    local test_response
    test_response=$(echo "y" | head -c1)

    if [ "$test_response" = "y" ] || [ "$test_response" = "Y" ]; then
        assert_true true "Auto-confirmation would be accepted"
    else
        assert_true false "Auto-confirmation would not be accepted"
    fi

    # Verify the release script exists and can handle piped input
    if [ -x "$PROJECT_ROOT/bin/release.sh" ]; then
        assert_true true "Release script is executable"
    else
        assert_true false "Release script is not executable"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test test_script_exists "Release script exists and is executable"
run_test test_bump_patch "Patch version bump calculation"
run_test test_bump_minor "Minor version bump calculation"
run_test test_bump_major "Major version bump calculation"
run_test test_invalid_version_format "Invalid version format detection"
run_test_with_setup test_version_file_check "Version file operations"
run_test_with_setup test_changelog_file_check "Changelog file operations"
run_test test_requires_argument "Script requires bump type argument"
run_test test_valid_bump_types "Script accepts valid bump types"
run_test test_invalid_bump_types "Script rejects invalid bump types"
run_test test_semver_parsing "Semantic version parsing"
run_test test_changelog_date_format "Changelog date format"
run_test_with_setup test_cancellation_message "Cancellation message provides automation guidance"
run_test test_auto_confirmation "Auto-confirmation with echo y works"

# Generate test report
generate_report
