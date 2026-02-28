#!/usr/bin/env bash
# Shared version API functions for runtime check scripts
#
# Provides package registry query functions used by both
# check-installed-versions.sh and check-versions.sh.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/version-api.sh"

set -euo pipefail

# Use GNU grep (ggrep on macOS, grep on Linux)
_vapi_grep() {
    if command -v ggrep &>/dev/null; then
        ggrep "$@"
    else
        command grep "$@"
    fi
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
        if echo "$response" | _vapi_grep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | _vapi_grep -oP '"tag_name": "\K[^"]+' || echo "unknown"
    else
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(command curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/tags")
        else
            response=$(command curl -s "https://api.github.com/repos/${repo}/tags")
        fi
        if echo "$response" | _vapi_grep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | jq -r ".[].name | select(. | test(\"${tag_pattern}\"))" | command head -1 || echo "unknown"
    fi
}

# Get PyPI package latest version
get_pypi_version() {
    local package="$1"
    local response
    if response=$(command curl -s "https://pypi.org/pypi/${package}/json"); then
        echo "$response" | jq -r '.info.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get crates.io package latest version
get_crates_version() {
    local package="$1"
    local response
    if response=$(command curl -s "https://crates.io/api/v1/crates/${package}"); then
        echo "$response" | jq -r '.crate.max_version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get RubyGems latest version
get_rubygems_version() {
    local gem="$1"
    local response
    if response=$(command curl -s "https://rubygems.org/api/v1/gems/${gem}.json"); then
        echo "$response" | jq -r '.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get CRAN package latest version
get_cran_version() {
    local package="$1"
    local response
    if response=$(command curl -s "https://crandb.r-pkg.org/${package}"); then
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
            sorted=$(printf "%s\n%s" "$current" "$latest" | command sort -V | command tail -1)
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
