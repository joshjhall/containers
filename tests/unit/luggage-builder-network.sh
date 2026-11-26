#!/usr/bin/env bash
# Unit tests: the luggage-builder Dockerfile stage keeps fetching git sources
# through cargo's built-in libgit2 (#1760).
#
# The workspace has a git dependency (repo-baseline, from containers-db), so
# `cargo build -p luggage` clones it at image build time. That works on
# rust:*-slim because cargo uses libgit2. The repo's .cargo/config.toml sets
# `git-fetch-with-cli = true`, which needs a `git` binary the slim image lacks —
# so bringing .cargo/ into the stage, or turning git-fetch-with-cli on there any
# other way, would break the image build.
#
# The guard is a SNAPSHOT, not a parser. An allowlist that parsed COPY/mount
# syntax kept missing spellings across six review cycles (JSON COPY, multi-
# source COPY, --mount with no type=, key case and quoting, an inherited FROM
# stage, ...). Instead the whole stage — FROM line included, comments and blank
# lines stripped — must equal LUGGAGE_BUILDER_SNAPSHOT below exactly. Nothing
# is parsed, so there is no spelling to slip past: any change at all fails, and
# a human checks it before updating the snapshot.
#
# LUGGAGE_BUILDER_DOCKERFILE overrides the Dockerfile path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "luggage-builder network/git-fetch tests"

DOCKERFILE="${LUGGAGE_BUILDER_DOCKERFILE:-$PROJECT_ROOT/Dockerfile}"

# The approved luggage-builder stage, normalized (see normalized_stage_of).
# Update this only after checking that the change cannot bring .cargo/ (or
# .cargo/config.toml) into the build and cannot set CARGO_NET_GIT_FETCH_WITH_CLI
# or git-fetch-with-cli — including through the FROM image (an earlier stage in
# this Dockerfile is inherited whole), COPY/ADD sources, and RUN --mount options
# (a --mount with no type= is a bind mount of the build context).
LUGGAGE_BUILDER_SNAPSHOT='FROM rust:1.99-slim-trixie AS luggage-builder
WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/workspace/target \
    cargo build --release -p luggage --bin luggage \
    && cp target/release/luggage /tmp/luggage'

# normalized_stage_of <dockerfile-path> — the first luggage-builder stage, from
# its FROM line through the line before the next FROM, with comment lines,
# blank lines and trailing whitespace removed. awk reads the file directly and
# to EOF: no pipe, so no SIGPIPE abort under `set -o pipefail` (#1760 cycle 5).
normalized_stage_of() {
    command awk '
        /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+luggage-builder([[:space:]]|$)/ { if (!done) in_stage = 1 }
        in_stage && seen && /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]/ { in_stage = 0; done = 1 }
        in_stage {
            seen = 1
            line = $0
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
            print line
        }' "$1"
}

STAGE="$(normalized_stage_of "$DOCKERFILE")"

SNAPSHOT_HELP="The luggage-builder stage in $DOCKERFILE no longer matches the approved snapshot in tests/unit/luggage-builder-network.sh (#1760). Before updating LUGGAGE_BUILDER_SNAPSHOT, check that the change cannot bring .cargo/ (or .cargo/config.toml) into the build and cannot set CARGO_NET_GIT_FETCH_WITH_CLI or git-fetch-with-cli: .cargo/config.toml sets git-fetch-with-cli = true, which needs a git binary rust:*-slim lacks. Watch the FROM image (an earlier stage in the Dockerfile is inherited whole), COPY/ADD sources, and RUN --mount options (no type= means a bind mount). Then paste the new normalized stage into LUGGAGE_BUILDER_SNAPSHOT."

test_stage_found() {
    assert_matches "$STAGE" '^FROM .* AS luggage-builder' \
        "Dockerfile must contain a luggage-builder stage (the snapshot comparison would be meaningless without it)"
}

test_stage_matches_snapshot() {
    if [ "$STAGE" = "$LUGGAGE_BUILDER_SNAPSHOT" ]; then
        assert_equals "$LUGGAGE_BUILDER_SNAPSHOT" "$STAGE" "luggage-builder stage matches the snapshot"
        return
    fi
    echo "    --- approved snapshot"
    echo "    +++ current stage"
    command diff <(printf '%s\n' "$LUGGAGE_BUILDER_SNAPSHOT") <(printf '%s\n' "$STAGE") |
        command sed 's/^/    /' || true
    assert_equals "$LUGGAGE_BUILDER_SNAPSHOT" "$STAGE" "$SNAPSHOT_HELP"
}

test_stage_documents_git_fetch() {
    # The snapshot strips comments, so check the explanation separately: the
    # reason for the snapshot must stay next to the stage it protects.
    local raw
    raw="$(command awk '
        /^[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+luggage-builder([[:space:]]|$)/ { s = 1; next }
        s && /^[Ff][Rr][Oo][Mm][[:space:]]/ { s = 0 }
        s { print }' "$DOCKERFILE")"
    assert_contains "$raw" 'git-fetch-with-cli' \
        "luggage-builder stage comment must explain the git-fetch-with-cli / .cargo caveat (#1760)"
    assert_contains "$raw" 'luggage-builder-network.sh' \
        "luggage-builder stage comment must point at the snapshot test that guards it"
}

run_test test_stage_found "luggage-builder stage exists"
run_test test_stage_matches_snapshot "luggage-builder stage matches the approved snapshot"
run_test test_stage_documents_git_fetch "luggage-builder documents the git-fetch caveat and its guard"

generate_report
