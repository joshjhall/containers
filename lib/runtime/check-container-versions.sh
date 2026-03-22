#!/usr/bin/env bash
# Version Checker - Compare pinned versions with latest releases
#
# Description:
#   Checks all pinned versions in feature scripts against the latest available
#   versions from authoritative sources (GitHub, official APIs, etc.)
#   This is purely informational to help maintainers know when updates are available.
#
# Usage:
#   ./check-versions.sh [--json]
#
# Options:
#   --json    Output results in JSON format
#
# Exit codes:
#   0 - All checks completed (regardless of outdated versions)
#   1 - Error during execution
#

set -euo pipefail

# Check bash version - we need 4+ for associative arrays
if [ "${BASH_VERSION%%.*}" -lt 4 ]; then
    echo "Error: This script requires Bash 4.0 or newer for associative array support"
    echo "Current version: ${BASH_VERSION}"
    echo ""
    echo "On macOS, install newer bash with: brew install bash"
    echo "Then run this script with: /opt/homebrew/bin/bash $0"
    exit 1
fi

# Source .env file if it exists (for GITHUB_TOKEN)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a  # Automatically export all variables
    source "$SCRIPT_DIR/.env"
    set +a  # Turn off automatic export
fi

# Color codes for output
# shellcheck source=lib/shared/colors.sh
source "/opt/container-runtime/shared/colors.sh" 2>/dev/null \
    || { RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'; }

# Parse arguments
output_format="text"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) output_format="json"; shift ;;
        --help|-h)
            command head -n 16 "$0" | command grep "^#" | command sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Arrays to store results
declare -A CURRENT_VERSIONS
declare -A LATEST_VERSIONS
declare -A VERSION_STATUS

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURES_DIR="${SCRIPT_DIR}/../features"

# ============================================================================
# Helper Functions
# ============================================================================

# Source shared version API functions
# shellcheck source=lib/runtime/lib/version-api.sh
source "${SCRIPT_DIR}/lib/version-api.sh"

# Print result
print_result() {
    local name="$1"
    local current="$2"
    local latest="$3"
    local status="$4"

    if [ "$output_format" = "json" ]; then
        return  # JSON output handled separately
    fi

    local status_color
    local status_text="$status"
    case "$status" in
        "up-to-date")
            status_color="$GREEN"
            ;;
        "newer")
            status_color="$BLUE"
            ;;
        "outdated")
            status_color="$YELLOW"
            ;;
        *)
            status_color="$RED"
            ;;
    esac

    printf "%-25s %-15s %-15s ${status_color}%-12s${NC}\n" "$name" "$current" "$latest" "$status_text"
}

# Check a version-pinned tool against its latest release
check_tool() {
    local key="$1" print_name="$2" file="$3" pattern="$4" getter_fn="$5"
    shift 5
    [ -f "$file" ] || return 0
    local current latest status
    current=$(extract_version "$file" "$pattern")
    if [ "$current" = "latest" ]; then
        latest="latest"; status="up-to-date"
    else
        latest=$("$getter_fn" "$@")
        status=$(compare_version "$current" "$latest")
    fi
    CURRENT_VERSIONS["$key"]="$current"
    LATEST_VERSIONS["$key"]="$latest"
    VERSION_STATUS["$key"]="$status"
    print_result "$print_name" "$current" "$latest" "$status"
}

# Thin wrapper: GitHub release with v-prefix stripped
# shellcheck disable=SC2317  # Called dynamically via check_tool
_get_github_release_stripped() {
    get_github_release "$1" "${2:-}" | command sed 's/^v//'
}

# Thin wrapper: kubectl latest stable
# shellcheck disable=SC2317  # Called dynamically via check_tool
_get_latest_kubectl() {
    command curl -Lsf https://dl.k8s.io/release/stable.txt \
        | command sed 's/^v//' | command cut -d. -f1,2 || echo "unknown"
}

# Thin wrapper: glab latest from GitLab API
# shellcheck disable=SC2317  # Called dynamically via check_tool
_get_latest_glab() {
    command curl -sf "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases" \
        | jq -r '.[0].tag_name' | command sed 's/^v//' || echo "unknown"
}

# ============================================================================
# Version Checks
# ============================================================================

echo "Checking versions in feature scripts..."
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "Using GitHub token for API authentication"
else
    echo "No GitHub token found. To avoid rate limits, set GITHUB_TOKEN in .env file"
fi
echo

# Header
if [ "$output_format" != "json" ]; then
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

