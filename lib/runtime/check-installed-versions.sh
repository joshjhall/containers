#!/usr/bin/env bash
# Check Installed Versions - Compare installed tools with latest stable versions
#
# Description:
#   Checks what tools are actually installed in the container and compares
#   their versions with the latest stable versions available. By default,
#   only shows installed tools. Use --all to see all tools including missing ones.
#
# Usage:
#   ./check-installed-versions.sh [OPTIONS]
#
# Options:
#   --all                  Show all tools including those not installed
#   --json                 Output results in JSON format
#   --filter <category>    Filter by category (language, dev-tool, cloud, database, tool)
#   --compare              Only show tools with version differences (outdated or newer)
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
FILTER_CATEGORY=""
COMPARE_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            SHOW_ALL=true
            shift
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --filter)
            FILTER_CATEGORY="$2"
            shift 2
            ;;
        --compare)
            COMPARE_MODE=true
            shift
            ;;
        --help|-h)
            command head -n 20 "$0" | command grep "^#" | command sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
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

# Check if section should be displayed based on filter
should_display_section() {
    local section="$1"

    # If no filter, show everything
    [ -z "$FILTER_CATEGORY" ] && return 0

    # Map filter categories to sections
    case "$FILTER_CATEGORY" in
        language)
            [[ "$section" == "Programming Languages" ]]
            ;;
        dev-tool)
            [[ "$section" =~ "Development Tools" ]]
            ;;
        cloud)
            [[ "$section" == "Cloud Tools" ]]
            ;;
        database)
            [[ "$section" == "Database Tools" ]]
            ;;
        tool)
            [[ "$section" == "Development Tools" || "$section" == "Cloud Tools" || "$section" == "Database Tools" ]]
            ;;
        *)
            return 0
            ;;
    esac
}

# Source shared version API functions
# shellcheck source=lib/runtime/lib/version-api.sh
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_script_dir}/lib/version-api.sh"

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
            version=$("$command" "$version_flag" 2>&1 | command grep -oP "$extract_pattern" | command head -1 || echo "error")
        else
            version=$("$command" "$version_flag" 2>&1 | command head -1 || echo "error")
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

    # In compare mode, only show tools with version differences
    if [ "$COMPARE_MODE" = true ]; then
        if [ "$status" != "outdated" ] && [ "$status" != "newer" ]; then
            return
        fi
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

