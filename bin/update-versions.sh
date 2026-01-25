#!/usr/bin/env bash
# Automatically update outdated versions found by check-versions.sh
set -euo pipefail

# Get script directory and source shared utilities
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BIN_DIR}/lib/common.sh"
source "${BIN_DIR}/lib/version-utils.sh"

# Set project root
PROJECT_ROOT="$(dirname "$BIN_DIR")"

# Allow override for testing
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$PROJECT_ROOT}"

# Parse command line arguments
DRY_RUN=false
AUTO_COMMIT=true
BUMP_VERSION=true
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-commit)
            AUTO_COMMIT=false
            shift
            ;;
        --no-bump)
            BUMP_VERSION=false
            shift
            ;;
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --dry-run       Show what would be updated without making changes"
            echo "  --no-commit     Update files but don't commit changes"
            echo "  --no-bump       Don't bump patch version after updates"
            echo "  --input FILE    Use JSON file instead of running check-versions.sh"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Note: validate_version() is now in bin/lib/version-utils.sh

# Function to update a version in a file
update_version() {
    local tool="$1"
    local current="$2"
    local latest="$3"
    local file="$4"

    # Validate the new version before updating
    if ! validate_version "$latest"; then
        echo -e "${RED}  ERROR: Invalid version format for $tool: '$latest'${NC}"
        echo -e "${YELLOW}  Skipping update for $tool${NC}"
        return 1
    fi

    # Also check that we're not downgrading (basic check)
    if [ "$current" = "$latest" ]; then
        echo -e "${YELLOW}  Skipping $tool: already at version $current${NC}"
        return 0
    fi

    echo -e "${BLUE}  Updating $tool: $current → $latest in $file${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY RUN] Would update $file"
        return
    fi

    # Update based on file type
    case "$file" in
        Dockerfile)
            # Update ARG lines in Dockerfile
            case "$tool" in
                Python)
                    command sed -i "s/^ARG PYTHON_VERSION=.*/ARG PYTHON_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Node.js)
                    command sed -i "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Go)
                    command sed -i "s/^ARG GO_VERSION=.*/ARG GO_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Rust)
                    command sed -i "s/^ARG RUST_VERSION=.*/ARG RUST_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Ruby)
                    command sed -i "s/^ARG RUBY_VERSION=.*/ARG RUBY_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in ruby.sh
                    command sed -i "s/RUBY_VERSION=\"\${RUBY_VERSION:-.*}\"/RUBY_VERSION=\"\${RUBY_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/ruby.sh"
                    ;;
                Java)
                    command sed -i "s/^ARG JAVA_VERSION=.*/ARG JAVA_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                R)
                    command sed -i "s/^ARG R_VERSION=.*/ARG R_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Kotlin)
                    command sed -i "s/^ARG KOTLIN_VERSION=.*/ARG KOTLIN_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                android-cmdline-tools)
                    command sed -i "s/^ARG ANDROID_CMDLINE_TOOLS_VERSION=.*/ARG ANDROID_CMDLINE_TOOLS_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                android-ndk)
                    command sed -i "s/^ARG ANDROID_NDK_VERSION=.*/ARG ANDROID_NDK_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                kubectl)
                    command sed -i "s/^ARG KUBECTL_VERSION=.*/ARG KUBECTL_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                k9s)
                    command sed -i "s/^ARG K9S_VERSION=.*/ARG K9S_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                krew)
                    command sed -i "s/^ARG KREW_VERSION=.*/ARG KREW_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Helm)
                    command sed -i "s/^ARG HELM_VERSION=.*/ARG HELM_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                Terragrunt)
                    command sed -i "s/^ARG TERRAGRUNT_VERSION=.*/ARG TERRAGRUNT_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                terraform-docs)
                    command sed -i "s/^ARG TFDOCS_VERSION=.*/ARG TFDOCS_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                tflint)
                    command sed -i "s/^ARG TFLINT_VERSION=.*/ARG TFLINT_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                pixi)
                    command sed -i "s/^ARG PIXI_VERSION=.*/ARG PIXI_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    ;;
                *)
                    echo -e "${YELLOW}    Warning: Unknown Dockerfile tool: $tool${NC}"
                    ;;
            esac
            ;;
        setup.sh)
            # Update version strings in base setup script
            # Preserve ${VAR:-default} pattern if present
            local script_path="$PROJECT_ROOT/lib/base/$file"
            case "$tool" in
                zoxide)
                    command sed -i "s/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-[^}]*}\"/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^ZOXIDE_VERSION=\"[0-9][^\"]*\"/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cosign)
                    command sed -i "s/COSIGN_VERSION=\"\${COSIGN_VERSION:-[^}]*}\"/COSIGN_VERSION=\"\${COSIGN_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^COSIGN_VERSION=\"[0-9][^\"]*\"/COSIGN_VERSION=\"\${COSIGN_VERSION:-$latest}\"/" "$script_path"
                    ;;
                *)
                    echo -e "${YELLOW}    Warning: Unknown base setup tool: $tool${NC}"
                    ;;
            esac
            ;;
        *.sh)
            # Update version strings in feature shell scripts
            # Preserve ${VAR:-default} pattern if present
            local script_path="$PROJECT_ROOT/lib/features/$file"
            case "$tool" in
                lazygit)
                    command sed -i "s/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-[^}]*}\"/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^LAZYGIT_VERSION=\"[0-9][^\"]*\"/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                direnv)
                    command sed -i "s/DIRENV_VERSION=\"\${DIRENV_VERSION:-[^}]*}\"/DIRENV_VERSION=\"\${DIRENV_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^DIRENV_VERSION=\"[0-9][^\"]*\"/DIRENV_VERSION=\"\${DIRENV_VERSION:-$latest}\"/" "$script_path"
                    ;;
                act)
                    command sed -i "s/ACT_VERSION=\"\${ACT_VERSION:-[^}]*}\"/ACT_VERSION=\"\${ACT_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^ACT_VERSION=\"[0-9][^\"]*\"/ACT_VERSION=\"\${ACT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                delta)
                    command sed -i "s/DELTA_VERSION=\"\${DELTA_VERSION:-[^}]*}\"/DELTA_VERSION=\"\${DELTA_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^DELTA_VERSION=\"[0-9][^\"]*\"/DELTA_VERSION=\"\${DELTA_VERSION:-$latest}\"/" "$script_path"
                    ;;
                glab)
                    command sed -i "s/GLAB_VERSION=\"\${GLAB_VERSION:-[^}]*}\"/GLAB_VERSION=\"\${GLAB_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^GLAB_VERSION=\"[0-9][^\"]*\"/GLAB_VERSION=\"\${GLAB_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mkcert)
                    command sed -i "s/MKCERT_VERSION=\"\${MKCERT_VERSION:-[^}]*}\"/MKCERT_VERSION=\"\${MKCERT_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^MKCERT_VERSION=\"[0-9][^\"]*\"/MKCERT_VERSION=\"\${MKCERT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                dive)
                    command sed -i "s/DIVE_VERSION=\"\${DIVE_VERSION:-[^}]*}\"/DIVE_VERSION=\"\${DIVE_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^DIVE_VERSION=\"[0-9][^\"]*\"/DIVE_VERSION=\"\${DIVE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                lazydocker)
                    command sed -i "s/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-[^}]*}\"/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^LAZYDOCKER_VERSION=\"[0-9][^\"]*\"/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-$latest}\"/" "$script_path"
                    ;;
                spring-boot-cli)
                    command sed -i "s/SPRING_VERSION=\"\${SPRING_VERSION:-[^}]*}\"/SPRING_VERSION=\"\${SPRING_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^SPRING_VERSION=\"[0-9][^\"]*\"/SPRING_VERSION=\"\${SPRING_VERSION:-$latest}\"/" "$script_path"
                    ;;
                jbang)
                    command sed -i "s/JBANG_VERSION=\"\${JBANG_VERSION:-[^}]*}\"/JBANG_VERSION=\"\${JBANG_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^JBANG_VERSION=\"[0-9][^\"]*\"/JBANG_VERSION=\"\${JBANG_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mvnd)
                    command sed -i "s/MVND_VERSION=\"\${MVND_VERSION:-[^}]*}\"/MVND_VERSION=\"\${MVND_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^MVND_VERSION=\"[0-9][^\"]*\"/MVND_VERSION=\"\${MVND_VERSION:-$latest}\"/" "$script_path"
                    ;;
                google-java-format)
                    command sed -i "s/GJF_VERSION=\"\${GJF_VERSION:-[^}]*}\"/GJF_VERSION=\"\${GJF_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^GJF_VERSION=\"[0-9][^\"]*\"/GJF_VERSION=\"\${GJF_VERSION:-$latest}\"/" "$script_path"
                    ;;
                jmh)
                    command sed -i "s/JMH_VERSION=\"\${JMH_VERSION:-[^}]*}\"/JMH_VERSION=\"\${JMH_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^JMH_VERSION=\"[0-9][^\"]*\"/JMH_VERSION=\"\${JMH_VERSION:-$latest}\"/" "$script_path"
                    ;;
                duf)
                    command sed -i "s/DUF_VERSION=\"\${DUF_VERSION:-[^}]*}\"/DUF_VERSION=\"\${DUF_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^DUF_VERSION=\"[0-9][^\"]*\"/DUF_VERSION=\"\${DUF_VERSION:-$latest}\"/" "$script_path"
                    ;;
                entr)
                    command sed -i "s/ENTR_VERSION=\"\${ENTR_VERSION:-[^}]*}\"/ENTR_VERSION=\"\${ENTR_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^ENTR_VERSION=\"[0-9][^\"]*\"/ENTR_VERSION=\"\${ENTR_VERSION:-$latest}\"/" "$script_path"
                    ;;
                biome)
                    command sed -i "s/BIOME_VERSION=\"\${BIOME_VERSION:-[^}]*}\"/BIOME_VERSION=\"\${BIOME_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^BIOME_VERSION=\"[0-9][^\"]*\"/BIOME_VERSION=\"\${BIOME_VERSION:-$latest}\"/" "$script_path"
                    ;;
                taplo)
                    command sed -i "s/TAPLO_VERSION=\"\${TAPLO_VERSION:-[^}]*}\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^TAPLO_VERSION=\"[0-9][^\"]*\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                Poetry)
                    command sed -i "s/POETRY_VERSION=\"\${POETRY_VERSION:-[^}]*}\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^POETRY_VERSION=\"[0-9][^\"]*\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    ;;
                ktlint)
                    command sed -i "s/KTLINT_VERSION=\"\${KTLINT_VERSION:-[^}]*}\"/KTLINT_VERSION=\"\${KTLINT_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^KTLINT_VERSION=\"[0-9][^\"]*\"/KTLINT_VERSION=\"\${KTLINT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                detekt)
                    command sed -i "s/DETEKT_VERSION=\"\${DETEKT_VERSION:-[^}]*}\"/DETEKT_VERSION=\"\${DETEKT_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^DETEKT_VERSION=\"[0-9][^\"]*\"/DETEKT_VERSION=\"\${DETEKT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                kotlin-language-server)
                    command sed -i "s/KLS_VERSION=\"\${KLS_VERSION:-[^}]*}\"/KLS_VERSION=\"\${KLS_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^KLS_VERSION=\"[0-9][^\"]*\"/KLS_VERSION=\"\${KLS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                *)
                    echo -e "${YELLOW}    Warning: Unknown shell script tool: $tool${NC}"
                    ;;
            esac
            ;;
        ci.yml)
            # Update GitHub Actions versions
            local workflow_path="$PROJECT_ROOT/.github/workflows/$file"
            case "$tool" in
                trivy-action)
                    command sed -i "s|uses: aquasecurity/trivy-action@[0-9.]*|uses: aquasecurity/trivy-action@$latest|g" "$workflow_path"
                    ;;
                *)
                    echo -e "${YELLOW}    Warning: Unknown ci.yml tool: $tool${NC}"
                    ;;
            esac
            ;;
        *)
            echo -e "${YELLOW}    Warning: Unknown file type: $file${NC}"
            ;;
    esac
}

