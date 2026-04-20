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

# Full test suite (Rust + shell unit + Rust lint). For integration tests run `just test-integration`.
test: test-rust lint-rust test-shell

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

# Run every linter lefthook would run on a full pass.
lint:
    lefthook run pre-commit --all-files

# Rust lint: clippy (pedantic + nursery, warnings as errors) and fmt --check
lint-rust:
    cargo clippy --workspace -- -D warnings
    cargo fmt --all -- --check

# Check docs formatting: rumdl (Markdown) + dprint (JSON/YAML), no writes
lint-docs:
    rumdl check .
    dprint check

# Format all code: cargo fmt (Rust) + rumdl fmt (Markdown) + dprint fmt (JSON/YAML)
fmt:
    cargo fmt --all
    rumdl fmt .
    dprint fmt

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
# Versions
# ============================================================================

# Report pinned vs. upstream versions for every tool
check-versions:
    ./bin/check-versions.sh

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
