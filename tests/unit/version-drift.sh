#!/usr/bin/env bash
# Unit tests for version drift between Dockerfile ARGs and feature script fallbacks
#
# This test validates that every version ARG in the Dockerfile matches its
# corresponding fallback default in the feature script. Drift occurs when
# the auto-patch system updates Dockerfile ARGs but misses the feature
# script fallbacks.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Drift Detection Tests"

# Setup
DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# Mapping of Dockerfile ARG names to feature script paths
declare -A VERSION_MAP
VERSION_MAP=(
    ["PYTHON_VERSION"]="lib/features/python.sh"
    ["NODE_VERSION"]="lib/features/node.sh"
    ["RUST_VERSION"]="lib/features/rust.sh"
    ["RUBY_VERSION"]="lib/features/ruby.sh"
    ["GO_VERSION"]="lib/features/golang.sh"
    ["R_VERSION"]="lib/features/r.sh"
    ["JAVA_VERSION"]="lib/features/java.sh"
    ["KOTLIN_VERSION"]="lib/features/kotlin.sh"
    ["KUBECTL_VERSION"]="lib/features/kubernetes.sh"
    ["K9S_VERSION"]="lib/features/kubernetes.sh"
    ["KREW_VERSION"]="lib/features/kubernetes.sh"
    ["HELM_VERSION"]="lib/features/kubernetes.sh"
    ["TERRAGRUNT_VERSION"]="lib/features/terraform.sh"
    ["TFDOCS_VERSION"]="lib/features/terraform.sh"
    ["TFLINT_VERSION"]="lib/features/terraform.sh"
    ["PIXI_VERSION"]="lib/features/mojo.sh"
    ["ANDROID_CMDLINE_TOOLS_VERSION"]="lib/features/android.sh"
    ["ANDROID_NDK_VERSION"]="lib/features/android.sh"
)

# Extract the Dockerfile ARG value for a given variable name
get_dockerfile_version() {
    local arg_name="$1"
    command grep -E "^ARG ${arg_name}=" "$DOCKERFILE" | command sed "s/^ARG ${arg_name}=//"
}

# Extract the feature script fallback value for a given variable name
get_feature_fallback() {
    local arg_name="$1"
    local script_path="$PROJECT_ROOT/$2"
    command grep -oE "${arg_name}=\"\\\$\{${arg_name}:-[^}]+\}" "$script_path" | command sed "s/.*:-//" | command sed "s/}//"
}

# Generate test functions for each version mapping
for arg_name in "${!VERSION_MAP[@]}"; do
    feature_script="${VERSION_MAP[$arg_name]}"

    # Define test function using eval to capture loop variables
    eval "
test_${arg_name}_drift() {
    local dockerfile_val
    local fallback_val
    dockerfile_val=\"\$(get_dockerfile_version '${arg_name}')\"
    fallback_val=\"\$(get_feature_fallback '${arg_name}' '${feature_script}')\"

    if [ -z \"\$dockerfile_val\" ]; then
        echo \"SKIP: ARG ${arg_name} not found in Dockerfile\"
        return 0
    fi

    if [ -z \"\$fallback_val\" ]; then
        echo \"SKIP: Fallback for ${arg_name} not found in ${feature_script}\"
        return 0
    fi

    assert_equals \"\$dockerfile_val\" \"\$fallback_val\" \\
        \"${arg_name}: Dockerfile ARG (\$dockerfile_val) must match ${feature_script} fallback (\$fallback_val)\"
}
"
    run_test "test_${arg_name}_drift" "No drift: ${arg_name} (Dockerfile vs ${feature_script})"
done

# Generate report
generate_report
