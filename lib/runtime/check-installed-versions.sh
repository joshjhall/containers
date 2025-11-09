#!/usr/bin/env bash
# Check Installed Versions - Compare installed tools with latest stable versions
#
# Description:
#   Checks what tools are actually installed in the container and compares
#   their versions with the latest stable versions available. By default,
#   only shows installed tools. Use --all to see all tools including missing ones.
#
# Usage:
#   ./check-installed-versions.sh [--all] [--json]
#
# Options:
#   --all     Show all tools including those not installed
#   --json    Output results in JSON format
#
# Exit codes:
#   0 - All checks completed
#   1 - Error during execution
#
# Note: This script is designed to run inside the container where macOS-specific
#       issues (like grep -P) are not a concern.
#

set -euo pipefail

# Source .env file if it exists (for GITHUB_TOKEN and other config)
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

# Parse command line options
SHOW_ALL=false
OUTPUT_FORMAT="text"

for arg in "$@"; do
    case $arg in
        --all)
            SHOW_ALL=true
            ;;
        --json)
            OUTPUT_FORMAT="json"
            ;;
    esac
done

# Arrays to store results
declare -A INSTALLED_VERSIONS
declare -A LATEST_VERSIONS
declare -A VERSION_STATUS

# ============================================================================
# Helper Functions
# ============================================================================

# Get latest release from GitHub
get_github_release() {
    local repo="$1"
    local tag_pattern="${2:-}"
    local response

    if [ -z "$tag_pattern" ]; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/releases/latest")
        else
            response=$(curl -s "https://api.github.com/repos/${repo}/releases/latest")
        fi
        # Check if we got rate limited
        if echo "$response" | grep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | grep -oP '"tag_name": "\K[^"]+' || echo "unknown"
    else
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/tags")
        else
            response=$(curl -s "https://api.github.com/repos/${repo}/tags")
        fi
        if echo "$response" | grep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | jq -r ".[].name | select(. | test(\"${tag_pattern}\"))" | head -1 || echo "unknown"
    fi
}

# Get PyPI package latest version
get_pypi_version() {
    local package="$1"
    local response
    response=$(curl -s "https://pypi.org/pypi/${package}/json")
    if [ $? -eq 0 ]; then
        echo "$response" | jq -r '.info.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get crates.io package latest version
get_crates_version() {
    local package="$1"
    local response
    response=$(curl -s "https://crates.io/api/v1/crates/${package}")
    if [ $? -eq 0 ]; then
        echo "$response" | jq -r '.crate.max_version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get RubyGems latest version
get_rubygems_version() {
    local gem="$1"
    local response
    response=$(curl -s "https://rubygems.org/api/v1/gems/${gem}.json")
    if [ $? -eq 0 ]; then
        echo "$response" | jq -r '.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get CRAN package latest version
get_cran_version() {
    local package="$1"
    local response
    response=$(curl -s "https://crandb.r-pkg.org/${package}")
    if [ $? -eq 0 ]; then
        echo "$response" | jq -r '.Version // .version // "unknown"' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
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

check_version() {
    local name="$1"
    local command="$2"
    local version_flag="${3:---version}"
    local extract_pattern="${4:-}"
    local latest_getter="${5:-}"
    local latest_args="${6:-}"
    
    if command -v "$command" >/dev/null 2>&1; then
        local version
        if [ -n "$extract_pattern" ]; then
            version=$("$command" "$version_flag" 2>&1 | grep -oP "$extract_pattern" | head -1 || echo "error")
        else
            version=$("$command" "$version_flag" 2>&1 | head -1 || echo "error")
        fi
        
        # Special handling for cargo subcommands that don't report version
        if [ "$version" = "error" ] && [ "$name" = "cargo-outdated" ]; then
            # Check if the command exists by looking for the subcommand
            if $command outdated --help &>/dev/null; then
                version="installed"
            fi
        fi
        
        INSTALLED_VERSIONS["$name"]="$version"
        
        # Get latest version if getter provided
        if [ -n "$latest_getter" ]; then
            local latest
            case "$latest_getter" in
                "github")
                    latest=$(get_github_release "$latest_args")
                    ;;
                "pypi")
                    latest=$(get_pypi_version "$latest_args")
                    ;;
                "crates")
                    latest=$(get_crates_version "$latest_args")
                    ;;
                "rubygems")
                    latest=$(get_rubygems_version "$latest_args")
                    ;;
                "cran")
                    latest=$(get_cran_version "$latest_args")
                    ;;
                *)
                    latest="unknown"
                    ;;
            esac
            LATEST_VERSIONS["$name"]="$latest"
            # Mark as error if version extraction failed
            if [ "$version" = "error" ]; then
                VERSION_STATUS["$name"]="error"
            else
                VERSION_STATUS["$name"]=$(compare_version "$version" "$latest")
            fi
        else
            LATEST_VERSIONS["$name"]="-"
            if [ "$version" = "error" ]; then
                VERSION_STATUS["$name"]="error"
            else
                VERSION_STATUS["$name"]="installed"
            fi
        fi
    else
        INSTALLED_VERSIONS["$name"]="not installed"
        LATEST_VERSIONS["$name"]="-"
        VERSION_STATUS["$name"]="missing"
    fi
}

