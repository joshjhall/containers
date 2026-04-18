#!/bin/bash
# install-binary-tools.sh — Binary tool downloads, source builds, and symlinks
#
# Functions:
#   install_entr        — build entr from source tarball
#   install_fzf         — git clone fzf with retry logic
#   install_github_binary_tools — all install_github_release calls (includes lefthook)
#   create_tool_symlinks — fd/bat/fzf symlinks

install_entr() {
    log_message "Installing entr (file watcher)..."
    local ENTR_TARBALL="entr-${ENTR_VERSION}.tar.gz"
    local ENTR_URL="https://eradman.com/entrproject/code/${ENTR_TARBALL}"

    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || exit 1
    log_message "Downloading entr ${ENTR_VERSION}..."
    if ! command curl -L -f --retry 8 --retry-delay 10 --retry-all-errors --progress-bar -o "$ENTR_TARBALL" "$ENTR_URL"; then
        log_error "Failed to download entr ${ENTR_VERSION}"
        cd /
        return 1
    fi

    # Source checksum verification if available
    if [ -f /tmp/build-scripts/base/checksum-verification.sh ]; then
        source /tmp/build-scripts/base/checksum-verification.sh
        verify_download_or_fail "tool" "entr" "$ENTR_VERSION" "$ENTR_TARBALL" "$(dpkg --print-architecture)" || { cd /; return 1; }
    fi

    log_message "✓ entr v${ENTR_VERSION} downloaded successfully"

    log_command "Extracting entr source" \
        tar -xzf "$ENTR_TARBALL"

    log_command "Building entr" \
        bash -c "cd entr-${ENTR_VERSION} && ./configure && make && make install"

    cd /
}

install_fzf() {
    local max_retries=3
    local retry_delay=5
    local i

    for i in $(seq 1 $max_retries); do
        log_message "Cloning fzf repository (attempt $i/$max_retries)..."
        if log_command "Cloning fzf repository" \
            git clone --depth 1 https://github.com/junegunn/fzf.git /opt/fzf; then
            break
        fi

        if [ "$i" -lt "$max_retries" ]; then
            log_warning "Failed to clone fzf repository, retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        else
            log_warning "Failed to clone fzf repository after $max_retries attempts"
            return 1
        fi
    done

    export FZF_NO_UPDATE_RC=1
    retry_delay=5
    for i in $(seq 1 $max_retries); do
        log_message "Running fzf installer (attempt $i/$max_retries)..."
        if log_command "Installing fzf" \
            bash -c "cd /opt/fzf && ./install --bin"; then
            log_message "fzf installed successfully"
            return 0
        fi

        if [ "$i" -lt "$max_retries" ]; then
            log_warning "fzf installer failed, retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
    done

    log_warning "Failed to install fzf after $max_retries attempts"
    return 1
}

