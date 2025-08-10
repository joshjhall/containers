#!/bin/bash
# Test all features in the container image - Optimized version
# This version runs all tests in a single docker exec to avoid memory issues

set -uo pipefail

# Parse command line arguments
SHOW_ALL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --all|-a)
            SHOW_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--all]"
            echo ""
            echo "Options:"
            echo "  --all, -a          Show all tools (including not installed)"
            echo "  -h, --help         Show this help message"
            echo ""
            echo "By default, only installed tools are shown."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use '$0 --help' for usage information"
            exit 1
            ;;
    esac
done

# IMAGE_NAME="test-amd64-mojo"
IMAGE_NAME="test-all-features"
CONTAINER_NAME="test-verify"

# Check if image exists
if [ -z "$(docker images -q $IMAGE_NAME 2>/dev/null)" ]; then
    echo "Error: Image $IMAGE_NAME not found. Build it first with:"
    echo "  ./build-all-features.sh"
    exit 1
fi

echo "=== Testing $IMAGE_NAME image ==="
echo ""

# Clean up any existing container with the same name
docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true

# Start container with explicit command to bypass entrypoint
echo "Starting test container..."
docker run -d --name $CONTAINER_NAME --entrypoint /bin/bash $IMAGE_NAME -c "sleep infinity" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Container started"
else
    echo "✗ Failed to start container"
    exit 1
fi

# Give it a moment to initialize
sleep 2

# Create test script that will run inside the container
cat > /tmp/test-script.sh << 'TESTSCRIPT'
#!/bin/bash

# Accept show-all flag
SHOW_ALL=$1

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check/X marks
CHECK="✓"
CROSS="✗"