# Languages
check_tool "Python"  "Python"     "$FEATURES_DIR/python.sh"  'PYTHON_VERSION="?\$\{PYTHON_VERSION:-\K[^"}]+' get_latest_python
check_tool "Ruby"    "Ruby"       "$FEATURES_DIR/ruby.sh"    'RUBY_VERSION="?\$\{RUBY_VERSION:-\K[^"}]+'   get_latest_ruby
check_tool "Node.js" "Node.js"    "$FEATURES_DIR/node.sh"    'NODE_VERSION="?\$\{NODE_VERSION:-\K[^"}]+'   get_latest_node
check_tool "Go"      "Go"         "$FEATURES_DIR/golang.sh"  'GO_VERSION="?\$\{GO_VERSION:-\K[^"}]+'       get_latest_go
check_tool "Rust"    "Rust"       "$FEATURES_DIR/rust.sh"    'RUST_VERSION="?\$\{RUST_VERSION:-\K[^"}]+'   get_latest_rust
check_tool "Java"    "Java (LTS)" "$FEATURES_DIR/java.sh"    'JAVA_VERSION="?\$\{JAVA_VERSION:-\K[^"}]+'   get_latest_java_lts
check_tool "Mojo"    "Mojo"       "$FEATURES_DIR/mojo.sh"    'MOJO_VERSION="?\$\{MOJO_VERSION:-\K[^"}]+'   get_latest_mojo

# ============================================================================
# Development Tools Checks
# ============================================================================

if [ "$output_format" != "json" ]; then
    echo
    echo "Development Tools:"
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

if [ -f "$FEATURES_DIR/dev-tools.sh" ]; then
    check_tool "direnv"  "direnv"  "$FEATURES_DIR/dev-tools.sh" 'DIRENV_VERSION="\K[^"]+'  _get_github_release_stripped "direnv/direnv"
    check_tool "lazygit" "lazygit" "$FEATURES_DIR/dev-tools.sh" 'LAZYGIT_VERSION="\K[^"]+' _get_github_release_stripped "jesseduffield/lazygit"
    check_tool "delta"   "delta"   "$FEATURES_DIR/dev-tools.sh" 'DELTA_VERSION="\K[^"]+'   _get_github_release_stripped "dandavison/delta"
    check_tool "mkcert"  "mkcert"  "$FEATURES_DIR/dev-tools.sh" 'MKCERT_VERSION="\K[^"]+'  _get_github_release_stripped "FiloSottile/mkcert"
    check_tool "act"     "act"     "$FEATURES_DIR/dev-tools.sh" 'ACT_VERSION="\K[^"]+'     _get_github_release_stripped "nektos/act"
    check_tool "glab"    "glab"    "$FEATURES_DIR/dev-tools.sh" 'GLAB_VERSION="\K[^"]+'    _get_latest_glab
fi

# ============================================================================
# Cloud Tools Checks
# ============================================================================

if [ "$output_format" != "json" ]; then
    echo
    echo "Cloud & Infrastructure Tools:"
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

if [ -f "$FEATURES_DIR/terraform.sh" ]; then
    check_tool "Terraform"     "Terraform"     "$FEATURES_DIR/terraform.sh" 'TERRAFORM_VERSION="?\K[^"]+'                         _get_github_release_stripped "hashicorp/terraform"
    check_tool "Terragrunt"    "Terragrunt"    "$FEATURES_DIR/terraform.sh" 'TERRAGRUNT_VERSION="?\$\{TERRAGRUNT_VERSION:-\K[^"}]+' _get_github_release_stripped "gruntwork-io/terragrunt"
    check_tool "terraform-docs" "terraform-docs" "$FEATURES_DIR/terraform.sh" 'TFDOCS_VERSION="?\$\{TFDOCS_VERSION:-\K[^"}]+'       _get_github_release_stripped "terraform-docs/terraform-docs"
fi

if [ -f "$FEATURES_DIR/kubernetes.sh" ]; then
    check_tool "kubectl" "kubectl" "$FEATURES_DIR/kubernetes.sh" 'KUBECTL_VERSION="?\$\{KUBECTL_VERSION:-\K[^"}]+' _get_latest_kubectl
    check_tool "k9s"     "k9s"     "$FEATURES_DIR/kubernetes.sh" 'K9S_VERSION="?\$\{K9S_VERSION:-\K[^"}]+'        _get_github_release_stripped "derailed/k9s"
    check_tool "krew"    "krew"    "$FEATURES_DIR/kubernetes.sh" 'KREW_VERSION="?\$\{KREW_VERSION:-\K[^"}]+'       _get_github_release_stripped "kubernetes-sigs/krew"
    check_tool "Helm"    "Helm"    "$FEATURES_DIR/kubernetes.sh" 'HELM_VERSION="?\$\{HELM_VERSION:-\K[^"}]+'       _get_github_release_stripped "helm/helm"
fi

