#!/usr/bin/env bash
# Unit tests for the per-tool checker functions in bin/lib/check-versions/checks.sh
# Each test stubs fetch_url with a canned API response; no network access.
# Split from tests/unit/bin/check-versions.sh (#1024).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Check Versions Checker Mock Tests"

# ============================================================================
# Test: Mock-based check function tests
# ============================================================================

# Helper to set up mock environment for check functions
setup_check_env() {
    # Source dependencies
    source "$PROJECT_ROOT/bin/lib/common.sh" 2>/dev/null || true
    source "$PROJECT_ROOT/bin/lib/version-utils.sh" 2>/dev/null || true

    # Initialize arrays
    TOOLS=()
    CURRENT_VERSIONS=()
    LATEST_VERSIONS=()
    VERSION_STATUS=()
    VERSION_FILES=()

    # Quiet output
    OUTPUT_FORMAT="json"
    export OUTPUT_FORMAT

    # Define helper functions from check-versions.sh that check functions depend on
    add_tool() {
        local tool="$1" current="$2" file="$3"
        TOOLS+=("$tool")
        CURRENT_VERSIONS+=("$current")
        LATEST_VERSIONS+=("")
        VERSION_STATUS+=("unchecked")
        VERSION_FILES+=("$file")
    }

    set_latest() {
        local tool="$1" version="$2"
        if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "undefined" ]; then
            version="error"
        fi
        for i in "${!TOOLS[@]}"; do
            if [ "${TOOLS[i]}" = "$tool" ]; then
                LATEST_VERSIONS[i]="$version"
                if version_matches "${CURRENT_VERSIONS[i]}" "$version"; then
                    VERSION_STATUS[i]="current"
                elif [ "$version" = "error" ]; then
                    VERSION_STATUS[i]="error"
                else
                    VERSION_STATUS[i]="outdated"
                fi
                break
            fi
        done
    }
}

test_check_python_mock() {
    setup_check_env

    add_tool "Python" "3.12.8" "Dockerfile"

    # Mock fetch_url
    fetch_url() {
        case "$1" in
            *"endoflife.date/api/python.json"*)
                echo '[{"cycle":"3.13","latest":"3.13.6"},{"cycle":"3.12","latest":"3.12.8"}]'
                ;;
        esac
    }

    # Source and run check function
    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_python

    assert_equals "3.13.6" "${LATEST_VERSIONS[0]}" "Python latest version set correctly"
}

test_check_rust_mock() {
    setup_check_env

    add_tool "Rust" "1.84.0" "Dockerfile"

    fetch_url() {
        case "$1" in
            *"api.github.com/repos/rust-lang/rust/releases"*)
                echo '[{"tag_name":"1.85.0","prerelease":false},{"tag_name":"1.84.0","prerelease":false}]'
                ;;
        esac
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rust

    assert_equals "1.85.0" "${LATEST_VERSIONS[0]}" "Rust latest version extracted from releases"
}

test_check_github_release_mock() {
    setup_check_env

    add_tool "lazygit" "0.56.0" "dev-tools.sh"

    fetch_url() {
        echo '{"tag_name":"v0.57.0"}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release "lazygit" "jesseduffield/lazygit"

    assert_equals "0.57.0" "${LATEST_VERSIONS[0]}" "GitHub release version extracted correctly"
}

test_check_github_release_prerelease_mock() {
    setup_check_env

    add_tool "conform" "0.1.0-alpha.30" "dev-tools.sh"

    # /releases endpoint returns prereleases too, ordered newest first
    fetch_url() {
        echo '[{"tag_name":"v0.1.0-alpha.31","draft":false,"prerelease":true},{"tag_name":"v0.1.0-alpha.30","draft":false,"prerelease":true}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release_prerelease "conform" "siderolabs/conform"

    assert_equals "0.1.0-alpha.31" "${LATEST_VERSIONS[0]}" "Prerelease GitHub tag extracted correctly"
}

test_check_github_release_prerelease_skips_drafts() {
    setup_check_env

    add_tool "conform" "0.1.0-alpha.30" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"v0.1.0-alpha.32","draft":true,"prerelease":true},{"tag_name":"v0.1.0-alpha.31","draft":false,"prerelease":true}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release_prerelease "conform" "siderolabs/conform"

    assert_equals "0.1.0-alpha.31" "${LATEST_VERSIONS[0]}" "Drafts skipped, latest non-draft prerelease used"
}

test_check_gitlab_release_mock() {
    setup_check_env

    add_tool "glab" "1.45.0" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"v1.46.0"}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_gitlab_release "glab" "gitlab-org%2Fcli"

    assert_equals "1.46.0" "${LATEST_VERSIONS[0]}" "GitLab release version extracted correctly"
}