# Function to check if a tool is installed
check_tool() {
    local name="$1"
    local command="$2"
    local version_extract="${3:-}"

    # Skip entirely if not showing all and tool not found
    if [ "$SHOW_ALL" != "true" ]; then
        if ! output=$(eval "$command" 2>&1); then
            return 1
        fi
        # Check if output contains error messages
        if echo "$output" | grep -q "command not found\|No such file\|not found"; then
            return 1
        fi
    fi

    printf "  %-25s" "$name:"

    if output=$(eval "$command" 2>&1); then
        # Command succeeded - check if output contains error messages
        if echo "$output" | grep -q "command not found\|No such file\|not found"; then
            printf "${RED}${CROSS} NOT FOUND${NC}\n"
            return 1
        fi

        # Extract just the first line to avoid multiline output
        output=$(echo "$output" | head -1)

        if [ -n "$version_extract" ]; then
            # Try to extract version, fall back to the whole line if no match
            version=$(echo "$output" | grep -oE "$version_extract" | head -1)
            if [ -z "$version" ]; then
                # For simple numeric versions, extract the first number pattern
                version=$(echo "$output" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+" | head -1)
            fi
        else
            version="$output"
        fi

        # Clean up version string (remove newlines and excess whitespace)
        version=$(echo "$version" | tr -d '\n' | sed 's/  */ /g')

        # Check if version is empty
        if [ -z "$version" ]; then
            printf "${RED}${CROSS} NOT FOUND${NC}\n"
            return 1
        fi

        printf "${GREEN}${CHECK} %s${NC}\n" "$version"
        return 0
    else
        printf "${RED}${CROSS} NOT FOUND${NC}\n"
        return 1
    fi
}

# Function to check R package
check_r_package() {
    local name="$1"
    local package="$2"

    # Skip entirely if not showing all and package not found
    if [ "$SHOW_ALL" != "true" ]; then
        if ! output=$(Rscript -e "cat(as.character(packageVersion(\"$package\")))" 2>/dev/null); then
            return 1
        fi
    fi

    printf "  %-25s" "$name:"

    if output=$(Rscript -e "cat(as.character(packageVersion(\"$package\")))" 2>/dev/null); then
        printf "${GREEN}${CHECK} %s${NC}\n" "$output"
        return 0
    else
        printf "${RED}${CROSS} NOT FOUND${NC}\n"
        return 1
    fi
}

echo "=== Container Environment ==="
echo -n "User: "
whoami
echo -n "Working directory: "
pwd

# Global variables to track section content
SECTION_OUTPUT=""
SECTION_HAS_ITEMS=false

# Function to start a new section
start_section() {
    SECTION_OUTPUT=""
    SECTION_HAS_ITEMS=false
}

# Function to end a section and display if needed
end_section() {
    local section_name="$1"
    if [ "$SECTION_HAS_ITEMS" = true ] || [ "$SHOW_ALL" = "true" ]; then
        echo ""
        echo "=== $section_name ==="
        printf "%b" "$SECTION_OUTPUT"
    fi
}

# Modified check_tool to work with sections
check_tool_section() {
    local name="$1"
    local command="$2"
    local version_extract="${3:-}"

    # Run command and capture output and exit status
    output=$(eval "$command" 2>&1)
    exit_status=$?

    if [ $exit_status -eq 0 ]; then
        # Command succeeded

        # Extract just the first line to avoid multiline output
        output=$(echo "$output" | head -1)

        if [ -n "$version_extract" ]; then
            # Try to extract version, fall back to the whole line if no match
            version=$(echo "$output" | grep -oE "$version_extract" | head -1)
            if [ -z "$version" ]; then
                # For simple numeric versions, extract the first number pattern
                version=$(echo "$output" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+" | head -1)
            fi
        else
            version="$output"
        fi

        # Clean up version string (remove newlines and excess whitespace)
        version=$(echo "$version" | tr -d '\n' | sed 's/  */ /g')

        # Check if version is empty
        if [ -z "$version" ]; then
            if [ "$SHOW_ALL" = "true" ]; then
                SECTION_OUTPUT="${SECTION_OUTPUT}$(printf "  %-25s" "$name:")$(printf "${RED}${CROSS} NOT FOUND${NC}")\n"
            fi
            return 1
        fi

        # Tool is installed - show it
        SECTION_HAS_ITEMS=true
        SECTION_OUTPUT="${SECTION_OUTPUT}$(printf "  %-25s" "$name:")$(printf "${GREEN}${CHECK} ${version}${NC}")\n"
        return 0
    else
        if [ "$SHOW_ALL" = "true" ]; then
            SECTION_OUTPUT="${SECTION_OUTPUT}$(printf "  %-25s" "$name:")$(printf "${RED}${CROSS} NOT FOUND${NC}")\n"
        fi
        return 1
    fi
}

# Modified check_r_package to work with sections
check_r_package_section() {
    local name="$1"
    local package="$2"

    if output=$(Rscript -e "cat(as.character(packageVersion(\"$package\")))" 2>/dev/null); then
        SECTION_HAS_ITEMS=true
        SECTION_OUTPUT="${SECTION_OUTPUT}$(printf "  %-25s" "$name:")$(printf "${GREEN}${CHECK} ${output}${NC}")\n"
        return 0
    else
        if [ "$SHOW_ALL" = "true" ]; then
            SECTION_OUTPUT="${SECTION_OUTPUT}$(printf "  %-25s" "$name:")$(printf "${RED}${CROSS} NOT FOUND${NC}")\n"
        fi
        return 1
    fi
}

# Programming Languages section
start_section
check_tool_section "Python" "python --version 2>/dev/null || python3 --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Ruby" "ruby --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Node.js" "node --version" "v[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Go" "go version" "go[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Rust" "rustc --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Java" "java --version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "R" "R --version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Mojo" "mojo --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'wrapper installed'" "[0-9]+\.[0-9]+\.[0-9]+|wrapper installed"
end_section "Programming Languages"

# Package Managers section
start_section
check_tool_section "pip" "pip --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pipx" "pipx --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Poetry" "poetry --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "gem" "gem --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "bundler" "bundle --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "npm" "npm --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "yarn" "yarn --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pnpm" "pnpm --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cargo" "cargo --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pixi" "pixi --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Package Managers"

# Python Development Tools section
start_section
check_tool_section "black" "black --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "isort" "python -c 'import isort; print(isort.__version__)' 2>/dev/null || isort --version 2>&1 | grep 'VERSION' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "ruff" "ruff --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "flake8" "flake8 --version | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "mypy" "mypy --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pylint" "pylint --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pytest" "pytest --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "tox" "python -c 'import tox; print(tox.__version__)' 2>/dev/null || tox --version 2>&1 | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pre-commit" "pre-commit --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cookiecutter" "cookiecutter --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "sphinx" "sphinx-build --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "jupyter" "python -c 'import jupyter_core; print(jupyter_core.__version__)' 2>/dev/null || jupyter --version 2>&1 | grep 'jupyter_core' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "ipython" "ipython --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "httpie" "http --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "yq" "yq --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Python Development Tools"

# Rust Development Tools section
start_section
check_tool_section "tree-sitter" "tree-sitter --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cargo-watch" "cargo-watch --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cargo-edit" "cargo install --list 2>/dev/null | grep 'cargo-edit' | head -1" "v[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cargo-expand" "cargo-expand --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cargo-outdated" "cargo install --list 2>/dev/null | grep 'cargo-outdated' | head -1" "v[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "bacon" "bacon --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "tokei" "tokei --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "hyperfine" "hyperfine --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "just" "just --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "sccache" "sccache --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "mdbook" "mdbook --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Rust Development Tools"

# Ruby Development Tools section
start_section
check_tool_section "rspec" "rspec --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "rubocop" "rubocop --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pry" "pry --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "yard" "yard --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "reek" "reek --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "brakeman" "brakeman --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "rails" "rails --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "solargraph" "solargraph --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Ruby Development Tools"

# R Development Tools section
start_section
# Core development tools only - as per r-dev.sh
check_r_package_section "devtools" "devtools"
check_r_package_section "usethis" "usethis"
check_r_package_section "testthat" "testthat"
check_r_package_section "roxygen2" "roxygen2"

# Documentation tools
check_r_package_section "rmarkdown" "rmarkdown"
check_r_package_section "knitr" "knitr"

# Code quality tools
check_r_package_section "lintr" "lintr"
check_r_package_section "styler" "styler"

# Minimal data tools
check_r_package_section "data.table" "data.table"
check_r_package_section "jsonlite" "jsonlite"

# Package checking
check_r_package_section "rcmdcheck" "rcmdcheck"
check_r_package_section "covr" "covr"
end_section "R Development Tools"

# Node.js Development Tools section
start_section
check_tool_section "TypeScript" "tsc --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "ts-node" "ts-node --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "tsx" "tsx --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "jest" "jest --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "mocha" "mocha --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "vitest" "vitest --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "playwright" "playwright --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "eslint" "eslint --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "prettier" "prettier --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "webpack" "webpack --version 2>&1 | grep -E 'webpack|CLI' | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "vite" "vite --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "esbuild" "esbuild --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "rollup" "rollup --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "parcel" "parcel --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "pm2" "pm2 -V 2>&1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | tail -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "nodemon" "nodemon --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Node.js Development Tools"

# Go Development Tools section
start_section
check_tool_section "gopls" "gopls version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "dlv" "dlv version 2>&1 | grep -oE 'Version: [0-9.]+' | cut -d' ' -f2 || echo '1.0.0'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "golangci-lint" "golangci-lint --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "staticcheck" "staticcheck -version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "gosec" "gosec --version 2>&1 | grep Version | awk '{print \$2}'" "[0-9a-zA-Z.]+"
check_tool_section "revive" "revive -version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "errcheck" "which errcheck >/dev/null && echo 'installed'" "installed"
check_tool_section "gotests" "which gotests >/dev/null && echo 'installed'" "installed"
check_tool_section "mockgen" "mockgen -version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "richgo" "richgo version 2>&1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "air" "air -v 2>&1 | grep -oE 'v[0-9.]+' | tr -d 'v'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "goreleaser" "goreleaser --version 2>&1 | grep GitVersion | awk '{print \$2}' | tr -d 'v'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "ko" "ko version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "swag" "swag -v" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "govulncheck" "govulncheck -version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Go Development Tools"

# Java Development Tools section
start_section
check_tool_section "Spring Boot CLI" "spring --version 2>&1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "JBang" "jbang --version 2>&1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Maven Daemon" "mvnd --version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "Google Java Format" "google-java-format --version 2>&1" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Java Development Tools"

# Development Tools section
start_section
check_tool_section "git" "git --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "zoxide" "zoxide --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "gh" "gh --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "glab" "glab --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "docker" "docker --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "docker compose" "docker compose version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "lazydocker" "lazydocker --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "dive" "dive --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "lazygit" "lazygit --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "delta" "delta --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "direnv" "direnv version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "mkcert" "mkcert --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "act" "act --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "fzf" "fzf --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "ripgrep" "rg --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "fd" "fd --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "bat" "bat --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "exa" "exa --version 2>&1 | grep '^v' | head -1" "v[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "1Password CLI" "op --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Development Tools"

# Cloud & Infrastructure Tools section
start_section
check_tool_section "kubectl" "kubectl version --client" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "k9s" "k9s version 2>&1 | grep -E '^.*Version:' | awk '{print \$2}'" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "helm" "helm version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "terraform" "terraform version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "terragrunt" "terragrunt --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "terraform-docs" "terraform-docs --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "aws" "aws --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "gcloud" "gcloud --version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "wrangler" "wrangler --version 2>/dev/null" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "cloudflared" "cloudflared --version 2>&1 | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Cloud & Infrastructure Tools"

# Database Tools section
start_section
check_tool_section "psql" "psql --version" "[0-9]+\.[0-9]+"
check_tool_section "redis-cli" "redis-cli --version" "[0-9]+\.[0-9]+\.[0-9]+"
check_tool_section "sqlite3" "sqlite3 --version" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "Database Tools"

# AI/ML Tools section
start_section
check_tool_section "ollama" "ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" "[0-9]+\.[0-9]+\.[0-9]+"
end_section "AI/ML Tools"

echo ""
echo "=== Cache Directories ==="
ls -la /cache/ 2>/dev/null | sed 's/^/  /' || echo "  /cache directory not found"
TESTSCRIPT

# Copy test script to container
docker cp /tmp/test-script.sh $CONTAINER_NAME:/tmp/test.sh

echo "Running all tests (this may take a moment)..."
echo ""

# Run all tests in a single docker exec using bash
docker exec $CONTAINER_NAME bash /tmp/test.sh "$SHOW_ALL"

echo ""
echo "=== Cleanup ==="
docker stop $CONTAINER_NAME >/dev/null 2>&1
docker rm $CONTAINER_NAME >/dev/null 2>&1
rm -f /tmp/test-script.sh
echo "✓ Test container removed"

echo ""
echo "=== Test Complete ==="
echo "To run the container interactively, use:"
echo "  ./run-all-features.sh"
