#!/bin/bash
# Version updater functions for update-versions.sh
#
# Description:
#   Contains the update_version() function that handles updating version
#   strings across different file types (Dockerfile, shell scripts, CI files).
#
# Usage:
#   source "${BIN_DIR}/lib/update-versions/updaters.sh"
#   update_version "Python" "3.12.7" "3.12.8" "Dockerfile"

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
                    # mvnd version may be indented (inside if block), so don't anchor to ^
                    command sed -i "s/MVND_VERSION=\"[0-9][^\"]*\"/MVND_VERSION=\"$latest\"/" "$script_path"
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
                    # Keep biome.json schema version in sync
                    if [ -f "$PROJECT_ROOT/biome.json" ]; then
                        command sed -i "s|biomejs.dev/schemas/[0-9][0-9.]*/schema.json|biomejs.dev/schemas/$latest/schema.json|" "$PROJECT_ROOT/biome.json"
                    fi
                    ;;
                taplo)
                    command sed -i "s/TAPLO_VERSION=\"\${TAPLO_VERSION:-[^}]*}\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^TAPLO_VERSION=\"[0-9][^\"]*\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                Poetry)
                    command sed -i "s/POETRY_VERSION=\"\${POETRY_VERSION:-[^}]*}\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^POETRY_VERSION=\"[0-9][^\"]*\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    ;;
                uv)
                    command sed -i "s/UV_VERSION=\"\${UV_VERSION:-[^}]*}\"/UV_VERSION=\"\${UV_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^UV_VERSION=\"[0-9][^\"]*\"/UV_VERSION=\"\${UV_VERSION:-$latest}\"/" "$script_path"
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
                jdtls)
                    command sed -i "s/JDTLS_VERSION=\"\${JDTLS_VERSION:-[^}]*}\"/JDTLS_VERSION=\"\${JDTLS_VERSION:-$latest}\"/" "$script_path"
                    command sed -i "s/^JDTLS_VERSION=\"[0-9][^\"]*\"/JDTLS_VERSION=\"\${JDTLS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                Trivy)
                    ;; # Trivy is installed via APT (no version to update in script)
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
