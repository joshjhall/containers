#!/usr/bin/env bash
# Test r-dev container build
#
# This test verifies the R development environment that includes:
# - R with development tools
# - Common R packages (tidyverse, etc.)
# - Development tools integration
# - Cache directory configuration

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "R Development Container Build"

# Test: R dev environment builds successfully
test_r_dev_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-r-dev-$$"

        # Build with r-dev configuration
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-r-dev \
            --build-arg INCLUDE_R_DEV=true \
            -t "$image"
    fi

    # Verify R is installed
    assert_executable_in_path "$image" "R"
    assert_executable_in_path "$image" "Rscript"
}

# Test: R version and basic functionality
test_r_version() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # R can show version
    assert_command_in_container "$image" "R --version" "R version"

    # Rscript works
    assert_command_in_container "$image" "Rscript --version" "R scripting"
}

# Test: R can execute basic commands
test_r_execution() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # Basic arithmetic
    assert_command_in_container "$image" "Rscript -e 'cat(2 + 2)'" "4"

    # String manipulation
    assert_command_in_container "$image" "Rscript -e 'cat(\"Hello from R\")'" "Hello from R"

    # Basic function definition and execution
    assert_command_in_container "$image" "Rscript -e 'f <- function(x) x * 2; cat(f(21))'" "42"
}

# Test: Base R packages work
test_r_base_packages() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # Load and use base packages
    assert_command_in_container "$image" "Rscript -e 'library(stats); cat(\"ok\")'" "ok"
    assert_command_in_container "$image" "Rscript -e 'library(utils); cat(\"ok\")'" "ok"
    assert_command_in_container "$image" "Rscript -e 'library(graphics); cat(\"ok\")'" "ok"

    # Create a simple data frame
    assert_command_in_container "$image" "Rscript -e 'df <- data.frame(x=1:3, y=4:6); cat(nrow(df))'" "3"
}

# Test: Development packages are available
test_r_dev_packages() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # remotes package for package installation
    assert_command_in_container "$image" "Rscript -e 'library(remotes); cat(\"ok\")'" "ok"

    # devtools for development
    assert_command_in_container "$image" "Rscript -e 'library(devtools); cat(\"ok\")'" "ok"

    # pak for package management
    assert_command_in_container "$image" "Rscript -e 'library(pak); cat(\"ok\")'" "ok"
}

# Test: Data manipulation packages work
test_r_data_packages() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # dplyr for data manipulation
    assert_command_in_container "$image" "Rscript -e 'library(dplyr); cat(\"ok\")'" "ok"

    # Test dplyr functionality
    assert_command_in_container "$image" "Rscript -e 'library(dplyr); df <- data.frame(x=1:5); result <- df %>% filter(x > 3) %>% nrow(); cat(result)'" "2"

    # ggplot2 for visualization
    assert_command_in_container "$image" "Rscript -e 'library(ggplot2); cat(\"ok\")'" "ok"
}

# Test: R can install packages
test_r_package_install() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # Install a simple package using pak (faster and more reliable)
    # jsonlite is a lightweight package good for testing
    assert_command_in_container "$image" "Rscript -e 'pak::pkg_install(\"jsonlite\", ask = FALSE); library(jsonlite); cat(\"ok\")'" "ok"
}

# Test: Cache directories are configured correctly
test_r_cache() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # R library cache directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/r/library && echo writable" "writable"

    # R cache directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/r && echo writable" "writable"

    # R temporary directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/r/tmp && echo writable" "writable"

    # Verify R_LIBS_USER is set correctly
    assert_command_in_container "$image" "Rscript -e 'cat(.libPaths()[1])'" "/cache/r/library"
}

# Test: R development tools work
test_r_dev_tools() {
    local image="${IMAGE_TO_TEST:-test-r-dev-$$}"

    # testthat for testing
    assert_command_in_container "$image" "Rscript -e 'library(testthat); cat(\"ok\")'" "ok"

    # roxygen2 for documentation
    assert_command_in_container "$image" "Rscript -e 'library(roxygen2); cat(\"ok\")'" "ok"

    # usethis for project setup
    assert_command_in_container "$image" "Rscript -e 'library(usethis); cat(\"ok\")'" "ok"
}

# Run all tests
run_test test_r_dev_build "R dev environment builds successfully"
run_test test_r_version "R version and basic functionality work"
run_test test_r_execution "R can execute basic commands"
run_test test_r_base_packages "Base R packages work correctly"
run_test test_r_dev_packages "Development packages are available"
run_test test_r_data_packages "Data manipulation packages work"
run_test test_r_package_install "R can install new packages"
run_test test_r_cache "R cache directories are configured correctly"
run_test test_r_dev_tools "R development tools work"

# Generate test report
generate_report
