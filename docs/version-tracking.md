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
- `HELM_VERSION` (currently 3.19.0)
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
- `DUF_VERSION="0.9.1"`
- `ENTR_VERSION="5.7"`

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

### lib/features/python.sh

- `POETRY_VERSION="2.2.1"` (installed via pipx)

### Via apt-get install

- Most system packages (git, curl, etc.)

## Currently Tracked in check-versions.sh

✅ **Dockerfile versions:**

- Python, Node.js, Go, Rust, Ruby, Java, R, Mojo
- kubectl, k9s, Helm, Krew, Terragrunt, terraform-docs

✅ **Shell script versions:**

- lazygit, direnv, act, delta, glab, mkcert, duf, entr (dev-tools.sh)
- dive, lazydocker (docker.sh)
- spring-boot-cli, jbang, mvnd, google-java-format (java-dev.sh)
- Poetry (python.sh)

## Version Tracking Status

✅ **All critical tools are now properly versioned and tracked:**
- All Dockerfile ARG versions are pinned and tracked
- All shell script tool installations use version variables
- Poetry is pinned to a specific version (2.2.1)
- Helm is pinned to a specific version (3.19.0)
- duf and entr have version variables (0.9.1 and 5.7)

✅ **Automated version management:**
- `check-versions.sh` monitors all pinned versions weekly
- Automatic PRs created when updates are available
- Version updates applied via `update-versions.sh`

## Tools Intentionally Not Pinned

These tools get the latest stable version by design:

1. **Package manager installed tools** (cargo, npm, gem)
   - cargo-watch, tree-sitter-cli, tokei, etc. (via cargo install)
   - typescript, jest, vitest, etc. (via npm install -g)
   - bundler, rails, rspec, etc. (via gem install)
   - These package managers handle their own versioning and updates

2. **System packages** (via apt-get)
   - git, curl, build-essential, etc.
   - Managed by Debian package management

This approach balances reproducibility (pinned critical versions) with freshness (latest stable for development tools).
