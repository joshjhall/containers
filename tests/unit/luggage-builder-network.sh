#!/usr/bin/env bash
# Unit tests: the luggage-builder Dockerfile stage keeps fetching git sources
# through cargo's built-in libgit2 (#1760).
#
# The workspace has a git dependency (repo-baseline, from containers-db), so
# `cargo build -p luggage` clones it at image build time. That works on
# rust:*-slim because cargo uses libgit2. The repo's .cargo/config.toml sets
# `git-fetch-with-cli = true`, which needs a `git` binary the slim image lacks —
# so exposing .cargo/ to the stage, or setting CARGO_NET_GIT_FETCH_WITH_CLI
# there, would break the image build. These tests pin that invariant.
#
# The guard is an ALLOWLIST, not a denylist: a denylist of "bad" COPY/mount
# spellings kept missing forms (JSON COPY, multi-source COPY, --mount with no
# type=, ...). Instead the stage may only COPY the sources below and only
# declare the mount types below; anything else fails.
#
# LUGGAGE_BUILDER_DOCKERFILE overrides the Dockerfile path (for mutation checks).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "luggage-builder network/git-fetch tests"

DOCKERFILE="${LUGGAGE_BUILDER_DOCKERFILE:-$PROJECT_ROOT/Dockerfile}"

# --- The allowlist -----------------------------------------------------------
# To extend it, add the entry here, after confirming it cannot bring .cargo/
# (or .cargo/config.toml) into the luggage-builder stage.
#   ALLOWED_COPY_SOURCES      build-context paths COPY may name (no globs, no `.`)
#   ALLOWED_MOUNT_TYPES       RUN --mount types (bind is the BuildKit default)
#   ALLOWED_COPY_FROM_STAGES  earlier stages COPY --from / --mount from= may
#                             read (none today)
ALLOWED_COPY_SOURCES="Cargo.toml Cargo.lock crates"
ALLOWED_MOUNT_TYPES="cache"
ALLOWED_COPY_FROM_STAGES=""

