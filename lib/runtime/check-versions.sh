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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output format
OUTPUT_FORMAT="${1:-text}"

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

# Check if command exists
# shellcheck disable=SC2317  # Function is called dynamically
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get latest release from GitHub
get_github_release() {
    local repo="$1"
    local tag_pattern="${2:-}"
    local response
    if [ -z "$tag_pattern" ]; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(command curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/releases/latest")
        else
            response=$(command curl -s "https://api.github.com/repos/${repo}/releases/latest")
        fi
        # Check if we got rate limited
        if echo "$response" | ggrep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | ggrep -oP '"tag_name": "\K[^"]+' || echo "unknown"
    else
        # For specific tag patterns (e.g., some projects use different naming)
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(command curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/tags")
        else
            response=$(command curl -s "https://api.github.com/repos/${repo}/tags")
        fi
        if echo "$response" | ggrep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | jq -r ".[].name | select(. | test(\"${tag_pattern}\"))" | head -1 || echo "unknown"
    fi
}

# Get latest Python version
get_latest_python() {
    # Use Python's official JSON API endpoint
    command curl -s https://endoflife.date/api/python.json | jq -r '.[] | select(.latest) | .latest' | head -1 || echo "unknown"
}

# Get latest Ruby version
get_latest_ruby() {
    local response
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        response=$(command curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/ruby/ruby/releases)
    else
        response=$(command curl -s https://api.github.com/repos/ruby/ruby/releases)
    fi

    if echo "$response" | ggrep -q "rate limit exceeded"; then
        echo "rate-limited"
        return
    fi
    echo "$response" | jq -r '.[].tag_name | select(startswith("v"))' | head -1 | command sed 's/^v//' | tr '_' '.' || echo "unknown"
}

# Get latest Node.js LTS version
get_latest_node() {
    command curl -s https://nodejs.org/dist/index.json | jq -r '.[] | select(.lts != false) | .version' | head -1 | command sed 's/^v//' | cut -d. -f1 || echo "unknown"
}

# Get latest Go version
get_latest_go() {
    command curl -s https://go.dev/VERSION?m=text | head -1 | command sed 's/^go//' || echo "unknown"
}

# Get latest Rust stable version
get_latest_rust() {
    # Try to get the latest stable version from the Rust release API
    local version
    version=$(command curl -s https://api.github.com/repos/rust-lang/rust/releases | jq -r '.[] | select(.prerelease == false) | .tag_name' | head -1 | command sed 's/^v//')
    
    if [ -n "$version" ] && [ "$version" != "null" ]; then
        echo "$version"
    else
        # Fallback: try forge.rust-lang.org
        version=$(command curl -s https://forge.rust-lang.org/infra/channel-layout.html | ggrep -oP 'stable.*?rustc \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$version" ]; then
            echo "$version"
        else
            echo "1.88.0"  # Fallback to known version
        fi
    fi
}

# Get latest Java LTS version
get_latest_java_lts() {
    # OpenJDK doesn't have a simple API, so we'll check for known LTS versions
    echo "21"  # As of 2024, Java 21 is the latest LTS
}

# Get latest Mojo version
get_latest_mojo() {
    # Mojo uses YY.M format (e.g., 25.3, 25.4)
    # Since Mojo's versioning follows YY.M and we're in July 2025,
    # we expect versions like 25.3, 25.4, 25.5, etc.
    # 
    # Note: Mojo doesn't have a simple API for latest version yet
    # This is a placeholder that should be updated when Modular provides
    # a proper API endpoint or when we find a reliable source
    #
    # For now, we'll use a reasonable estimate based on their release cadence
    echo "25.4"  # Update this manually based on Mojo releases
}

# Extract version from script
extract_version() {
    local file="$1"
    local pattern="$2"
    ggrep -oP "${pattern}" "$file" | head -1 || echo "not found"
}

# Compare versions
compare_version() {
    local current="$1"
    local latest="$2"
    
    if [ "$current" = "$latest" ]; then
        echo "up-to-date"
    elif [ "$latest" = "unknown" ] || [ "$latest" = "not found" ] || [ "$latest" = "rate-limited" ]; then
        echo "unknown"
    else
        # Try to determine if current is newer than latest
        # This is a simple comparison - works for most semantic versions
        if command -v sort &>/dev/null; then
            local sorted
            sorted=$(printf "%s\n%s" "$current" "$latest" | sort -V | tail -1)
            if [ "$sorted" = "$current" ] && [ "$current" != "$latest" ]; then
                echo "newer"
            else
                echo "outdated"
            fi
        else
            echo "outdated"
        fi
    fi
}

# Print result
print_result() {
    local name="$1"
    local current="$2"
    local latest="$3"
    local status="$4"
    
    if [ "$OUTPUT_FORMAT" = "--json" ]; then
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
if [ "$OUTPUT_FORMAT" != "--json" ]; then
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

# Check Python
if [ -f "$FEATURES_DIR/python.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/python.sh" 'PYTHON_VERSION="?\$\{PYTHON_VERSION:-\K[^"}]+')
    latest=$(get_latest_python)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Python"]="$current"
    LATEST_VERSIONS["Python"]="$latest"
    VERSION_STATUS["Python"]="$status"
    print_result "Python" "$current" "$latest" "$status"
fi

# Check Ruby
if [ -f "$FEATURES_DIR/ruby.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/ruby.sh" 'RUBY_VERSION="?\$\{RUBY_VERSION:-\K[^"}]+')
    latest=$(get_latest_ruby)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Ruby"]="$current"
    LATEST_VERSIONS["Ruby"]="$latest"
    VERSION_STATUS["Ruby"]="$status"
    print_result "Ruby" "$current" "$latest" "$status"
fi

# Check Node.js
if [ -f "$FEATURES_DIR/node.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/node.sh" 'NODE_VERSION="?\$\{NODE_VERSION:-\K[^"}]+')
    latest=$(get_latest_node)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Node.js"]="$current"
    LATEST_VERSIONS["Node.js"]="$latest"
    VERSION_STATUS["Node.js"]="$status"
    print_result "Node.js" "$current" "$latest" "$status"
fi

# Check Go
if [ -f "$FEATURES_DIR/golang.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/golang.sh" 'GO_VERSION="?\$\{GO_VERSION:-\K[^"}]+')
    latest=$(get_latest_go)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Go"]="$current"
    LATEST_VERSIONS["Go"]="$latest"
    VERSION_STATUS["Go"]="$status"
    print_result "Go" "$current" "$latest" "$status"
fi

# Check Rust
if [ -f "$FEATURES_DIR/rust.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/rust.sh" 'RUST_VERSION="?\$\{RUST_VERSION:-\K[^"}]+')
    latest=$(get_latest_rust)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Rust"]="$current"
    LATEST_VERSIONS["Rust"]="$latest"
    VERSION_STATUS["Rust"]="$status"
    print_result "Rust" "$current" "$latest" "$status"
fi

# Check Java
if [ -f "$FEATURES_DIR/java.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/java.sh" 'JAVA_VERSION="?\$\{JAVA_VERSION:-\K[^"}]+')
    latest=$(get_latest_java_lts)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Java"]="$current"
    LATEST_VERSIONS["Java"]="$latest"
    VERSION_STATUS["Java"]="$status"
    print_result "Java (LTS)" "$current" "$latest" "$status"
fi

# Check Mojo
if [ -f "$FEATURES_DIR/mojo.sh" ]; then
    current=$(extract_version "$FEATURES_DIR/mojo.sh" 'MOJO_VERSION="?\$\{MOJO_VERSION:-\K[^"}]+')
    latest=$(get_latest_mojo)
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Mojo"]="$current"
    LATEST_VERSIONS["Mojo"]="$latest"
    VERSION_STATUS["Mojo"]="$status"
    print_result "Mojo" "$current" "$latest" "$status"
fi

# ============================================================================
# Development Tools Checks
# ============================================================================

if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo
    echo "Development Tools:"
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

# Check dev-tools.sh
if [ -f "$FEATURES_DIR/dev-tools.sh" ]; then
    # direnv
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'DIRENV_VERSION="\K[^"]+')
    latest=$(get_github_release "direnv/direnv" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["direnv"]="$current"
    LATEST_VERSIONS["direnv"]="$latest"
    VERSION_STATUS["direnv"]="$status"
    print_result "direnv" "$current" "$latest" "$status"
    
    # lazygit
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'LAZYGIT_VERSION="\K[^"]+')
    latest=$(get_github_release "jesseduffield/lazygit" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["lazygit"]="$current"
    LATEST_VERSIONS["lazygit"]="$latest"
    VERSION_STATUS["lazygit"]="$status"
    print_result "lazygit" "$current" "$latest" "$status"
    
    # delta
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'DELTA_VERSION="\K[^"]+')
    latest=$(get_github_release "dandavison/delta" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["delta"]="$current"
    LATEST_VERSIONS["delta"]="$latest"
    VERSION_STATUS["delta"]="$status"
    print_result "delta" "$current" "$latest" "$status"
    
    # mkcert
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'MKCERT_VERSION="\K[^"]+')
    latest=$(get_github_release "FiloSottile/mkcert" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["mkcert"]="$current"
    LATEST_VERSIONS["mkcert"]="$latest"
    VERSION_STATUS["mkcert"]="$status"
    print_result "mkcert" "$current" "$latest" "$status"
    
    # act
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'ACT_VERSION="\K[^"]+')
    latest=$(get_github_release "nektos/act" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["act"]="$current"
    LATEST_VERSIONS["act"]="$latest"
    VERSION_STATUS["act"]="$status"
    print_result "act" "$current" "$latest" "$status"
    
    # glab
    current=$(extract_version "$FEATURES_DIR/dev-tools.sh" 'GLAB_VERSION="\K[^"]+')
    # GitLab CLI is hosted on GitLab, not GitHub - use GitLab API
    latest=$(command curl -s "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases" | jq -r '.[0].tag_name' | command sed 's/^v//' || echo "unknown")
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["glab"]="$current"
    LATEST_VERSIONS["glab"]="$latest"
    VERSION_STATUS["glab"]="$status"
    print_result "glab" "$current" "$latest" "$status"
fi

# ============================================================================
# Cloud Tools Checks
# ============================================================================

if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo
    echo "Cloud & Infrastructure Tools:"
    printf "%-25s %-15s %-15s %-12s\n" "TOOL" "CURRENT" "LATEST" "STATUS"
    printf "%-25s %-15s %-15s %-12s\n" "----" "-------" "------" "------"
fi

# Check terraform.sh
if [ -f "$FEATURES_DIR/terraform.sh" ]; then
    # Terraform version
    current=$(extract_version "$FEATURES_DIR/terraform.sh" 'TERRAFORM_VERSION="?\K[^"]+')
    if [ "$current" = "latest" ]; then
        # Terraform is installed via APT, so we show "latest"
        latest="latest"
        status="up-to-date"
    else
        latest=$(get_github_release "hashicorp/terraform" | command sed 's/^v//')
        status=$(compare_version "$current" "$latest")
    fi
    CURRENT_VERSIONS["Terraform"]="$current"
    LATEST_VERSIONS["Terraform"]="$latest"
    VERSION_STATUS["Terraform"]="$status"
    print_result "Terraform" "$current" "$latest" "$status"
    
    # Terragrunt version
    current=$(extract_version "$FEATURES_DIR/terraform.sh" 'TERRAGRUNT_VERSION="?\$\{TERRAGRUNT_VERSION:-\K[^"}]+')
    latest=$(get_github_release "gruntwork-io/terragrunt" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["Terragrunt"]="$current"
    LATEST_VERSIONS["Terragrunt"]="$latest"
    VERSION_STATUS["Terragrunt"]="$status"
    print_result "Terragrunt" "$current" "$latest" "$status"
    
    # terraform-docs version
    current=$(extract_version "$FEATURES_DIR/terraform.sh" 'TFDOCS_VERSION="?\$\{TFDOCS_VERSION:-\K[^"}]+')
    latest=$(get_github_release "terraform-docs/terraform-docs" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["terraform-docs"]="$current"
    LATEST_VERSIONS["terraform-docs"]="$latest"
    VERSION_STATUS["terraform-docs"]="$status"
    print_result "terraform-docs" "$current" "$latest" "$status"
fi

# Check kubernetes.sh
if [ -f "$FEATURES_DIR/kubernetes.sh" ]; then
    # kubectl
    current=$(extract_version "$FEATURES_DIR/kubernetes.sh" 'KUBECTL_VERSION="?\$\{KUBECTL_VERSION:-\K[^"}]+')
    # kubectl returns the full version, but we track major.minor
    latest=$(command curl -Ls https://dl.k8s.io/release/stable.txt | command sed 's/^v//' | cut -d. -f1,2 || echo "unknown")
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["kubectl"]="$current"
    LATEST_VERSIONS["kubectl"]="$latest"
    VERSION_STATUS["kubectl"]="$status"
    print_result "kubectl" "$current" "$latest" "$status"
    
    # k9s
    current=$(extract_version "$FEATURES_DIR/kubernetes.sh" 'K9S_VERSION="?\$\{K9S_VERSION:-\K[^"}]+')
    latest=$(get_github_release "derailed/k9s" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["k9s"]="$current"
    LATEST_VERSIONS["k9s"]="$latest"
    VERSION_STATUS["k9s"]="$status"
    print_result "k9s" "$current" "$latest" "$status"
    
    # krew
    current=$(extract_version "$FEATURES_DIR/kubernetes.sh" 'KREW_VERSION="?\$\{KREW_VERSION:-\K[^"}]+')
    latest=$(get_github_release "kubernetes-sigs/krew" | command sed 's/^v//')
    status=$(compare_version "$current" "$latest")
    CURRENT_VERSIONS["krew"]="$current"
    LATEST_VERSIONS["krew"]="$latest"
    VERSION_STATUS["krew"]="$status"
    print_result "krew" "$current" "$latest" "$status"
    
    # helm
    current=$(extract_version "$FEATURES_DIR/kubernetes.sh" 'HELM_VERSION="?\$\{HELM_VERSION:-\K[^"}]+')
    if [ "$current" = "latest" ]; then
        latest="latest"
        status="up-to-date"
    else
        latest=$(get_github_release "helm/helm" | command sed 's/^v//')
        status=$(compare_version "$current" "$latest")
    fi
    CURRENT_VERSIONS["Helm"]="$current"
    LATEST_VERSIONS["Helm"]="$latest"
    VERSION_STATUS["Helm"]="$status"
    print_result "Helm" "$current" "$latest" "$status"
fi

# ============================================================================
# Development Tools (Informational Only - Not Pinned)
# ============================================================================
if [ "$OUTPUT_FORMAT" != "--json" ]; then
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

# Function to get PyPI package latest version
get_pypi_version() {
    local package="$1"
    local response
    if response=$(command curl -s "https://pypi.org/pypi/${package}/json"); then
        echo "$response" | jq -r '.info.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

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
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo
    echo "Rust Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# Function to get crates.io package latest version
get_crates_version() {
    local package="$1"
    local response
    if response=$(command curl -s "https://crates.io/api/v1/crates/${package}"); then
        echo "$response" | jq -r '.crate.max_version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

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
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo
    echo "Ruby Development Tools:"
    printf "%-25s %-15s\n" "TOOL" "LATEST AVAILABLE"
    printf "%-25s %-15s\n" "----" "----------------"
fi

# Function to get RubyGems latest version
get_rubygems_version() {
    local gem="$1"
    local response
    if response=$(command curl -s "https://rubygems.org/api/v1/gems/${gem}.json"); then
        echo "$response" | jq -r '.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

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
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$OUTPUT_FORMAT" != "--json" ]; then
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

# Function to get CRAN package latest version
get_cran_version() {
    local package="$1"
    # Use the CRAN API to get package info
    local response
    if response=$(command curl -s "https://crandb.r-pkg.org/${package}"); then
        echo "$response" | jq -r '.Version // .version // "unknown"' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

for tool in "${r_dev_tools[@]}"; do
    latest=$(get_cran_version "$tool")
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        printf "%-25s ${BLUE}%-15s${NC}\n" "$tool" "$latest"
    fi
done

if [ "$OUTPUT_FORMAT" != "--json" ]; then
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

if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo
    echo "Summary:"
    
    outdated_count=0
    uptodate_count=0
    newer_count=0
    unknown_count=0
    
    # Debug: check array size
    # echo "Debug: VERSION_STATUS has ${#VERSION_STATUS[@]} elements"
    
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
    if printf '%s\n' "${LATEST_VERSIONS[@]}" | ggrep -q "rate-limited"; then
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