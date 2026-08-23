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
        verify_download_or_fail "tool" "entr" "$ENTR_VERSION" "$ENTR_TARBALL" "$(dpkg --print-architecture)" || {
            cd /
            return 1
        }
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
    if command -v uv &>/dev/null; then
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
    verify_download_or_fail "tool" "uv" "$UV_VERSION" "$local_file" "$arch" || {
        cd /
        return 1
    }

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

install_codegraph() {
    # codegraph — pre-indexed code knowledge graph that serves an MCP server to
    # AI coding agents (Claude Code, Codex, Cursor, …). Ships its own bundled
    # Node runtime, so it works regardless of INCLUDE_NODE. Distributed as a
    # per-OS/arch tarball containing a `codegraph-<os>-<arch>/` bundle dir; the
    # bin/codegraph launcher resolves symlinks back to the bundle, so a symlink
    # onto PATH works. Checksum is pinned in checksums.json (Tier 2) and kept
    # current by bin/update-checksums.sh (TOOL_CHECKSUM_REGISTRY_ARCH).
    log_message "Installing codegraph ${CODEGRAPH_VERSION} (code knowledge graph for AI agents)..."

    local arch asset
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64) asset="codegraph-linux-x64.tar.gz" ;;
        arm64) asset="codegraph-linux-arm64.tar.gz" ;;
        *)
            log_warning "codegraph not available for architecture ${arch}, skipping..."
            return 0
            ;;
    esac

    local file_url="https://github.com/colbymchenry/codegraph/releases/download/v${CODEGRAPH_VERSION}/${asset}"

    local build_temp
    build_temp=$(create_secure_temp_dir)
    cd "$build_temp" || exit 1

    local local_file="codegraph.tar.gz"
    log_message "Downloading codegraph for ${arch}..."
    if ! command curl -L -f --retry 8 --retry-delay 10 --retry-all-errors --progress-bar -o "$local_file" "$file_url"; then
        log_error "Download failed for codegraph ${CODEGRAPH_VERSION}"
        cd /
        return 1
    fi

    # 4-tier verification (Tier 2 pinned checksum from checksums.json)
    verify_download_or_fail "tool" "codegraph" "$CODEGRAPH_VERSION" "$local_file" "$arch" || {
        cd /
        return 1
    }

    # Extract the bundle to /opt/codegraph (strip the top-level dir).
    command rm -rf /opt/codegraph
    command mkdir -p /opt/codegraph
    if ! log_command "Extracting codegraph" \
        tar -xzf "$local_file" -C /opt/codegraph --strip-components=1; then
        log_error "Failed to extract codegraph"
        cd /
        command rm -rf /opt/codegraph
        return 1
    fi
    cd /

    create_symlink "/opt/codegraph/bin/codegraph" "/usr/local/bin/codegraph" "codegraph (code knowledge graph)"

    log_message "✓ codegraph ${CODEGRAPH_VERSION} installed successfully"
    return 0
}

