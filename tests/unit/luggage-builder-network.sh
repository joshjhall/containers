#!/usr/bin/env bash
# Unit tests: the luggage-builder Dockerfile stage keeps fetching git sources
# through cargo's built-in libgit2 (#1760).
#
# The workspace has a git dependency (repo-baseline, from containers-db), so
# `cargo build -p luggage` clones it at image build time. That works on
# rust:*-slim because cargo uses libgit2. The repo's .cargo/config.toml sets
# `git-fetch-with-cli = true`, which needs a `git` binary the slim image lacks —
# so exposing .cargo/ to the stage (a COPY of it or of the whole context, or a
# bind mount), or setting CARGO_NET_GIT_FETCH_WITH_CLI there, would break the
# image build. These tests pin that invariant.
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

# Instruction lines only, for the COPY/ADD checks: comments stripped, then
# backslash-continued lines joined so a COPY split across lines is one line.
INSTRUCTIONS="$(printf '%s\n' "$STAGE" | command grep -vE '^[[:space:]]*#' |
    command awk '/\\$/ { sub(/\\$/, ""); buf = buf $0 " "; next } { print buf $0; buf = "" }
        END { if (buf != "") print buf }' || true)"

test_stage_exists() {
    assert_matches "$STAGE" 'cargo build --release -p luggage' \
        "Dockerfile must contain a luggage-builder stage that builds luggage (guards below would pass vacuously)"
}

test_no_cargo_config_copied() {
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" |
        command grep -E '^[[:space:]]*(COPY|ADD)[[:space:]].*\.cargo([/[:space:]"]|$)' || true)"
    assert_empty "$hits" \
        "luggage-builder must not COPY/ADD .cargo/: .cargo/config.toml sets git-fetch-with-cli = true, which needs a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_no_whole_context_copy() {
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" |
        command grep -E '^[[:space:]]*(COPY|ADD)([[:space:]]+--[^[:space:]]+)*[[:space:]]+((\.\/?|\*)[[:space:]]|\[[[:space:]]*"(\.\/?|\*)")' || true)"
    assert_empty "$hits" \
        "luggage-builder must not copy the whole build context: it would pull in .cargo/config.toml (git-fetch-with-cli = true) and need a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_instructions_parsed() {
    # The negative guards below scan INSTRUCTIONS; prove the filter pipeline
    # produced the real build line so they cannot pass on an empty string.
    assert_matches "$INSTRUCTIONS" 'cargo build --release -p luggage' \
        "INSTRUCTIONS filter lost the cargo build line (the negative guards would pass vacuously)"
}

test_no_bind_mount() {
    # A bind mount exposes context files (incl. .cargo/config.toml) without any
    # COPY. BuildKit's --mount defaults to type=bind, so every --mount option
    # must name an explicitly safe type; one with no type= or any other type fails.
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" | command grep -oE -- '--mount[= ][^[:space:]]+' |
        command grep -vE -- '(^--mount[= ]|,)type=(cache|tmpfs|secret|ssh)(,|$)' || true)"
    assert_empty "$hits" \
        "luggage-builder must not bind-mount the build context: it would expose .cargo/config.toml (git-fetch-with-cli = true) to cargo (#1760). Offending: $hits"
}

test_no_cli_fetch_env() {
    # The env-var spelling of the same cargo setting.
    local hits
    hits="$(printf '%s\n' "$INSTRUCTIONS" | command grep -E 'CARGO_NET_GIT_FETCH_WITH_CLI' || true)"
    assert_empty "$hits" \
        "luggage-builder must not set CARGO_NET_GIT_FETCH_WITH_CLI: CLI git fetch needs a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_stage_documents_git_fetch() {
    assert_contains "$STAGE" 'git-fetch-with-cli' \
        "luggage-builder stage comment must explain the git-fetch-with-cli / .cargo caveat (#1760)"
}

run_test test_stage_exists "luggage-builder stage exists and builds luggage"
run_test test_instructions_parsed "luggage-builder instruction filter keeps the build line"
run_test test_no_cargo_config_copied "luggage-builder does not copy .cargo/"
run_test test_no_whole_context_copy "luggage-builder does not copy the whole context"
run_test test_no_bind_mount "luggage-builder does not bind-mount the context"
run_test test_no_cli_fetch_env "luggage-builder does not set CARGO_NET_GIT_FETCH_WITH_CLI"
run_test test_stage_documents_git_fetch "luggage-builder documents the git-fetch caveat"

generate_report