# Main execution
echo -e "${GREEN}=== Container Version Updater ===${NC}"
echo ""

# Get version data
if [ -n "$INPUT_FILE" ]; then
    echo "Reading version data from $INPUT_FILE..."
    if [ ! -f "$INPUT_FILE" ]; then
        echo -e "${RED}Error: Input file not found: $INPUT_FILE${NC}"
        exit 1
    fi
    VERSION_DATA=$(command cat "$INPUT_FILE")
else
    echo "Running version check..."
    VERSION_DATA=$("$BIN_DIR/check-versions.sh" --json 2>/dev/null)
fi

# Extract outdated tools
OUTDATED=$(echo "$VERSION_DATA" | jq '[.tools[] | select(.status == "outdated")]')
UPDATE_COUNT=$(echo "$OUTDATED" | jq 'length')

if [ "$UPDATE_COUNT" -eq 0 ]; then
    echo -e "${GREEN}All versions are up to date!${NC}"
    exit 0
fi

echo -e "${YELLOW}Found $UPDATE_COUNT outdated version(s)${NC}"
echo ""

# Track if any updates were applied
UPDATES_APPLIED=false

# Track successful updates
SUCCESSFUL_UPDATES=0
FAILED_UPDATES=0

# Process each outdated tool
while IFS= read -r update; do
    TOOL=$(echo "$update" | jq -r '.tool')
    CURRENT=$(echo "$update" | jq -r '.current')
    LATEST=$(echo "$update" | jq -r '.latest')
    FILE=$(echo "$update" | jq -r '.file')

    if update_version "$TOOL" "$CURRENT" "$LATEST" "$FILE"; then
        SUCCESSFUL_UPDATES=$((SUCCESSFUL_UPDATES + 1))
        UPDATES_APPLIED=true
    else
        FAILED_UPDATES=$((FAILED_UPDATES + 1))
    fi
