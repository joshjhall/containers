# Version Tracking Overview

This document lists all manually pinned versions in the container build system
that need tracking and updating.

## Dockerfile ARG Versions

These are defined as build arguments in the Dockerfile:

- `PYTHON_VERSION` (currently 3.14.3)
- `NODE_VERSION` (currently 22)
- `RUST_VERSION` (currently 1.93.1)
- `RUBY_VERSION` (currently 4.0.1)
- `R_VERSION` (currently 4.5.2)
- `GO_VERSION` (currently 1.26.0)
- `MOJO_VERSION` (currently 25.4)
- `JAVA_VERSION` (currently 21)
- `KOTLIN_VERSION` (currently 2.3.10)
- `KUBECTL_VERSION` (currently 1.33.8)
- `K9S_VERSION` (currently 0.50.18)
- `KREW_VERSION` (currently 0.4.5)
- `HELM_VERSION` (currently 4.1.1)
- `TERRAGRUNT_VERSION` (currently 0.99.4)
- `TFDOCS_VERSION` (currently 0.21.0)

## Shell Script Hardcoded Versions

### lib/features/dev-tools.sh

- `DIRENV_VERSION="2.37.1"`
- `LAZYGIT_VERSION="0.59.0"`
- `DELTA_VERSION="0.18.2"`
- `MKCERT_VERSION="1.4.4"`
- `ACT_VERSION="0.2.84"`
- `GLAB_VERSION="1.86.0"`
- `DUF_VERSION="0.9.1"`
- `ENTR_VERSION="5.7"`
- `GITCLIFF_VERSION="2.8.0"`
- `BIOME_VERSION="2.4.4"`
- `TAPLO_VERSION="0.10.0"`

### lib/features/docker.sh

- `LAZYDOCKER_VERSION="0.24.4"`
- `DIVE_VERSION="0.13.1"`

### lib/features/java-dev.sh

- `SPRING_VERSION="4.0.3"`
- `JBANG_VERSION="0.137.0"`
- `MVND_VERSION="1.0.3"` (indented)
- `GJF_VERSION="1.34.1"`

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

- `POETRY_VERSION="2.3.2"` (installed via pipx)

### Via apt-get install

- Most system packages (git, curl, etc.)

## Currently Tracked in check-versions.sh

✅ **Dockerfile versions:**

- Python, Node.js, Go, Rust, Ruby, Java, R, Mojo, Kotlin
- kubectl, k9s, Helm, Krew, Terragrunt, terraform-docs

✅ **Shell script versions:**

- lazygit, direnv, act, delta, glab, mkcert, duf, entr, git-cliff, biome, taplo (dev-tools.sh)
- dive, lazydocker (docker.sh)
- spring-boot-cli, jbang, mvnd, google-java-format (java-dev.sh)
- Poetry (python.sh)

## Version Tracking Status

✅ **All critical tools are now properly versioned and tracked:**

- All Dockerfile ARG versions are pinned and tracked
- All shell script tool installations use version variables
- Poetry is pinned to a specific version (2.3.2)
- Helm is pinned to a specific version (4.1.1)
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

1. **System packages** (via apt-get)

   - git, curl, build-essential, etc.
   - Managed by Debian package management

This approach balances reproducibility (pinned critical versions) with freshness
(latest stable for development tools).
