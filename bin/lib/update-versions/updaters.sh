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

# Portable in-place sed across GNU sed (Linux) and BSD sed (macOS).
# Usage: sed_inplace 'EXPRESSION' file [file ...]
sed_inplace() {
    local expr="$1"
    shift
    command sed -i.bak "$expr" "$@"
    local f
    for f in "$@"; do
        command rm -f "$f.bak"
    done
}

# Add a bumped luggage-installed tool's new version to the vendored catalog
# snapshot (crates/luggage/testdata/catalog), which the image build COPYs to
# /opt/containers-db and resolves `luggage install <tool>@<version>` against.
# Without this, a Dockerfile pin can outrun the catalog and the build fails
# with "no version of <tool> matches spec <version>" (see issue #506).
#
# The `luggage catalog add-version` subcommand is additive and idempotent, so a
# re-run for an already-present version is a no-op. A missing luggage binary is
# a hard error rather than a silent skip: skipping would let the pin and the
# catalog drift, breaking the build the change is meant to keep green.
# Usage: update_luggage_catalog <tool> <version>
update_luggage_catalog() {
    local tool="$1"
    local version="$2"
    local catalog="$PROJECT_ROOT/crates/luggage/testdata/catalog"

    local luggage_bin="${LUGGAGE_BIN:-}"
    if [ -z "$luggage_bin" ]; then
        if [ -x "$PROJECT_ROOT/target/release/luggage" ]; then
            luggage_bin="$PROJECT_ROOT/target/release/luggage"
        elif [ -x "$PROJECT_ROOT/target/debug/luggage" ]; then
            luggage_bin="$PROJECT_ROOT/target/debug/luggage"
        else
            luggage_bin="$(command -v luggage 2>/dev/null || true)"
        fi
    fi

    if [ -z "$luggage_bin" ]; then
        echo -e "${RED}    ERROR: luggage binary not found; cannot update vendored catalog for ${tool}@${version}${NC}" >&2
        echo -e "${YELLOW}    Build it first (cargo build --release -p luggage) or set LUGGAGE_BIN.${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}    Updating vendored luggage catalog: ${tool}@${version}${NC}"
    "$luggage_bin" catalog add-version "${tool}@${version}" --catalog "$catalog"
}

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
                    sed_inplace "s/^ARG PYTHON_VERSION=.*/ARG PYTHON_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in python.sh
                    sed_inplace "s/PYTHON_VERSION=\"\${PYTHON_VERSION:-[^}]*}\"/PYTHON_VERSION=\"\${PYTHON_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/python.sh"
                    ;;
                Node.js)
                    sed_inplace "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in node.sh
                    sed_inplace "s/NODE_VERSION=\"\${NODE_VERSION:-[^}]*}\"/NODE_VERSION=\"\${NODE_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/node.sh"
                    ;;
                Go)
                    sed_inplace "s/^ARG GO_VERSION=.*/ARG GO_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in golang.sh
                    sed_inplace "s/GO_VERSION=\"\${GO_VERSION:-[^}]*}\"/GO_VERSION=\"\${GO_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/golang.sh"
                    ;;
                Rust)
                    sed_inplace "s/^ARG RUST_VERSION=.*/ARG RUST_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in rust.sh
                    sed_inplace "s/RUST_VERSION=\"\${RUST_VERSION:-[^}]*}\"/RUST_VERSION=\"\${RUST_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/rust.sh"
                    # Rust installs via luggage — keep the vendored catalog in
                    # lockstep with the pin (issue #506). Future luggage-managed
                    # tools add the same one-liner to their case.
                    update_luggage_catalog "rust" "$latest"
                    ;;
                Ruby)
                    sed_inplace "s/^ARG RUBY_VERSION=.*/ARG RUBY_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in ruby.sh
                    sed_inplace "s/RUBY_VERSION=\"\${RUBY_VERSION:-[^}]*}\"/RUBY_VERSION=\"\${RUBY_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/ruby.sh"
                    ;;
                Java)
                    sed_inplace "s/^ARG JAVA_VERSION=.*/ARG JAVA_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in java.sh
                    sed_inplace "s/JAVA_VERSION=\"\${JAVA_VERSION:-[^}]*}\"/JAVA_VERSION=\"\${JAVA_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/java.sh"
                    ;;
                R)
                    sed_inplace "s/^ARG R_VERSION=.*/ARG R_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in r.sh
                    sed_inplace "s/R_VERSION=\"\${R_VERSION:-[^}]*}\"/R_VERSION=\"\${R_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/r.sh"
                    ;;
                Kotlin)
                    sed_inplace "s/^ARG KOTLIN_VERSION=.*/ARG KOTLIN_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in kotlin.sh
                    sed_inplace "s/KOTLIN_VERSION=\"\${KOTLIN_VERSION:-[^}]*}\"/KOTLIN_VERSION=\"\${KOTLIN_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/kotlin.sh"
                    ;;
                android-cmdline-tools)
                    sed_inplace "s/^ARG ANDROID_CMDLINE_TOOLS_VERSION=.*/ARG ANDROID_CMDLINE_TOOLS_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in android.sh
                    sed_inplace "s/ANDROID_CMDLINE_TOOLS_VERSION=\"\${ANDROID_CMDLINE_TOOLS_VERSION:-[^}]*}\"/ANDROID_CMDLINE_TOOLS_VERSION=\"\${ANDROID_CMDLINE_TOOLS_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/android.sh"
                    ;;
                android-ndk)
                    sed_inplace "s/^ARG ANDROID_NDK_VERSION=.*/ARG ANDROID_NDK_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in android.sh
                    sed_inplace "s/ANDROID_NDK_VERSION=\"\${ANDROID_NDK_VERSION:-[^}]*}\"/ANDROID_NDK_VERSION=\"\${ANDROID_NDK_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/android.sh"
                    ;;
                kubectl)
                    sed_inplace "s/^ARG KUBECTL_VERSION=.*/ARG KUBECTL_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in kubernetes.sh
                    sed_inplace "s/KUBECTL_VERSION=\"\${KUBECTL_VERSION:-[^}]*}\"/KUBECTL_VERSION=\"\${KUBECTL_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/kubernetes.sh"
                    ;;
                k9s)
                    sed_inplace "s/^ARG K9S_VERSION=.*/ARG K9S_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in kubernetes.sh
                    sed_inplace "s/K9S_VERSION=\"\${K9S_VERSION:-[^}]*}\"/K9S_VERSION=\"\${K9S_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/kubernetes.sh"
                    ;;
                krew)
                    sed_inplace "s/^ARG KREW_VERSION=.*/ARG KREW_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in kubernetes.sh
                    sed_inplace "s/KREW_VERSION=\"\${KREW_VERSION:-[^}]*}\"/KREW_VERSION=\"\${KREW_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/kubernetes.sh"
                    ;;
                Helm)
                    sed_inplace "s/^ARG HELM_VERSION=.*/ARG HELM_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in kubernetes.sh
                    sed_inplace "s/HELM_VERSION=\"\${HELM_VERSION:-[^}]*}\"/HELM_VERSION=\"\${HELM_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/kubernetes.sh"
                    ;;
                Terragrunt)
                    sed_inplace "s/^ARG TERRAGRUNT_VERSION=.*/ARG TERRAGRUNT_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in terraform.sh
                    sed_inplace "s/TERRAGRUNT_VERSION=\"\${TERRAGRUNT_VERSION:-[^}]*}\"/TERRAGRUNT_VERSION=\"\${TERRAGRUNT_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/terraform.sh"
                    ;;
                terraform-docs)
                    sed_inplace "s/^ARG TFDOCS_VERSION=.*/ARG TFDOCS_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in terraform.sh
                    sed_inplace "s/TFDOCS_VERSION=\"\${TFDOCS_VERSION:-[^}]*}\"/TFDOCS_VERSION=\"\${TFDOCS_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/terraform.sh"
                    ;;
                tflint)
                    sed_inplace "s/^ARG TFLINT_VERSION=.*/ARG TFLINT_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in terraform.sh
                    sed_inplace "s/TFLINT_VERSION=\"\${TFLINT_VERSION:-[^}]*}\"/TFLINT_VERSION=\"\${TFLINT_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/terraform.sh"
                    ;;
                pixi)
                    sed_inplace "s/^ARG PIXI_VERSION=.*/ARG PIXI_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in mojo.sh
                    sed_inplace "s/PIXI_VERSION=\"\${PIXI_VERSION:-[^}]*}\"/PIXI_VERSION=\"\${PIXI_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/mojo.sh"
                    ;;
                Mise)
                    sed_inplace "s/^ARG MISE_VERSION=.*/ARG MISE_VERSION=$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in mise.sh
                    sed_inplace "s/MISE_VERSION=\"\${MISE_VERSION:-[^}]*}\"/MISE_VERSION=\"\${MISE_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/mise.sh"
                    ;;
                librarian)
                    # LIBRARIAN_REF is stored stripped of `v` for comparison but is
                    # used directly as a git tag, so re-add the `v` on writeback.
                    sed_inplace "s/^ARG LIBRARIAN_REF=.*/ARG LIBRARIAN_REF=v$latest/" "$PROJECT_ROOT/Dockerfile"
                    # Also update the fallback default in claude-code-setup.sh so it
                    # stays in sync with the ARG (enforced by version-drift.sh).
                    sed_inplace "s/LIBRARIAN_REF=\"\${LIBRARIAN_REF:-[^}]*}\"/LIBRARIAN_REF=\"\${LIBRARIAN_REF:-v$latest}\"/" "$PROJECT_ROOT/lib/features/claude-code-setup.sh"
                    ;;
                *)
                    echo -e "${RED}    ERROR: Unknown Dockerfile tool: $tool — add a case in updaters.sh${NC}" >&2
                    return 1
                    ;;
            esac
            ;;
        setup.sh)
            # Update version strings in base setup script
            # Preserve ${VAR:-default} pattern if present
            local script_path="$PROJECT_ROOT/lib/base/$file"
            case "$tool" in
                zoxide)
                    sed_inplace "s/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-[^}]*}\"/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^ZOXIDE_VERSION=\"[0-9][^\"]*\"/ZOXIDE_VERSION=\"\${ZOXIDE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cosign)
                    sed_inplace "s/COSIGN_VERSION=\"\${COSIGN_VERSION:-[^}]*}\"/COSIGN_VERSION=\"\${COSIGN_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^COSIGN_VERSION=\"[0-9][^\"]*\"/COSIGN_VERSION=\"\${COSIGN_VERSION:-$latest}\"/" "$script_path"
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
                    sed_inplace "s/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-[^}]*}\"/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^LAZYGIT_VERSION=\"[0-9][^\"]*\"/LAZYGIT_VERSION=\"\${LAZYGIT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                direnv)
                    sed_inplace "s/DIRENV_VERSION=\"\${DIRENV_VERSION:-[^}]*}\"/DIRENV_VERSION=\"\${DIRENV_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DIRENV_VERSION=\"[0-9][^\"]*\"/DIRENV_VERSION=\"\${DIRENV_VERSION:-$latest}\"/" "$script_path"
                    ;;
                act)
                    sed_inplace "s/ACT_VERSION=\"\${ACT_VERSION:-[^}]*}\"/ACT_VERSION=\"\${ACT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^ACT_VERSION=\"[0-9][^\"]*\"/ACT_VERSION=\"\${ACT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                delta)
                    sed_inplace "s/DELTA_VERSION=\"\${DELTA_VERSION:-[^}]*}\"/DELTA_VERSION=\"\${DELTA_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DELTA_VERSION=\"[0-9][^\"]*\"/DELTA_VERSION=\"\${DELTA_VERSION:-$latest}\"/" "$script_path"
                    ;;
                glab)
                    sed_inplace "s/GLAB_VERSION=\"\${GLAB_VERSION:-[^}]*}\"/GLAB_VERSION=\"\${GLAB_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^GLAB_VERSION=\"[0-9][^\"]*\"/GLAB_VERSION=\"\${GLAB_VERSION:-$latest}\"/" "$script_path"
                    ;;
                just)
                    sed_inplace "s/JUST_VERSION=\"\${JUST_VERSION:-[^}]*}\"/JUST_VERSION=\"\${JUST_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^JUST_VERSION=\"[0-9][^\"]*\"/JUST_VERSION=\"\${JUST_VERSION:-$latest}\"/" "$script_path"
                    ;;
                rumdl)
                    sed_inplace "s/RUMDL_VERSION=\"\${RUMDL_VERSION:-[^}]*}\"/RUMDL_VERSION=\"\${RUMDL_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^RUMDL_VERSION=\"[0-9][^\"]*\"/RUMDL_VERSION=\"\${RUMDL_VERSION:-$latest}\"/" "$script_path"
                    ;;
                conform)
                    sed_inplace "s/CONFORM_VERSION=\"\${CONFORM_VERSION:-[^}]*}\"/CONFORM_VERSION=\"\${CONFORM_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^CONFORM_VERSION=\"[0-9][^\"]*\"/CONFORM_VERSION=\"\${CONFORM_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mkcert)
                    sed_inplace "s/MKCERT_VERSION=\"\${MKCERT_VERSION:-[^}]*}\"/MKCERT_VERSION=\"\${MKCERT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^MKCERT_VERSION=\"[0-9][^\"]*\"/MKCERT_VERSION=\"\${MKCERT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                dive)
                    sed_inplace "s/DIVE_VERSION=\"\${DIVE_VERSION:-[^}]*}\"/DIVE_VERSION=\"\${DIVE_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DIVE_VERSION=\"[0-9][^\"]*\"/DIVE_VERSION=\"\${DIVE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                lazydocker)
                    sed_inplace "s/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-[^}]*}\"/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^LAZYDOCKER_VERSION=\"[0-9][^\"]*\"/LAZYDOCKER_VERSION=\"\${LAZYDOCKER_VERSION:-$latest}\"/" "$script_path"
                    ;;
                spring-boot-cli)
                    sed_inplace "s/SPRING_VERSION=\"\${SPRING_VERSION:-[^}]*}\"/SPRING_VERSION=\"\${SPRING_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^SPRING_VERSION=\"[0-9][^\"]*\"/SPRING_VERSION=\"\${SPRING_VERSION:-$latest}\"/" "$script_path"
                    ;;
                jbang)
                    sed_inplace "s/JBANG_VERSION=\"\${JBANG_VERSION:-[^}]*}\"/JBANG_VERSION=\"\${JBANG_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^JBANG_VERSION=\"[0-9][^\"]*\"/JBANG_VERSION=\"\${JBANG_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mvnd)
                    sed_inplace "s/MVND_VERSION=\"\${MVND_VERSION:-[^}]*}\"/MVND_VERSION=\"\${MVND_VERSION:-$latest}\"/" "$script_path"
                    # mvnd version may be indented (inside if block), so don't anchor to ^
                    sed_inplace "s/MVND_VERSION=\"[0-9][^\"]*\"/MVND_VERSION=\"$latest\"/" "$script_path"
                    ;;
                google-java-format)
                    sed_inplace "s/GJF_VERSION=\"\${GJF_VERSION:-[^}]*}\"/GJF_VERSION=\"\${GJF_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^GJF_VERSION=\"[0-9][^\"]*\"/GJF_VERSION=\"\${GJF_VERSION:-$latest}\"/" "$script_path"
                    ;;
                jmh)
                    sed_inplace "s/JMH_VERSION=\"\${JMH_VERSION:-[^}]*}\"/JMH_VERSION=\"\${JMH_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^JMH_VERSION=\"[0-9][^\"]*\"/JMH_VERSION=\"\${JMH_VERSION:-$latest}\"/" "$script_path"
                    ;;
                duf)
                    sed_inplace "s/DUF_VERSION=\"\${DUF_VERSION:-[^}]*}\"/DUF_VERSION=\"\${DUF_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DUF_VERSION=\"[0-9][^\"]*\"/DUF_VERSION=\"\${DUF_VERSION:-$latest}\"/" "$script_path"
                    ;;
                dua)
                    sed_inplace "s/DUA_VERSION=\"\${DUA_VERSION:-[^}]*}\"/DUA_VERSION=\"\${DUA_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DUA_VERSION=\"[0-9][^\"]*\"/DUA_VERSION=\"\${DUA_VERSION:-$latest}\"/" "$script_path"
                    ;;
                entr)
                    sed_inplace "s/ENTR_VERSION=\"\${ENTR_VERSION:-[^}]*}\"/ENTR_VERSION=\"\${ENTR_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^ENTR_VERSION=\"[0-9][^\"]*\"/ENTR_VERSION=\"\${ENTR_VERSION:-$latest}\"/" "$script_path"
                    ;;
                biome)
                    sed_inplace "s/BIOME_VERSION=\"\${BIOME_VERSION:-[^}]*}\"/BIOME_VERSION=\"\${BIOME_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^BIOME_VERSION=\"[0-9][^\"]*\"/BIOME_VERSION=\"\${BIOME_VERSION:-$latest}\"/" "$script_path"
                    ;;
                taplo)
                    sed_inplace "s/TAPLO_VERSION=\"\${TAPLO_VERSION:-[^}]*}\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^TAPLO_VERSION=\"[0-9][^\"]*\"/TAPLO_VERSION=\"\${TAPLO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                lefthook)
                    sed_inplace "s/LEFTHOOK_VERSION=\"\${LEFTHOOK_VERSION:-[^}]*}\"/LEFTHOOK_VERSION=\"\${LEFTHOOK_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^LEFTHOOK_VERSION=\"[0-9][^\"]*\"/LEFTHOOK_VERSION=\"\${LEFTHOOK_VERSION:-$latest}\"/" "$script_path"
                    ;;
                gitleaks)
                    sed_inplace "s/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-[^}]*}\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^GITLEAKS_VERSION=\"[0-9][^\"]*\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mado)
                    sed_inplace "s/MADO_VERSION=\"\${MADO_VERSION:-[^}]*}\"/MADO_VERSION=\"\${MADO_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^MADO_VERSION=\"[0-9][^\"]*\"/MADO_VERSION=\"\${MADO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                dprint)
                    sed_inplace "s/DPRINT_VERSION=\"\${DPRINT_VERSION:-[^}]*}\"/DPRINT_VERSION=\"\${DPRINT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DPRINT_VERSION=\"[0-9][^\"]*\"/DPRINT_VERSION=\"\${DPRINT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                osv-scanner)
                    sed_inplace "s/OSV_SCANNER_VERSION=\"\${OSV_SCANNER_VERSION:-[^}]*}\"/OSV_SCANNER_VERSION=\"\${OSV_SCANNER_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^OSV_SCANNER_VERSION=\"[0-9][^\"]*\"/OSV_SCANNER_VERSION=\"\${OSV_SCANNER_VERSION:-$latest}\"/" "$script_path"
                    ;;
                yq)
                    sed_inplace "s/YQ_VERSION=\"\${YQ_VERSION:-[^}]*}\"/YQ_VERSION=\"\${YQ_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^YQ_VERSION=\"[0-9][^\"]*\"/YQ_VERSION=\"\${YQ_VERSION:-$latest}\"/" "$script_path"
                    ;;
                Poetry)
                    sed_inplace "s/POETRY_VERSION=\"\${POETRY_VERSION:-[^}]*}\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^POETRY_VERSION=\"[0-9][^\"]*\"/POETRY_VERSION=\"\${POETRY_VERSION:-$latest}\"/" "$script_path"
                    ;;
                uv)
                    sed_inplace "s/UV_VERSION=\"\${UV_VERSION:-[^}]*}\"/UV_VERSION=\"\${UV_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^UV_VERSION=\"[0-9][^\"]*\"/UV_VERSION=\"\${UV_VERSION:-$latest}\"/" "$script_path"
                    ;;
                ktlint)
                    sed_inplace "s/KTLINT_VERSION=\"\${KTLINT_VERSION:-[^}]*}\"/KTLINT_VERSION=\"\${KTLINT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^KTLINT_VERSION=\"[0-9][^\"]*\"/KTLINT_VERSION=\"\${KTLINT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                detekt)
                    sed_inplace "s/DETEKT_VERSION=\"\${DETEKT_VERSION:-[^}]*}\"/DETEKT_VERSION=\"\${DETEKT_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^DETEKT_VERSION=\"[0-9][^\"]*\"/DETEKT_VERSION=\"\${DETEKT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                kotlin-language-server)
                    sed_inplace "s/KLS_VERSION=\"\${KLS_VERSION:-[^}]*}\"/KLS_VERSION=\"\${KLS_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^KLS_VERSION=\"[0-9][^\"]*\"/KLS_VERSION=\"\${KLS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                jdtls)
                    sed_inplace "s/JDTLS_VERSION=\"\${JDTLS_VERSION:-[^}]*}\"/JDTLS_VERSION=\"\${JDTLS_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^JDTLS_VERSION=\"[0-9][^\"]*\"/JDTLS_VERSION=\"\${JDTLS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                # Cargo tools pinned in rust.sh and rust-dev.sh. cargo-watch and
                # mdbook are defined in both files and must be kept in sync.
                cargo-watch)
                    sed_inplace "s/CARGO_WATCH_VERSION=\"\${CARGO_WATCH_VERSION:-[^}]*}\"/CARGO_WATCH_VERSION=\"\${CARGO_WATCH_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/rust.sh"
                    sed_inplace "s/CARGO_WATCH_VERSION=\"\${CARGO_WATCH_VERSION:-[^}]*}\"/CARGO_WATCH_VERSION=\"\${CARGO_WATCH_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/rust-dev.sh"
                    ;;
                mdbook)
                    sed_inplace "s/MDBOOK_VERSION=\"\${MDBOOK_VERSION:-[^}]*}\"/MDBOOK_VERSION=\"\${MDBOOK_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/rust.sh"
                    sed_inplace "s/MDBOOK_VERSION=\"\${MDBOOK_VERSION:-[^}]*}\"/MDBOOK_VERSION=\"\${MDBOOK_VERSION:-$latest}\"/" "$PROJECT_ROOT/lib/features/rust-dev.sh"
                    ;;
                mdbook-mermaid)
                    sed_inplace "s/MDBOOK_MERMAID_VERSION=\"\${MDBOOK_MERMAID_VERSION:-[^}]*}\"/MDBOOK_MERMAID_VERSION=\"\${MDBOOK_MERMAID_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mdbook-toc)
                    sed_inplace "s/MDBOOK_TOC_VERSION=\"\${MDBOOK_TOC_VERSION:-[^}]*}\"/MDBOOK_TOC_VERSION=\"\${MDBOOK_TOC_VERSION:-$latest}\"/" "$script_path"
                    ;;
                mdbook-admonish)
                    sed_inplace "s/MDBOOK_ADMONISH_VERSION=\"\${MDBOOK_ADMONISH_VERSION:-[^}]*}\"/MDBOOK_ADMONISH_VERSION=\"\${MDBOOK_ADMONISH_VERSION:-$latest}\"/" "$script_path"
                    ;;
                tree-sitter-cli)
                    sed_inplace "s/TREE_SITTER_CLI_VERSION=\"\${TREE_SITTER_CLI_VERSION:-[^}]*}\"/TREE_SITTER_CLI_VERSION=\"\${TREE_SITTER_CLI_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-expand)
                    sed_inplace "s/CARGO_EXPAND_VERSION=\"\${CARGO_EXPAND_VERSION:-[^}]*}\"/CARGO_EXPAND_VERSION=\"\${CARGO_EXPAND_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-modules)
                    sed_inplace "s/CARGO_MODULES_VERSION=\"\${CARGO_MODULES_VERSION:-[^}]*}\"/CARGO_MODULES_VERSION=\"\${CARGO_MODULES_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-outdated)
                    sed_inplace "s/CARGO_OUTDATED_VERSION=\"\${CARGO_OUTDATED_VERSION:-[^}]*}\"/CARGO_OUTDATED_VERSION=\"\${CARGO_OUTDATED_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-sweep)
                    sed_inplace "s/CARGO_SWEEP_VERSION=\"\${CARGO_SWEEP_VERSION:-[^}]*}\"/CARGO_SWEEP_VERSION=\"\${CARGO_SWEEP_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-audit)
                    sed_inplace "s/CARGO_AUDIT_VERSION=\"\${CARGO_AUDIT_VERSION:-[^}]*}\"/CARGO_AUDIT_VERSION=\"\${CARGO_AUDIT_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-deny)
                    sed_inplace "s/CARGO_DENY_VERSION=\"\${CARGO_DENY_VERSION:-[^}]*}\"/CARGO_DENY_VERSION=\"\${CARGO_DENY_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-geiger)
                    sed_inplace "s/CARGO_GEIGER_VERSION=\"\${CARGO_GEIGER_VERSION:-[^}]*}\"/CARGO_GEIGER_VERSION=\"\${CARGO_GEIGER_VERSION:-$latest}\"/" "$script_path"
                    ;;
                bacon)
                    sed_inplace "s/BACON_VERSION=\"\${BACON_VERSION:-[^}]*}\"/BACON_VERSION=\"\${BACON_VERSION:-$latest}\"/" "$script_path"
                    ;;
                tokei)
                    sed_inplace "s/TOKEI_VERSION=\"\${TOKEI_VERSION:-[^}]*}\"/TOKEI_VERSION=\"\${TOKEI_VERSION:-$latest}\"/" "$script_path"
                    ;;
                hyperfine-cargo)
                    sed_inplace "s/HYPERFINE_CARGO_VERSION=\"\${HYPERFINE_CARGO_VERSION:-[^}]*}\"/HYPERFINE_CARGO_VERSION=\"\${HYPERFINE_CARGO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                just-cargo)
                    sed_inplace "s/JUST_CARGO_VERSION=\"\${JUST_CARGO_VERSION:-[^}]*}\"/JUST_CARGO_VERSION=\"\${JUST_CARGO_VERSION:-$latest}\"/" "$script_path"
                    ;;
                sccache)
                    sed_inplace "s/SCCACHE_VERSION=\"\${SCCACHE_VERSION:-[^}]*}\"/SCCACHE_VERSION=\"\${SCCACHE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                cargo-release)
                    sed_inplace "s/CARGO_RELEASE_VERSION=\"\${CARGO_RELEASE_VERSION:-[^}]*}\"/CARGO_RELEASE_VERSION=\"\${CARGO_RELEASE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                taplo-cli)
                    sed_inplace "s/TAPLO_CLI_VERSION=\"\${TAPLO_CLI_VERSION:-[^}]*}\"/TAPLO_CLI_VERSION=\"\${TAPLO_CLI_VERSION:-$latest}\"/" "$script_path"
                    ;;
                vale)
                    sed_inplace "s/VALE_VERSION=\"\${VALE_VERSION:-[^}]*}\"/VALE_VERSION=\"\${VALE_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^VALE_VERSION=\"[0-9][^\"]*\"/VALE_VERSION=\"\${VALE_VERSION:-$latest}\"/" "$script_path"
                    ;;
                typos)
                    sed_inplace "s/TYPOS_VERSION=\"\${TYPOS_VERSION:-[^}]*}\"/TYPOS_VERSION=\"\${TYPOS_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^TYPOS_VERSION=\"[0-9][^\"]*\"/TYPOS_VERSION=\"\${TYPOS_VERSION:-$latest}\"/" "$script_path"
                    ;;
                codegraph)
                    sed_inplace "s/CODEGRAPH_VERSION=\"\${CODEGRAPH_VERSION:-[^}]*}\"/CODEGRAPH_VERSION=\"\${CODEGRAPH_VERSION:-$latest}\"/" "$script_path"
                    sed_inplace "s/^CODEGRAPH_VERSION=\"[0-9][^\"]*\"/CODEGRAPH_VERSION=\"\${CODEGRAPH_VERSION:-$latest}\"/" "$script_path"
                    ;;
                Trivy)
                    ;; # Trivy is installed via APT (no version to update in script)
                *)
                    echo -e "${RED}    ERROR: Unknown shell script tool: $tool — add a case in updaters.sh${NC}" >&2
                    return 1
                    ;;
            esac
            ;;
        ci.yml)
            # Update GitHub Actions versions
            local workflow_path="$PROJECT_ROOT/.github/workflows/$file"
            case "$tool" in
                trivy-action)
                    # Upstream switched to `v`-prefixed tags at v0.36.0.
                    # Always write `v$latest` — both the new convention
                    # and old `v`-prefixed releases work; bare-numeric
                    # tags like `0.35.0` are no longer published.
                    sed_inplace "s|uses: aquasecurity/trivy-action@v\{0,1\}[0-9.]*|uses: aquasecurity/trivy-action@v$latest|g" "$workflow_path"
                    ;;
                *)
                    echo -e "${RED}    ERROR: Unknown ci.yml tool: $tool — add a case in updaters.sh${NC}" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}    ERROR: Unknown file type: $file (tool: $tool) — add a case in updaters.sh${NC}" >&2
            return 1
            ;;
    esac
}
