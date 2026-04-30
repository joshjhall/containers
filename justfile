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
# containers-db (sibling repo) — see "containers-db" section below
# ============================================================================

# Path to the sibling containers-db checkout. Devcontainer mounts it at
# /workspace/containers-db; host clones typically use ../containers-db.
# Override with CONTAINERS_DB=/path/to/containers-db.
CONTAINERS_DB := env_var_or_default("CONTAINERS_DB", justfile_directory() + "/../containers-db")

# ajv-cli + ajv-formats versions are pinned to match the source-of-truth CI
# workflow at containers-db/.github/workflows/validate.yml — bump in lockstep
# with that workflow (and only that workflow).
AJV_CLI_VERSION := "5.0.0"
AJV_FORMATS_VERSION := "3.0.1"

# Mandatory ajv flags. Every db-* recipe interpolates {{ AJV_FLAGS }} so the
# spec dialect and format plugin can never be silently dropped.
# --spec=draft2020 selects JSON Schema 2020-12 (the schemas use
# `unevaluatedProperties` and `$dynamicRef`, which behave differently under
# the default draft-07). -c ajv-formats enables the `format` keyword
# (uri, date-time, …), which is otherwise a no-op.
AJV_FLAGS := "--spec=draft2020 -c ajv-formats"

# ============================================================================
# Tests
# ============================================================================

# Test suite. Default: rust tests + clippy + fmt --check + shell unit. Scopes: v5, v4, stibbons, containers-common, luggage (integration stays in `just test-integration`).
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
      stibbons|containers-common|luggage)
          cargo test -p "{{ SCOPE }}"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common, luggage" >&2
          exit 2
          ;;
    esac

# Rust workspace tests (stibbons + containers-common + luggage)
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

# Lint. Default: full lefthook pre-commit sweep. Scopes: v5 (rust workspace), v4 (shellcheck+shfmt), stibbons, containers-common, luggage.
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
      stibbons|containers-common|luggage)
          cargo clippy -p "{{ SCOPE }}" --all-targets -- -D warnings
          cargo fmt -p "{{ SCOPE }}" -- --check
          taplo fmt --check "crates/{{ SCOPE }}/**/*.toml"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common, luggage" >&2
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
# containers-db
# ============================================================================
# Wrappers around the ajv-cli commands that the containers-db CI workflow
# runs. The mandatory flags (--spec=draft2020, -c ajv-formats) are baked in
# via AJV_FLAGS so contributors can't silently drop them.
#
# Catalog path comes from $CONTAINERS_DB (default: ../containers-db sibling).
# Source of truth for command shape and pinned versions:
#   containers-db/.github/workflows/validate.yml

# Internal: fail fast if the containers-db checkout is missing.
[private]
_db-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ CONTAINERS_DB }}" ]; then
        echo "containers-db not found at: {{ CONTAINERS_DB }}" >&2
        echo "" >&2
        echo "Clone joshjhall/containers-db as a sibling of this repo, or set" >&2
        echo "CONTAINERS_DB=/path/to/containers-db before invoking." >&2
        exit 1
    fi

# Compile both containers-db schemas (catches schema-internal mistakes).
db-compile: _db-check
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ CONTAINERS_DB }}"
    npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- \
        ajv compile {{ AJV_FLAGS }} -s schema/tool.schema.json
    npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- \
        ajv compile {{ AJV_FLAGS }} -s schema/version.schema.json

# Validate every fixture (positive cases pass, _negative/* must fail).
db-validate: db-compile
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ CONTAINERS_DB }}"
    ajv() {
        npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- ajv "$@"
    }
    # Positive fixtures
    ajv validate {{ AJV_FLAGS }} -s schema/tool.schema.json    -d fixtures/sample-tool/index.json
    ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "fixtures/sample-tool/versions/*.json"
    ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "fixtures/tier*-example.json"
    # Cross-reference + comparator-placeholder check
    node scripts/validate-cross-refs.mjs
    # Negative fixtures: each must be rejected by ajv OR by validate-cross-refs
    # (matches the workflow's combined ajv_rc/xref_rc check).
    for fixture in fixtures/_negative/*.json; do
        ajv_rc=0
        xref_rc=0
        set +e
        ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "$fixture"
        ajv_rc=$?
        node scripts/validate-cross-refs.mjs --only "$fixture"
        xref_rc=$?
        set -e
        if [ "$ajv_rc" -eq 0 ] && [ "$xref_rc" -eq 0 ]; then
            echo "ERROR: negative fixture $fixture passed both ajv AND cross-ref" >&2
            exit 1
        fi
        echo "Negative fixture $fixture correctly rejected (ajv=$ajv_rc, xref=$xref_rc)"
    done

# Validate one tool's index (and versions/, if present).
db-validate-tool TOOL: db-compile
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ CONTAINERS_DB }}"
    if [ ! -d "tools/{{ TOOL }}" ]; then
        echo "tools/{{ TOOL }}/ not found in {{ CONTAINERS_DB }}" >&2
        exit 1
    fi
    ajv() {
        npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- ajv "$@"
    }
    ajv validate {{ AJV_FLAGS }} -s schema/tool.schema.json -d "tools/{{ TOOL }}/index.json"
    if compgen -G "tools/{{ TOOL }}/versions/*.json" >/dev/null; then
        ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "tools/{{ TOOL }}/versions/*.json"
    fi

# Validate every tool under tools/.
db-validate-all: db-compile
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ CONTAINERS_DB }}"
    ajv() {
        npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- ajv "$@"
    }
    shopt -s nullglob
    for dir in tools/*/; do
        tool="${dir%/}"
        tool="${tool#tools/}"
        echo "=== $tool ==="
        ajv validate {{ AJV_FLAGS }} -s schema/tool.schema.json -d "tools/$tool/index.json"
        if compgen -G "tools/$tool/versions/*.json" >/dev/null; then
            ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "tools/$tool/versions/*.json"
        fi
    done

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
