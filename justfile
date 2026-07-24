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

# Test suite. Default: rust tests + clippy + fmt --check + shell unit. Scopes: v5, v4, stibbons, containers-common, luggage, record-evidence (integration stays in `just test-integration`).
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
      stibbons|containers-common|luggage|record-evidence)
          cargo test -p "{{ SCOPE }}"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common, luggage, record-evidence" >&2
          exit 2
          ;;
    esac

# Rust workspace tests (stibbons + containers-common + luggage + record-evidence)
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

# Preview which features the PR tier would build for the current diff
test-changed-features:
    ./tests/changed_features.sh

# Everything test-worthy: unit + rust + clippy + fmt check + integration
test-all: test test-integration

# ============================================================================
# Lint & format
# ============================================================================

# Lint. Default: full lefthook pre-commit sweep. Scopes: v5 (rust workspace), v4 (shellcheck+shfmt), stibbons, containers-common, luggage, record-evidence.
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
      stibbons|containers-common|luggage|record-evidence)
          cargo clippy -p "{{ SCOPE }}" --all-targets -- -D warnings
          cargo fmt -p "{{ SCOPE }}" -- --check
          taplo fmt --check "crates/{{ SCOPE }}/**/*.toml"
          ;;
      *)
          echo "Unknown scope: {{ SCOPE }}" >&2
          echo "Valid scopes: v5, v4, stibbons, containers-common, luggage, record-evidence" >&2
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

# Lint Dockerfile(s) with hadolint — root Dockerfile + every base-images/**/Dockerfile.
lint-docker:
    hadolint Dockerfile $(find base-images -name Dockerfile -type f | sort)

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
# Worktree & orchestration (golems)
# ============================================================================
#
# These recipes are THIN WRAPPERS over the canonical scripts bundled in the
# `librarian` marketplace's `workflow` plugin (#609). The scripts — not these
# recipes — are the source of truth, so the golem/worktree flow runs identically
# on a host Mac, a bare Linux box, or inside a devcontainer WITHOUT `just`
# (skills invoke them via `${CLAUDE_PLUGIN_ROOT}`; `just` is muscle-memory sugar
# on top). `bin/workflow-scripts-dir.sh` locates the bundled `scripts/` dir
# (the just-side analogue of `${CLAUDE_PLUGIN_ROOT}`, which is unset outside
# Claude Code).
#
# Per-environment config is env-overridable (defaults live in the plugin's
# `config.sh`); export any of these before `just` to relocate worktrees, rename
# branches, or point at a different librarian checkout:
#   GOLEM_WORKTREE_DIR          per-issue worktree dir   (default .worktrees)
#   GOLEM_STATUS_DIR            status cache + feed dir   (default <wt>/.status)
#   GOLEM_BRANCH_PREFIX         branch is <prefix><N>     (default feature/issue-)
#   GOLEM_BASE_REF              ref new branches fork from (default origin/main)
#   GOLEM_WORKTREE_LOCAL_FILES  gitignored files copied into a fresh worktree
#                               (default ".env .claude/settings.local.json")
#   WORKFLOW_SCRIPTS_DIR        override the bundled-scripts location entirely

# Create a push-ready Mode-2 worktree for issue N (idempotent; copies .env etc.).
worktree-new N:
    #!/usr/bin/env bash
    set -euo pipefail
    # Guard N at the just layer before it reaches the shell. just interpolates
    # `{{ N }}` TEXTUALLY before bash parses the line, so a raw `[[ "{{ N }}" ]]`
    # would eagerly run `$(...)` / break quotes (injection) even though the regex
    # later rejects it. `quote()` emits a properly shell-escaped literal, so the
    # value is captured verbatim and only THEN validated. The bundled script
    # re-validates too; this is defense-in-depth at the wrapper.
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "worktree-new: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/worktree-new.sh" "$_n"

# Post-merge cleanup: remove the issue-N worktree and its feature/issue-N branch (clean no-op if absent).
worktree-rm N:
    #!/usr/bin/env bash
    set -euo pipefail
    # See worktree-new for why N is quoted before validation (just interpolates
    # textually; quote() prevents eager $(...)/quote-break injection).
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "worktree-rm: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    bash "$scripts/worktree-rm.sh" "$_n"
    # The bundled script is intentionally portable and does NOT carry the
    # containers-specific tail below: a golem PR usually merges into origin/main
    # right before its worktree is torn down, and on a BARE host the on-disk
    # runtime copies (.claude/hooks, justfile, bin) don't update on their own
    # (no work tree to check out into), so the next golem would fire the
    # just-superseded hook/justfile (#606). Refresh them here. Best-effort and
    # bare-host-only: a normal checkout uses git checkout/pull and is left
    # untouched; any failure never aborts the teardown.
    if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
        bash "{{ justfile_directory() }}/bin/sync-host.sh" || \
            echo "  (sync-host refresh skipped — run 'just sync-host' manually)" >&2
    fi

