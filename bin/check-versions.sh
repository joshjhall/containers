#!/usr/bin/env bash
# Comprehensive version checker for all pinned versions in the container build system
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    if [ $file_age -lt $CACHE_DURATION ]; then
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
        cat "$cache_file"
        return 0
    fi
    
    # Fetch fresh data
    local response
    if [ -n "$GITHUB_TOKEN" ] && [[ "$url" == *"api.github.com"* ]]; then
        response=$(curl -s --max-time "$timeout" -H "Authorization: token $GITHUB_TOKEN" "$url" 2>/dev/null || echo "")
    else
        response=$(curl -s --max-time "$timeout" "$url" 2>/dev/null || echo "")
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

# Compare versions with partial matching support
# Returns 0 if versions match (considering partial versions)
version_matches() {
    local current="$1"
    local latest="$2"
    
    # Exact match
    if [ "$current" = "$latest" ]; then
        return 0
    fi
    
    # Check if current is a prefix of latest (e.g., "1.33" matches "1.33.3")
    if [[ "$latest" == "$current"* ]]; then
        # Make sure it's a valid version prefix (followed by . or end)
        local next_char="${latest:${#current}:1}"
        if [ -z "$next_char" ] || [ "$next_char" = "." ]; then
            return 0
        fi
    fi
    
    return 1
}

