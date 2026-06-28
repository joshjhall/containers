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

# Machine-local files a fresh Mode-2 worktree needs but that are gitignored
# (so absent from a new worktree). Space-separated, repo-root-relative. Keep
# this list in ONE place so it is easy to extend when other local files become
# required. See the worktree-push-hooks-gitignore / golem-push-gate-under-auto
# memory notes for why each is needed:
#   .env                         — docker-compose-validate pre-push hook reads
#                                  .devcontainer/docker-compose.yml's
#                                  `env_file: - ../.env`.
#   .claude/settings.local.json  — permissions.defaultMode "auto" + the
#                                  push/PR `ask` gates. The launch passes
#                                  `--permission-mode auto` explicitly (a fresh
#                                  worktree is untrusted, so `defaultMode` here
#                                  is not loaded on its own — #585); this file
#                                  still supplies the push/PR `ask` rules once
#                                  trust is seeded.
WORKTREE_LOCAL_FILES := ".env .claude/settings.local.json"

# Creates .worktrees/issue-N on branch feature/issue-N from origin/main and
# copies in the gitignored machine-local files (WORKTREE_LOCAL_FILES) a push needs.
# Create a push-ready Mode-2 worktree for issue N (idempotent; copies .env etc.).
worktree-new N:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ "{{ N }}" =~ ^[0-9]+$ ]]; then
        echo "worktree-new: N must be an issue number, got '{{ N }}'" >&2
        exit 2
    fi
    root="$(bash "{{ justfile_directory() }}/bin/repo-root.sh")"
    cd "$root"
    wt=".worktrees/issue-{{ N }}"
    br="feature/issue-{{ N }}"
    if git worktree list --porcelain | /usr/bin/grep -qx "worktree $root/$wt"; then
        echo "worktree-new: $wt already exists — remove it first (just worktree-rm {{ N }})" >&2
        exit 1
    fi
    if [ -n "$(git branch --list "$br")" ]; then
        echo "worktree-new: branch $br already exists — delete it or pick another issue" >&2
        exit 1
    fi
    git fetch origin main --quiet
    git worktree add "$wt" -b "$br" origin/main
    for f in {{ WORKTREE_LOCAL_FILES }}; do
        if [ -e "$f" ]; then
            /usr/bin/mkdir -p "$wt/$(/usr/bin/dirname "$f")"
            /usr/bin/cp "$f" "$wt/$f"
            echo "  copied $f"
        else
            echo "  skipped $f (not present in main checkout)"
        fi
    done
    # Seed a workspace-trust entry for the new worktree path so the copied
    # settings.local.json (defaultMode "auto" + push/PR `ask` gates) actually
    # loads — Claude Code does not load project settings for an UNTRUSTED folder,
    # and a non-interactive tmux launch can't show the trust dialog (#585).
    # Complements the explicit `--permission-mode auto` in the launch hint below
    # (which works even if this step is unavailable). Delegated to a tested
    # helper (covered by tests/unit/bin/seed-worktree-trust.sh); best-effort,
    # always exits 0 so a trust-seed failure never aborts worktree creation.
    "$root/bin/seed-worktree-trust.sh" "$root/$wt"
    echo ""
    echo "Worktree ready: $wt (branch $br)"
    echo "Launch a golem there with:"
    echo "  tmux new-session -d -s golem-{{ N }} -c \"$root/$wt\" -e GOLEM_ID=golem-{{ N }} \"claude --permission-mode auto '/next-issue {{ N }} --auto' ; claude --permission-mode auto '/next-issue-ship --auto'\""

