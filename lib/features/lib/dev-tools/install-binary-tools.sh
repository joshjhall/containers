#!/bin/bash
# install-binary-tools.sh — Binary tool downloads, source builds, and symlinks
#
# Functions:
#   install_entr        — build entr from source tarball
#   install_fzf         — git clone fzf with retry logic
#   install_github_binary_tools — all install_github_release calls
#   create_tool_symlinks — fd/bat/fzf symlinks

install_entr() {
    log_message "Installing entr (file watcher)..."
    local ENTR_TARBALL="entr-${ENTR_VERSION}.tar.gz"
    local ENTR_URL="http://eradman.com/entrproject/code/${ENTR_TARBALL}"

    # entr doesn't publish checksums — TOFU with unified logging

    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || exit 1
    log_message "Downloading entr ${ENTR_VERSION}..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "$ENTR_TARBALL" "$ENTR_URL"; then
        log_error "Failed to download entr ${ENTR_VERSION}"
        cd /
        return 1
    fi

    # Source checksum verification if available
    if [ -f /tmp/build-scripts/base/checksum-verification.sh ]; then
        source /tmp/build-scripts/base/checksum-verification.sh
        local verify_rc=0
        verify_download "tool" "entr" "$ENTR_VERSION" "$ENTR_TARBALL" "$(dpkg --print-architecture)" || verify_rc=$?
        if [ "$verify_rc" -eq 1 ]; then
            log_error "Verification failed for entr ${ENTR_VERSION}"
            cd /
            return 1
        fi
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