print_result() {
    local name="$1"
    local installed="$2"
    local latest="$3"
    local status="$4"
    
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        return
    fi
    
    # Skip missing tools unless --all flag is set
    if [ "$status" = "missing" ] && [ "$SHOW_ALL" = false ]; then
        return
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
        "installed")
            status_color="$GREEN"
            status_text="installed"
            ;;
        "error")
            status_color="$RED"
            status_text="error"
            ;;
        "missing")
            status_color="$RED"
            status_text="not installed"
            ;;
        *) 
            status_color="$RED" 
            ;;
    esac
    
    printf "%-25s %-20s %-20s ${status_color}%-12s${NC}\n" "$name" "$installed" "$latest" "$status_text"
}

# ============================================================================
# Version Checks
# ============================================================================

if [ "$OUTPUT_FORMAT" != "json" ]; then
    echo "Checking installed versions in container..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "Using GitHub token for API authentication"
    else
        echo "No GitHub token found. To avoid rate limits, set GITHUB_TOKEN in .env file"
    fi
    echo
    echo "Programming Languages:"
    echo "====================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check languages
check_version "Python" "python" "--version" "Python \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Ruby" "ruby" "--version" "ruby \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Node.js" "node" "--version" "v\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Go" "go" "version" "go\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Rust" "rustc" "--version" "rustc \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Java" "java" "--version" "openjdk \K[0-9]+"
check_version "R" "R" "--version" "R version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Mojo" "mojo" "--version" "mojo \K[0-9]+\.[0-9]+\.[0-9]+"

# Print language results
if [ "$OUTPUT_FORMAT" != "--json" ]; then
    for lang in "Python" "Ruby" "Node.js" "Go" "Rust" "Java" "R" "Mojo"; do
        if [ -n "${INSTALLED_VERSIONS[$lang]:-}" ]; then
            print_result "$lang" "${INSTALLED_VERSIONS[$lang]}" "${INSTALL_STATUS[$lang]}"
        fi
    done
    
    echo
    echo "Package Managers:"
    echo "================="
fi

# Check package managers
check_version "pip" "pip" "--version" "pip \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "pipx" "pipx" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "Poetry" "poetry" "--version" "Poetry.*version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "gem" "gem" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "bundler" "bundle" "--version" "Bundler version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "npm" "npm" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "yarn" "yarn" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "pnpm" "pnpm" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "cargo" "cargo" "--version" "cargo \K[0-9]+\.[0-9]+\.[0-9]+"

# Print package manager results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for pm in "pip" "pipx" "Poetry" "gem" "bundler" "npm" "yarn" "pnpm" "cargo"; do
        if [ -n "${INSTALLED_VERSIONS[$pm]:-}" ]; then
            print_result "$pm" "${INSTALLED_VERSIONS[$pm]}" "${LATEST_VERSIONS[$pm]:-}" "${VERSION_STATUS[$pm]}"
        fi
    done
    
    echo
    echo "Python Development Tools:"
    echo "========================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check Python dev tools
