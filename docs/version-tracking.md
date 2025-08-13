# Version Tracking Overview

This document lists all manually pinned versions in the container build system that need tracking and updating.

## Dockerfile ARG Versions

These are defined as build arguments in the Dockerfile:

- `PYTHON_VERSION` (currently 3.13.6)
- `NODE_VERSION` (currently 22.10.0)
- `RUST_VERSION` (currently 1.89.0)
- `RUBY_VERSION` (currently 3.4.5)
- `R_VERSION` (currently 4.5.1)
- `GO_VERSION` (currently 1.24.6)
- `MOJO_VERSION` (currently 25.4)
- `JAVA_VERSION` (currently 21)
- `KUBECTL_VERSION` (currently 1.33)
- `K9S_VERSION` (currently 0.50.9)
- `KREW_VERSION` (currently 0.4.5)
- `HELM_VERSION` (currently latest - not pinned)
- `TERRAGRUNT_VERSION` (currently 0.84.1)
- `TFDOCS_VERSION` (currently 0.20.0)

## Shell Script Hardcoded Versions

### lib/features/dev-tools.sh
- `DIRENV_VERSION="2.37.1"`
- `LAZYGIT_VERSION="0.54.2"`
- `DELTA_VERSION="0.18.2"`
- `MKCERT_VERSION="1.4.4"`
- `ACT_VERSION="0.2.80"`
- `GLAB_VERSION="1.65.0"`
- **HARDCODED:** `duf` version 0.8.1 (lines 268, 271)
- **HARDCODED:** `entr` version 5.5 (line 286)

### lib/features/docker.sh
- `LAZYDOCKER_VERSION="0.24.1"`
- `DIVE_VERSION="0.13.1"`

### lib/features/java-dev.sh
- `SPRING_VERSION="3.4.2"`
- `JBANG_VERSION="0.121.0"`
- `MVND_VERSION="1.0.2"` (indented)
- `GJF_VERSION="1.25.2"`

## Tools Installed Without Version Pinning

These tools get the latest version at build time, which is generally fine:

### Via cargo install (in rust-dev.sh)
- tree-sitter-cli
- cargo-watch
- cargo-edit
- cargo-expand
- cargo-outdated
- bacon
- tokei
- hyperfine
- just
- sccache
- mdbook (and extensions)

### Via npm install -g (in node-dev.sh)
- typescript
- ts-node
- tsx
- @types/node
- jest
- mocha
- vitest
- @playwright/test
- (and many more dev tools)

### Via gem install (in ruby-dev.sh)
- bundler
- rails
- sinatra
- rspec
- rubocop
- (and more)

### Via pipx install (in python.sh)
- poetry (gets latest)

### Via apt-get install
- Most system packages (git, curl, etc.)

## Currently Tracked in check-versions.sh

✅ **Dockerfile versions:**
- Python, Node.js, Go, Rust, Ruby, Java, R
- kubectl, k9s, Terragrunt, terraform-docs

✅ **Shell script versions:**
- lazygit, direnv, act, delta, glab, mkcert (dev-tools.sh)
- dive, lazydocker (docker.sh)
- spring-boot-cli, jbang, mvnd, google-java-format (java-dev.sh)

❌ **NOT tracked but should be:**
- duf (hardcoded as 0.8.1 in dev-tools.sh)
- entr (hardcoded as 5.5 in dev-tools.sh)

## Recommendations

1. **Add version variables for duf and entr** in dev-tools.sh:
   - Replace hardcoded `0.8.1` with `DUF_VERSION` variable
   - Replace hardcoded `5.5` with `ENTR_VERSION` variable

2. **Add checks for duf and entr** in check-versions.sh

3. **Consider removing misleading comments** about `just v1.42.3` in dev-tools.sh since it's actually installed via cargo in rust-dev.sh

4. **Tools that don't need version tracking:**
   - Package manager installed tools (cargo, npm, gem, pipx) - these handle their own updates
   - apt packages - handled by Debian package management

5. **Special cases:**
   - HELM_VERSION is set to "latest" which means it's not actually pinned
   - Poetry is installed via pipx which gets the latest version