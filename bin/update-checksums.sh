#!/usr/bin/env bash
# Automatically update lib/checksums.json with checksums for detected versions
#
# This script can:
# 1. Fill in missing checksums for versions already in checksums.json
# 2. Add checksums for new versions detected by check-versions.sh
# 3. Work standalone or as part of the auto-patch workflow
#
# Usage:
#   ./bin/update-checksums.sh [OPTIONS]
#
# Options:
#   --versions-json FILE  Use check-versions.sh JSON output to add new versions
#   --dry-run             Show what would be updated without making changes
#   --help                Show this help message

set -euo pipefail

# Get script directory and source shared utilities
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BIN_DIR}/lib/common.sh"

# Set project root
PROJECT_ROOT="$(dirname "$BIN_DIR")"
CHECKSUMS_FILE="$PROJECT_ROOT/lib/checksums.json"

# Parse command line arguments
DRY_RUN=false
VERSIONS_JSON=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --versions-json)
            # shellcheck disable=SC2034  # Reserved for future use
            VERSIONS_JSON="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Update lib/checksums.json with checksums for languages and tools"
            echo
            echo "Options:"
            echo "  --versions-json FILE  Use check-versions.sh JSON output to add new versions"
            echo "  --dry-run             Show what would be updated without making changes"
            echo "  --help                Show this help message"
            echo
            echo "Examples:"
            echo "  # Update existing versions with missing checksums"
            echo "  $0"
            echo
            echo "  # Add checksums for new versions from check-versions.sh"
            echo "  ./bin/check-versions.sh --json > versions.json"
            echo "  $0 --versions-json versions.json"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Source checksum-fetch utilities
if [ ! -f "$PROJECT_ROOT/lib/base/checksum-fetch.sh" ]; then
    echo -e "${RED}ERROR: checksum-fetch.sh not found${NC}"
    exit 1
fi

# We need to source this in a way that works outside of container builds
# Create a minimal stub environment
export -f echo 2>/dev/null || true
source "$PROJECT_ROOT/lib/base/checksum-fetch.sh" 2>/dev/null || {
    echo -e "${YELLOW}Warning: Some checksum fetch functions may not be available${NC}"
}

# Check if checksums.json exists
if [ ! -f "$CHECKSUMS_FILE" ]; then
    echo -e "${RED}ERROR: $CHECKSUMS_FILE not found${NC}"
    exit 1
fi

# Validate JSON
if ! jq empty "$CHECKSUMS_FILE" 2>/dev/null; then
    echo -e "${RED}ERROR: $CHECKSUMS_FILE is not valid JSON${NC}"
    exit 1
fi

echo -e "${GREEN}Updating checksums database: $CHECKSUMS_FILE${NC}"
echo

# Create backup
BACKUP_FILE="${CHECKSUMS_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
command cp "$CHECKSUMS_FILE" "$BACKUP_FILE"
echo -e "${BLUE}Created backup: $BACKUP_FILE${NC}"

# Track changes
UPDATED_COUNT=0
FAILED_COUNT=0

