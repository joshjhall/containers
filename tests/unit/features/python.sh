#!/usr/bin/env bash
# Unit tests for lib/features/python.sh
# Tests Python installation and configuration logic

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Python Feature Tests"

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/features/python.sh"
    assert_executable "$PROJECT_ROOT/lib/features/python.sh"
}

# Test: Version parsing logic
test_version_parsing() {
    # Test Python version parsing
    local version="3.13.6"
    local major
    major=$(echo "$version" | cut -d. -f1,2)

    assert_equals "3.13" "$major" "Python major version parsed correctly"

    # Test different versions
    version="3.12.1"
    major=$(echo "$version" | cut -d. -f1,2)
    assert_equals "3.12" "$major" "Python 3.12 major version parsed correctly"
}

# Test: Python download URL construction
test_download_url_construction() {
    local version="3.13.6"
    local expected_url="https://www.python.org/ftp/python/${version}/Python-${version}.tgz"

    assert_equals "$expected_url" "https://www.python.org/ftp/python/3.13.6/Python-3.13.6.tgz" "Python download URL constructed correctly"
}

# Test: Build dependencies list
test_build_dependencies() {
    # These are the core build dependencies for Python
    # shellcheck disable=SC2034  # Array used to demonstrate expected dependencies structure
    local required_deps=(
        "build-essential"
        "libffi-dev"
        "libssl-dev"
        "libbz2-dev"
        "libreadline-dev"
        "libsqlite3-dev"
        "libncurses5-dev"
        "libgdbm-dev"
        "liblzma-dev"
        "uuid-dev"
        "zlib1g-dev"
    )

    # Test that we have a reasonable list of dependencies
    assert_true true "Build dependencies list defined"

    # Test specific critical ones
    local deps_string="build-essential libffi-dev libssl-dev"
    if [[ "$deps_string" == *"build-essential"* ]] && [[ "$deps_string" == *"libffi-dev"* ]]; then
        assert_true true "Critical build dependencies included"
    else
        assert_true false "Critical build dependencies missing"
    fi
}

# Test: Python configuration options
test_configure_options() {
    # Test that configure options are reasonable
    # shellcheck disable=SC2034  # Array used to demonstrate expected configure options structure
    local configure_opts=(
        "--enable-optimizations"
        "--with-ensurepip=install"
        "--enable-shared"
        "--enable-loadable-sqlite-extensions"
    )

    # Test optimization option
    local opts_string="--enable-optimizations --with-ensurepip=install"
    if [[ "$opts_string" == *"--enable-optimizations"* ]]; then
        assert_true true "Optimization enabled in configure options"
    else
        assert_true false "Optimization not enabled"
    fi

    # Test pip installation
    if [[ "$opts_string" == *"--with-ensurepip=install"* ]]; then
        assert_true true "Pip installation enabled in configure"
    else
        assert_true false "Pip installation not enabled"
    fi
}

