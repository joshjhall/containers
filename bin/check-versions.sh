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
    ver=$(echo "$line" | cut -d= -f2 | tr -d '"')

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
    echo "$CACHE_DIR/$(echo "$url" | sha256sum | cut -d' ' -f1)"
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

# Extract all versions from files
extract_all_versions() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -e "${BLUE}Scanning for version pins...${NC}"
    fi

    # Languages from Dockerfile
    local ver
    ver=$(grep "^ARG PYTHON_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Python" "$ver" "Dockerfile"

    ver=$(grep "^ARG NODE_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Node.js" "$ver" "Dockerfile"

    ver=$(grep "^ARG GO_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Go" "$ver" "Dockerfile"

    ver=$(grep "^ARG RUST_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Rust" "$ver" "Dockerfile"

    ver=$(grep "^ARG RUBY_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Ruby" "$ver" "Dockerfile"

    ver=$(grep "^ARG JAVA_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Java" "$ver" "Dockerfile"

    ver=$(grep "^ARG R_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "R" "$ver" "Dockerfile"

    ver=$(grep "^ARG KOTLIN_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Kotlin" "$ver" "Dockerfile"

    ver=$(grep "^ARG ANDROID_CMDLINE_TOOLS_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "android-cmdline-tools" "$ver" "Dockerfile"

    ver=$(grep "^ARG ANDROID_NDK_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "android-ndk" "$ver" "Dockerfile"

    # Kubernetes tools from Dockerfile
    ver=$(grep "^ARG KUBECTL_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "kubectl" "$ver" "Dockerfile"

    ver=$(grep "^ARG K9S_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "k9s" "$ver" "Dockerfile"

    ver=$(grep "^ARG KREW_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "krew" "$ver" "Dockerfile"

    ver=$(grep "^ARG HELM_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && [ "$ver" != "latest" ] && add_tool "Helm" "$ver" "Dockerfile"

    # Terraform tools from Dockerfile
    ver=$(grep "^ARG TERRAGRUNT_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Terragrunt" "$ver" "Dockerfile"

    ver=$(grep "^ARG TFDOCS_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "terraform-docs" "$ver" "Dockerfile"

    ver=$(grep "^ARG TFLINT_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "tflint" "$ver" "Dockerfile"

    # Trivy from terraform.sh (replaces deprecated tfsec)
    if [ -f "$PROJECT_ROOT/lib/features/terraform.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^TRIVY_VERSION=" "$PROJECT_ROOT/lib/features/terraform.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "Trivy" "$ver" "terraform.sh"
    fi

    ver=$(grep "^ARG PIXI_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "pixi" "$ver" "Dockerfile"

    # Python tools
    if [ -f "$PROJECT_ROOT/lib/features/python.sh" ]; then
        ver=$(extract_version_from_line "$(grep "POETRY_VERSION=" "$PROJECT_ROOT/lib/features/python.sh" 2>/dev/null | head -1)")
        [ -n "$ver" ] && add_tool "Poetry" "$ver" "python.sh"

        ver=$(extract_version_from_line "$(grep "UV_VERSION=" "$PROJECT_ROOT/lib/features/python.sh" 2>/dev/null | head -1)")
        [ -n "$ver" ] && add_tool "uv" "$ver" "python.sh"
    fi

    # Dev tools from dev-tools.sh
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^LAZYGIT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "lazygit" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^DIRENV_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "direnv" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^ACT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "act" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^DELTA_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "delta" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^GLAB_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "glab" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^MKCERT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "mkcert" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^DUF_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "duf" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^ENTR_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "entr" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^BIOME_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "biome" "$ver" "dev-tools.sh"

        ver=$(extract_version_from_line "$(grep "^TAPLO_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "taplo" "$ver" "dev-tools.sh"
    fi

    # Docker tools from docker.sh
    if [ -f "$PROJECT_ROOT/lib/features/docker.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^DIVE_VERSION=" "$PROJECT_ROOT/lib/features/docker.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "dive" "$ver" "docker.sh"

        ver=$(extract_version_from_line "$(grep "^LAZYDOCKER_VERSION=" "$PROJECT_ROOT/lib/features/docker.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "lazydocker" "$ver" "docker.sh"
    fi

    # Kotlin dev tools from kotlin-dev.sh
    if [ -f "$PROJECT_ROOT/lib/features/kotlin-dev.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^KTLINT_VERSION=" "$PROJECT_ROOT/lib/features/kotlin-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "ktlint" "$ver" "kotlin-dev.sh"

        ver=$(extract_version_from_line "$(grep "^DETEKT_VERSION=" "$PROJECT_ROOT/lib/features/kotlin-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "detekt" "$ver" "kotlin-dev.sh"

        ver=$(extract_version_from_line "$(grep "^KLS_VERSION=" "$PROJECT_ROOT/lib/features/kotlin-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "kotlin-language-server" "$ver" "kotlin-dev.sh"
    fi

    # jdtls from install-jdtls.sh
    if [ -f "$PROJECT_ROOT/lib/features/lib/install-jdtls.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^JDTLS_VERSION=" "$PROJECT_ROOT/lib/features/lib/install-jdtls.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "jdtls" "$ver" "install-jdtls.sh"
    fi

    # Java dev tools from java-dev.sh
    if [ -f "$PROJECT_ROOT/lib/features/java-dev.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^SPRING_VERSION=" "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "spring-boot-cli" "$ver" "java-dev.sh"

        ver=$(extract_version_from_line "$(grep "^JBANG_VERSION=" "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "jbang" "$ver" "java-dev.sh"

        ver=$(extract_version_from_line "$(grep "^MVND_VERSION=" "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "mvnd" "$ver" "java-dev.sh"

        ver=$(extract_version_from_line "$(grep "^GJF_VERSION=" "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "google-java-format" "$ver" "java-dev.sh"

        ver=$(extract_version_from_line "$(grep "^JMH_VERSION=" "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "jmh" "$ver" "java-dev.sh"
    fi

    # Base system tools from setup.sh
    if [ -f "$PROJECT_ROOT/lib/base/setup.sh" ]; then
        ver=$(extract_version_from_line "$(grep "^ZOXIDE_VERSION=" "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "zoxide" "$ver" "setup.sh"

        ver=$(extract_version_from_line "$(grep "^COSIGN_VERSION=" "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)")
        [ -n "$ver" ] && add_tool "cosign" "$ver" "setup.sh"
    fi

    # GitHub Actions from workflows
    if [ -f "$PROJECT_ROOT/.github/workflows/ci.yml" ]; then
        ver=$(grep "uses: aquasecurity/trivy-action@" "$PROJECT_ROOT/.github/workflows/ci.yml" 2>/dev/null | head -1 | command sed 's/.*@//' | tr -d ' ')
        [ -n "$ver" ] && [ "$ver" != "master" ] && add_tool "trivy-action" "$ver" "ci.yml"
    fi
}

# Progress helpers for quiet mode in JSON
progress_msg() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -n "$1"
    fi
}

progress_done() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo " ✓"
    fi
}

# Check functions for each tool
check_python() {
    progress_msg "  Python..."
    local latest
    latest=$(fetch_url "https://endoflife.date/api/python.json" | jq -r '[.[] | select(.cycle | startswith("3."))] | .[0].latest // "null"' 2>/dev/null)
    set_latest "Python" "$latest"
    progress_done
}

check_nodejs() {
    progress_msg "  Node.js..."
    local current=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "Node.js" ]; then
            current="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    local latest=""
    # If version is just major (like "22"), get the latest LTS in that major version
    if [[ "$current" =~ ^[0-9]+$ ]]; then
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\")) | select(.lts != false)] | .[0].version" 2>/dev/null | command sed 's/^v//')
        # If no LTS found for that major, get any version
        if [ -z "$latest" ] || [ "$latest" = "null" ]; then
            latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\"))] | .[0].version" 2>/dev/null | command sed 's/^v//')
        fi
    else
        # Get latest LTS
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r '[.[] | select(.lts != false)] | .[0].version' 2>/dev/null | command sed 's/^v//')
    fi

    set_latest "Node.js" "$latest"
    progress_done
}

check_go() {
    progress_msg "  Go..."
    local latest
    latest=$(fetch_url "https://go.dev/VERSION?m=text" | head -1 | command sed 's/^go//')
    set_latest "Go" "$latest"
    progress_done
}

check_rust() {
    progress_msg "  Rust..."
    # Try the Rust API endpoint
    local latest
    latest=$(fetch_url "https://api.github.com/repos/rust-lang/rust/releases" | jq -r '[.[] | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[0].tag_name' 2>/dev/null)
    if [ -z "$latest" ]; then
        # Fallback to forge.rust-lang.org
        latest=$(fetch_url "https://forge.rust-lang.org/infra/channel-layout.html" | grep -oE 'stable.*?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    set_latest "Rust" "$latest"
    progress_done
}

check_ruby() {
    progress_msg "  Ruby..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/ruby/ruby/releases/latest" | jq -r '.tag_name' 2>/dev/null | command sed 's/^v//' | command sed 's/_/./g')
    set_latest "Ruby" "$latest"
    progress_done
}

check_java() {
    progress_msg "  Java..."
    # Get the current major version
    local current_major=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "Java" ]; then
            current_major="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    # Use Adoptium API to get latest version for this major
    local latest
    latest=$(fetch_url "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=${current_major}" | jq -r '.versions[0].semver' 2>/dev/null | command sed 's/+.*//')

    # If that fails, try the release names endpoint
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.adoptium.net/v3/assets/latest/${current_major}/hotspot" | jq -r '.[0].release_name' 2>/dev/null | command sed 's/jdk-//' | command sed 's/+.*//')
    fi

    set_latest "Java" "$latest"
    progress_done
}

check_r() {
    progress_msg "  R..."
    local latest

    # Use CRAN sources page - more reliable than homepage or SVN
    # Parse the latest release tarball name
    latest=$(fetch_url "https://cran.r-project.org/sources.html" 8 | grep -oE 'R-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | head -1 | command sed 's/R-//;s/\.tar\.gz//' 2>/dev/null)

    # Mark as error if fetch failed
    if [ -z "$latest" ]; then
        latest="error"
    fi

    set_latest "R" "$latest"
    progress_done
}

check_kotlin() {
    progress_msg "  Kotlin..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/JetBrains/kotlin/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "Kotlin" "$latest"
    progress_done
}

check_ktlint() {
    progress_msg "  ktlint..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/pinterest/ktlint/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "ktlint" "$latest"
    progress_done
}

check_detekt() {
    progress_msg "  detekt..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/detekt/detekt/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "detekt" "$latest"
    progress_done
}

check_kotlin_language_server() {
    progress_msg "  kotlin-language-server..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/fwcd/kotlin-language-server/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "kotlin-language-server" "$latest"
    progress_done
}

check_jdtls() {
    progress_msg "  jdtls..."
    # Get the latest jdtls version from Eclipse downloads
    local latest
    latest=$(fetch_url "https://download.eclipse.org/jdtls/milestones/" 10 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 2>/dev/null)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        set_latest "jdtls" "error"
    else
        set_latest "jdtls" "$latest"
    fi
    progress_done
}

check_android_cmdline_tools() {
    progress_msg "  android-cmdline-tools..."
    # Get the latest cmdline-tools version from the Android Studio download page
    # The version is embedded in the download filename
    local latest
    latest=$(fetch_url "https://developer.android.com/studio" 10 | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | head -1 | grep -oE '[0-9]+' 2>/dev/null)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        # Fallback: mark as needing manual check
        set_latest "android-cmdline-tools" "error"
    else
        set_latest "android-cmdline-tools" "$latest"
    fi
    progress_done
}

check_android_ndk() {
    progress_msg "  android-ndk..."
    # Get the latest NDK version from the download page
    # NDK versions are like r27d, r29, etc. We need to map to the SDK manager format
    local ndk_release
    ndk_release=$(fetch_url "https://developer.android.com/ndk/downloads" 10 | grep -oE 'android-ndk-r[0-9]+[a-z]?' | sort -V | tail -1 | grep -oE 'r[0-9]+[a-z]?' 2>/dev/null)

    if [ -z "$ndk_release" ]; then
        set_latest "android-ndk" "error"
    else
        # NDK version format in SDK manager is like "29.0.14206865"
        # We can't easily get the full version, but we can check if major version matches
        # Extract major version (e.g., r29 -> 29)
        local major_ver
        major_ver=$(echo "$ndk_release" | grep -oE '[0-9]+')

        # Get the current major version from what's pinned
        local current=""
        for i in "${!TOOLS[@]}"; do
            if [ "${TOOLS[$i]}" = "android-ndk" ]; then
                current="${CURRENT_VERSIONS[$i]}"
                break
            fi
        done
        local current_major
        current_major=$(echo "$current" | cut -d. -f1)

        # If major versions match, consider it current
        if [ "$major_ver" = "$current_major" ]; then
            set_latest "android-ndk" "$current"
        else
            # Different major version - report the release name for reference
            set_latest "android-ndk" "${major_ver}.x.x ($ndk_release)"
        fi
    fi
    progress_done
}

check_github_release() {
    local tool="$1"
    local repo="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "$tool" "$latest"
    progress_done
}

check_gitlab_release() {
    local tool="$1"
    local project_id="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://gitlab.com/api/v4/projects/$project_id/releases" | jq -r '.[0].tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "$tool" "$latest"
    progress_done
}

check_entr() {
    progress_msg "  entr..."
    # entr uses a simple versioning on their website
    # We'll check the latest version from the downloads page
    local latest
    latest=$(fetch_url "http://eradman.com/entrproject/" | grep -oE 'entr-[0-9]+\.[0-9]+\.tar\.gz' | head -1 | command sed 's/entr-//;s/\.tar\.gz//')

    set_latest "entr" "$latest"
    progress_done
}

check_biome() {
    progress_msg "  biome..."
    # Biome changed tag format from cli/vX.Y.Z to @biomejs/biome@X.Y.Z
    local latest
    latest=$(fetch_url "https://api.github.com/repos/biomejs/biome/releases" | jq -r '[.[] | select(.tag_name | startswith("@biomejs/biome@"))] | .[0].tag_name // "null"' 2>/dev/null | command sed 's|^@biomejs/biome@||')
    # Fallback to old format if new format not found
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.github.com/repos/biomejs/biome/releases" | jq -r '[.[] | select(.tag_name | startswith("cli/v"))] | .[0].tag_name // "null"' 2>/dev/null | command sed 's|^cli/v||')
    fi
    set_latest "biome" "$latest"
    progress_done
}

check_taplo() {
    progress_msg "  taplo..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/tamasfe/taplo/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null)
    set_latest "taplo" "$latest"
    progress_done
}

check_cargo_release() {
    progress_msg "  cargo-release..."
    local latest
    # Check crates.io for latest version
    latest=$(fetch_url "https://crates.io/api/v1/crates/cargo-release" | jq -r '.crate.max_version // "null"' 2>/dev/null)
    set_latest "cargo-release" "$latest"
    progress_done
}

check_maven_central() {
    local tool="$1"
    local group_id="$2"
    local artifact_id="$3"
    progress_msg "  $tool..."
    # Check Maven Central for latest version
    local latest
    latest=$(fetch_url "https://search.maven.org/solrsearch/select?q=g:${group_id}+AND+a:${artifact_id}&rows=1&wt=json" | \
        jq -r '.response.docs[0].latestVersion // "unknown"' 2>/dev/null)

    if [ -n "$latest" ] && [ "$latest" != "unknown" ] && [ "$latest" != "null" ]; then
        set_latest "$tool" "$latest"
    else
        set_latest "$tool" "error"
    fi
    progress_done
}

check_kubectl() {
    progress_msg "  kubectl..."
    local current=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "kubectl" ]; then
            current="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    local latest=""
    # Extract major.minor from current version (handles both 1.33 and 1.33.0 formats)
    local major_minor=""
    if [[ "$current" =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
        # Get latest patch version for this major.minor from GitHub releases
        latest=$(fetch_url "https://api.github.com/repos/kubernetes/kubernetes/releases" | jq -r "[.[] | select(.tag_name | startswith(\"v$major_minor.\")) | select(.prerelease == false)] | .[0].tag_name" 2>/dev/null | command sed 's/^v//')
    fi

    # If no specific version found, get the latest stable release (not stable.txt which lags behind)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.github.com/repos/kubernetes/kubernetes/releases" | jq -r '[.[] | select(.prerelease == false)] | .[0].tag_name' 2>/dev/null | command sed 's/^v//')
    fi

    set_latest "kubectl" "$latest"
    progress_done
}

# Print results in JSON format
print_json_results() {
    local outdated=0
    local current=0
    local errors=0
    local manual=0

    # Build JSON array
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"tools\": ["

    for i in "${!TOOLS[@]}"; do
        local tool="${TOOLS[$i]}"
        local cur_ver="${CURRENT_VERSIONS[$i]}"
        local latest="${LATEST_VERSIONS[$i]}"
        local status="${VERSION_STATUS[$i]}"
        local file="${VERSION_FILES[$i]}"

        # Update counters
        case "$status" in
            outdated) outdated=$((outdated + 1)) ;;
            current) current=$((current + 1)) ;;
            error) errors=$((errors + 1)) ;;
            manual) manual=$((manual + 1)) ;;
        esac

        # Print JSON object for this tool
        echo -n "    {"
        echo -n "\"tool\":\"$tool\","
        echo -n "\"current\":\"$cur_ver\","
        echo -n "\"latest\":\"$latest\","
        echo -n "\"file\":\"$file\","
        echo -n "\"status\":\"$status\""
        echo -n "}"

        # Add comma if not last item
        if [ "$i" -lt $((${#TOOLS[@]} - 1)) ]; then
            echo ","
        else
            echo ""
        fi
    done

    echo "  ],"
    echo "  \"summary\": {"
    echo "    \"total\": ${#TOOLS[@]},"
    echo "    \"current\": $current,"
    echo "    \"outdated\": $outdated,"
    echo "    \"errors\": $errors,"
    echo "    \"manual_check\": $manual"
    echo "  },"
    echo "  \"exit_code\": $([ $outdated -gt 0 ] && echo 1 || echo 0)"
    echo "}"
}

# Print results
print_results() {
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        print_json_results
        return
    fi

    echo ""
    echo -e "${BLUE}=== Version Check Results ===${NC}"
    echo ""

    printf "%-20s %-15s %-15s %-20s %s\n" "Tool" "Current" "Latest" "File" "Status"
    printf "%-20s %-15s %-15s %-20s %s\n" "----" "-------" "------" "----" "------"

    local outdated=0
    local current=0
    local errors=0
    local manual=0

    for i in "${!TOOLS[@]}"; do
        local tool="${TOOLS[$i]}"
        local cur_ver="${CURRENT_VERSIONS[$i]}"
        local lat_ver="${LATEST_VERSIONS[$i]:-unknown}"
        local file="${VERSION_FILES[$i]}"
        local status="${VERSION_STATUS[$i]}"

        local status_color=""
        case "$status" in
            current)
                status_color="${GREEN}✓ current${NC}"
                current=$((current + 1))
                ;;
            outdated)
                status_color="${YELLOW}⚠ outdated${NC}"
                outdated=$((outdated + 1))
                ;;
            error)
                status_color="${RED}✗ error${NC}"
                errors=$((errors + 1))
                ;;
            *)
                if [ "$lat_ver" = "check manually" ]; then
                    status_color="${BLUE}ℹ manual${NC}"
                    manual=$((manual + 1))
                else
                    status_color="unchecked"
                fi
                ;;
        esac

        printf "%-20s %-15s %-15s %-20s %b\n" "$tool" "$cur_ver" "$lat_ver" "$file" "$status_color"
    done

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Current: ${GREEN}$current${NC}"
    echo -e "  Outdated: ${YELLOW}$outdated${NC}"
    echo -e "  Errors: ${RED}$errors${NC}"
    echo -e "  Manual Check: ${BLUE}$manual${NC}"

    if [ $outdated -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Note: $outdated tool(s) have newer versions available${NC}"
        exit 1
    fi
}

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
            Go) check_go ;;
            Rust) check_rust ;;
            Ruby) check_ruby ;;
            Java) check_java ;;
            R) check_r ;;
            Kotlin) check_kotlin ;;
            ktlint) check_ktlint ;;
            detekt) check_detekt ;;
            kotlin-language-server) check_kotlin_language_server ;;
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
            Trivy) check_github_release "Trivy" "aquasecurity/trivy" ;;
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
            taplo) check_taplo ;;
            cargo-release) check_cargo_release ;;
            zoxide) check_github_release "zoxide" "ajeetdsouza/zoxide" ;;
            cosign) check_github_release "cosign" "sigstore/cosign" ;;
            trivy-action) check_github_release "trivy-action" "aquasecurity/trivy-action" ;;
            *) [ "$OUTPUT_FORMAT" = "text" ] && echo "  Skipping $tool (no checker)" ;;
        esac
    done

    print_results
}

main "$@"
