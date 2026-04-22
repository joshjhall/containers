# Task runner for the container build system.
# Install `just` via dev-tools feature, then run `just` to list recipes
# or `just <recipe>` to run one.
#
# Prefer these recipes over direct cargo/tests/bin invocations — they
# keep CLAUDE.md, README, and muscle-memory consistent with CI.

# Default target: show the list of recipes
default:
    @just --list --unsorted

# ============================================================================
# Tests
# ============================================================================

# Test suite. Default: rust tests + clippy + fmt --check + shell unit. Scopes: v5, v4, stibbons, containers-common (integration stays in `just test-integration`).
test SCOPE="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ SCOPE }}" in
      "")
          cargo test --workspace
          cargo clippy --workspace -- -D warnings
          cargo fmt --all -- --check
          ./tests/run_unit_tests.sh
          ;;
      v5)
          cargo test --workspace
          ;;
      v4)
          ./tests/run_unit_tests.sh
          ;;
      stibbons|containers-common)
          cargo test -p "{{ SCOPE }}"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common" >&2
          exit 2
          ;;
    esac

# Rust workspace tests (stibbons + containers-common)
test-rust:
    cargo test --workspace

# Shell unit tests (fast, no Docker)
test-shell:
    ./tests/run_unit_tests.sh

# Integration tests (all, requires Docker)
test-integration:
    ./tests/run_integration_tests.sh

# Single integration test by name (e.g. `just test-integration-one python_dev`)
test-integration-one NAME:
    ./tests/run_integration_tests.sh {{ NAME }}

# Changed-file tests only (what lefthook pre-push runs)
test-changed:
    ./tests/run_changed_tests.sh

# Quick single-feature test in isolation (e.g. `just test-feature golang`)
test-feature NAME:
    ./tests/test_feature.sh {{ NAME }}

# Everything test-worthy: unit + rust + clippy + fmt check + integration
test-all: test test-integration

# ============================================================================
# Lint & format
# ============================================================================

# Lint. Default: full lefthook pre-commit sweep. Scopes: v5 (rust workspace), v4 (shellcheck+shfmt), stibbons, containers-common.
lint SCOPE="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ SCOPE }}" in
      "")
          lefthook run pre-commit --all-files
          ;;
      v5)
          cargo clippy --workspace -- -D warnings
          cargo fmt --all -- --check
          taplo fmt --check
          ;;
      v4)
          files=$(git ls-files '*.sh' | /usr/bin/grep -v '^tests/results/' || true)
          if [ -n "$files" ]; then
              echo "$files" | xargs -r shellcheck --severity=warning
              echo "$files" | xargs -r shfmt -d -i 4 -ci
          fi
          ;;
      stibbons|containers-common)
          cargo clippy -p "{{ SCOPE }}" --all-targets -- -D warnings
          cargo fmt -p "{{ SCOPE }}" -- --check
          taplo fmt --check "crates/{{ SCOPE }}/**/*.toml"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common" >&2
          exit 2
          ;;
    esac

# Rust lint: clippy (pedantic + nursery, warnings as errors) and fmt --check
lint-rust:
    cargo clippy --workspace -- -D warnings
    cargo fmt --all -- --check

# Check docs formatting: rumdl (Markdown) + dprint (JSON/YAML) + taplo (TOML), no writes
lint-docs:
    rumdl check .
    dprint check
    taplo fmt --check

# Lint Dockerfile(s) with hadolint
lint-docker:
    hadolint Dockerfile

# Lint GitHub Actions workflows with actionlint (embedded shellcheck at warning severity, matching the .sh policy)
lint-workflows:
    actionlint -shellcheck "shellcheck --severity=warning"

# Format all code: cargo fmt (Rust) + rumdl fmt (Markdown) + dprint fmt (JSON/YAML) + taplo fmt (TOML)
fmt:
    cargo fmt --all
    rumdl fmt .
    dprint fmt
    taplo fmt

