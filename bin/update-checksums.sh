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
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    # Validate checksum format (SHA256 should be 64 hex characters)
    if ! [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo -e "${RED}    ✗ Invalid checksum format: $checksum${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    echo -e "${GREEN}    ✓ $checksum${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}    [DRY RUN] Would update checksums.json${NC}"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
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
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        echo -e "${RED}    ✗ Failed to update JSON (invalid output)${NC}"
        command rm "$tmp_file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Tool checksum registry
# ---------------------------------------------------------------------------
# Architecture-independent (4 fields): "tool|var|script|url_template"
# Architecture-dependent (5 fields):   "tool|var|script|amd64_url|arm64_url"
#
# URL templates use {VERSION} placeholder, substituted at runtime.
#
# To add a new tool, append an entry here. The script will:
# 1. Extract the current version from the feature script
# 2. Check if a checksum already exists in checksums.json
# 3. If not, download the file(s) and compute sha256

# Architecture-independent tools (same file for all platforms)
TOOL_CHECKSUM_REGISTRY_NOARCH=(
    "entr|ENTR_VERSION|lib/features/dev-tools.sh|https://eradman.com/entrproject/code/entr-{VERSION}.tar.gz"
    "kotlin-compiler|KOTLIN_VERSION|lib/features/kotlin.sh|https://github.com/JetBrains/kotlin/releases/download/v{VERSION}/kotlin-compiler-{VERSION}.zip"
    "spring-boot-cli|SPRING_VERSION|lib/features/java-dev.sh|https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/{VERSION}/spring-boot-cli-{VERSION}-bin.tar.gz"
    "jbang|JBANG_VERSION|lib/features/java-dev.sh|https://github.com/jbangdev/jbang/releases/download/v{VERSION}/jbang-{VERSION}.tar"
)

# Architecture-dependent tools (different files per arch)
TOOL_CHECKSUM_REGISTRY_ARCH=(
    "direnv|DIRENV_VERSION|lib/features/dev-tools.sh|https://github.com/direnv/direnv/releases/download/v{VERSION}/direnv.linux-amd64|https://github.com/direnv/direnv/releases/download/v{VERSION}/direnv.linux-arm64"
    "delta|DELTA_VERSION|lib/features/dev-tools.sh|https://github.com/dandavison/delta/releases/download/{VERSION}/delta-{VERSION}-x86_64-unknown-linux-gnu.tar.gz|https://github.com/dandavison/delta/releases/download/{VERSION}/delta-{VERSION}-aarch64-unknown-linux-gnu.tar.gz"
    "mkcert|MKCERT_VERSION|lib/features/dev-tools.sh|https://github.com/FiloSottile/mkcert/releases/download/v{VERSION}/mkcert-v{VERSION}-linux-amd64|https://github.com/FiloSottile/mkcert/releases/download/v{VERSION}/mkcert-v{VERSION}-linux-arm64"
    "biome|BIOME_VERSION|lib/features/dev-tools.sh|https://github.com/biomejs/biome/releases/download/@biomejs/biome@{VERSION}/biome-linux-x64|https://github.com/biomejs/biome/releases/download/@biomejs/biome@{VERSION}/biome-linux-arm64"
    "taplo|TAPLO_VERSION|lib/features/dev-tools.sh|https://github.com/tamasfe/taplo/releases/download/{VERSION}/taplo-linux-x86_64.gz|https://github.com/tamasfe/taplo/releases/download/{VERSION}/taplo-linux-aarch64.gz"
    "eza|EZA_VERSION|lib/features/dev-tools.sh|https://github.com/eza-community/eza/releases/download/v{VERSION}/eza_x86_64-unknown-linux-gnu.tar.gz|https://github.com/eza-community/eza/releases/download/v{VERSION}/eza_aarch64-unknown-linux-gnu.tar.gz"
    "cloudflared|CLOUDFLARED_VERSION|lib/features/cloudflare.sh|https://github.com/cloudflare/cloudflared/releases/download/{VERSION}/cloudflared-linux-amd64.deb|https://github.com/cloudflare/cloudflared/releases/download/{VERSION}/cloudflared-linux-arm64.deb"
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
            | command sed -E "s/^${var_name}=\"?([^\"]+)\"?.*/\1/" | command head -1)
    fi

    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi
    return 1
}

# Download a URL and return its sha256
_download_and_hash() {
    local url="$1"
    local tmp_download
    tmp_download=$(mktemp)

    if ! command curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_download" "$url" 2>/dev/null; then
        command rm -f "$tmp_download"
        return 1
    fi

    local checksum
    checksum=$(command sha256sum "$tmp_download" | command awk '{print $1}')
    command rm -f "$tmp_download"

    # Validate checksum format
    if ! [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        return 1
    fi

    echo "$checksum"
}

# Update checksum for an architecture-independent tool
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

    local checksum
    checksum=$(_download_and_hash "$url") || {
        echo -e "${RED}    ✗ Failed to download or hash ${url}${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    }

    echo -e "${GREEN}    ✓ $checksum${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}    [DRY RUN] Would update checksums.json${NC}"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp)
    jq ".tools.\"${tool}\".versions.\"${version}\" = {
            \"sha256\": \"${checksum}\",
            \"url\": \"${url}\",
            \"added\": \"$(date -u +%Y-%m-%d)\"
        }" "$CHECKSUMS_FILE" > "$tmp_file"

    if jq empty "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$CHECKSUMS_FILE"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        echo -e "${RED}    ✗ Failed to update JSON (invalid output)${NC}"
        command rm "$tmp_file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

