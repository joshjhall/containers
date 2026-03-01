#!/usr/bin/env bash
# Comprehensive version checker for all pinned versions in the container build system
set -uo pipefail

# Get script directory and source shared utilities
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BIN_DIR}/lib/common.sh"
source "${BIN_DIR}/lib/version-utils.sh"

# Set project root
PROJECT_ROOT="$(dirname "$BIN_DIR")"

# Parse command line arguments
OUTPUT_FORMAT="text"
USE_CACHE="true"
CACHE_DURATION=3600  # 1 hour in seconds

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --no-cache)
            USE_CACHE="false"
            shift
            ;;
        --cache-duration)
            CACHE_DURATION="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --json              Output results in JSON format"
            echo "  --no-cache          Don't use cached version data"
            echo "  --cache-duration N  Cache duration in seconds (default: 3600)"
            echo "  --help              Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Cache directory
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/container-version-checker"
mkdir -p "$CACHE_DIR"

# Helper function to extract version from a variable assignment
# Handles both plain assignments (VAR="1.2.3") and parameter expansion (VAR="${VAR:-1.2.3}")
extract_version_from_line() {
    local line="$1"
    local ver

    # Extract the value after the = sign, removing quotes
    ver=$(echo "$line" | command cut -d= -f2 | command tr -d '"')

    # If it's a parameter expansion like ${VAR:-default}, extract the default value
    if [[ "$ver" =~ \$\{[^:]*:-([^}]+)\} ]]; then
        ver="${BASH_REMATCH[1]}"
    fi

    echo "$ver"
}

# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        export "$key=$value"
    done < "$PROJECT_ROOT/.env"
    set +a
fi

# GitHub token for API calls
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -n "$GITHUB_TOKEN" ] && [ "$OUTPUT_FORMAT" = "text" ]; then
    echo -e "${GREEN}Using GitHub token for API calls${NC}"
elif [ -z "$GITHUB_TOKEN" ] && [ "$OUTPUT_FORMAT" = "text" ]; then
    echo -e "${YELLOW}Warning: No GITHUB_TOKEN set. API rate limits may apply.${NC}"
fi

# Cache helper functions
get_cache_file() {
    local url="$1"
    echo "$CACHE_DIR/$(echo "$url" | sha256sum | command cut -d' ' -f1)"
}

is_cache_valid() {
    local cache_file="$1"
    if [ ! -f "$cache_file" ] || [ "$USE_CACHE" = "false" ]; then
        return 1
    fi

    local file_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))
    if [ "$file_age" -lt "$CACHE_DURATION" ]; then
        return 0
    fi
    return 1
}

# Helper function for API calls with timeout and caching
fetch_url() {
    local url="$1"
    local timeout="${2:-10}"
    local cache_file
    cache_file=$(get_cache_file "$url")

    # Check cache first
    if is_cache_valid "$cache_file"; then
        command cat "$cache_file"
        return 0
    fi

    # Fetch fresh data
    # Use both --connect-timeout and --max-time to prevent hanging
    local response
    if [ -n "$GITHUB_TOKEN" ] && [[ "$url" == *"api.github.com"* ]]; then
        response=$(command curl -s --connect-timeout 5 --max-time "$timeout" -H "Authorization: token $GITHUB_TOKEN" "$url" 2>/dev/null || echo "")
    else
        response=$(command curl -s --connect-timeout 5 --max-time "$timeout" "$url" 2>/dev/null || echo "")
    fi

    # Cache the response if not empty
    if [ -n "$response" ] && [ "$USE_CACHE" = "true" ]; then
        echo "$response" > "$cache_file"
    fi

    echo "$response"
}

# Version storage
declare -a TOOLS
declare -a CURRENT_VERSIONS
declare -a LATEST_VERSIONS
declare -a VERSION_STATUS
declare -a VERSION_FILES

# Add a tool/version pair
add_tool() {
    local tool="$1"
    local current="$2"
    local file="$3"
    TOOLS+=("$tool")
    CURRENT_VERSIONS+=("$current")
    LATEST_VERSIONS+=("")
    VERSION_STATUS+=("unchecked")
    VERSION_FILES+=("$file")
}