# Set latest version for a tool
set_latest() {
    local tool="$1"
    local version="$2"
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "$tool" ]; then
            LATEST_VERSIONS[$i]="$version"
            if version_matches "${CURRENT_VERSIONS[$i]}" "$version"; then
                VERSION_STATUS[$i]="current"
            elif [ "$version" = "error" ]; then
                VERSION_STATUS[$i]="error"
            else
                VERSION_STATUS[$i]="outdated"
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
    
    # Kubernetes tools from Dockerfile
    ver=$(grep "^ARG KUBECTL_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "kubectl" "$ver" "Dockerfile"
    
    ver=$(grep "^ARG K9S_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "k9s" "$ver" "Dockerfile"
    
    ver=$(grep "^ARG HELM_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && [ "$ver" != "latest" ] && add_tool "Helm" "$ver" "Dockerfile"
    
    # Terraform tools from Dockerfile
    ver=$(grep "^ARG TERRAGRUNT_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "Terragrunt" "$ver" "Dockerfile"
    
    ver=$(grep "^ARG TFDOCS_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ver" ] && add_tool "terraform-docs" "$ver" "Dockerfile"
    
    # Python tools
    if [ -f "$PROJECT_ROOT/lib/features/python.sh" ]; then
        ver=$(grep "POETRY_VERSION=" "$PROJECT_ROOT/lib/features/python.sh" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "Poetry" "$ver" "python.sh"
    fi
    
    # Dev tools from dev-tools.sh
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        ver=$(grep "^LAZYGIT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "lazygit" "$ver" "dev-tools.sh"
        
        ver=$(grep "^DIRENV_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "direnv" "$ver" "dev-tools.sh"
        
        ver=$(grep "^ACT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "act" "$ver" "dev-tools.sh"
        
        ver=$(grep "^DELTA_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "delta" "$ver" "dev-tools.sh"
        
        ver=$(grep "^GLAB_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "glab" "$ver" "dev-tools.sh"
        
        ver=$(grep "^MKCERT_VERSION=" "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "mkcert" "$ver" "dev-tools.sh"
    fi
    
    # Docker tools from docker.sh
    if [ -f "$PROJECT_ROOT/lib/features/docker.sh" ]; then
        ver=$(grep "^DIVE_VERSION=" "$PROJECT_ROOT/lib/features/docker.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "dive" "$ver" "docker.sh"
        
        ver=$(grep "^LAZYDOCKER_VERSION=" "$PROJECT_ROOT/lib/features/docker.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$ver" ] && add_tool "lazydocker" "$ver" "docker.sh"
    fi
}

# Progress helpers for quiet mode in JSON
progress_msg() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        progress_msg "$1"
    fi
}

progress_done() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        progress_done
    fi
}

# Check functions for each tool
check_python() {
    progress_msg "  Python..."
    local latest
    latest=$(fetch_url "https://endoflife.date/api/python.json" | jq -r '[.[] | select(.cycle | startswith("3."))] | .[0].latest' 2>/dev/null)
    [ -n "$latest" ] && set_latest "Python" "$latest" || set_latest "Python" "error"
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
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\")) | select(.lts != false)] | .[0].version" 2>/dev/null | sed 's/^v//')
        # If no LTS found for that major, get any version
        if [ -z "$latest" ] || [ "$latest" = "null" ]; then
            latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\"))] | .[0].version" 2>/dev/null | sed 's/^v//')
        fi
    else
        # Get latest LTS
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r '[.[] | select(.lts != false)] | .[0].version' 2>/dev/null | sed 's/^v//')
    fi
    
    [ -n "$latest" ] && set_latest "Node.js" "$latest" || set_latest "Node.js" "error"
    progress_done
}

check_go() {
    progress_msg "  Go..."
    local latest
    latest=$(fetch_url "https://go.dev/VERSION?m=text" | head -1 | sed 's/^go//')
    [ -n "$latest" ] && set_latest "Go" "$latest" || set_latest "Go" "error"
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
    [ -n "$latest" ] && set_latest "Rust" "$latest" || set_latest "Rust" "error"
    progress_done
}

check_ruby() {
    progress_msg "  Ruby..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/ruby/ruby/releases/latest" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//' | sed 's/_/./g')
    [ -n "$latest" ] && set_latest "Ruby" "$latest" || set_latest "Ruby" "error"
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
    latest=$(fetch_url "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=${current_major}" | jq -r '.versions[0].semver' 2>/dev/null | sed 's/+.*//')
    
    # If that fails, try the release names endpoint
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.adoptium.net/v3/assets/latest/${current_major}/hotspot" | jq -r '.[0].release_name' 2>/dev/null | sed 's/jdk-//' | sed 's/+.*//')
    fi
    
    [ -n "$latest" ] && [ "$latest" != "null" ] && set_latest "Java" "$latest" || set_latest "Java" "error"
    progress_done
}

check_r() {
    progress_msg "  R..."
    # Check R version from the R project website
    # The R project lists versions in their news page
    local latest
    latest=$(fetch_url "https://cran.r-project.org/" | grep -oE 'R-[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/R-//')
    
    # If that fails, try the SVN tags
    if [ -z "$latest" ]; then
        latest=$(fetch_url "https://svn.r-project.org/R/tags/" | grep -oE 'R-[0-9]+-[0-9]+-[0-9]+' | tail -1 | sed 's/R-//' | sed 's/-/./g')
    fi
    
    # If still nothing, check the news page
    if [ -z "$latest" ]; then
        latest=$(fetch_url "https://cran.r-project.org/doc/manuals/r-release/NEWS.html" | grep -oE 'VERSION [0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/VERSION //')
    fi
    
    [ -n "$latest" ] && set_latest "R" "$latest" || set_latest "R" "error"
    progress_done
}

check_github_release() {
    local tool="$1"
    local repo="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    [ -n "$latest" ] && set_latest "$tool" "$latest" || set_latest "$tool" "error"
    progress_done
}

check_gitlab_release() {
    local tool="$1"
    local project_id="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://gitlab.com/api/v4/projects/$project_id/releases" | jq -r '.[0].tag_name' 2>/dev/null | sed 's/^v//')
    [ -n "$latest" ] && set_latest "$tool" "$latest" || set_latest "$tool" "error"
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
    # kubectl uses major.minor format - get latest patch
    if [[ "$current" =~ ^[0-9]+\.[0-9]+$ ]]; then
        # Get latest patch version for this major.minor
        latest=$(fetch_url "https://api.github.com/repos/kubernetes/kubernetes/releases" | jq -r "[.[] | select(.tag_name | startswith(\"v$current.\"))] | .[0].tag_name" 2>/dev/null | sed 's/^v//')
    fi
    
    # If no specific version found, get the stable version
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://storage.googleapis.com/kubernetes-release/release/stable.txt" | sed 's/^v//')
    fi
    
    [ -n "$latest" ] && set_latest "kubectl" "$latest" || set_latest "kubectl" "error"
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
            outdated) ((outdated++)) ;;
            current) ((current++)) ;;
            error) ((errors++)) ;;
            manual) ((manual++)) ;;
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
        if [ $i -lt $((${#TOOLS[@]} - 1)) ]; then
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
                ((current++))
                ;;
            outdated)
                status_color="${YELLOW}⚠ outdated${NC}"
                ((outdated++))
                ;;
            error)
                status_color="${RED}✗ error${NC}"
                ((errors++))
                ;;
            *)
                if [ "$lat_ver" = "check manually" ]; then
                    status_color="${BLUE}ℹ manual${NC}"
                    ((manual++))
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
            kubectl) check_kubectl ;;
            k9s) check_github_release "k9s" "derailed/k9s" ;;
            Helm) check_github_release "Helm" "helm/helm" ;;
            Terragrunt) check_github_release "Terragrunt" "gruntwork-io/terragrunt" ;;
            terraform-docs) check_github_release "terraform-docs" "terraform-docs/terraform-docs" ;;
            Poetry) check_github_release "Poetry" "python-poetry/poetry" ;;
            lazygit) check_github_release "lazygit" "jesseduffield/lazygit" ;;
            lazydocker) check_github_release "lazydocker" "jesseduffield/lazydocker" ;;
            direnv) check_github_release "direnv" "direnv/direnv" ;;
            act) check_github_release "act" "nektos/act" ;;
            delta) check_github_release "delta" "dandavison/delta" ;;
            dive) check_github_release "dive" "wagoodman/dive" ;;
            mkcert) check_github_release "mkcert" "FiloSottile/mkcert" ;;
            glab) check_gitlab_release "glab" "gitlab-org%2Fcli" ;;
            *) [ "$OUTPUT_FORMAT" = "text" ] && echo "  Skipping $tool (no checker)" ;;
        esac
    done
    
    print_results
}

main "$@"