# ============================================================================
# Development Tools (Informational Only - Not Pinned)
# ============================================================================
if [ "$output_format" != "json" ]; then
    echo
    echo "================================================================================"
    echo "Development Tools (Informational Only - Not Pinned)"
    echo "================================================================================"
    echo
    echo "The following tools are not version-pinned in the build scripts."
    echo "Latest available versions are shown for informational purposes only."
    echo
    echo "Python Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# Python dev tools (informational only)
python_dev_tools=(
    "black"
    "isort"
    "ruff"
    "flake8"
    "mypy"
    "pylint"
    "pytest"
    "tox"
    "pre-commit"
    "cookiecutter"
    "sphinx"
    "jupyter"
    "ipython"
    "httpie"
    "yq"
)

for tool in "${python_dev_tools[@]}"; do
    latest=$(get_pypi_version "$tool")
    if [ "$output_format" != "json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$output_format" != "json" ]; then
    echo
    echo "Rust Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# Rust dev tools (informational only)
rust_dev_tools=(
    "tree-sitter-cli"
    "cargo-watch"
    "cargo-edit"
    "cargo-expand"
    "cargo-outdated"
    "bacon"
    "tokei"
    "hyperfine"
    "just"
    "sccache"
    "mdbook"
)

for tool in "${rust_dev_tools[@]}"; do
    latest=$(get_crates_version "$tool")
    if [ "$output_format" != "json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$output_format" != "json" ]; then
    echo
    echo "Ruby Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# Ruby dev tools (informational only)
ruby_dev_tools=(
    "rspec"
    "rubocop"
    "pry"
    "yard"
    "reek"
    "brakeman"
    "rails"
    "solargraph"
)

for tool in "${ruby_dev_tools[@]}"; do
    latest=$(get_rubygems_version "$tool")
    if [ "$output_format" != "json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$output_format" != "json" ]; then
    echo
    echo "R Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# R dev tools (informational only)
r_dev_tools=(
    "devtools"
    "tidyverse"
    "testthat"
    "roxygen2"
    "usethis"
    "rmarkdown"
    "knitr"
    "shiny"
    "plumber"
    "lintr"
    "styler"
    "profvis"
    "renv"
    "pak"
)

for tool in "${r_dev_tools[@]}"; do
    latest=$(get_cran_version "$tool")
    if [ "$output_format" != "json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$output_format" != "json" ]; then
    echo
    echo "--------------------------------------------------------------------------------"
    echo "Note: These tools are NOT version-pinned in the build scripts."
    echo "They will install the latest available version at container build time."
    echo "Use 'check-installed-versions.sh' inside the container to see what's installed."
    echo "--------------------------------------------------------------------------------"
fi

# ============================================================================
# Summary
# ============================================================================

if [ "$output_format" != "json" ]; then
    echo
    echo "Summary:"

    outdated_count=0
    uptodate_count=0
    newer_count=0
    unknown_count=0

    for tool in "${!VERSION_STATUS[@]}"; do
        case "${VERSION_STATUS[$tool]}" in
            "outdated") outdated_count=$((outdated_count + 1)) ;;
            "up-to-date") uptodate_count=$((uptodate_count + 1)) ;;
            "newer") newer_count=$((newer_count + 1)) ;;
            *) unknown_count=$((unknown_count + 1)) ;;
        esac
    done

    echo -e "  Up-to-date: ${GREEN}${uptodate_count}${NC}"
    echo -e "  Newer: ${BLUE}${newer_count}${NC}"
    echo -e "  Outdated: ${YELLOW}${outdated_count}${NC}"
    echo -e "  Unknown: ${RED}${unknown_count}${NC}"

    if [ $outdated_count -gt 0 ]; then
        echo
        echo "Run 'make update-versions' to update outdated versions (when implemented)"
    fi

    # Check if any rate limiting occurred
    if printf '%s\n' "${LATEST_VERSIONS[@]}" | _vapi_grep -q "rate-limited"; then
        echo
        echo -e "${YELLOW}Warning: GitHub API rate limit exceeded.${NC}"
        echo "Some version checks could not be completed."
        echo "To avoid rate limits, you can:"
        echo "  - Wait an hour for the rate limit to reset"
        echo "  - Use an authenticated GitHub token: export GITHUB_TOKEN=your_token"
    fi
else
    # JSON output
    echo "{"
    echo '  "results": ['
    first=true
    for tool in "${!CURRENT_VERSIONS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        printf '    {"tool": "%s", "current": "%s", "latest": "%s", "status": "%s"}' \
            "$tool" "${CURRENT_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]}" "${VERSION_STATUS[$tool]}"
    done
    echo
    echo "  ]"
    echo "}"
fi

exit 0
