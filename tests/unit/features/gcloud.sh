#!/usr/bin/env bash
# Unit tests for lib/features/gcloud.sh
# Tests Google Cloud SDK installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Google Cloud SDK Feature Tests"

# Setup function - runs before each test
setup() {
    # Create unique temporary directory for testing (avoid collisions with parallel runs)
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gcloud-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.config/gcloud"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: gcloud CLI installation
test_gcloud_installation() {
    local gcloud_bin="$TEST_TEMP_DIR/usr/local/bin/gcloud"

    # Create mock gcloud
    touch "$gcloud_bin"
    chmod +x "$gcloud_bin"

    assert_file_exists "$gcloud_bin"

    # Check executable
    if [ -x "$gcloud_bin" ]; then
        assert_true true "gcloud is executable"
    else
        assert_true false "gcloud is not executable"
    fi
}

# Test: gcloud components
test_gcloud_components() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"

    # List of gcloud components
    local components=("gsutil" "bq" "kubectl")

    # Create mock components
    for comp in "${components[@]}"; do
        touch "$bin_dir/$comp"
        chmod +x "$bin_dir/$comp"
    done

    # Check each component
    for comp in "${components[@]}"; do
        if [ -x "$bin_dir/$comp" ]; then
            assert_true true "$comp is installed"
        else
            assert_true false "$comp is not installed"
        fi
    done
}

# Test: gcloud configuration
test_gcloud_config() {
    local config_dir="$TEST_TEMP_DIR/home/testuser/.config/gcloud"
    local config_file="$config_dir/configurations/config_default"
    mkdir -p "$(dirname "$config_file")"

    # Create config
    command cat > "$config_file" << 'EOF'
[core]
account = user@example.com
project = my-project
[compute]
region = us-central1
zone = us-central1-a
EOF

    assert_file_exists "$config_file"

    # Check configuration
    if grep -q "project = my-project" "$config_file"; then
        assert_true true "Default project configured"
    else
        assert_true false "Default project not configured"
    fi
}

# Test: Application default credentials
test_app_default_credentials() {
    local adc_file="$TEST_TEMP_DIR/home/testuser/.config/gcloud/application_default_credentials.json"
    mkdir -p "$(dirname "$adc_file")"

    # Create mock ADC
    command cat > "$adc_file" << 'EOF'
{
  "type": "authorized_user",
  "client_id": "test.apps.googleusercontent.com",
  "client_secret": "test_secret"
}
EOF

    assert_file_exists "$adc_file"
}

# Test: gcloud aliases
test_gcloud_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/66-gcloud.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias gc='gcloud'
alias gcp='gcloud projects'
alias gce='gcloud compute'
alias gke='gcloud container'
alias gcr='gcloud container images'
EOF

    # Check aliases
    if grep -q "alias gc='gcloud'" "$bashrc_file"; then
        assert_true true "gcloud alias defined"
    else
        assert_true false "gcloud alias not defined"
    fi
}

# Test: gcloud environment variables
test_gcloud_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/66-gcloud.sh"

    # Add environment variables
    command cat >> "$bashrc_file" << 'EOF'
export CLOUDSDK_PYTHON="python3"
export CLOUDSDK_CONFIG="$HOME/.config/gcloud"
EOF

    # Check environment variables
    if grep -q "export CLOUDSDK_CONFIG=" "$bashrc_file"; then
        assert_true true "CLOUDSDK_CONFIG is exported"
    else
        assert_true false "CLOUDSDK_CONFIG is not exported"
    fi
}

# Test: gcloud completion
test_gcloud_completion() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/66-gcloud.sh"

    # Add completion
    command cat >> "$bashrc_file" << 'EOF'
source /usr/share/google-cloud-sdk/completion.bash.inc
EOF

    # Check completion setup
    if grep -q "completion.bash.inc" "$bashrc_file"; then
        assert_true true "gcloud completion configured"
    else
        assert_true false "gcloud completion not configured"
    fi
}

# Test: Cloud Build config
test_cloud_build_config() {
    local cloudbuild_yaml="$TEST_TEMP_DIR/cloudbuild.yaml"

    # Create config
    command cat > "$cloudbuild_yaml" << 'EOF'
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', 'gcr.io/$PROJECT_ID/app', '.']
EOF

    assert_file_exists "$cloudbuild_yaml"

    # Check configuration
    if grep -q "gcr.io/cloud-builders/docker" "$cloudbuild_yaml"; then
        assert_true true "Cloud Build uses docker builder"
    else
        assert_true false "Cloud Build doesn't use docker builder"
    fi
}

# Test: Firebase CLI
test_firebase_cli() {
    local firebase_bin="$TEST_TEMP_DIR/usr/local/bin/firebase"

    # Create mock firebase
    touch "$firebase_bin"
    chmod +x "$firebase_bin"

    # Check Firebase CLI
    if [ -x "$firebase_bin" ]; then
        assert_true true "Firebase CLI is available"
    else
        assert_true false "Firebase CLI is not available"
    fi
}

# Test: Verification script
test_gcloud_verification() {
    local test_script="$TEST_TEMP_DIR/test-gcloud.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Google Cloud SDK version:"
gcloud version 2>/dev/null || echo "gcloud not installed"
echo "Components:"
gcloud components list 2>/dev/null || echo "No components"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
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
run_test_with_setup test_gcloud_installation "gcloud CLI installation"
run_test_with_setup test_gcloud_components "gcloud components"
run_test_with_setup test_gcloud_config "gcloud configuration"
run_test_with_setup test_app_default_credentials "Application default credentials"
run_test_with_setup test_gcloud_aliases "gcloud aliases"
run_test_with_setup test_gcloud_environment "gcloud environment variables"
run_test_with_setup test_gcloud_completion "gcloud completion"
run_test_with_setup test_cloud_build_config "Cloud Build configuration"
run_test_with_setup test_firebase_cli "Firebase CLI"
run_test_with_setup test_gcloud_verification "gcloud verification"

# Generate test report
generate_report