# Show the central golem status table + which golems are BLOCKED (TTY-free).
golems:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-status.sh"

# Attach to issue N's golem session (worktree or container).
golem-attach N:
    #!/usr/bin/env bash
    set -euo pipefail
    # See worktree-new for why N is quoted before validation.
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "golem-attach: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-attach.sh" "$_n"

# Proactively watch for blocked golems (streams feed + pane gate channels; Ctrl-C to stop).
golem-watch:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-watch.sh"

# A bare repo never checks files out, so the host's on-disk .claude/hooks,
# justfile, and bin/ drift behind origin/main after a merge and it runs stale
# hooks/justfile (#606). Pass path prefixes to narrow the set.
# Refresh a bare host's on-disk runtime copies (.claude/hooks, justfile, bin) from origin/main.
sync-host *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" {{ PREFIXES }}

# Drift guard for #606: report any on-disk runtime copy that differs from origin/main, exit non-zero if so (writes nothing).
sync-host-check *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" --check {{ PREFIXES }}

# Opt-in: wire the INCLUDE_HOST_EVENTS forwarder into the HOST ~/.claude for worktree golems (#738). Idempotent, preserves existing hooks.
host-events-install:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" install

# Un-wire the host event forwarder from the HOST ~/.claude (removes only our hooks + the copied script).
host-events-remove:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" remove

# Report whether the host event forwarder is wired into the HOST ~/.claude (read-only; exit 1 if not).
host-events-check:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" check

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

# Apply outdated version bumps (no release; pass --dry-run/--no-commit/etc. to override)
update-versions *ARGS:
    ./bin/update-versions.sh --no-bump {{ARGS}}

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
    # Build the Rust semantic validator once; the negative-fixture loop below
    # invokes it per fixture and we don't want cargo re-checking freshness each time.
    cargo build --release -p db-validator --bin validate-catalog
    ajv() {
        npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- ajv "$@"
    }
    # Positive fixtures
    ajv validate {{ AJV_FLAGS }} -s schema/tool.schema.json    -d fixtures/sample-tool/index.json
    ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "fixtures/sample-tool/versions/*.json"
    ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "fixtures/tier*-example.json"
    # Semantic validation (full catalog walk via the Rust validator)
    ./target/release/validate-catalog
    # Negative fixtures: each must be rejected by ajv OR by validate-catalog
    # (matches the workflow's combined ajv_rc/sem_rc check).
    for fixture in fixtures/_negative/*.json; do
        ajv_rc=0
        sem_rc=0
        set +e
        ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "$fixture"
        ajv_rc=$?
        ./target/release/validate-catalog --only "$fixture"
        sem_rc=$?
        set -e
        if [ "$ajv_rc" -eq 0 ] && [ "$sem_rc" -eq 0 ]; then
            echo "ERROR: negative fixture $fixture passed both ajv AND validate-catalog" >&2
            exit 1
        fi
        echo "Negative fixture $fixture correctly rejected (ajv=$ajv_rc, validate-catalog=$sem_rc)"
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
# evidence-runs (sub-issue C of #473)
# ============================================================================
# See docs/operations/evidence-runs.md for the full ingestion contract.
# These recipes drive the local development loop; the real producer is
# .github/workflows/evidence-run.yml.

# Emit a deterministic TestEntry-shaped row from the checked-in fixture.
# Useful for piping into `just ingest-evidence` while developing the
# transport without spinning a full Docker run.
evidence-row-stub:
    @cat tests/fixtures/evidence-row-sample.json

# Run the ingest script in dry-run against the sibling containers-db
# checkout. Reads the row from the fixture; for ad-hoc rows pipe via
# `--row -` directly to bin/ingest-evidence.sh instead.
ingest-evidence TOOL="rust" VERSION="1.95.0":
    ./bin/ingest-evidence.sh \
        --row tests/fixtures/evidence-row-sample.json \
        --db-path {{ CONTAINERS_DB }} \
        --tool {{ TOOL }} \
        --version {{ VERSION }} \
        --dry-run

# Reconcile support_matrix claims against tested[] evidence (report mode —
# informational, always exits 0). Pass a TOOL (or tool@version) to scope it;
# omit it (`just reconcile`) to walk the whole catalog. Reads the sibling
# containers-db checkout. See docs/operations/evidence-runs.md
# § Coverage reconciliation.
reconcile TOOL="": _db-check
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release -p luggage
    ./target/release/luggage reconcile {{ TOOL }} --catalog "{{ CONTAINERS_DB }}"

# Gate variant: exit non-zero when a `supported` cell has no passing evidence
# row (or an `unsupported` cell has one). Omit TOOL to gate the whole catalog.
# Opt-in — wire into CI once the base-image matrix covers the claimed cells.
reconcile-gate TOOL="": _db-check
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release -p luggage
    ./target/release/luggage reconcile {{ TOOL }} --catalog "{{ CONTAINERS_DB }}" --gate

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