check_version "black" "black" "--version" "black, \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "isort" "isort" "--version 2>&1 | grep 'VERSION'" "VERSION \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "ruff" "ruff" "--version" "ruff \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "flake8" "flake8" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "mypy" "mypy" "--version" "mypy \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "pylint" "pylint" "--version" "pylint \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "pytest" "pytest" "--version" "pytest \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "tox" "tox" "--version 2>&1 | tail -1" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "pre-commit" "pre-commit" "--version" "pre-commit \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "cookiecutter" "cookiecutter" "--version" "Cookiecutter \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "sphinx" "sphinx-build" "--version" "sphinx-build \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "jupyter" "jupyter" "--version 2>&1 | grep 'jupyter_core'" "jupyter_core.*: \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "ipython" "ipython" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "httpie" "http" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "yq" "yq" "--version" "yq \K[0-9]+\.[0-9]+\.[0-9]+"

# Print Python dev tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "black" "isort" "ruff" "flake8" "mypy" "pylint" "pytest" "tox" "pre-commit" "cookiecutter" "sphinx" "jupyter" "ipython" "httpie" "yq"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "Rust Development Tools:"
    echo "======================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check Rust dev tools
check_version "tree-sitter" "tree-sitter" "--version" "tree-sitter \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "tree-sitter-cli"
check_version "cargo-watch" "cargo-watch" "--version" "cargo-watch \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "cargo-watch"
# cargo-edit provides cargo-add command, check version via cargo install --list
check_version "cargo-edit" "cargo" "install --list | grep 'cargo-edit' | head -1" "v\K[0-9]+\.[0-9]+\.[0-9]+" "crates" "cargo-edit"
check_version "cargo-expand" "cargo-expand" "--version" "cargo-expand \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "cargo-expand"
# cargo-outdated is invoked as 'cargo outdated', check version via cargo install --list
check_version "cargo-outdated" "cargo" "install --list | grep 'cargo-outdated' | head -1" "v\K[0-9]+\.[0-9]+\.[0-9]+" "crates" "cargo-outdated"
check_version "bacon" "bacon" "--version" "bacon \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "bacon"
check_version "tokei" "tokei" "--version" "tokei \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "tokei"
check_version "hyperfine" "hyperfine" "--version" "hyperfine \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "hyperfine"
check_version "just" "just" "--version" "just \K[0-9]+\.[0-9]+\.[0-9]+" "github" "casey/just"
check_version "sccache" "sccache" "--version" "sccache \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "sccache"
check_version "mdbook" "mdbook" "--version" "mdbook \K[0-9]+\.[0-9]+\.[0-9]+" "crates" "mdbook"

# Print Rust dev tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "tree-sitter" "cargo-watch" "cargo-edit" "cargo-expand" "cargo-outdated" "bacon" "tokei" "hyperfine" "just" "sccache" "mdbook"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "Ruby Development Tools:"
    echo "======================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check Ruby dev tools
check_version "rspec" "rspec" "--version" "RSpec \K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "rspec"
check_version "rubocop" "rubocop" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "rubocop"
check_version "pry" "pry" "--version" "Pry version \K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "pry"
check_version "yard" "yard" "--version" "yard \K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "yard"
check_version "reek" "reek" "--version" "reek \K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "reek"
check_version "brakeman" "brakeman" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "brakeman"
check_version "rails" "rails" "--version" "Rails \K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "rails"
check_version "solargraph" "solargraph" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+" "rubygems" "solargraph"

# Print Ruby dev tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "rspec" "rubocop" "pry" "yard" "reek" "brakeman" "rails" "solargraph"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "R Development Tools:"
    echo "===================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check R dev tools - using Rscript to check package versions
check_r_package() {
    local name="$1"
    local package="$2"
    
    if command -v Rscript >/dev/null 2>&1; then
        local version
        version=$(Rscript -e "if(requireNamespace('$package', quietly = TRUE)) cat(as.character(packageVersion('$package'))) else cat('not installed')" 2>/dev/null || echo "error")
        INSTALLED_VERSIONS["$name"]="$version"
        
        if [ "$version" != "not installed" ] && [ "$version" != "error" ]; then
            local latest
            latest=$(get_cran_version "$package")
            LATEST_VERSIONS["$name"]="$latest"
            if [ "$version" = "$latest" ]; then
                VERSION_STATUS["$name"]="up-to-date"
            elif [ "$latest" = "unknown" ]; then
                VERSION_STATUS["$name"]="installed"
            else
                VERSION_STATUS["$name"]="outdated"
            fi
        else
            LATEST_VERSIONS["$name"]="-"
            VERSION_STATUS["$name"]="missing"
        fi
    else
        INSTALLED_VERSIONS["$name"]="R not installed"
        LATEST_VERSIONS["$name"]="-"
        VERSION_STATUS["$name"]="missing"
    fi
}