# Post-merge cleanup: remove the issue-N worktree and its feature/issue-N branch (clean no-op if absent).
worktree-rm N:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ "{{ N }}" =~ ^[0-9]+$ ]]; then
        echo "worktree-rm: N must be an issue number, got '{{ N }}'" >&2
        exit 2
    fi
    root="$(bash "{{ justfile_directory() }}/bin/repo-root.sh")"
    cd "$root"
    wt=".worktrees/issue-{{ N }}"
    br="feature/issue-{{ N }}"
    removed=0
    if git worktree list --porcelain | /usr/bin/grep -qx "worktree $root/$wt"; then
        if ! git worktree remove "$wt" 2>/dev/null; then
            echo "worktree-rm: $wt has uncommitted changes." >&2
            echo "  Re-run after committing, or force: git worktree remove --force $wt" >&2
            exit 1
        fi
        echo "  removed worktree $wt"
        removed=1
    fi
    if [ -n "$(git branch --list "$br")" ]; then
        git branch -D "$br"
        echo "  deleted branch $br"
        removed=1
    fi
    if [ "$removed" -eq 0 ]; then
        echo "worktree-rm: nothing to remove for issue {{ N }} ($wt / $br absent)"
    fi
    # A golem PR usually merges into origin/main right before its worktree is
    # torn down here. On a BARE host the on-disk runtime copies (.claude/hooks,
    # justfile, bin) don't update on their own (no work tree to check out into),
    # so refresh them now — otherwise the next golem fires the just-superseded
    # hook/justfile (#606). Best-effort and bare-host-only: a normal checkout
    # uses git checkout/pull and is left untouched; any failure never aborts the
    # teardown.
    if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
        bash "{{ justfile_directory() }}/bin/sync-host.sh" || \
            echo "  (sync-host refresh skipped — run 'just sync-host' manually)" >&2
    fi