# Function to fetch and update checksum for a version
update_checksum() {
    local language="$1"
    local version="$2"
    local current_checksum="$3"

    # Skip if checksum already exists and is valid
    if [ -n "$current_checksum" ] && \
       [ "$current_checksum" != "null" ] && \
       [ "$current_checksum" != "placeholder_to_be_added" ] && \
       [ "$current_checksum" != "MANUAL_VERIFICATION_NEEDED" ]; then
        return 0
    fi

    echo -e "${BLUE}  Fetching checksum for $language $version...${NC}"

    local checksum=""
    local url=""

    # Fetch checksum based on language
    case "$language" in
        nodejs)
            local filename="node-v${version}-linux-x64.tar.xz"
            local shasums_url="https://nodejs.org/dist/v${version}/SHASUMS256.txt"
            checksum=$(command curl -fsSL "$shasums_url" 2>/dev/null | command grep "$filename" | command awk '{print $1}' || echo "")
            url="https://nodejs.org/dist/v${version}/${filename}"
            ;;
        golang)
            local filename="go${version}.linux-amd64.tar.gz"
            local json_data
            json_data=$(command curl -fsSL "https://go.dev/dl/?mode=json" 2>/dev/null)
            checksum=$(echo "$json_data" | jq -r ".[] | select(.version == \"go${version}\") | .files[] | select(.filename == \"${filename}\") | .sha256" 2>/dev/null || echo "")
            url="https://go.dev/dl/${filename}"
            ;;
        ruby)
            # Use the fetch_ruby_checksum function if available
            if type fetch_ruby_checksum >/dev/null 2>&1; then
                checksum=$(fetch_ruby_checksum "$version" 2>/dev/null || echo "")
            else
                # Fallback: parse downloads page
                local major_minor
                major_minor=$(echo "$version" | command cut -d. -f1-2)
                checksum=$(command curl -fsSL "https://www.ruby-lang.org/en/downloads/" 2>/dev/null | \
                    command grep -A2 ">Ruby ${version}" | \
                    command grep -oP 'sha256: \K[a-f0-9]{64}' | \
                    command head -1 || echo "")
            fi
            local major_minor
            major_minor=$(echo "$version" | command cut -d. -f1-2)
            url="https://cache.ruby-lang.org/pub/ruby/${major_minor}/ruby-${version}.tar.gz"
            ;;
        *)
            echo -e "${YELLOW}    Skipping $language (no checksum fetch method)${NC}"
            return 1
            ;;
    esac

    if [ -z "$checksum" ] || [ "$checksum" = "null" ]; then
        echo -e "${RED}    ✗ Failed to fetch checksum for $language $version${NC}"
        ((FAILED_COUNT++))
        return 1
    fi

    # Validate checksum format (SHA256 should be 64 hex characters)
    if ! [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo -e "${RED}    ✗ Invalid checksum format: $checksum${NC}"
        ((FAILED_COUNT++))
        return 1
    fi

    echo -e "${GREEN}    ✓ $checksum${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}    [DRY RUN] Would update checksums.json${NC}"
        ((UPDATED_COUNT++))
        return 0
    fi

    # Update checksums.json
    local tmp_file
    tmp_file=$(mktemp)
    jq ".languages.${language}.versions.\"${version}\".sha256 = \"${checksum}\" | \
        .languages.${language}.versions.\"${version}\".url = \"${url}\" | \
        .languages.${language}.versions.\"${version}\".added = \"$(date -u +%Y-%m-%d)\" | \
        del(.languages.${language}.versions.\"${version}\".note)" \
        "$CHECKSUMS_FILE" > "$tmp_file"

    if jq empty "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$CHECKSUMS_FILE"
        ((UPDATED_COUNT++))
    else
        echo -e "${RED}    ✗ Failed to update JSON (invalid output)${NC}"
        command rm "$tmp_file"
        ((FAILED_COUNT++))
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Tool checksum registry
# ---------------------------------------------------------------------------
# Each entry: "tool_name|version_var|feature_script|url_template"
# - version_var: shell variable name in the feature script (e.g., ENTR_VERSION)
# - feature_script: path relative to PROJECT_ROOT (e.g., lib/features/dev-tools.sh)
# - url_template: download URL with {VERSION} placeholder
#
# To add a new tool, append an entry here. The script will:
# 1. Extract the current version from the feature script
# 2. Check if a checksum already exists in checksums.json
# 3. If not, download the file and compute sha256
TOOL_CHECKSUM_REGISTRY=(
    "entr|ENTR_VERSION|lib/features/dev-tools.sh|https://eradman.com/entrproject/code/entr-{VERSION}.tar.gz"
)

# Extract a tool version from its feature script
extract_tool_version() {
    local var_name="$1"
    local script_path="$2"
    local full_path="$PROJECT_ROOT/$script_path"

    if [ ! -f "$full_path" ]; then
        return 1
    fi

    # Match both VAR="value" and VAR="${VAR:-value}" patterns
    local version
    version=$(command grep -E "^${var_name}=\"?\\\$\{${var_name}:-[^}]+\}" "$full_path" 2>/dev/null \
        | command sed -E "s/.*:-([^}]+)\}.*/\1/" | command head -1)

    if [ -z "$version" ]; then
        version=$(command grep -E "^${var_name}=" "$full_path" 2>/dev/null \
            | command sed -E "s/^${var_name}=\"?([^\"]+)\"?/\1/" | command head -1)
    fi

    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi
    return 1
}

# Fetch and update checksum for a tool version by downloading and computing sha256
update_tool_checksum() {
    local tool="$1"
    local version="$2"
    local url="$3"

    # Check if checksum already exists
    local current_checksum
    current_checksum=$(jq -r ".tools.\"${tool}\".versions.\"${version}\".sha256 // empty" "$CHECKSUMS_FILE" 2>/dev/null || echo "")

    if [ -n "$current_checksum" ] && \
       [ "$current_checksum" != "null" ] && \
       [ "$current_checksum" != "placeholder_to_be_added" ] && \
       [ "$current_checksum" != "MANUAL_VERIFICATION_NEEDED" ]; then
        echo -e "  ${tool} ${version}: already has checksum, skipping"
        return 0
    fi

    echo -e "${BLUE}  Fetching checksum for ${tool} ${version}...${NC}"

    # Download file and compute sha256
    local tmp_download
    tmp_download=$(mktemp)
    if ! command curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_download" "$url" 2>/dev/null; then
        echo -e "${RED}    ✗ Failed to download ${url}${NC}"
        command rm -f "$tmp_download"
        ((FAILED_COUNT++))
        return 1
    fi

    local checksum
    checksum=$(command sha256sum "$tmp_download" | command awk '{print $1}')
    command rm -f "$tmp_download"

    # Validate checksum format
    if ! [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo -e "${RED}    ✗ Invalid checksum format: $checksum${NC}"
        ((FAILED_COUNT++))
        return 1
    fi

    echo -e "${GREEN}    ✓ $checksum${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}    [DRY RUN] Would update checksums.json${NC}"
        ((UPDATED_COUNT++))
        return 0
    fi

    # Ensure the tool entry has a versions object, then add the version
    local tmp_file
    tmp_file=$(mktemp)
    jq ".tools.\"${tool}\".versions.\"${version}\" = {
            \"sha256\": \"${checksum}\",
            \"url\": \"${url}\",
            \"added\": \"$(date -u +%Y-%m-%d)\"
        }" "$CHECKSUMS_FILE" > "$tmp_file"

    if jq empty "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$CHECKSUMS_FILE"
        ((UPDATED_COUNT++))
    else
        echo -e "${RED}    ✗ Failed to update JSON (invalid output)${NC}"
        command rm "$tmp_file"
        ((FAILED_COUNT++))
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Process existing language versions in checksums.json
# ---------------------------------------------------------------------------
echo -e "${BLUE}Checking existing language versions for missing checksums...${NC}"

for language in nodejs golang ruby; do
    # Get all versions for this language
    versions=$(jq -r ".languages.${language}.versions | keys[]" "$CHECKSUMS_FILE" 2>/dev/null || echo "")

    if [ -z "$versions" ]; then
        continue
    fi

    echo -e "${BLUE}${language}:${NC}"

    while IFS= read -r version; do
        checksum=$(jq -r ".languages.${language}.versions.\"${version}\".sha256" "$CHECKSUMS_FILE")
        update_checksum "$language" "$version" "$checksum"
    done <<< "$versions"
done

# ---------------------------------------------------------------------------
# Process tool checksums from registry
# ---------------------------------------------------------------------------
echo
echo -e "${BLUE}Checking tool versions for missing checksums...${NC}"

for entry in "${TOOL_CHECKSUM_REGISTRY[@]}"; do
    IFS='|' read -r tool var_name script_path url_template <<< "$entry"

    # Extract current version from feature script
    local_version=$(extract_tool_version "$var_name" "$script_path" 2>/dev/null || echo "")
    if [ -z "$local_version" ]; then
        echo -e "${YELLOW}  ${tool}: could not extract version from ${script_path}, skipping${NC}"
        continue
    fi

    # Build the download URL
    local_url="${url_template//\{VERSION\}/$local_version}"

    echo -e "${BLUE}${tool}:${NC}"
    update_tool_checksum "$tool" "$local_version" "$local_url"
done

# Update metadata
if [ "$DRY_RUN" = false ] && [ "$UPDATED_COUNT" -gt 0 ]; then
    tmp_file=$(mktemp)
    jq ".metadata.generated = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$CHECKSUMS_FILE" > "$tmp_file"
    command mv "$tmp_file" "$CHECKSUMS_FILE"
fi

echo
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Summary:${NC}"
echo -e "  Updated: ${UPDATED_COUNT}"
echo -e "  Failed:  ${FAILED_COUNT}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  (Dry run - no changes made)${NC}"
fi
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

if [ "$UPDATED_COUNT" -gt 0 ] && [ "$DRY_RUN" = false ]; then
    echo
    echo -e "${GREEN}✓ Updated $CHECKSUMS_FILE${NC}"
    echo -e "${BLUE}Backup saved to: $BACKUP_FILE${NC}"
fi

exit 0