# Run a section: check versions and print results for a list of tools.
# Each entry in the tools array is: "name:cmd:flag:pattern[:getter[:getter_args]]"
# Arguments:
#   $1 - Section display name (e.g., "Programming Languages")
#   $2 - Section filter name for should_display_section (same as $1 typically)
#   $@ - Remaining args are tool entries
run_section() {
    local section_name="$1"
    local section_filter="$2"
    shift 2

    local tools=("$@")
    local tool_names=()

    # Check all tools
    for entry in "${tools[@]}"; do
        IFS=':' read -r name cmd flag pattern getter getter_args <<< "$entry"
        check_version "$name" "$cmd" "$flag" "$pattern" "${getter:-}" "${getter_args:-}"
        tool_names+=("$name")
    done

    # Print section header and results
    if [ "$OUTPUT_FORMAT" != "json" ] && should_display_section "$section_filter"; then
        echo "$section_name:"
        printf '%0.s=' $(seq 1 ${#section_name})
        echo
        printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
        printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"

        for name in "${tool_names[@]}"; do
            if [ -n "${INSTALLED_VERSIONS[$name]:-}" ]; then
                print_result "$name" "${INSTALLED_VERSIONS[$name]}" "${LATEST_VERSIONS[$name]:-}" "${VERSION_STATUS[$name]}"
            fi
        done
        echo
    fi
}

# Run a section for R packages using check_r_package instead of check_version.
# Each entry is: "name:package"
run_r_section() {
    local section_name="$1"
    local section_filter="$2"
    shift 2

    local tools=("$@")
    local tool_names=()

    for entry in "${tools[@]}"; do
        IFS=':' read -r name package <<< "$entry"
        check_r_package "$name" "$package"
        tool_names+=("$name")
    done

    if [ "$OUTPUT_FORMAT" != "json" ] && should_display_section "$section_filter"; then
        echo "$section_name:"
        printf '%0.s=' $(seq 1 ${#section_name})
        echo
        printf "%-25s %-20s %-20s %-12s\n" "TOOL" "INSTALLED" "LATEST" "STATUS"
        printf "%-25s %-20s %-20s %-12s\n" "----" "---------" "------" "------"

        for name in "${tool_names[@]}"; do
            if [ -n "${INSTALLED_VERSIONS[$name]:-}" ]; then
                print_result "$name" "${INSTALLED_VERSIONS[$name]}" "${LATEST_VERSIONS[$name]:-}" "${VERSION_STATUS[$name]}"
            fi
        done
        echo
    fi
}

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
    if [ "$COMPARE_MODE" = true ]; then
        echo "Compare mode: Showing only tools with version differences"
    fi
    echo
fi

# --- Programming Languages ---
run_section "Programming Languages" "Programming Languages" \
    "Python:python:--version:Python \K[0-9]+\.[0-9]+\.[0-9]+" \
    "Ruby:ruby:--version:ruby \K[0-9]+\.[0-9]+\.[0-9]+" \
    "Node.js:node:--version:v\K[0-9]+\.[0-9]+\.[0-9]+" \
    "Go:go:version:go\K[0-9]+\.[0-9]+\.[0-9]+" \
    "Rust:rustc:--version:rustc \K[0-9]+\.[0-9]+\.[0-9]+" \
    "Java:java:--version:openjdk \K[0-9]+" \
    "R:R:--version:R version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "Mojo:mojo:--version:mojo \K[0-9]+\.[0-9]+\.[0-9]+"

# --- Package Managers ---
run_section "Package Managers" "Programming Languages" \
    "pip:pip:--version:pip \K[0-9]+\.[0-9]+\.[0-9]+" \
    "pipx:pipx:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "Poetry:poetry:--version:Poetry.*version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "gem:gem:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "bundler:bundle:--version:Bundler version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "npm:npm:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "yarn:yarn:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "pnpm:pnpm:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "cargo:cargo:--version:cargo \K[0-9]+\.[0-9]+\.[0-9]+"

# --- Python Development Tools ---
run_section "Python Development Tools" "Development Tools" \
    "black:black:--version:black, \K[0-9]+\.[0-9]+\.[0-9]+" \
    "isort:isort:--version 2>&1 | command grep 'VERSION':VERSION \K[0-9]+\.[0-9]+\.[0-9]+" \
    "ruff:ruff:--version:ruff \K[0-9]+\.[0-9]+\.[0-9]+" \
    "flake8:flake8:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "mypy:mypy:--version:mypy \K[0-9]+\.[0-9]+\.[0-9]+" \
    "pylint:pylint:--version:pylint \K[0-9]+\.[0-9]+\.[0-9]+" \
    "pytest:pytest:--version:pytest \K[0-9]+\.[0-9]+\.[0-9]+" \
    "tox:tox:--version 2>&1 | command tail -1:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "pre-commit:pre-commit:--version:pre-commit \K[0-9]+\.[0-9]+\.[0-9]+" \
    "cookiecutter:cookiecutter:--version:Cookiecutter \K[0-9]+\.[0-9]+\.[0-9]+" \
    "sphinx:sphinx-build:--version:sphinx-build \K[0-9]+\.[0-9]+\.[0-9]+" \
    "jupyter:jupyter:--version 2>&1 | command grep 'jupyter_core':jupyter_core.*: \K[0-9]+\.[0-9]+\.[0-9]+" \
    "ipython:ipython:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "httpie:http:--version:\K[0-9]+\.[0-9]+\.[0-9]+" \
    "yq:yq:--version:yq \K[0-9]+\.[0-9]+\.[0-9]+"

# --- Rust Development Tools ---
run_section "Rust Development Tools" "Development Tools" \
    "tree-sitter:tree-sitter:--version:tree-sitter \K[0-9]+\.[0-9]+\.[0-9]+:crates:tree-sitter-cli" \
    "cargo-watch:cargo-watch:--version:cargo-watch \K[0-9]+\.[0-9]+\.[0-9]+:crates:cargo-watch" \
    "cargo-edit:cargo:install --list | command grep 'cargo-edit' | command head -1:v\K[0-9]+\.[0-9]+\.[0-9]+:crates:cargo-edit" \
    "cargo-expand:cargo-expand:--version:cargo-expand \K[0-9]+\.[0-9]+\.[0-9]+:crates:cargo-expand" \
    "cargo-outdated:cargo:install --list | command grep 'cargo-outdated' | command head -1:v\K[0-9]+\.[0-9]+\.[0-9]+:crates:cargo-outdated" \
    "bacon:bacon:--version:bacon \K[0-9]+\.[0-9]+\.[0-9]+:crates:bacon" \
    "tokei:tokei:--version:tokei \K[0-9]+\.[0-9]+\.[0-9]+:crates:tokei" \
    "hyperfine:hyperfine:--version:hyperfine \K[0-9]+\.[0-9]+\.[0-9]+:crates:hyperfine" \
    "just:just:--version:just \K[0-9]+\.[0-9]+\.[0-9]+:github:casey/just" \
    "sccache:sccache:--version:sccache \K[0-9]+\.[0-9]+\.[0-9]+:crates:sccache" \
    "mdbook:mdbook:--version:mdbook \K[0-9]+\.[0-9]+\.[0-9]+:crates:mdbook"

# --- Ruby Development Tools ---
run_section "Ruby Development Tools" "Development Tools" \
    "rspec:rspec:--version:RSpec \K[0-9]+\.[0-9]+\.[0-9]+:rubygems:rspec" \
    "rubocop:rubocop:--version:\K[0-9]+\.[0-9]+\.[0-9]+:rubygems:rubocop" \
    "pry:pry:--version:Pry version \K[0-9]+\.[0-9]+\.[0-9]+:rubygems:pry" \
    "yard:yard:--version:yard \K[0-9]+\.[0-9]+\.[0-9]+:rubygems:yard" \
    "reek:reek:--version:reek \K[0-9]+\.[0-9]+\.[0-9]+:rubygems:reek" \
    "brakeman:brakeman:--version:\K[0-9]+\.[0-9]+\.[0-9]+:rubygems:brakeman" \
    "rails:rails:--version:Rails \K[0-9]+\.[0-9]+\.[0-9]+:rubygems:rails" \
    "solargraph:solargraph:--version:\K[0-9]+\.[0-9]+\.[0-9]+:rubygems:solargraph"

# --- R Development Tools ---
run_r_section "R Development Tools" "Development Tools" \
    "devtools:devtools" \
    "tidyverse:tidyverse" \
    "testthat:testthat" \
    "roxygen2:roxygen2" \
    "usethis:usethis" \
    "rmarkdown:rmarkdown" \
    "knitr:knitr" \
    "shiny:shiny" \
    "plumber:plumber" \
    "lintr:lintr" \
    "styler:styler" \
    "profvis:profvis" \
    "renv:renv"

# --- Development Tools ---
run_section "Development Tools" "Development Tools" \
    "git:git:--version:git version \K[0-9]+\.[0-9]+\.[0-9]+:github:git/git" \
    "gh:gh:--version:gh version \K[0-9]+\.[0-9]+\.[0-9]+:github:cli/cli" \
    "glab:glab:--version:glab version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "docker:docker:--version:Docker version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "docker-compose:docker-compose:--version:docker-compose version \K[0-9]+\.[0-9]+\.[0-9]+" \
    "direnv:direnv:version:\K[0-9]+\.[0-9]+\.[0-9]+:github:direnv/direnv" \
    "lazygit:lazygit:--version:version=\K[0-9]+\.[0-9]+\.[0-9]+:github:jesseduffield/lazygit" \
    "delta:delta:--version:delta \K[0-9]+\.[0-9]+\.[0-9]+:github:dandavison/delta" \
    "mkcert:mkcert:--version:v\K[0-9]+\.[0-9]+\.[0-9]+:github:FiloSottile/mkcert" \
    "act:act:--version:act version \K[0-9]+\.[0-9]+\.[0-9]+:github:nektos/act" \
    "fzf:fzf:--version:\K[0-9]+\.[0-9]+\.[0-9]+:github:junegunn/fzf" \
    "ripgrep:rg:--version:ripgrep \K[0-9]+\.[0-9]+\.[0-9]+:github:BurntSushi/ripgrep" \
    "fd:fd:--version:fd \K[0-9]+\.[0-9]+\.[0-9]+:github:sharkdp/fd" \
    "bat:bat:--version:bat \K[0-9]+\.[0-9]+\.[0-9]+:github:sharkdp/bat" \
    "eza:eza:--version:v\K[0-9]+\.[0-9]+\.[0-9]+:github:eza-community/eza" \
    "exa:exa:--version:v\K[0-9]+\.[0-9]+\.[0-9]+:github:ogham/exa" \
    "op:op:--version:\K[0-9]+\.[0-9]+\.[0-9]+:github:1Password/op"

# --- Cloud Tools ---
run_section "Cloud Tools" "Cloud Tools" \
    "kubectl:kubectl:version --client:Client Version: v\K[0-9]+\.[0-9]+\.[0-9]+" \
    "k9s:k9s:version:Version:\s*v\K[0-9]+\.[0-9]+\.[0-9]+:github:derailed/k9s" \
    "krew:kubectl-krew:version:GitTag:\"v\K[0-9]+\.[0-9]+\.[0-9]+:github:kubernetes-sigs/krew" \
    "helm:helm:version:Version:\"v\K[0-9]+\.[0-9]+\.[0-9]+:github:helm/helm" \
    "terraform:terraform:version:Terraform v\K[0-9]+\.[0-9]+\.[0-9]+:github:hashicorp/terraform" \
    "terragrunt:terragrunt:--version:terragrunt version v\K[0-9]+\.[0-9]+\.[0-9]+:github:gruntwork-io/terragrunt" \
    "terraform-docs:terraform-docs:--version:terraform-docs version v\K[0-9]+\.[0-9]+\.[0-9]+:github:terraform-docs/terraform-docs" \
    "aws:aws:--version:aws-cli/\K[0-9]+\.[0-9]+\.[0-9]+" \
    "gcloud:gcloud:--version:Google Cloud SDK \K[0-9]+\.[0-9]+\.[0-9]+" \
    "az:az:--version:azure-cli.*\K[0-9]+\.[0-9]+\.[0-9]+" \
    "wrangler:wrangler:--version:wrangler \K[0-9]+\.[0-9]+\.[0-9]+" \
    "ollama:ollama:--version:ollama version is \K[0-9]+\.[0-9]+\.[0-9]+:github:ollama/ollama"

# --- Database Tools ---
run_section "Database Tools" "Database Tools" \
    "psql:psql:--version:psql \(PostgreSQL\) \K[0-9]+\.[0-9]+" \
    "redis-cli:redis-cli:--version:redis-cli \K[0-9]+\.[0-9]+\.[0-9]+" \
    "sqlite3:sqlite3:--version:\K[0-9]+\.[0-9]+\.[0-9]+"

# ============================================================================
# Output Results
# ============================================================================

if [ "$OUTPUT_FORMAT" = "json" ]; then
    # JSON output
    echo "{"
    echo '  "results": ['
    first=true
    for tool in "${!INSTALLED_VERSIONS[@]}"; do
        tool_status="${VERSION_STATUS[$tool]}"

        # Skip missing tools unless --all flag is set
        if [ "$tool_status" = "missing" ] && [ "$SHOW_ALL" = false ]; then
            continue
        fi

        # In compare mode, only show tools with version differences
        if [ "$COMPARE_MODE" = true ]; then
            if [ "$tool_status" != "outdated" ] && [ "$tool_status" != "newer" ]; then
                continue
            fi
        fi

        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        printf '    {"tool": "%s", "installed": "%s", "latest": "%s", "status": "%s"}' \
            "$tool" "${INSTALLED_VERSIONS[$tool]}" "${LATEST_VERSIONS[$tool]:-}" "$tool_status"
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
    if printf '%s\n' "${LATEST_VERSIONS[@]}" | command grep -q "rate-limited"; then
        echo
        echo -e "${YELLOW}Warning: GitHub API rate limit exceeded.${NC}"
        echo "Some version checks could not be completed."
        echo "To avoid rate limits, you can:"
        echo "  - Wait an hour for the rate limit to reset"
        echo "  - Use an authenticated GitHub token: export GITHUB_TOKEN=your_token"
    fi
fi

exit 0
