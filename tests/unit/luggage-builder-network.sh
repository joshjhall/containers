#!/usr/bin/env bash
# Unit tests: the luggage-builder Dockerfile stage keeps fetching git sources
# through cargo's built-in libgit2 (#1760).
#
# The workspace has a git dependency (repo-baseline, from containers-db), so
# `cargo build -p luggage` clones it at image build time. That works on
# rust:*-slim because cargo uses libgit2. The repo's .cargo/config.toml sets
# `git-fetch-with-cli = true`, which needs a `git` binary the slim image lacks —
# so copying .cargo/ (explicitly, or via a whole-context `COPY . `) into the
# stage would break the image build. These tests pin that invariant.
#
# LUGGAGE_BUILDER_DOCKERFILE overrides the Dockerfile path (for mutation checks).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "luggage-builder network/git-fetch tests"

DOCKERFILE="${LUGGAGE_BUILDER_DOCKERFILE:-$PROJECT_ROOT/Dockerfile}"

# Lines of the luggage-builder stage: its FROM through the line before the next FROM.
STAGE="$(command awk '
    /^FROM[[:space:]].*[[:space:]][Aa][Ss][[:space:]]+luggage-builder([[:space:]]|$)/ { in_stage = 1; print; next }
    in_stage && /^FROM[[:space:]]/ { exit }
    in_stage { print }
' "$DOCKERFILE")"

# Instruction lines only (comments stripped), for the COPY/ADD checks.
INSTRUCTIONS="$(printf '%s\n' "$STAGE" | command grep -vE '^[[:space:]]*#' || true)"

test_stage_exists() {
    assert_matches "$STAGE" 'cargo build --release -p luggage' \
        "Dockerfile must contain a luggage-builder stage that builds luggage (guards below would pass vacuously)"
}

test_no_cargo_config_copied() {
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" |
        command grep -E '^[[:space:]]*(COPY|ADD)[[:space:]].*\.cargo([/[:space:]]|$)' || true)"
    assert_empty "$hits" \
        "luggage-builder must not COPY/ADD .cargo/: .cargo/config.toml sets git-fetch-with-cli = true, which needs a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_no_whole_context_copy() {
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" |
        command grep -E '^[[:space:]]*(COPY|ADD)([[:space:]]+--[^[:space:]]+)*[[:space:]]+\.\/?[[:space:]]' || true)"
    assert_empty "$hits" \
        "luggage-builder must not copy the whole build context: it would pull in .cargo/config.toml (git-fetch-with-cli = true) and need a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_stage_documents_git_fetch() {
    assert_contains "$STAGE" 'git-fetch-with-cli' \
        "luggage-builder stage comment must explain the git-fetch-with-cli / .cargo caveat (#1760)"
}

run_test test_stage_exists "luggage-builder stage exists and builds luggage"
run_test test_no_cargo_config_copied "luggage-builder does not copy .cargo/"
run_test test_no_whole_context_copy "luggage-builder does not copy the whole context"
run_test test_stage_documents_git_fetch "luggage-builder documents the git-fetch caveat"

generate_report