# Check R development packages
check_r_package "devtools" "devtools"
check_r_package "tidyverse" "tidyverse"
check_r_package "testthat" "testthat"
check_r_package "roxygen2" "roxygen2"
check_r_package "usethis" "usethis"
check_r_package "rmarkdown" "rmarkdown"
check_r_package "knitr" "knitr"
check_r_package "shiny" "shiny"
check_r_package "plumber" "plumber"
check_r_package "lintr" "lintr"
check_r_package "styler" "styler"
check_r_package "profvis" "profvis"
check_r_package "renv" "renv"

# Print R dev tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "devtools" "tidyverse" "testthat" "roxygen2" "usethis" "rmarkdown" "knitr" "shiny" "plumber" "lintr" "styler" "profvis" "renv"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "Development Tools:"
    echo "=================="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check dev tools
check_version "git" "git" "--version" "git version \K[0-9]+\.[0-9]+\.[0-9]+" "github" "git/git"
check_version "gh" "gh" "--version" "gh version \K[0-9]+\.[0-9]+\.[0-9]+" "github" "cli/cli"
check_version "glab" "glab" "--version" "glab version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "docker" "docker" "--version" "Docker version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "docker-compose" "docker-compose" "--version" "docker-compose version \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "direnv" "direnv" "version" "\K[0-9]+\.[0-9]+\.[0-9]+" "github" "direnv/direnv"
check_version "lazygit" "lazygit" "--version" "version=\K[0-9]+\.[0-9]+\.[0-9]+" "github" "jesseduffield/lazygit"
check_version "delta" "delta" "--version" "delta \K[0-9]+\.[0-9]+\.[0-9]+" "github" "dandavison/delta"
check_version "mkcert" "mkcert" "--version" "v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "FiloSottile/mkcert"
check_version "act" "act" "--version" "act version \K[0-9]+\.[0-9]+\.[0-9]+" "github" "nektos/act"
check_version "fzf" "fzf" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+" "github" "junegunn/fzf"
check_version "ripgrep" "rg" "--version" "ripgrep \K[0-9]+\.[0-9]+\.[0-9]+" "github" "BurntSushi/ripgrep"
check_version "fd" "fd" "--version" "fd \K[0-9]+\.[0-9]+\.[0-9]+" "github" "sharkdp/fd"
check_version "bat" "bat" "--version" "bat \K[0-9]+\.[0-9]+\.[0-9]+" "github" "sharkdp/bat"
check_version "eza" "eza" "--version" "v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "eza-community/eza"
check_version "exa" "exa" "--version" "v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "ogham/exa"
check_version "op" "op" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+" "github" "1Password/op"

# Print dev tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "git" "gh" "glab" "docker" "docker-compose" "direnv" "lazygit" "delta" "mkcert" "act" "fzf" "ripgrep" "fd" "bat" "eza" "exa" "op"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "Cloud Tools:"
    echo "============"
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check cloud tools
check_version "kubectl" "kubectl" "version --client" "Client Version: v\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "k9s" "k9s" "version" "Version:\s*v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "derailed/k9s"
check_version "krew" "kubectl-krew" "version" "GitTag:\"v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "kubernetes-sigs/krew"
check_version "helm" "helm" "version" "Version:\"v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "helm/helm"
check_version "terraform" "terraform" "version" "Terraform v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "hashicorp/terraform"
check_version "terragrunt" "terragrunt" "--version" "terragrunt version v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "gruntwork-io/terragrunt"
check_version "terraform-docs" "terraform-docs" "--version" "terraform-docs version v\K[0-9]+\.[0-9]+\.[0-9]+" "github" "terraform-docs/terraform-docs"
check_version "aws" "aws" "--version" "aws-cli/\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "gcloud" "gcloud" "--version" "Google Cloud SDK \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "az" "az" "--version" "azure-cli.*\K[0-9]+\.[0-9]+\.[0-9]+"
check_version "wrangler" "wrangler" "--version" "wrangler \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "ollama" "ollama" "--version" "ollama version is \K[0-9]+\.[0-9]+\.[0-9]+" "github" "ollama/ollama"