install_github_binary_tools() {
    # duf (modern disk usage utility)
    install_github_release "duf" "$DUF_VERSION" \
        "https://github.com/muesli/duf/releases/download/v${DUF_VERSION}" \
        "duf_${DUF_VERSION}_linux_amd64.deb" "duf_${DUF_VERSION}_linux_arm64.deb" \
        "checksums_txt" "dpkg" ||
        return 1

    # direnv (direct binary, no published checksums)
    install_github_release "direnv" "$DIRENV_VERSION" \
        "https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}" \
        "direnv.linux-amd64" "direnv.linux-arm64" \
        "calculate" "binary" ||
        return 1

    # lazygit (tar with binary at top level)
    install_github_release "lazygit" "$LAZYGIT_VERSION" \
        "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}" \
        "lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz" \
        "lazygit_${LAZYGIT_VERSION}_linux_arm64.tar.gz" \
        "checksums_txt" "extract_flat:lazygit" ||
        return 1

    # delta (better git diffs — tar with binary in subdirectory, no published checksums)
    install_github_release "delta" "$DELTA_VERSION" \
        "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}" \
        "delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        "delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "calculate" "extract:delta" ||
        return 1

    # mkcert (local HTTPS certificates, no published checksums)
    install_github_release "mkcert" "$MKCERT_VERSION" \
        "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}" \
        "mkcert-v${MKCERT_VERSION}-linux-amd64" "mkcert-v${MKCERT_VERSION}-linux-arm64" \
        "calculate" "binary" ||
        return 1

    # act (GitHub Actions CLI)
    install_github_release "act" "$ACT_VERSION" \
        "https://github.com/nektos/act/releases/download/v${ACT_VERSION}" \
        "act_Linux_x86_64.tar.gz" "act_Linux_arm64.tar.gz" \
        "checksums_txt" "extract_flat:act" ||
        return 1

    # git-cliff (automatic changelog generator, SHA512 checksums)
    install_github_release "git-cliff" "$GITCLIFF_VERSION" \
        "https://github.com/orhun/git-cliff/releases/download/v${GITCLIFF_VERSION}" \
        "git-cliff-${GITCLIFF_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        "git-cliff-${GITCLIFF_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "sha512" "extract:git-cliff" ||
        return 1

    # glab (GitLab CLI — non-fatal, uses GitLab release URLs)
    install_github_release "glab" "$GLAB_VERSION" \
        "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads" \
        "glab_${GLAB_VERSION}_linux_amd64.deb" "glab_${GLAB_VERSION}_linux_arm64.deb" \
        "checksums_txt" "dpkg" ||
        log_warning "glab installation failed, continuing without glab"

    # biome (linting and formatting — non-standard tag format, no published checksums)
    install_github_release "biome" "$BIOME_VERSION" \
        "https://github.com/biomejs/biome/releases/download/@biomejs/biome@${BIOME_VERSION}" \
        "biome-linux-x64" "biome-linux-arm64" \
        "calculate" "binary" ||
        return 1

    # taplo (TOML formatter/linter) — skip if already installed by rust-dev
    if ! command -v taplo &>/dev/null; then
        install_github_release "taplo" "$TAPLO_VERSION" \
            "https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}" \
            "taplo-linux-x86_64.gz" "taplo-linux-aarch64.gz" \
            "calculate" "gunzip" ||
            return 1
    else
        log_message "taplo already installed (likely via rust-dev), skipping..."
    fi

    # just (command runner) — skip if already installed (e.g., by rust-dev via cargo)
    if ! command -v just &>/dev/null; then
        install_github_release "just" "$JUST_VERSION" \
            "https://github.com/casey/just/releases/download/${JUST_VERSION}" \
            "just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
            "just-${JUST_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
            "calculate" "extract_flat:just" ||
            return 1
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
        "calculate" "gunzip" ||
        return 1

    # gitleaks (secret scanner — Go binary, called by lefthook pre-commit hook)
    install_github_release "gitleaks" "$GITLEAKS_VERSION" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}" \
        "gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        "gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz" \
        "calculate" "extract_flat:gitleaks" ||
        return 1

    # rumdl (markdown linter + formatter — Rust, replaces mado + dprint-markdown)
    install_github_release "rumdl" "$RUMDL_VERSION" \
        "https://github.com/rvben/rumdl/releases/download/v${RUMDL_VERSION}" \
        "rumdl-v${RUMDL_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        "rumdl-v${RUMDL_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "sha256" "extract_flat:rumdl" ||
        return 1

    # dprint (polyglot formatter — Rust, used for JSON and YAML; markdown is handled by rumdl)
    install_github_release "dprint" "$DPRINT_VERSION" \
        "https://github.com/dprint/dprint/releases/download/${DPRINT_VERSION}" \
        "dprint-x86_64-unknown-linux-gnu.zip" \
        "dprint-aarch64-unknown-linux-gnu.zip" \
        "calculate" "zip_to:/usr/local/bin" ||
        return 1

    # osv-scanner (dependency CVE scanner — Go binary, bare binary assets)
    install_github_release "osv-scanner" "$OSV_SCANNER_VERSION" \
        "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}" \
        "osv-scanner_linux_amd64" \
        "osv-scanner_linux_arm64" \
        "calculate" "binary" ||
        return 1

    # yq (YAML query/edit tool — Go binary, bare binary assets)
    install_github_release "yq" "$YQ_VERSION" \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
        "yq_linux_amd64" \
        "yq_linux_arm64" \
        "calculate" "binary" ||
        return 1

    # sd (Rust sed alternative — no published checksums, musl builds for both archs)
    install_github_release "sd" "$SD_VERSION" \
        "https://github.com/chmln/sd/releases/download/v${SD_VERSION}" \
        "sd-v${SD_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "sd-v${SD_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:sd" ||
        return 1

    # dua-cli (Rust disk usage analyzer — no published checksums, musl builds for both archs)
    install_github_release "dua" "$DUA_VERSION" \
        "https://github.com/Byron/dua-cli/releases/download/v${DUA_VERSION}" \
        "dua-v${DUA_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "dua-v${DUA_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:dua" ||
        return 1

    # hyperfine (Rust benchmarking CLI — no aarch64 musl build, fall back to gnu)
    install_github_release "hyperfine" "$HYPERFINE_VERSION" \
        "https://github.com/sharkdp/hyperfine/releases/download/v${HYPERFINE_VERSION}" \
        "hyperfine-v${HYPERFINE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "hyperfine-v${HYPERFINE_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
        "calculate" "extract:hyperfine" ||
        return 1

    # vale (Go prose linter — no published checksums, single static binary at tar root)
    # Note: repo moved from errata-ai/vale to vale-cli/vale (2024 org rename)
    install_github_release "vale" "$VALE_VERSION" \
        "https://github.com/vale-cli/vale/releases/download/v${VALE_VERSION}" \
        "vale_${VALE_VERSION}_Linux_64-bit.tar.gz" \
        "vale_${VALE_VERSION}_Linux_arm64.tar.gz" \
        "calculate" "extract:vale" ||
        return 1

    # typos (Rust code-aware spell checker — musl builds for both archs, no Node dependency)
    install_github_release "typos" "$TYPOS_VERSION" \
        "https://github.com/crate-ci/typos/releases/download/v${TYPOS_VERSION}" \
        "typos-v${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        "typos-v${TYPOS_VERSION}-aarch64-unknown-linux-musl.tar.gz" \
        "calculate" "extract:typos" ||
        return 1

    # shfmt (Go shell formatter — raw binaries for both archs, no tarball, no published checksums)
    install_github_release "shfmt" "$SHFMT_VERSION" \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}" \
        "shfmt_v${SHFMT_VERSION}_linux_amd64" \
        "shfmt_v${SHFMT_VERSION}_linux_arm64" \
        "calculate" "binary" ||
        return 1

    # conform (siderolabs commit-message / repo linter — raw Go binaries, sha256sum.txt
    # is published but uses a non-standard filename the helper doesn't fetch, so calculate)
    install_github_release "conform" "$CONFORM_VERSION" \
        "https://github.com/siderolabs/conform/releases/download/v${CONFORM_VERSION}" \
        "conform-linux-amd64" \
        "conform-linux-arm64" \
        "calculate" "binary" ||
        return 1

    # hadolint (Dockerfile linter — Haskell binary, bare binary assets)
    install_github_release "hadolint" "$HADOLINT_VERSION" \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}" \
        "hadolint-Linux-x86_64" \
        "hadolint-Linux-arm64" \
        "calculate" "binary" ||
        return 1

    # actionlint (GitHub Actions workflow linter — Go binary inside a tarball)
    install_github_release "actionlint" "$ACTIONLINT_VERSION" \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}" \
        "actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        "actionlint_${ACTIONLINT_VERSION}_linux_arm64.tar.gz" \
        "calculate" "extract:actionlint" ||
        return 1

    # agnix (AI config linter) — requires Node.js/npm.
    # Pinned via AGNIX_VERSION (set in dev-tools.sh) rather than @latest: a
    # rule-set bump must not fail a previously-green tree with no code change.
    # Stays in lockstep with the librarian consumers' .agnix.toml pin (#769).
    #
    # SIGNATURE VERIFICATION (#814). The pin fixes WHICH version npm serves; it
    # says nothing about whether the tarball npm serves for that version is the
    # one its publisher signed. `npm audit signatures` checks the registry
    # signature. That matters more here than at a CI install site: this runs
    # during the image build, and the global install executes agnix's
    # `postinstall` (`node install.js`, which downloads a binary from GitHub
    # releases). Same gap librarian#740 closed for its two CI-side sites.
    #
    # The audit CANNOT simply be appended after `npm install -g` — npm rejects
    # that pairing outright with `EAUDITGLOBAL: does not support global
    # packages`, because the audit reads a package.json/package-lock.json pair
    # that only a LOCAL install tree has. Hence the three-step sequence:
    # scratch install → audit that tree → global install FROM that tree.
    #
    # `--ignore-scripts` on the scratch install is load-bearing. The order is
    # verify-THEN-install precisely so a tampered tarball's `postinstall` never
    # executes; letting scripts run during the scratch install would run
    # attacker code first and audit afterwards, which is the same as not
    # auditing at all.
    #
    # The global install then reads the VERIFIED DIRECTORY, not the registry.
    # Re-resolving "agnix@${AGNIX_VERSION}" would be a second, independent
    # fetch whose bytes were never audited — and `-g` is where `postinstall`
    # runs. Installing the verified path makes the audited bytes and the
    # installed bytes the same bytes by construction.
    #
    # SCOPE: `npm install -g <local-dir>` PACKS the directory, and a pack
    # excludes node_modules — so for a package WITH runtime dependencies npm
    # would re-resolve that closure from the registry (a second unaudited
    # fetch, the same problem one level down). agnix declares no dependencies,
    # optionalDependencies, or peerDependencies, so the audited closure and the
    # installed closure are the same single package. That is a property of
    # agnix, not of this pattern: if agnix ever gains a dependency, re-check
    # with `npm install -g --offline` from the verified tree, which fails the
    # moment any byte still has to be fetched.
    #
    # CLASSIFYING THE FAILURE. `npm audit signatures` exits non-zero for BOTH
    # "the signature does not match" and "the audit could not run" (registry
    # 5xx, ECONNREFUSED, DNS failure, nothing auditable). Treating every
    # non-zero exit as tampering would report a network blip as a supply-chain
    # attack — and an operator who sees that message during an outage learns to
    # re-run past it, which is exactly how a real mismatch gets waved through.
    #
    # So the classifier keys on the POSITIVE signal instead of enumerating
    # benign ones: `--json` returns {"invalid":[...],"missing":[...]} when the
    # audit ran, and {"error":{...}} when it could not. A non-empty `invalid`
    # array is the only thing treated as a mismatch. Everything else is
    # "unverifiable", which warns and skips — the same line
    # verify_download_or_fail() (lib/base/checksum-verification.sh) draws when
    # it hard-fails only on rc 1 (verification ran and failed) and falls
    # through when verification was unavailable.
    #
    # STDOUT AND STDERR ARE CAPTURED SEPARATELY, and that separation is what
    # makes a real parse possible (#817). Verified against the live registry:
    # on BOTH a clean run and an outage, stdout is pure JSON (an outage yields
    # {"error":{...}}), while `npm warn`/`npm error` prose goes to stderr.
    # Merging them with 2>&1 is what would force substring matching, since a
    # single warning line prepended to the body makes it unparseable. stderr is
    # still captured — it carries the human-readable diagnostic the JSON lacks
    # — but it is used only for the log message, never for the verdict.
    #
    # The verdict is computed by jq. jq is NOT optional here: dev-tools.sh
    # apt-installs it unconditionally (its "File processing extras" block) well
    # before this function is called, and it is a declared tool of this feature.
    # So there is no textual fallback — one would be untested dead code
    # guarding a state that cannot occur.
    #
    # Two properties of that jq predicate are load-bearing, both established by
    # probing rather than assumed:
    #   - It checks the TYPE before the length. A bare `.invalid | length`
    #     returns 0 for the outage shape — identical to a clean audit — so
    #     length alone would silently install when the audit never ran.
    #   - Empty output is guarded BEFORE the call, because jq exits 0 with
    #     empty output on empty input, so a trailing `|| echo SKIP` never fires.
    #
    # LIMIT, stated so it is not over-read: this verifies the REGISTRY-attested
    # tarball, i.e. that npm served the bytes the publisher signed. It is not
    # an integrity check on the unpacked tree — editing a file under
    # node_modules after install does not make `invalid` non-empty. The threat
    # this closes is a tampered/substituted tarball from the registry, which is
    # the threat #814 describes.
    if command -v npm &>/dev/null; then
        log_message "Installing agnix (AI config linter) v${AGNIX_VERSION}..."
        local agnix_verify_dir agnix_audit_json agnix_audit_err agnix_verdict
        # The assignment is the `if` condition on purpose. As a standalone
        # statement it would abort the whole script under dev-tools.sh's
        # `set -euo pipefail` before any guard below could run, so the
        # "continuing without agnix" fallback would be unreachable.
        # Likewise an elif chain rather than an early `return`: agentsys and
        # cspell install further down in this same function.
        if ! agnix_verify_dir=$(create_secure_temp_dir) ||
            [ -z "$agnix_verify_dir" ] || [ ! -d "$agnix_verify_dir" ]; then
            log_warning "agnix verification scratch dir unavailable, continuing without agnix"
        elif npm install --prefix "$agnix_verify_dir" --ignore-scripts \
            "agnix@${AGNIX_VERSION}" 2>/dev/null; then

            # Streams kept apart: stdout is the JSON the verdict is computed
            # from, stderr is diagnostics for the log. `|| true` keeps set -e
            # out of it — the verdict comes from the JSON, never from the exit
            # code, which conflates the two failure kinds.
            agnix_audit_err="${agnix_verify_dir}/audit.stderr"
            agnix_audit_json=$(cd "$agnix_verify_dir" &&
                npm audit signatures --json 2>"$agnix_audit_err" || true)

            # Empty stdout is decided here, before jq: jq exits 0 and prints
            # nothing for empty input, so it cannot report this case itself.
            if [ -z "$agnix_audit_json" ]; then
                agnix_verdict="skip"
            else
                # `sed -n '/^[[:space:]]*{/,$p'` drops anything before the JSON
                # body starts. stdout is pure JSON in every case probed here,
                # but an npm banner (update-notifier, a proxy notice) landing on
                # stdout in some other configuration would otherwise make the
                # body unparseable — and unparseable degrades to "skip", which
                # would turn a REAL mismatch into a benign-looking skip. That is
                # the one direction this design must never fail in, so the noise
                # is stripped rather than trusted not to appear.
                #
                # Type before length — see the comment block above.
                agnix_verdict=$(command printf '%s' "$agnix_audit_json" |
                    command sed -n '/^[[:space:]]*{/,$p' |
                    command jq -r 'if (.invalid | type) != "array" then "skip"
                        elif (.invalid | length) > 0 then "fatal"
                        else "install" end' 2>/dev/null || true)
                # Unparseable stdout (jq failed, or printed nothing) is
                # unverifiable, not a mismatch.
                [ -z "$agnix_verdict" ] && agnix_verdict="skip"
            fi

            if [ "$agnix_verdict" = "fatal" ]; then
                # Verification RAN and FAILED. npm was reachable, we hold the
                # tarball, and it is not what its publisher signed. Its own
                # message, at ERROR, and it aborts the build — matching the
                # `|| return 1` on every install_github_release call above and
                # the cargo install policy in CLAUDE.md ("Failures abort the
                # build"). A supply-chain signal must never read as an outage.
                log_error "agnix signature verification FAILED for v${AGNIX_VERSION} — npm served a tarball that does not match its published registry signature. Refusing to install. Audit output: ${agnix_audit_json}"
                # This branch returns early, so it does its OWN cleanup: the
                # unconditional rm -rf at the end of the block is unreachable
                # from here.
                command rm -rf "$agnix_verify_dir"
                return 1
            elif [ "$agnix_verdict" = "install" ]; then
                # Audit ran, nothing invalid: install the AUDITED BYTES.
                # A failure HERE is an install problem, not a signature
                # problem — the bytes were verified — so it warns like any
                # other best-effort npm tool and never reaches the fatal path.
                if npm install -g "$agnix_verify_dir/node_modules/agnix" 2>/dev/null; then
                    log_message "✓ agnix installed successfully (registry signature verified)"
                else
                    log_warning "agnix installation failed, continuing without agnix"
                fi
            else
                # Audit could not run (registry error, nothing auditable, or an
                # output shape this doesn't recognize). Unverifiable, NOT a
                # mismatch: warn and skip rather than accuse. stderr carries the
                # readable reason that the JSON body does not.
                log_warning "agnix signature could not be verified (audit did not run), continuing without agnix. Audit stdout: ${agnix_audit_json:-<empty>}. Audit stderr: $(command head -c 500 "$agnix_audit_err" 2>/dev/null || true)"
            fi
        else
            log_warning "agnix installation failed, continuing without agnix"
        fi
        command rm -rf "$agnix_verify_dir"
    else
        log_message "agnix skipped (requires Node.js/npm)"
    fi

    # agentsys (AI plugin marketplace) — requires Node.js/npm
    if command -v npm &>/dev/null; then
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
    if command -v npm &>/dev/null; then
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

    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        create_symlink "$(which fdfind)" "/usr/local/bin/fd" "fd (find alternative)"
    fi

    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        create_symlink "$(which batcat)" "/usr/local/bin/bat" "bat (cat alternative)"
    fi

    if [ -f /opt/fzf/bin/fzf ]; then
        create_symlink "/opt/fzf/bin/fzf" "/usr/local/bin/fzf" "fzf fuzzy finder"
        if [ -f /opt/fzf/bin/fzf-tmux ]; then
            create_symlink "/opt/fzf/bin/fzf-tmux" "/usr/local/bin/fzf-tmux" "fzf-tmux"
        fi
    fi
}