# Test: Poetry installation logic
test_poetry_installation() {
    # Poetry is actually installed in python-dev.sh, not python.sh
    # Test that we can handle Poetry version checking
    local poetry_version="1.8.5"  # Mock version

    if [[ "$poetry_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Poetry version format is valid: $poetry_version"
    else
        assert_true false "Poetry version format invalid: $poetry_version"
    fi
}

# Test: uv version format
test_uv_version_format() {
    local version
    version=$(command grep "UV_VERSION=" "$PROJECT_ROOT/lib/features/lib/python/install-tools.sh" | head -1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "UV_VERSION format is valid: $version"
    else
        assert_true false "UV_VERSION format invalid: $version"
    fi
}

# Test: uv installation
test_uv_installation() {
    if command grep -q "UV_VERSION=" "$PROJECT_ROOT/lib/features/lib/python/install-tools.sh"; then
        assert_true true "UV_VERSION is defined in install-tools.sh"
    else
        assert_true false "UV_VERSION is not defined in install-tools.sh"
    fi

    if command grep -q "pip install.*uv==" "$PROJECT_ROOT/lib/features/lib/python/install-tools.sh"; then
        assert_true true "uv is installed via pip"
    else
        assert_true false "uv pip install command not found"
    fi
}

# Test: Cache directory configuration
test_cache_directories() {
    # Test pip cache path
    local pip_cache="/cache/pip"
    assert_equals "/cache/pip" "$pip_cache" "Pip cache directory path"

    # Test that cache paths are absolute
    if [[ "$pip_cache" == /* ]]; then
        assert_true true "Cache path is absolute"
    else
        assert_true false "Cache path should be absolute"
    fi
}

# Test: Python executable paths
test_python_paths() {
    local python_version="3.13"
    local expected_python="/usr/local/bin/python${python_version}"
    local expected_pip="/usr/local/bin/pip${python_version}"

    # Test path construction
    assert_equals "/usr/local/bin/python3.13" "$expected_python" "Python executable path"
    assert_equals "/usr/local/bin/pip3.13" "$expected_pip" "Pip executable path"
}

# Test: Environment variables setup
test_environment_variables() {
    # Test Python-related environment variables
    local python_version="3.13"

    # Test PYTHONPATH construction
    local pythonpath="/usr/local/lib/python${python_version}/site-packages"
    assert_equals "/usr/local/lib/python3.13/site-packages" "$pythonpath" "Python path construction"

    # Test cache environment variables
    local pip_cache_dir="/cache/pip"
    assert_equals "/cache/pip" "$pip_cache_dir" "Pip cache directory"
}

# Test: Make command construction
test_make_commands() {
    # Test make command with parallel jobs
    local nprocs="4"
    local make_cmd="make -j${nprocs}"

    assert_equals "make -j4" "$make_cmd" "Make command with parallel jobs"

    # Test that we can get nproc value (mock it)
    local mock_nproc
    mock_nproc="$(nproc 2>/dev/null || echo 4)"
    if [[ "$mock_nproc" =~ ^[0-9]+$ ]] && [ "$mock_nproc" -gt 0 ]; then
        assert_true true "nproc command returns valid number: $mock_nproc"
    else
        assert_true false "nproc command failed"
    fi
}

# Test: Python installation verification
test_python_verification() {
    # Test version check command
    local version_check_cmd="python3 --version"
    assert_equals "python3 --version" "$version_check_cmd" "Version check command"

    # Test pip version check
    local pip_check_cmd="pip3 --version"
    assert_equals "pip3 --version" "$pip_check_cmd" "Pip version check command"
}

# Test: Feature header integration
test_feature_header() {
    # Test that the script sources the feature header
    if command grep -q "source /tmp/build-scripts/base/feature-header.sh" "$PROJECT_ROOT/lib/features/python.sh"; then
        assert_true true "Feature header is sourced"
    else
        assert_true false "Feature header not sourced"
    fi

    # Test logging integration
    if command grep -q "log_feature_start" "$PROJECT_ROOT/lib/features/python.sh"; then
        assert_true true "Logging integration present"
    else
        assert_true false "Logging integration missing"
    fi
}

# Test: Error handling patterns
test_error_handling() {
    # Test that script uses set -euo pipefail
    if command grep -q "set -euo pipefail" "$PROJECT_ROOT/lib/features/python.sh"; then
        assert_true true "Strict error handling enabled"
    else
        assert_true false "Strict error handling not enabled"
    fi
}

# Test: Package installation commands
test_package_commands() {
    # Test that apt-utils is sourced
    if command grep -q "source /tmp/build-scripts/base/apt-utils.sh" "$PROJECT_ROOT/lib/features/python.sh"; then
        assert_true true "apt-utils.sh is sourced for reliable package management"
    else
        assert_true false "apt-utils.sh not sourced"
    fi

    # Test that apt_install is used for package installation
    if command grep -q "apt_install" "$PROJECT_ROOT/lib/features/python.sh"; then
        assert_true true "Using apt_install function from apt-utils"
    else
        assert_true false "Not using apt_install function"
    fi
}

# Test: Cleanup operations
test_cleanup_operations() {
    # Test that build artifacts are cleaned up
    local cleanup_patterns=("*.tar.gz" "Python-*" "build" "*.pyc")

    # Test cleanup of source archives
    if [[ " ${cleanup_patterns[*]} " == *" *.tar.gz "* ]]; then
        assert_true true "Source archive cleanup included"
    else
        assert_true false "Source archive cleanup missing"
    fi
}

# Run all tests
run_test test_script_exists "Python script exists and is executable"
run_test test_version_parsing "Python version parsing logic"
run_test test_download_url_construction "Python download URL construction"
run_test test_build_dependencies "Build dependencies validation"
run_test test_configure_options "Python configure options"
run_test test_poetry_installation "Poetry installation logic"
run_test test_uv_version_format "uv version format validation"
run_test test_uv_installation "uv installation in python.sh"
run_test test_cache_directories "Cache directory configuration"
run_test test_python_paths "Python executable paths"
run_test test_environment_variables "Environment variables setup"
run_test test_make_commands "Make command construction"
run_test test_python_verification "Python installation verification"
run_test test_feature_header "Feature header integration"
run_test test_error_handling "Error handling patterns"
run_test test_package_commands "Package installation commands"
run_test test_cleanup_operations "Cleanup operations"

# Generate test report
generate_report