done < <(echo "$OUTDATED" | jq -c '.[]')

echo ""

# Update checksums for tools that require it
if [ "$UPDATES_APPLIED" = true ] && [ "$DRY_RUN" = false ]; then
    # Check if any Kubernetes tools were updated
    K8S_TOOLS_UPDATED=false
    while IFS= read -r update; do
        TOOL=$(echo "$update" | jq -r '.tool')
        if [ "$TOOL" = "k9s" ] || [ "$TOOL" = "krew" ] || [ "$TOOL" = "Helm" ]; then
            K8S_TOOLS_UPDATED=true
            break
        fi
    done < <(echo "$OUTDATED" | jq -c '.[]')

    # If Kubernetes tools were updated, update their checksums
    if [ "$K8S_TOOLS_UPDATED" = true ]; then
        echo -e "${BLUE}Updating Kubernetes tool checksums...${NC}"

        # Get current versions from Dockerfile
        K9S_VER=$(grep "^ARG K9S_VERSION=" "$PROJECT_ROOT/Dockerfile" | cut -d= -f2 | tr -d '"')
        KREW_VER=$(grep "^ARG KREW_VERSION=" "$PROJECT_ROOT/Dockerfile" | cut -d= -f2 | tr -d '"')
        HELM_VER=$(grep "^ARG HELM_VERSION=" "$PROJECT_ROOT/Dockerfile" | cut -d= -f2 | tr -d '"')

        if [ -n "$K9S_VER" ] && [ -n "$KREW_VER" ] && [ -n "$HELM_VER" ]; then
            if "$BIN_DIR/lib/update-versions/kubernetes-checksums.sh" "$K9S_VER" "$KREW_VER" "$HELM_VER"; then
                echo -e "${GREEN}✓ Kubernetes checksums updated${NC}"
            else
                echo -e "${RED}✗ Failed to update Kubernetes checksums${NC}"
                echo -e "${YELLOW}Manual checksum update may be required${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Could not determine all Kubernetes tool versions${NC}"
        fi
        echo ""
    fi
