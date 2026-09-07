# Version Tracking Overview

This document lists all manually pinned versions in the container build system
that need tracking and updating.

> **Note:** The Dockerfile is the authoritative source for version values.
> This document may lag behind — run `./bin/check-versions.sh` for current
> versions.

## Dockerfile ARG Versions

These are defined as build arguments in the Dockerfile:

- `PYTHON_VERSION` (currently 3.14.7)
- `NODE_VERSION` (currently 22)
- `RUST_VERSION` (currently 1.98.1)
- `RUBY_VERSION` (currently 4.0.6)
- `R_VERSION` (currently 4.6.1)
- `GO_VERSION` (currently 1.27.1)
- `MOJO_VERSION` (currently 25.4)
- `JAVA_VERSION` (currently 21)
- `KOTLIN_VERSION` (currently 2.4.20)
- `KUBECTL_VERSION` (currently 1.33.13)
- `K9S_VERSION` (currently 0.51.0)
- `KREW_VERSION` (currently 0.5.0)
- `HELM_VERSION` (currently 4.2.4)
- `TERRAGRUNT_VERSION` (currently 1.1.4)
- `TFDOCS_VERSION` (currently 0.24.0)
- `PIXI_VERSION` (currently 0.80.0)
- `TFLINT_VERSION` (currently 0.64.0)

## Shell Script Hardcoded Versions

### lib/features/dev-tools.sh

- `DIRENV_VERSION="2.37.1"`
- `LAZYGIT_VERSION="0.65.0"`
- `DELTA_VERSION="0.19.2"`
- `MKCERT_VERSION="1.4.4"`
- `ACT_VERSION="0.2.89"`
- `GLAB_VERSION="1.116.0"`
- `DUF_VERSION="0.9.1"`
- `ENTR_VERSION="5.8"`
- `GITCLIFF_VERSION="2.8.0"`
- `BIOME_VERSION="2.5.12"`
- `TAPLO_VERSION="0.10.0"`
- `TYPOS_VERSION="1.50.1"`
- `SHFMT_VERSION="3.14.1"`
- `CONFORM_VERSION="0.1.0-alpha.31"`

### lib/features/docker.sh

- `LAZYDOCKER_VERSION="0.25.2"`
- `DIVE_VERSION="0.13.1"`

### lib/features/java-dev.sh

- `SPRING_VERSION="4.1.1"`
- `JBANG_VERSION="0.141.0"`
- `MVND_VERSION="1.0.6"` (indented)
- `GJF_VERSION="1.36.1"`

## Tools Installed by Package Manager

Grouped by installer. The cargo tools below are version-pinned and tracked by
`check-versions.sh`; the npm/gem groups take the latest at build time, which is
generally fine.

### Via cargo binstall (in rust.sh and rust-dev.sh)

Installed with `cargo binstall` — it downloads a prebuilt, checksum-verified
binary for each crate instead of compiling from source, which is the fix for
the CI cold-build timeout (#517). `binstall` falls back to `cargo install` for
any crate without a prebuilt binary. All are `--locked` and pinned to a
`@${VAR}` version (see `bin/check-versions.sh`):

- tree-sitter-cli
- cargo-watch
- cargo-expand
- cargo-modules
- cargo-outdated
- cargo-sweep
- cargo-audit
- cargo-deny
- cargo-geiger
- cargo-machete
- cargo-nextest
- cargo-llvm-cov (also adds the `llvm-tools-preview` rustup component)
- cargo-release
- bacon
- tokei
- hyperfine
- just
- sccache
- mdbook (and the mdbook-mermaid/-toc/-admonish extensions, in rust.sh)
- taplo-cli

### Via pre-built binary (in rust.sh / rust-dev.sh)

- cargo-binstall (the binstall installer itself; tarball from
  `cargo-bins/cargo-binstall/releases`, `CARGO_BINSTALL_VERSION`, Tier 2 pinned
  checksum in `lib/checksums.json`)
- mold (Linux fast linker; tarball from `rui314/mold/releases`, `MOLD_VERSION`)

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

### Via npm install -g (in dev-tools.sh, requires Node.js)

- agnix (AI config linter) — pinned via `AGNIX_VERSION` and tracked by the
  weekly `check-versions` sweep; kept in lockstep with the librarian consumers'
  `.agnix.toml` pin (joshjhall/librarian#398, containers#769). The tarball's
  npm registry signature is verified before installation (containers#814): the
  pinned version is installed into a throwaway prefix with `--ignore-scripts`,
  `npm audit signatures` runs against that tree, and the global install then
  reads the verified directory rather than re-resolving the pin — so the
  audited bytes and the installed bytes are the same bytes, and a tampered
  tarball's `postinstall` never executes. The audit runs with `--json` and its
  stdout and stderr are captured separately (containers#817), so the verdict is
  computed by parsing pure JSON with `jq` rather than matching substrings;
  only a populated `invalid[]` — the registry saying "these bytes are not what
  the publisher signed" — is treated as a **mismatch**, which fails the build.
  Every other non-zero outcome (registry outage, DNS failure, nothing
  auditable) is *unverifiable*, not tampering: it warns and skips agnix. Note
  this attests the **registry tarball**, not the unpacked tree — it is not an
  integrity check against later edits under `node_modules`.
- agentsys (AI plugin marketplace)
- cspell (spell checker for code)

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
- Poetry, uv (`lib/features/lib/python/install-tools.sh`) — note this is a
  *second* uv pin, independent of the dev-tools.sh one; both are tracked
- cargo-* extensions, bacon, sccache, tokei, just, mdbook, taplo-cli (rust-dev.sh)
- cargo-nextest, cargo-llvm-cov, cargo-machete (rust-dev.sh)
- mold linker (rust-dev.sh; checked against `rui314/mold` GitHub releases)

✅ **CI template pins:**

- gitlab-triage (`.gitlab/triage/Gemfile`; checked against the RubyGems API).
  Powers the scheduled GitLab issue-triage job. The full dependency graph is
  locked in the committed `Gemfile.lock`, which `bundle install` verifies in
  deployment mode on every run. The weekly sweep can rewrite the **Gemfile**
  pin but cannot regenerate the **lock** — that needs a real Ruby resolver — so
  a bump is finished by hand using the command in the Gemfile's header. The two
  are asserted to stay in sync by `tests/unit/gitlab-templates.sh`, and frozen
  mode refuses to run if they ever disagree (#764).

## Version Tracking Status

✅ **All critical tools are now properly versioned and tracked:**

- All Dockerfile ARG versions are pinned and tracked
- All shell script tool installations use version variables
- Poetry is pinned to a specific version (2.4.3)
- Helm is pinned to a specific version (4.2.4)
- duf and entr have version variables (0.9.1 and 5.8)

✅ **Automated version management:**

- `check-versions.sh` monitors all pinned versions weekly
- Automatic PRs created when updates are available
- Version updates applied via `update-versions.sh`

## Tools Intentionally Not Pinned

These tools get the latest stable version by design:

1. **Package manager installed tools** (npm, gem)

   - typescript, jest, vitest, etc. (via npm install -g)
   - bundler, rails, rspec, etc. (via gem install)
   - These package managers handle their own versioning and updates
   - Note: cargo tools (cargo-watch, tree-sitter-cli, sccache, …) ARE pinned
     and tracked — they install via `cargo binstall --locked @${VAR}`, not
     unpinned `cargo install`

1. **System packages** (via apt-get)

   - git, curl, build-essential, etc.
   - Managed by Debian package management

This approach balances reproducibility (pinned critical versions) with freshness
(latest stable for development tools).