# Update checksums for an architecture-dependent tool (both amd64 and arm64)
update_tool_checksum_arch() {
    local tool="$1"
    local version="$2"
    local amd64_url="$3"
    local arm64_url="$4"

    # Check if both arch checksums already exist
    local amd64_checksum arm64_checksum
    amd64_checksum=$(jq -r ".tools.\"${tool}\".versions.\"${version}\".checksums.amd64.sha256 // empty" "$CHECKSUMS_FILE" 2>/dev/null || echo "")
    arm64_checksum=$(jq -r ".tools.\"${tool}\".versions.\"${version}\".checksums.arm64.sha256 // empty" "$CHECKSUMS_FILE" 2>/dev/null || echo "")

    local needs_amd64=true needs_arm64=true
    if [ -n "$amd64_checksum" ] && [ "$amd64_checksum" != "null" ] && \
       [ "$amd64_checksum" != "placeholder_to_be_added" ]; then
        needs_amd64=false
    fi
    if [ -n "$arm64_checksum" ] && [ "$arm64_checksum" != "null" ] && \
       [ "$arm64_checksum" != "placeholder_to_be_added" ]; then
        needs_arm64=false
    fi

    if [ "$needs_amd64" = false ] && [ "$needs_arm64" = false ]; then
        echo -e "  ${tool} ${version}: already has checksums for both architectures, skipping"
        return 0
    fi

    echo -e "${BLUE}  Fetching checksums for ${tool} ${version}...${NC}"

    local new_amd64="" new_arm64=""

    if [ "$needs_amd64" = true ]; then
        echo -e "${BLUE}    amd64: downloading...${NC}"
        new_amd64=$(_download_and_hash "$amd64_url") || {
            echo -e "${RED}    ✗ Failed to download amd64: ${amd64_url}${NC}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        }
        echo -e "${GREEN}    amd64: ✓ $new_amd64${NC}"
    fi

    if [ "$needs_arm64" = true ]; then
        echo -e "${BLUE}    arm64: downloading...${NC}"
        new_arm64=$(_download_and_hash "$arm64_url") || {
            echo -e "${RED}    ✗ Failed to download arm64: ${arm64_url}${NC}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        }
        echo -e "${GREEN}    arm64: ✓ $new_arm64${NC}"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}    [DRY RUN] Would update checksums.json${NC}"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    fi

    # Build the version entry with per-arch checksums
    local tmp_file
    tmp_file=$(mktemp)

    # Use final values (new or existing)
    local final_amd64="${new_amd64:-$amd64_checksum}"
    local final_arm64="${new_arm64:-$arm64_checksum}"

    jq ".tools.\"${tool}\".versions.\"${version}\" = {
            \"checksums\": {
                \"amd64\": {
                    \"sha256\": \"${final_amd64}\",
                    \"url\": \"${amd64_url}\"
                },
                \"arm64\": {
                    \"sha256\": \"${final_arm64}\",
                    \"url\": \"${arm64_url}\"
                }
            },
            \"added\": \"$(date -u +%Y-%m-%d)\"
        }" "$CHECKSUMS_FILE" > "$tmp_file"

    if jq empty "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$CHECKSUMS_FILE"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        echo -e "${RED}    ✗ Failed to update JSON (invalid output)${NC}"
        command rm "$tmp_file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
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
# Process tool checksums from registries
# ---------------------------------------------------------------------------
echo
echo -e "${BLUE}Checking tool versions for missing checksums...${NC}"

# Architecture-independent tools
for entry in "${TOOL_CHECKSUM_REGISTRY_NOARCH[@]}"; do
    IFS='|' read -r tool var_name script_path url_template <<< "$entry"

    local_version=$(extract_tool_version "$var_name" "$script_path" 2>/dev/null || echo "")
    if [ -z "$local_version" ]; then
        echo -e "${YELLOW}  ${tool}: could not extract version from ${script_path}, skipping${NC}"
        continue
    fi

    local_url="${url_template//\{VERSION\}/$local_version}"

    echo -e "${BLUE}${tool}:${NC}"
    update_tool_checksum "$tool" "$local_version" "$local_url"
done

# Architecture-dependent tools
for entry in "${TOOL_CHECKSUM_REGISTRY_ARCH[@]}"; do
    IFS='|' read -r tool var_name script_path amd64_template arm64_template <<< "$entry"

    local_version=$(extract_tool_version "$var_name" "$script_path" 2>/dev/null || echo "")
    if [ -z "$local_version" ]; then
        echo -e "${YELLOW}  ${tool}: could not extract version from ${script_path}, skipping${NC}"
        continue
    fi

    local_amd64_url="${amd64_template//\{VERSION\}/$local_version}"
    local_arm64_url="${arm64_template//\{VERSION\}/$local_version}"

    echo -e "${BLUE}${tool}:${NC}"
    update_tool_checksum_arch "$tool" "$local_version" "$local_amd64_url" "$local_arm64_url"
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