fi

# Handle commits and version bump
if [ "$UPDATES_APPLIED" = true ] && [ "$DRY_RUN" = false ]; then
    if [ "$AUTO_COMMIT" = true ]; then
        echo -e "${BLUE}Committing changes...${NC}"

        # Stage changes
        cd "$PROJECT_ROOT"
        git add -A

        # Create commit message with update details
        COMMIT_MSG="chore: Update dependency versions

Updated versions:"
        while IFS= read -r update; do
            TOOL=$(echo "$update" | jq -r '.tool')
            CURRENT=$(echo "$update" | jq -r '.current')
            LATEST=$(echo "$update" | jq -r '.latest')
            COMMIT_MSG="$COMMIT_MSG
- $TOOL: $CURRENT → $LATEST"
        done < <(echo "$OUTDATED" | jq -c '.[]')

        git commit -m "$COMMIT_MSG"
        echo -e "${GREEN}✓ Changes committed${NC}"

        # Bump version if requested
        if [ "$BUMP_VERSION" = true ]; then
            echo ""
            echo -e "${BLUE}Bumping patch version...${NC}"
            echo "y" | "$BIN_DIR/release.sh" patch

            # Commit version bump
            git add -A
            git commit -m "chore: Release patch version with dependency updates

Automated dependency updates applied."
            echo -e "${GREEN}✓ Version bumped${NC}"
        fi
    else
        echo -e "${YELLOW}Changes made but not committed (--no-commit flag set)${NC}"
    fi

    echo ""
    echo -e "${GREEN}=== Update Complete ===${NC}"
    echo "Updates applied: $SUCCESSFUL_UPDATES"
    if [ "$FAILED_UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}Updates skipped (invalid versions): $FAILED_UPDATES${NC}"
    fi
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry run complete - no changes made${NC}"
    else
        echo -e "${YELLOW}No updates applied${NC}"
    fi
fi