test_check_crates_io_mock() {
    setup_check_env

    add_tool "cargo-release" "0.25.0" "dev-tools.sh"

    fetch_url() {
        echo '{"crate":{"max_version":"0.25.15"}}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_crates_io "cargo-release"

    assert_equals "0.25.15" "${LATEST_VERSIONS[0]}" "crates.io version extracted correctly"
}

test_check_npm_mock() {
    setup_check_env

    add_tool "corepack" "0.36.0" "node.sh"
    add_tool "renamed-tool" "1.0.0" "dev-tools.sh"

    # Answer per URL so a wrong package name in the request reads as an error
    # row instead of borrowing another package's document.
    fetch_url() {
        case "$1" in
            https://registry.npmjs.org/corepack) echo '{"dist-tags":{"latest":"0.37.0","next":"0.38.0-rc.1"}}' ;;
            https://registry.npmjs.org/real-package) echo '{"dist-tags":{"latest":"2.1.0"}}' ;;
            *) echo '{}' ;;
        esac
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_npm "corepack"
    check_npm "renamed-tool" "real-package"

    assert_equals "0.37.0" "${LATEST_VERSIONS[0]}" "npm dist-tags.latest extracted (not another tag)"
    assert_equals "outdated" "${VERSION_STATUS[0]}" "older pin is reported outdated"
    assert_equals "2.1.0" "${LATEST_VERSIONS[1]}" "two-arg form queries the package name, not the tool name"
}

test_check_npm_missing_latest_is_error() {
    setup_check_env

    add_tool "corepack" "0.36.0" "node.sh"
    fetch_url() { echo '{"error":"Not found"}'; }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_npm "corepack"

    assert_equals "error" "${VERSION_STATUS[0]}" "a registry document with no dist-tags.latest is an error, not current"
}

test_check_rubygems_mock() {
    setup_check_env

    add_tool "gitlab-triage" "1.51.0" "Gemfile"

    fetch_url() {
        echo '{"version":"1.52.0"}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rubygems "gitlab-triage"

    assert_equals "1.52.0" "${LATEST_VERSIONS[0]}" "RubyGems version extracted correctly"
}

test_check_rubygems_missing_gem() {
    # A 404 / unparsable body must surface as an ERROR, never as "no update
    # available" — a silent pass there would stall the pin at its current
    # version forever, which is the whole failure mode this tracking prevents.
    # check_rubygems emits the "null" sentinel, which set_latest() normalizes to
    # "error" and marks the tool's status accordingly.
    setup_check_env

    add_tool "gitlab-triage" "1.51.0" "Gemfile"

    fetch_url() {
        echo ''
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rubygems "gitlab-triage"

    assert_equals "error" "${LATEST_VERSIONS[0]}" "an unparsable response is recorded as an error"
    assert_equals "error" "${VERSION_STATUS[0]}" "the tool's status is error, not current"
}

test_check_maven_central_mock() {
    setup_check_env

    add_tool "jmh" "1.37" "java-dev.sh"

    fetch_url() {
        echo '{"response":{"docs":[{"latestVersion":"1.38"}]}}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_maven_central "jmh" "org.openjdk.jmh" "jmh-core"

    assert_equals "1.38" "${LATEST_VERSIONS[0]}" "Maven Central version extracted correctly"
}

test_check_biome_new_format() {
    setup_check_env

    add_tool "biome" "1.9.0" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"@biomejs/biome@1.9.4"},{"tag_name":"@biomejs/biome@1.9.3"}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_biome

    assert_equals "1.9.4" "${LATEST_VERSIONS[0]}" "Biome new tag format parsed correctly"
}

test_check_kubectl_mock() {
    setup_check_env

    add_tool "kubectl" "1.33" "Dockerfile"

    fetch_url() {
        echo '[{"tag_name":"v1.33.1","prerelease":false},{"tag_name":"v1.33.0","prerelease":false},{"tag_name":"v1.32.5","prerelease":false}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_kubectl

    assert_equals "1.33.1" "${LATEST_VERSIONS[0]}" "kubectl version extracted for major.minor"
}

run_test test_check_python_mock "check_python with mock API response"
run_test test_check_rust_mock "check_rust with mock API response"
run_test test_check_github_release_mock "check_github_release with mock API response"
run_test test_check_github_release_prerelease_mock "check_github_release_prerelease picks newest tag including prereleases"
run_test test_check_github_release_prerelease_skips_drafts "check_github_release_prerelease skips draft releases"
run_test test_check_gitlab_release_mock "check_gitlab_release with mock API response"
run_test test_check_crates_io_mock "check_crates_io with mock API response"
run_test test_check_npm_mock "check_npm with mock API response"
run_test test_check_npm_missing_latest_is_error "check_npm with no dist-tags.latest reports error"
run_test test_check_rubygems_mock "check_rubygems with mock API response"
run_test test_check_rubygems_missing_gem "check_rubygems falls back to null on an empty response"
run_test test_check_maven_central_mock "check_maven_central with mock API response"
run_test test_check_biome_new_format "check_biome parses new tag format"
run_test test_check_kubectl_mock "check_kubectl with mock API response"

# Generate test report
generate_report
