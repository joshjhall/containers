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
            response=$(command curl -sf -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/releases/latest")
        else
            response=$(command curl -sf "https://api.github.com/repos/${repo}/releases/latest")
        fi
        # Check if we got rate limited
        if echo "$response" | _vapi_grep -q "rate limit exceeded"; then
            echo "rate-limited"
            return
        fi
        echo "$response" | _vapi_grep -oP '"tag_name": "\K[^"]+' || echo "unknown"
    else
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(command curl -sf -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${repo}/tags")
        else
            response=$(command curl -sf "https://api.github.com/repos/${repo}/tags")
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
    if response=$(command curl -sf "https://pypi.org/pypi/${package}/json"); then
        echo "$response" | jq -r '.info.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get crates.io package latest version
get_crates_version() {
    local package="$1"
    local response
    if response=$(command curl -sf "https://crates.io/api/v1/crates/${package}"); then
        echo "$response" | jq -r '.crate.max_version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get RubyGems latest version
get_rubygems_version() {
    local gem="$1"
    local response
    if response=$(command curl -sf "https://rubygems.org/api/v1/gems/${gem}.json"); then
        echo "$response" | jq -r '.version' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get CRAN package latest version
get_cran_version() {
    local package="$1"
    local response
    if response=$(command curl -sf "https://crandb.r-pkg.org/${package}"); then
        echo "$response" | jq -r '.Version // .version // "unknown"' 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get latest Python version
get_latest_python() {
    # Use Python's official JSON API endpoint
    command curl -sf https://endoflife.date/api/python.json | jq -r '.[] | select(.latest) | .latest' | command head -1 || echo "unknown"
}

# Get latest Ruby version
get_latest_ruby() {
    local response
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        response=$(command curl -sf -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/ruby/ruby/releases)
    else
        response=$(command curl -sf https://api.github.com/repos/ruby/ruby/releases)
    fi

    if echo "$response" | _vapi_grep -q "rate limit exceeded"; then
        echo "rate-limited"
        return
    fi
    echo "$response" | jq -r '.[].tag_name | select(startswith("v"))' | command head -1 | command sed 's/^v//' | command tr '_' '.' || echo "unknown"
}

# Get latest Node.js LTS version
get_latest_node() {
    command curl -sf https://nodejs.org/dist/index.json | jq -r '.[] | select(.lts != false) | .version' | command head -1 | command sed 's/^v//' | command cut -d. -f1 || echo "unknown"
}

# Get latest Go version
get_latest_go() {
    command curl -sf https://go.dev/VERSION?m=text | command head -1 | command sed 's/^go//' || echo "unknown"
}

# Get latest Rust stable version
get_latest_rust() {
    # Try to get the latest stable version from the Rust release API
    local version
    version=$(command curl -sf https://api.github.com/repos/rust-lang/rust/releases | jq -r '.[] | select(.prerelease == false) | .tag_name' | command head -1 | command sed 's/^v//')

    if [ -n "$version" ] && [ "$version" != "null" ]; then
        echo "$version"
    else
        # Fallback: try forge.rust-lang.org
        version=$(command curl -sf https://forge.rust-lang.org/infra/channel-layout.html | _vapi_grep -oP 'stable.*?rustc \K[0-9]+\.[0-9]+\.[0-9]+' | command head -1)
        if [ -n "$version" ]; then
            echo "$version"
        else
            echo "unknown"
        fi
    fi
}

# Get latest Java LTS version
get_latest_java_lts() {
    # Query Adoptium for available LTS releases, pick the highest
    local lts
    lts=$(command curl -sf "https://api.adoptium.net/v3/info/available_releases" |
        jq -r '.available_lts_releases | command sort | last' 2>/dev/null)
    if [ -n "$lts" ] && [ "$lts" != "null" ]; then
        echo "$lts"
    else
        echo "unknown"
    fi
}

# Get latest Mojo version
get_latest_mojo() {
    # Mojo versions track the modular package on PyPI
    get_pypi_version "modular"
}

# Extract version from script
extract_version() {
    local file="$1"
    local pattern="$2"
    _vapi_grep -oP "${pattern}" "$file" | command head -1 || echo "not found"
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