# Print cloud tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "kubectl" "k9s" "krew" "helm" "terraform" "terragrunt" "terraform-docs" "aws" "gcloud" "az" "wrangler" "ollama"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
    
    echo
    echo "Database Tools:"
    echo "==============="
    printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
    printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"
fi

# Check database tools
check_version "psql" "psql" "--version" "psql \(PostgreSQL\) \K[0-9]+\.[0-9]+"
check_version "redis-cli" "redis-cli" "--version" "redis-cli \K[0-9]+\.[0-9]+\.[0-9]+"
check_version "sqlite3" "sqlite3" "--version" "\K[0-9]+\.[0-9]+\.[0-9]+"

# Print database tools results
if [ "$OUTPUT_FORMAT" != "json" ]; then
    for tool in "psql" "redis-cli" "sqlite3"; do
        if [ -n "${INSTALLED_VERSIONS[$tool]:-}" ]; then
            print_result "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
        fi
    done
fi

# ============================================================================
# Output Results
# ============================================================================

if [ "$OUTPUT_FORMAT" = "json" ]; then
    # JSON output
    echo "{"
    echo '  "results": ['
    first=true
    for tool in "${!INSTALLED_VERSIONS[@]}"; do
        # Skip missing tools unless --all flag is set
        if [ "${VERSION_STATUS[$tool]}" = "missing" ] && [ "$SHOW_ALL" = false ]; then
            continue
        fi
        
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        printf '    {"tool": "%s", "installed": "%s", "latest": "%s", "status": "%s"}' \
            "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "${VERSION_STATUS[$tool]}"
    done
    echo
    echo "  ]"
    echo "}"
else
    # Summary
    echo
    echo "Summary:"
    installed_count=0
    missing_count=0
    outdated_count=0
    uptodate_count=0
    newer_count=0
    unknown_count=0
    total_count=0
    
    for tool in "${!VERSION_STATUS[@]}"; do
        ((total_count++))
        case "${VERSION_STATUS[$tool]}" in
            "installed") ((installed_count++)) ;;
            "missing") ((missing_count++)) ;;
            "outdated") ((outdated_count++)) ;;
            "up-to-date") ((uptodate_count++)) ;;
            "newer") ((newer_count++)) ;;
            *) ((unknown_count++)) ;;
        esac
    done
    
    echo -e "  Total tools checked: ${total_count}"
    
    if [ "$SHOW_ALL" = true ]; then
        echo -e "  Installed: ${GREEN}${installed_count}${NC}"
        echo -e "  Missing: ${RED}${missing_count}${NC}"
    else
        echo -e "  Showing only installed tools (use --all to see missing tools)"
    fi
    
    echo -e "  Up-to-date: ${GREEN}${uptodate_count}${NC}"
    echo -e "  Newer: ${BLUE}${newer_count}${NC}"
    echo -e "  Outdated: ${YELLOW}${outdated_count}${NC}"
    echo -e "  Unknown: ${RED}${unknown_count}${NC}"
    
    if [ $outdated_count -gt 0 ]; then
        echo
        echo "Note: Some tools have newer versions available."
        echo "Consider updating your container build to get the latest versions."
    fi
    
    # Check if any rate limiting occurred
    if printf '%s\n' "${LATEST_VERSIONS[@]}" | grep -q "rate-limited"; then
        echo
        echo -e "${YELLOW}Warning: GitHub API rate limit exceeded.${NC}"
        echo "Some version checks could not be completed."
        echo "To avoid rate limits, you can:"
        echo "  - Wait an hour for the rate limit to reset"
        echo "  - Use an authenticated GitHub token: export GITHUB_TOKEN=your_token"
    fi
fi

exit 0