# Note: version_matches() is now in bin/lib/version-utils.sh

# Set latest version for a tool
set_latest() {
    local tool="$1"
    local version="$2"

    # Validate version is not empty, null, or error-like
    if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "undefined" ]; then
        version="error"
    fi

    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[i]}" = "$tool" ]; then
            LATEST_VERSIONS[i]="$version"
            if version_matches "${CURRENT_VERSIONS[i]}" "$version"; then
                VERSION_STATUS[i]="current"
            elif [ "$version" = "error" ]; then
                VERSION_STATUS[i]="error"
            else
                VERSION_STATUS[i]="outdated"
            fi
            break
        fi
    done
}

# Extract version from a Dockerfile ARG and add as a tool
_add_dockerfile_version() {
    local arg_name="$1" tool_name="$2"
    local ver
    ver=$(command grep "^ARG ${arg_name}=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | command cut -d= -f2 | command tr -d '"') || true
    [ -n "$ver" ] && add_tool "$tool_name" "$ver" "Dockerfile" || true
}

# Extract version from a feature script variable and add as a tool
_add_feature_version() {
    local var_name="$1" tool_name="$2" file="$3"
    local source_label="${4:-$file}"
    local full_path="$PROJECT_ROOT/lib/features/$file"
    [ -f "$full_path" ] || return 0
    local ver
    # Match both top-level and indented assignments (e.g., inside if blocks)
    ver=$(extract_version_from_line "$(command grep "${var_name}=" "$full_path" 2>/dev/null | command head -1)") || true
    [ -n "$ver" ] && add_tool "$tool_name" "$ver" "$source_label" || true
}

# Extract all versions from files
extract_all_versions() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${BLUE}Scanning for version pins...${NC}"
    fi

    # Languages from Dockerfile
    _add_dockerfile_version PYTHON_VERSION "Python"
    _add_dockerfile_version NODE_VERSION "Node.js"
    _add_dockerfile_version GO_VERSION "Go"
    _add_dockerfile_version RUST_VERSION "Rust"
    _add_dockerfile_version RUBY_VERSION "Ruby"
    _add_dockerfile_version JAVA_VERSION "Java"
    _add_dockerfile_version R_VERSION "R"
    _add_dockerfile_version KOTLIN_VERSION "Kotlin"
    _add_dockerfile_version ANDROID_CMDLINE_TOOLS_VERSION "android-cmdline-tools"
    _add_dockerfile_version ANDROID_NDK_VERSION "android-ndk"

    # Kubernetes tools from Dockerfile
    _add_dockerfile_version KUBECTL_VERSION "kubectl"
    _add_dockerfile_version K9S_VERSION "k9s"
    _add_dockerfile_version KREW_VERSION "krew"

    # Helm: skip "latest" sentinel
    local ver
    ver=$(command grep "^ARG HELM_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | command cut -d= -f2 | command tr -d '"') || true
    [ -n "$ver" ] && [ "$ver" != "latest" ] && add_tool "Helm" "$ver" "Dockerfile" || true

    # Terraform tools from Dockerfile
    _add_dockerfile_version TERRAGRUNT_VERSION "Terragrunt"
    _add_dockerfile_version TFDOCS_VERSION "terraform-docs"
    _add_dockerfile_version TFLINT_VERSION "tflint"

    # Trivy is installed via APT (no pinned version to track)

    _add_dockerfile_version PIXI_VERSION "pixi"

    # Python tools (use non-anchored grep for POETRY_VERSION/UV_VERSION)
    if [ -f "$PROJECT_ROOT/lib/features/python.sh" ]; then
        ver=$(extract_version_from_line "$(command grep "POETRY_VERSION=" "$PROJECT_ROOT/lib/features/python.sh" 2>/dev/null | command head -1)") || true
        [ -n "$ver" ] && add_tool "Poetry" "$ver" "python.sh" || true

        ver=$(extract_version_from_line "$(command grep "UV_VERSION=" "$PROJECT_ROOT/lib/features/python.sh" 2>/dev/null | command head -1)") || true
        [ -n "$ver" ] && add_tool "uv" "$ver" "python.sh" || true
    fi

    # Dev tools from dev-tools.sh
    _add_feature_version LAZYGIT_VERSION "lazygit" "dev-tools.sh"
    _add_feature_version DIRENV_VERSION "direnv" "dev-tools.sh"
    _add_feature_version ACT_VERSION "act" "dev-tools.sh"
    _add_feature_version DELTA_VERSION "delta" "dev-tools.sh"
    _add_feature_version GLAB_VERSION "glab" "dev-tools.sh"
    _add_feature_version MKCERT_VERSION "mkcert" "dev-tools.sh"
    _add_feature_version DUF_VERSION "duf" "dev-tools.sh"
    _add_feature_version ENTR_VERSION "entr" "dev-tools.sh"
    _add_feature_version BIOME_VERSION "biome" "dev-tools.sh"
    _add_feature_version TAPLO_VERSION "taplo" "dev-tools.sh"

    # Docker tools from docker.sh
    _add_feature_version DIVE_VERSION "dive" "docker.sh"
    _add_feature_version LAZYDOCKER_VERSION "lazydocker" "docker.sh"

    # Kotlin dev tools from kotlin-dev.sh
    _add_feature_version KTLINT_VERSION "ktlint" "kotlin-dev.sh"
    _add_feature_version DETEKT_VERSION "detekt" "kotlin-dev.sh"
    _add_feature_version KLS_VERSION "kotlin-language-server" "kotlin-dev.sh"

    # jdtls from install-jdtls.sh (nested path, use inline)
    if [ -f "$PROJECT_ROOT/lib/features/lib/install-jdtls.sh" ]; then
        ver=$(extract_version_from_line "$(command grep "^JDTLS_VERSION=" "$PROJECT_ROOT/lib/features/lib/install-jdtls.sh" 2>/dev/null)") || true
        [ -n "$ver" ] && add_tool "jdtls" "$ver" "lib/install-jdtls.sh" || true
    fi

    # Java dev tools from java-dev.sh
    _add_feature_version SPRING_VERSION "spring-boot-cli" "java-dev.sh"
    _add_feature_version JBANG_VERSION "jbang" "java-dev.sh"
    _add_feature_version MVND_VERSION "mvnd" "java-dev.sh"
    _add_feature_version GJF_VERSION "google-java-format" "java-dev.sh"
    _add_feature_version JMH_VERSION "jmh" "java-dev.sh"

    # Base system tools from setup.sh (different base path, use inline)
    if [ -f "$PROJECT_ROOT/lib/base/setup.sh" ]; then
        ver=$(extract_version_from_line "$(command grep "^ZOXIDE_VERSION=" "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)") || true
        [ -n "$ver" ] && add_tool "zoxide" "$ver" "setup.sh" || true

        ver=$(extract_version_from_line "$(command grep "^COSIGN_VERSION=" "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)") || true
        [ -n "$ver" ] && add_tool "cosign" "$ver" "setup.sh" || true
    fi

    # GitHub Actions from workflows
    if [ -f "$PROJECT_ROOT/.github/workflows/ci.yml" ]; then
        ver=$(command grep "uses: aquasecurity/trivy-action@" "$PROJECT_ROOT/.github/workflows/ci.yml" 2>/dev/null | command head -1 | command sed 's/.*@//' | command tr -d ' ') || true
        [ -n "$ver" ] && [ "$ver" != "master" ] && add_tool "trivy-action" "$ver" "ci.yml" || true
    fi
}

# Source check functions and output formatting
source "${BIN_DIR}/lib/check-versions/checks.sh"
source "${BIN_DIR}/lib/check-versions/output.sh"

# Main execution
main() {
    extract_all_versions

    if [ ${#TOOLS[@]} -eq 0 ]; then
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            echo '{"timestamp":"'"$(date -Iseconds)"'","tools":[],"summary":{"total":0},"exit_code":0}'
        else
            echo -e "${YELLOW}No version pins found${NC}"
        fi
        exit 0
    fi

    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${BLUE}Checking for latest versions...${NC}"
    fi

    # Check each tool
    for i in "${!TOOLS[@]}"; do
        local tool="${TOOLS[$i]}"
        case "$tool" in
            Python) check_python ;;
            Node.js) check_nodejs ;;
            Go)
                progress_msg "  Go..."
                set_latest "Go" "$(fetch_url "https://go.dev/VERSION?m=text" | command head -1 | command sed 's/^go//')"
                progress_done
                ;;
            Rust) check_rust ;;
            Ruby)
                progress_msg "  Ruby..."
                set_latest "Ruby" "$(fetch_url "https://api.github.com/repos/ruby/ruby/releases/latest" | jq -r '.tag_name' 2>/dev/null | command sed 's/^v//' | command sed 's/_/./g')"
                progress_done
                ;;
            Java) check_java ;;
            R) check_r ;;
            Kotlin) check_github_release "Kotlin" "JetBrains/kotlin" ;;
            ktlint) check_github_release "ktlint" "pinterest/ktlint" ;;
            detekt) check_github_release "detekt" "detekt/detekt" ;;
            kotlin-language-server) check_github_release "kotlin-language-server" "fwcd/kotlin-language-server" ;;
            jdtls) check_jdtls ;;
            android-cmdline-tools) check_android_cmdline_tools ;;
            android-ndk) check_android_ndk ;;
            kubectl) check_kubectl ;;
            k9s) check_github_release "k9s" "derailed/k9s" ;;
            krew) check_github_release "krew" "kubernetes-sigs/krew" ;;
            Helm) check_github_release "Helm" "helm/helm" ;;
            Terragrunt) check_github_release "Terragrunt" "gruntwork-io/terragrunt" ;;
            terraform-docs) check_github_release "terraform-docs" "terraform-docs/terraform-docs" ;;
            tflint) check_github_release "tflint" "terraform-linters/tflint" ;;
            Trivy) ;; # Trivy is installed via APT (no GitHub release to check)
            pixi) check_github_release "pixi" "prefix-dev/pixi" ;;
            Poetry) check_github_release "Poetry" "python-poetry/poetry" ;;
            uv) check_github_release "uv" "astral-sh/uv" ;;
            lazygit) check_github_release "lazygit" "jesseduffield/lazygit" ;;
            lazydocker) check_github_release "lazydocker" "jesseduffield/lazydocker" ;;
            direnv) check_github_release "direnv" "direnv/direnv" ;;
            act) check_github_release "act" "nektos/act" ;;
            delta) check_github_release "delta" "dandavison/delta" ;;
            dive) check_github_release "dive" "wagoodman/dive" ;;
            mkcert) check_github_release "mkcert" "FiloSottile/mkcert" ;;
            glab) check_gitlab_release "glab" "gitlab-org%2Fcli" ;;
            spring-boot-cli) check_github_release "spring-boot-cli" "spring-projects/spring-boot" ;;
            jbang) check_github_release "jbang" "jbangdev/jbang" ;;
            mvnd) check_github_release "mvnd" "apache/maven-mvnd" ;;
            google-java-format) check_github_release "google-java-format" "google/google-java-format" ;;
            jmh) check_maven_central "jmh" "org.openjdk.jmh" "jmh-core" ;;
            duf) check_github_release "duf" "muesli/duf" ;;
            entr) check_entr ;;
            biome) check_biome ;;
            taplo) check_github_release "taplo" "tamasfe/taplo" ;;
            cargo-release) check_crates_io "cargo-release" ;;
            zoxide) check_github_release "zoxide" "ajeetdsouza/zoxide" ;;
            cosign) check_github_release "cosign" "sigstore/cosign" ;;
            trivy-action) check_github_release "trivy-action" "aquasecurity/trivy-action" ;;
            *) [ "$OUTPUT_FORMAT" = "text" ] && echo "  Skipping $tool (no checker)" ;;
        esac
    done

    print_results
}

main "$@"