# ============================================================================
# Build
# ============================================================================

# Build the Rust workspace (debug profile)
build:
    cargo build --workspace

# Release build
build-release:
    cargo build --workspace --release

# ============================================================================
# Git hooks
# ============================================================================

# Install lefthook git hooks (pre-commit + pre-push)
install-hooks:
    lefthook install

# Uninstall lefthook hooks (restore vanilla git hooks)
uninstall-hooks:
    lefthook uninstall

# Run all pre-commit hooks on every file in the repo
hooks-all:
    lefthook run pre-commit --all-files

# ============================================================================
# Security
# ============================================================================

# cargo-deny: advisories + licenses + bans + sources checks (see deny.toml)
deny:
    cargo deny check

# All dep security scans: cargo-deny + osv-scanner + cargo-audit. Fail-fast.
security-scan:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== cargo deny check ==="
    cargo deny check
    echo "=== osv-scanner (recursive) ==="
    osv-scanner scan source --recursive .
    echo "=== cargo audit ==="
    cargo audit

# ============================================================================
# Review cadence
# ============================================================================

# Quarterly dep-health sweep: informational, never fails on findings.
# Run alongside `/codebase-audit` on the 1st of Jan/Apr/Jul/Oct.
# See docs/operations/review-cadence.md.
quarterly-review:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "=== cargo machete (unused deps) ==="
    cargo machete || true
    echo ""
    echo "=== cargo geiger --all-features (unsafe surface) ==="
    cargo geiger --all-features || true
    echo ""
    echo "=== cargo outdated --workspace --root-deps-only ==="
    cargo outdated --workspace --root-deps-only || true
    echo ""
    echo "=== cargo deny check bans sources ==="
    cargo deny check bans sources || true
    echo ""
    echo "=== Manual follow-ups ==="
    echo "  1. Run: /codebase-audit   (in Claude Code)"
    echo "  2. Review open audit/* issues on GitHub"
    echo "  3. Update deps, rotate secrets if due,"
    echo "     prune .trivyignore / .osv-scanner.toml allowlists."

# ============================================================================
# Cleanup
# ============================================================================

# Remove orphan files left by interrupted hooks or unmounted FUSE mounts. Safe to rerun.
clean-stale:
    /usr/bin/find . -type f \( -name '*.enforce.*' -o -name '.fuse_hidden*' \) \
        -not -path './.git/*' -not -path './target/*' -not -path './node_modules/*' \
        -print -delete

# Preview `just clean-stale` without removing anything.
clean-stale-dry:
    /usr/bin/find . -type f \( -name '*.enforce.*' -o -name '.fuse_hidden*' \) \
        -not -path './.git/*' -not -path './target/*' -not -path './node_modules/*'

# ============================================================================
# Versions
# ============================================================================

# Report pinned vs. upstream versions for every tool
check-versions:
    ./bin/check-versions.sh

# Check .env files for key drift against their .env.example siblings
check-env:
    ./bin/check-env-drift.sh

# Refresh checksums after version bumps
update-checksums:
    ./bin/update-checksums.sh

# ============================================================================
# Release
# ============================================================================

# Cut a patch release (non-interactive). Use 'minor' or 'major' for other bumps.
release-patch:
    ./bin/release.sh --non-interactive patch

# Cut a minor release (non-interactive)
release-minor:
    ./bin/release.sh --non-interactive minor

# Cut a major release (non-interactive)
release-major:
    ./bin/release.sh --non-interactive major

# Generate SBOMs (SPDX JSON + CycloneDX JSON + table) for a container image using syft.
# Requires syft installed locally: https://github.com/anchore/syft#installation
# Example: `just sbom ghcr.io/joshjhall/containers:v5.0.0-minimal`
sbom IMAGE OUTPUT_DIR="./sboms":
    ./bin/generate-sbom.sh --output-dir {{ OUTPUT_DIR }} {{ IMAGE }}