install_uv() {
    # Skip if uv is already installed (e.g., by python-dev via pip)
    if command -v uv &> /dev/null; then
        log_message "uv already installed (likely via python-dev), skipping..."
        return 0
    fi

    log_message "Installing uv ${UV_VERSION}..."

    # Architecture detection
    local arch
    arch=$(dpkg --print-architecture)
    local filename
    case "$arch" in
        amd64) filename="uv-x86_64-unknown-linux-gnu.tar.gz" ;;
        arm64) filename="uv-aarch64-unknown-linux-gnu.tar.gz" ;;
        *)
            log_warning "uv not available for architecture ${arch}, skipping..."
            return 1
            ;;
    esac

    local base_url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
    local file_url="${base_url}/${filename}"

    # Register Tier 3 SHA256 fetcher
    local _sha256_url="${file_url}.sha256"
    eval "_fetch_uv_checksum() {
        fetch_github_sha256_file '$_sha256_url' 2>/dev/null
    }"
    register_tool_checksum_fetcher "uv" "_fetch_uv_checksum"

    # Download to temp location
    local build_temp
    build_temp=$(create_secure_temp_dir)
    cd "$build_temp" || exit 1

    local local_file="uv-download"
    log_message "Downloading uv for ${arch}..."
    if ! command curl -L -f --retry 8 --retry-delay 10 --retry-all-errors --progress-bar -o "$local_file" "$file_url"; then
        log_error "Download failed for uv ${UV_VERSION}"
        cd /
        return 1
    fi

    # Run 4-tier verification
    verify_download_or_fail "tool" "uv" "$UV_VERSION" "$local_file" "$arch" || { cd /; return 1; }

    # Extract both uv and uvx binaries
    log_command "Extracting uv" \
        tar -xzf "$local_file"

    # Find and install both binaries from the extracted directory
    local found_uv
    found_uv=$(command find . -name "uv" -type f | command head -1)
    local found_uvx
    found_uvx=$(command find . -name "uvx" -type f | command head -1)

    if [ -z "$found_uv" ]; then
        log_error "Binary 'uv' not found after extracting"
        cd /
        return 1
    fi

    log_command "Installing uv binary" \
        command mv "$found_uv" "/usr/local/bin/uv"
    log_command "Setting uv permissions" \
        chmod +x "/usr/local/bin/uv"

    if [ -n "$found_uvx" ]; then
        log_command "Installing uvx binary" \
            command mv "$found_uvx" "/usr/local/bin/uvx"
        log_command "Setting uvx permissions" \
            chmod +x "/usr/local/bin/uvx"
    fi

    cd /
    log_message "✓ uv ${UV_VERSION} installed successfully"
    return 0
}