# Lines of the luggage-builder stage: its FROM through the line before the next FROM.
STAGE="$(command awk '
    /^[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+luggage-builder([[:space:]]|$)/ { in_stage = 1; print; next }
    in_stage && /^[Ff][Rr][Oo][Mm][[:space:]]/ { exit }
    in_stage { print }
' "$DOCKERFILE")"

# Instruction lines only: comments stripped, then backslash-continued lines
# (a trailing `\`, optionally followed by whitespace) joined into one line.
INSTRUCTIONS="$(printf '%s\n' "$STAGE" | command grep -vE '^[[:space:]]*#' |
    command awk '/\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, ""); buf = buf $0 " "; next }
        { print buf $0; buf = "" }
        END { if (buf != "") print buf }' || true)"

# stage_violations — print one line per instruction outside the allowlist.
stage_violations() {
    printf '%s\n' "$INSTRUCTIONS" | command awk \
        -v sources="$ALLOWED_COPY_SOURCES" \
        -v mounts="$ALLOWED_MOUNT_TYPES" \
        -v stages="$ALLOWED_COPY_FROM_STAGES" '
        function listed(word, list,    n, i, a) {
            n = split(list, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] != "" && a[i] == word) return 1
            return 0
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            split(line, w, /[[:space:]]+/)
            kw = toupper(w[1])

            # Mounts: every --mount (= or space form) must name exactly one
            # allowlisted type. No type= means bind, the BuildKit default.
            rest = line
            while (match(rest, /--mount[= ][^[:space:]]+/)) {
                opt = substr(rest, RSTART + 8, RLENGTH - 8)
                rest = substr(rest, RSTART + RLENGTH)
                ntype = gsub(/(^|,)type=/, "&", opt)
                type = opt
                if (ntype == 1 && match(type, /(^|,)type=[^,]*/)) {
                    type = substr(type, RSTART, RLENGTH)
                    sub(/^,?type=/, "", type)
                } else {
                    type = ""
                }
                if (!listed(type, mounts))
                    print "mount type not allowlisted (--mount " opt "): " $0
                # A mount with from= is seeded from another stage/context, the
                # same route as COPY --from, so it gets the same stage allowlist.
                if (match(opt, /(^|,)from=[^,]*/)) {
                    mfrom = substr(opt, RSTART, RLENGTH)
                    sub(/^,?from=/, "", mfrom)
                    if (!listed(mfrom, stages))
                        print "mount from=" mfrom " is not an allowlisted stage (--mount " opt "): " $0
                }
            }

            if (kw == "ADD") { print "ADD is not allowlisted (use COPY): " $0; next }
            if (kw != "COPY") next

            args = substr(line, length(w[1]) + 1)
            sub(/^[[:space:]]+/, "", args)
            from = ""
            while (args ~ /^--/) {
                match(args, /^--[^[:space:]]+/)
                flag = substr(args, 1, RLENGTH)
                args = substr(args, RLENGTH + 1)
                sub(/^[[:space:]]+/, "", args)
                if (flag ~ /^--from=/) { from = substr(flag, 8) }
                else if (flag == "--from") {
                    match(args, /^[^[:space:]]+/); from = substr(args, 1, RLENGTH)
                    args = substr(args, RLENGTH + 1); sub(/^[[:space:]]+/, "", args)
                }
            }
            if (from != "") {
                if (!listed(from, stages))
                    print "COPY --from=" from " is not an allowlisted stage: " $0
                next
            }
            if (args ~ /^\[/) gsub(/[][",]/, " ", args)
            sub(/^[[:space:]]+/, "", args)
            sub(/[[:space:]]+$/, "", args)
            n = split(args, t, /[[:space:]]+/)
            if (n < 2) { print "COPY with no source: " $0; next }
            for (i = 1; i < n; i++) {
                src = t[i]
                sub(/^\.\//, "", src)
                sub(/\/+$/, "", src)
                if (!listed(src, sources))
                    print "COPY source \"" t[i] "\" not allowlisted: " $0
            }
        }'
}

test_stage_exists() {
    assert_matches "$STAGE" 'cargo build --release -p luggage' \
        "Dockerfile must contain a luggage-builder stage that builds luggage (the guards below would pass vacuously)"
}

test_instructions_parsed() {
    # The allowlist scans INSTRUCTIONS; prove the filter kept the real COPY and
    # build lines so the guard cannot pass on empty input.
    assert_matches "$INSTRUCTIONS" 'COPY crates' \
        "INSTRUCTIONS filter lost the COPY crates line (the allowlist would pass vacuously)"
    assert_matches "$INSTRUCTIONS" 'cargo build --release -p luggage' \
        "INSTRUCTIONS filter lost the cargo build line (the allowlist would pass vacuously)"
}

test_copy_and_mount_allowlist() {
    local hits
    hits="$(stage_violations)"
    assert_empty "$hits" \
        "luggage-builder may only COPY {$ALLOWED_COPY_SOURCES} and only declare --mount type={$ALLOWED_MOUNT_TYPES}: anything wider can expose .cargo/config.toml (git-fetch-with-cli = true), which needs a git binary rust:*-slim lacks (#1760). To allow a new source, mount type or COPY --from / --mount from= stage, add it to ALLOWED_COPY_SOURCES / ALLOWED_MOUNT_TYPES / ALLOWED_COPY_FROM_STAGES in tests/unit/luggage-builder-network.sh after confirming it cannot bring .cargo/ into the stage. Violations:
$hits"
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
run_test test_instructions_parsed "luggage-builder instruction filter keeps the COPY and build lines"
run_test test_copy_and_mount_allowlist "luggage-builder COPY sources and mount types are allowlisted"
run_test test_no_cli_fetch_env "luggage-builder does not set CARGO_NET_GIT_FETCH_WITH_CLI"
run_test test_stage_documents_git_fetch "luggage-builder documents the git-fetch caveat"

generate_report