# Reads .worktrees/.status/*.json + live golem-* tmux sessions and the
# Notification feed; PR + issue-label state remains authoritative (cache fills gaps).
# Show the central golem status table + which golems are BLOCKED (TTY-free).
golems:
    #!/usr/bin/env bash
    set -uo pipefail
    root="$(bash "{{ justfile_directory() }}/bin/repo-root.sh")"
    status_dir="$root/.worktrees/.status"
    feed="$status_dir/feed.jsonl"
    pool="$status_dir/pool.json"
    shopt -s nullglob
    # pool.json is operator policy, NOT a golem-status file — keep it out of the
    # golem-row glob (else it renders as a bogus "?" row). It's surfaced in the
    # pool header below instead.
    cache=()
    for f in "$status_dir"/*.json; do
        [ "$f" = "$pool" ] && continue
        cache+=("$f")
    done
    sessions="$(tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' || true)"
    if [ "${#cache[@]}" -eq 0 ] && [ -z "$sessions" ] && [ ! -f "$pool" ]; then
        echo "No active golems (no $status_dir/*.json, no golem-* tmux sessions)."
        exit 0
    fi
    # Pool header: size, slots in use, backlog depth, and the accepting state.
    # Defensive `// "-"` fallbacks mirror the golem-row jq style for absent fields.
    if [ -f "$pool" ]; then
        jq -r '"Pool: size=\(.size // "-")  slots=\((.slots // []) | length)/\(.size // "-")  backlog=\(.backlog_depth // "-")  accepting=\(.accepting // "-")"' \
            "$pool" 2>/dev/null || echo "Pool: (unreadable $pool)"
        echo ""
    fi
    printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
        GOLEM ISSUE BRANCH PR STATE PHASE BLOCKING
    for f in "${cache[@]}"; do
        jq -r '[
            (.golem // "?"),
            (.issue // "?" | tostring),
            (.branch // "-"),
            (.pr // "-" | tostring),
            (.state // "-"),
            (.phase // "-"),
            (if .blocking then "YES" else "-" end)
        ] | @tsv' "$f" 2>/dev/null \
        | while IFS=$'\t' read -r g i b p s ph bl; do
            printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' "$g" "$i" "$b" "$p" "$s" "$ph" "$bl"
        done
    done
    # Live sessions with no cache file yet.
    for sess in $sessions; do
        n="${sess#golem-}"
        if [ ! -e "$status_dir/golem-$n.json" ] && [ ! -e "$status_dir/issue-$n.json" ]; then
            printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
                "$sess" "$n" "-" "-" "(live)" "-" "-"
        fi
    done
    echo ""
    echo "BLOCKED (needs a human decision):"
    blocked=0
    for f in "${cache[@]}"; do
        if [ "$(jq -r '.blocking // false' "$f" 2>/dev/null)" = "true" ]; then
            n="$(jq -r '.issue // empty' "$f" 2>/dev/null)"
            echo "  golem-$n — just golem-attach $n"
            blocked=1
        fi
    done
    # Fresh-gate detection from the feed is delegated to bin/golem-gate-watch.sh
    # (--once snapshot) so the BLOCKED list here and the proactive `golem-watch`
    # stream share ONE source of truth and can never drift. The helper applies
    # the same rule: a golem is BLOCKED only when its most-recent feed line is a
    # fresh `gate` (legacy `blocked` honored) within GOLEM_BLOCK_TTL; an `idle`
    # emitted once the golem resumes supersedes and clears it. It emits
    # "<golem>\t<message>"; reformat to the "  golem — message" display here.
    if [ -f "$feed" ]; then
        feed_blocked="$(
            bash "{{ justfile_directory() }}/bin/golem-gate-watch.sh" --once 2>/dev/null \
            | /usr/bin/awk -F'\t' 'NF { printf "  %s — %s\n", $1, $2 }'
        )"
        if [ -n "$feed_blocked" ]; then
            printf '%s\n' "$feed_blocked"
            blocked=1
        fi
    fi
    [ "$blocked" -eq 0 ] && echo "  (none)"
    if [ -f "$feed" ]; then
        echo ""
        echo "Recent feed ($feed):"
        /usr/bin/tail -n 10 "$feed"
    fi

# Tries the golem-N worktree tmux session, else the container golem's `claude`
# session via docker exec (clean failure if neither exists).
# Attach to issue N's golem session (worktree or container).
golem-attach N:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ "{{ N }}" =~ ^[0-9]+$ ]]; then
        echo "golem-attach: N must be an issue number, got '{{ N }}'" >&2
        exit 2
    fi
    if tmux has-session -t "golem-{{ N }}" 2>/dev/null; then
        exec tmux attach -t "golem-{{ N }}"
    fi
    root="$(bash "{{ justfile_directory() }}/bin/repo-root.sh")"
    status_dir="$root/.worktrees/.status"
    shopt -s nullglob
    for f in "$status_dir"/*.json; do
        if [ "$(jq -r '.issue // empty' "$f" 2>/dev/null)" = "{{ N }}" ]; then
            ctr="$(jq -r '.container // empty' "$f" 2>/dev/null)"
            if [ -n "$ctr" ]; then
                exec docker exec -it "$ctr" tmux attach -t claude
            fi
        fi
    done
    echo "golem-attach: no golem-{{ N }} tmux session and no container golem for issue {{ N }}." >&2
    echo "  Check 'just golems' for active golems." >&2
    exit 1

# Proactive PUSH watch for golem permission gates — the complement to the PULL
# `just golems`. Streams both gate channels (issue #618): the classified feed
# (all golems, TTY-free) and live tmux pane prompt-overlays (worktree golems,
# best for plan gates). Emits one "<golem> <message>" line on each transition
# into a fresh gate; runs until interrupted (Ctrl-C).
# Proactively watch for blocked golems (streams feed + pane gate channels; Ctrl-C to stop).
golem-watch:
    #!/usr/bin/env bash
    set -uo pipefail
    watch="{{ justfile_directory() }}/bin/golem-gate-watch.sh"
    echo "Watching for golem permission gates (feed + panes). Ctrl-C to stop." >&2
    # Pane channel in the background, feed channel in the foreground; both prefix
    # their source so the operator can tell which channel fired. Kill the
    # background pane watcher when the foreground feed watcher exits.
    ( bash "$watch" --stream-panes 2>/dev/null | /usr/bin/sed -u 's/^/[pane] /' ) &
    pane_pid=$!
    trap '/usr/bin/kill "$pane_pid" 2>/dev/null || true' EXIT INT TERM
    bash "$watch" --stream 2>/dev/null | /usr/bin/sed -u 's/^/[feed] /'

# A bare repo never checks files out, so the host's on-disk .claude/hooks,
# justfile, and bin/ drift behind origin/main after a merge and it runs stale
# hooks/justfile (#606). Pass path prefixes to narrow the set.
# Refresh a bare host's on-disk runtime copies (.claude/hooks, justfile, bin) from origin/main.
sync-host *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" {{ PREFIXES }}

# Drift guard for #606: report any on-disk runtime copy that differs from origin/main, exit non-zero if so (writes nothing).
sync-host-check *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" --check {{ PREFIXES }}

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

# Reconcile support_matrix claims against tested[] evidence for a tool
# (report mode — informational, always exits 0). Omit TOOL to walk the whole
# catalog. Reads the sibling containers-db checkout. See
# docs/operations/evidence-runs.md § Coverage reconciliation.
reconcile TOOL="rust": _db-check
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release -p luggage
    ./target/release/luggage reconcile {{ TOOL }} --catalog "{{ CONTAINERS_DB }}"

# Gate variant: exit non-zero when a `supported` cell has no passing evidence
# row (or an `unsupported` cell has one). Opt-in — wire into CI once the
# base-image matrix covers the claimed cells.
reconcile-gate TOOL="rust": _db-check
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