install_github_binary_tools() {
    # duf (modern disk usage utility)
    install_github_release "duf" "$DUF_VERSION" \
        "https://github.com/muesli/duf/releases/download/v${DUF_VERSION}" \
        "duf_${DUF_VERSION}_linux_amd64.deb" "duf_${DUF_VERSION}_linux_arm64.deb" \
        "checksums_txt" "dpkg" \
        || return 1

    # direnv (direct binary, no published checksums)
    install_github_release "direnv" "$DIRENV_VERSION" \
        "https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}" \
        "direnv.linux-amd64" "direnv.linux-arm64" \
        "calculate" "binary" \
        || return 1

    # lazygit (tar with binary at top level)
    install_github_release "lazygit" "$LAZYGIT_VERSION" \
        "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}" \
        "lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz" \
        "lazygit_${LAZYGIT_VERSION}_linux_arm64.tar.gz" \
        "checksums_txt" "extract_flat:lazygit" \
        || return 1

    # delta (better git diffs — tar with binary in subdirectory, no published checksums)
    install_github_release "delta" "$DELTA_VERSION" \
        "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}" \
        "delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        "delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "calculate" "extract:delta" \
        || return 1

    # mkcert (local HTTPS certificates, no published checksums)
    install_github_release "mkcert" "$MKCERT_VERSION" \
        "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}" \
        "mkcert-v${MKCERT_VERSION}-linux-amd64" "mkcert-v${MKCERT_VERSION}-linux-arm64" \
        "calculate" "binary" \
        || return 1

    # act (GitHub Actions CLI)
    install_github_release "act" "$ACT_VERSION" \
        "https://github.com/nektos/act/releases/download/v${ACT_VERSION}" \
        "act_Linux_x86_64.tar.gz" "act_Linux_arm64.tar.gz" \
        "checksums_txt" "extract_flat:act" \
        || return 1

    # git-cliff (automatic changelog generator, SHA512 checksums)
    install_github_release "git-cliff" "$GITCLIFF_VERSION" \
        "https://github.com/orhun/git-cliff/releases/download/v${GITCLIFF_VERSION}" \
        "git-cliff-${GITCLIFF_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        "git-cliff-${GITCLIFF_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "sha512" "extract:git-cliff" \
        || return 1

    # glab (GitLab CLI — non-fatal, uses GitLab release URLs)
    install_github_release "glab" "$GLAB_VERSION" \
        "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads" \
        "glab_${GLAB_VERSION}_linux_amd64.deb" "glab_${GLAB_VERSION}_linux_arm64.deb" \
        "checksums_txt" "dpkg" \
        || log_warning "glab installation failed, continuing without glab"

    # biome (linting and formatting — non-standard tag format, no published checksums)
    install_github_release "biome" "$BIOME_VERSION" \
        "https://github.com/biomejs/biome/releases/download/@biomejs/biome@${BIOME_VERSION}" \
        "biome-linux-x64" "biome-linux-arm64" \
        "calculate" "binary" \
        || return 1

    # taplo (TOML formatter/linter) — skip if already installed by rust-dev
    if ! command -v taplo &> /dev/null; then
        install_github_release "taplo" "$TAPLO_VERSION" \
            "https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}" \
            "taplo-linux-x86_64.gz" "taplo-linux-aarch64.gz" \
            "calculate" "gunzip" \
            || return 1
    else
        log_message "taplo already installed (likely via rust-dev), skipping..."
    fi

    # just (command runner) — skip if already installed (e.g., by rust-dev via cargo)
    if ! command -v just &> /dev/null; then
        install_github_release "just" "$JUST_VERSION" \
            "https://github.com/casey/just/releases/download/${JUST_VERSION}" \
            "just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
            "just-${JUST_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
            "calculate" "extract_flat:just" \
            || return 1
    else
        log_message "just already installed (likely via rust-dev), skipping..."
    fi

    # uv (Python package installer) — skip if already installed by python-dev
    install_uv || return 1

    # lefthook (git hook manager — gzipped binary, Go-based, no runtime deps)
    install_github_release "lefthook" "$LEFTHOOK_VERSION" \
        "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}" \
        "lefthook_${LEFTHOOK_VERSION}_Linux_x86_64.gz" \
        "lefthook_${LEFTHOOK_VERSION}_Linux_aarch64.gz" \
        "calculate" "gunzip" \
        || return 1

    # gitleaks (secret scanner — Go binary, called by lefthook pre-commit hook)
    install_github_release "gitleaks" "$GITLEAKS_VERSION" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}" \
        "gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        "gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz" \
        "calculate" "extract_flat:gitleaks" \
        || return 1

    # mado (markdown linter — Rust, replaces pymarkdown)
    install_github_release "mado" "$MADO_VERSION" \
        "https://github.com/akiomik/mado/releases/download/v${MADO_VERSION}" \
        "mado-Linux-gnu-x86_64.tar.gz" \
        "mado-Linux-gnu-arm64.tar.gz" \
        "sha256" "extract_flat:mado" \
        || return 1

    # dprint (polyglot formatter — Rust, replaces mdformat for markdown)
    install_github_release "dprint" "$DPRINT_VERSION" \
        "https://github.com/dprint/dprint/releases/download/${DPRINT_VERSION}" \
        "dprint-x86_64-unknown-linux-gnu.zip" \
        "dprint-aarch64-unknown-linux-gnu.zip" \
        "calculate" "zip_to:/usr/local/bin" \
        || return 1

    # osv-scanner (dependency CVE scanner — Go binary, bare binary assets)
    install_github_release "osv-scanner" "$OSV_SCANNER_VERSION" \
        "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}" \
        "osv-scanner_linux_amd64" \
        "osv-scanner_linux_arm64" \
        "calculate" "binary" \
        || return 1

    # yq (YAML query/edit tool — Go binary, bare binary assets)
    install_github_release "yq" "$YQ_VERSION" \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
        "yq_linux_amd64" \
        "yq_linux_arm64" \
        "calculate" "binary" \
        || return 1

    # sd (Rust sed alternative — no published checksums, musl builds for both archs)
    install_github_release "sd" "$SD_VERSION" \
        "https://github.com/chmln/sd/releases/download/v${SD_VERSION}" \
        "sd-v${SD_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "sd-v${SD_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:sd" \
        || return 1

    # dua-cli (Rust disk usage analyzer — no published checksums, musl builds for both archs)
    install_github_release "dua" "$DUA_VERSION" \
        "https://github.com/Byron/dua-cli/releases/download/v${DUA_VERSION}" \
        "dua-v${DUA_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "dua-v${DUA_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:dua" \
        || return 1

    # hyperfine (Rust benchmarking CLI — no aarch64 musl build, fall back to gnu)
    install_github_release "hyperfine" "$HYPERFINE_VERSION" \
        "https://github.com/sharkdp/hyperfine/releases/download/v${HYPERFINE_VERSION}" \
        "hyperfine-v${HYPERFINE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "hyperfine-v${HYPERFINE_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "calculate" "extract:hyperfine" \
        || return 1

    # vale (Go prose linter — no published checksums, single static binary at tar root)
    # Note: repo moved from errata-ai/vale to vale-cli/vale (2024 org rename)
    install_github_release "vale" "$VALE_VERSION" \
        "https://github.com/vale-cli/vale/releases/download/v${VALE_VERSION}" \
        "vale_${VALE_VERSION}_Linux_64-bit.tar.gz" \
        "vale_${VALE_VERSION}_Linux_arm64.tar.gz" \
        "calculate" "extract:vale" \
        || return 1

    # typos (Rust code-aware spell checker — musl builds for both archs, no Node dependency)
    install_github_release "typos" "$TYPOS_VERSION" \
        "https://github.com/crate-ci/typos/releases/download/v${TYPOS_VERSION}" \
        "typos-v${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "typos-v${TYPOS_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:typos" \
        || return 1

    # agnix (AI config linter) — requires Node.js/npm
    if command -v npm &> /dev/null; then
        log_message "Installing agnix (AI config linter)..."
        if npm install -g agnix@latest 2>/dev/null; then
            log_message "✓ agnix installed successfully"
        else
            log_warning "agnix installation failed, continuing without agnix"
        fi
    else
        log_message "agnix skipped (requires Node.js/npm)"
    fi

    # agentsys (AI plugin marketplace) — requires Node.js/npm
    if command -v npm &> /dev/null; then
        log_message "Installing agentsys (AI plugin marketplace)..."
        if npm install -g agentsys@latest 2>/dev/null; then
            log_message "✓ agentsys installed successfully"
        else
            log_warning "agentsys installation failed, continuing without agentsys"
        fi
    else
        log_message "agentsys skipped (requires Node.js/npm)"
    fi

    # cspell (spell checker for code) — requires Node.js/npm
    if command -v npm &> /dev/null; then
        log_message "Installing cspell (spell checker)..."
        if npm install -g cspell@latest 2>/dev/null; then
            log_message "✓ cspell installed successfully"
        else
            log_warning "cspell installation failed, continuing without cspell"
        fi
    else
        log_message "cspell skipped (requires Node.js/npm)"
    fi
}

create_tool_symlinks() {
    log_message "Creating tool symlinks..."

    if command -v fdfind &> /dev/null && ! command -v fd &> /dev/null; then
        create_symlink "$(which fdfind)" "/usr/local/bin/fd" "fd (find alternative)"
    fi

    if command -v batcat &> /dev/null && ! command -v bat &> /dev/null; then
        create_symlink "$(which batcat)" "/usr/local/bin/bat" "bat (cat alternative)"
    fi

    if [ -f /opt/fzf/bin/fzf ]; then
        create_symlink "/opt/fzf/bin/fzf" "/usr/local/bin/fzf" "fzf fuzzy finder"
        if [ -f /opt/fzf/bin/fzf-tmux ]; then
            create_symlink "/opt/fzf/bin/fzf-tmux" "/usr/local/bin/fzf-tmux" "fzf-tmux"
        fi
    fi
}
