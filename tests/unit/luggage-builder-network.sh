#!/usr/bin/env bash
# Unit tests: the luggage-builder Dockerfile stage keeps fetching git sources
# through cargo's built-in libgit2 (#1760).
#
# The workspace has a git dependency (repo-baseline, from containers-db), so
# `cargo build -p luggage` clones it at image build time. That works on
# rust:*-slim because cargo uses libgit2. The repo's .cargo/config.toml sets
# `git-fetch-with-cli = true`, which needs a `git` binary the slim image lacks —
# so exposing .cargo/ to the stage, or turning git-fetch-with-cli on there any
# other way, would break the image build. These tests pin that invariant.
#
# The guard is an ALLOWLIST, not a denylist: a denylist of "bad" COPY/mount
# spellings kept missing forms (JSON COPY, multi-source COPY, --mount with no
# type=, ...). Instead the stage may only COPY the sources below and only
# declare the mount types below; anything else fails. The guard's own broken
# and legitimate examples live in this file (fixture tests below) so they run
# in CI, not only by hand.
#
# LUGGAGE_BUILDER_DOCKERFILE overrides the Dockerfile path.

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

# stage_of <dockerfile-text> — the luggage-builder stage: its FROM through the
# line before the next FROM. Two choices here together prevent a SIGPIPE
# abort: the input is a here-string (no separate writer process), and awk
# reads to EOF instead of exiting at the next FROM. The old form,
# `printf ... | awk '...{ exit }'`, closed the pipe while printf was still
# writing a large Dockerfile; printf took SIGPIPE and, under
# `set -o pipefail`, the 141 aborted the whole suite before any test ran.
# Only the first luggage-builder stage is taken.
stage_of() {
    command awk '
        /^[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+luggage-builder([[:space:]]|$)/ { if (!done) { in_stage = 1; print }; next }
        in_stage && /^[Ff][Rr][Oo][Mm][[:space:]]/ { in_stage = 0; done = 1; next }
        in_stage { print }' <<<"$1"
}

# instructions_of <stage-text> — comments stripped, then backslash-continued
# lines (a trailing `\`, optionally followed by whitespace) joined into one.
instructions_of() {
    printf '%s\n' "$1" | command grep -vE '^[[:space:]]*#' |
        command awk '/\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, ""); buf = buf $0 " "; next }
            { print buf $0; buf = "" }
            END { if (buf != "") print buf }' || true
}

# stage_violations <instructions-text> [allowed-from-stages] — one line per
# instruction outside the allowlist; no output means the stage is allowed. The
# optional second argument overrides ALLOWED_COPY_FROM_STAGES (fixtures use it
# to exercise the allowlisted-stage path, which the real empty list never hits).
stage_violations() {
    printf '%s\n' "$1" | command awk \
        -v sources="$ALLOWED_COPY_SOURCES" \
        -v mounts="$ALLOWED_MOUNT_TYPES" \
        -v stages="${2-$ALLOWED_COPY_FROM_STAGES}" '
        function listed(word, list,    n, i, a) {
            n = split(list, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] != "" && a[i] == word) return 1
            return 0
        }
        # check_mount: BuildKit reads a --mount value as CSV with
        # case-insensitive keys, so normalize first (lowercase, strip quotes),
        # then require exactly one type= (allowlisted) and at most one from=
        # (allowlisted stage). Missing type= is bind, the BuildKit default.
        function check_mount(raw, inst,    norm, nf, f, i, key, val, ntype, type, nfrom, from) {
            norm = tolower(raw)
            gsub(/["\047]/, "", norm)
            nf = split(norm, f, ",")
            ntype = 0; nfrom = 0; type = ""; from = ""
            for (i = 1; i <= nf; i++) {
                key = f[i]; val = ""
                if (index(key, "=")) { val = substr(key, index(key, "=") + 1); key = substr(key, 1, index(key, "=") - 1) }
                gsub(/[[:space:]]/, "", key)
                if (key == "type") { ntype++; type = val }
                if (key == "from") { nfrom++; from = val }
            }
            if (ntype != 1)
                print "mount must name exactly one type= (found " ntype ") (--mount " raw "): " inst
            else if (!listed(type, mounts))
                print "mount type \"" type "\" not allowlisted (--mount " raw "): " inst
            if (nfrom > 1)
                print "mount names from= more than once (--mount " raw "): " inst
            else if (nfrom == 1 && !listed(from, stages))
                print "mount from=" from " is not an allowlisted stage (--mount " raw "): " inst
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            split(line, w, /[[:space:]]+/)
            kw = toupper(w[1])

            # Every --mount (= or space form, any case) on the instruction.
            rest = line
            while (match(tolower(rest), /--mount[= ][^[:space:]]+/)) {
                check_mount(substr(rest, RSTART + 8, RLENGTH - 8), $0)
                rest = substr(rest, RSTART + RLENGTH)
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
                if (tolower(flag) ~ /^--from=/) { from = substr(flag, 8) }
                else if (tolower(flag) == "--from") {
                    match(args, /^[^[:space:]]+/); from = substr(args, 1, RLENGTH)
                    args = substr(args, RLENGTH + 1); sub(/^[[:space:]]+/, "", args)
                }
            }
            if (from != "") {
                gsub(/["\047]/, "", from)
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

# cli_fetch_hits <instructions-text> — any instruction that turns on CLI git
# fetch: the env var, or the config key itself (e.g. cargo --config
# net.git-fetch-with-cli=true). Comments are already stripped, so the stage's
# explanatory comment does not match.
cli_fetch_hits() {
    printf '%s\n' "$1" | command grep -iE 'CARGO_NET_GIT_FETCH_WITH_CLI|git-fetch-with-cli' || true
}

ALLOWLIST_HELP="luggage-builder may only COPY {$ALLOWED_COPY_SOURCES} and only declare --mount type={$ALLOWED_MOUNT_TYPES}: anything wider can expose .cargo/config.toml (git-fetch-with-cli = true), which needs a git binary rust:*-slim lacks (#1760). To allow a new source, mount type or COPY --from / --mount from= stage, add it to ALLOWED_COPY_SOURCES / ALLOWED_MOUNT_TYPES / ALLOWED_COPY_FROM_STAGES in tests/unit/luggage-builder-network.sh after confirming it cannot bring .cargo/ into the stage."

STAGE="$(stage_of "$(command cat "$DOCKERFILE")")"
INSTRUCTIONS="$(instructions_of "$STAGE")"

# --- The real Dockerfile -----------------------------------------------------

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
    hits="$(stage_violations "$INSTRUCTIONS")"
    assert_empty "$hits" "$ALLOWLIST_HELP Violations:
$hits"
}

test_no_cli_fetch() {
    local hits
    hits="$(cli_fetch_hits "$INSTRUCTIONS")"
    assert_empty "$hits" \
        "luggage-builder must not turn on git-fetch-with-cli (env var or cargo --config): CLI git fetch needs a git binary rust:*-slim lacks (#1760). Offending: $hits"
}

test_stage_documents_git_fetch() {
    assert_contains "$STAGE" 'git-fetch-with-cli' \
        "luggage-builder stage comment must explain the git-fetch-with-cli / .cargo caveat (#1760)"
}

# --- Fixtures: the guard itself must discriminate ----------------------------
# Each case is a minimal luggage-builder stage plus one extra instruction. BAD
# cases must produce a violation; GOOD cases must produce none. A regression in
# the parser that silently weakens the guard fails here, in CI.

FIXTURE_HEAD='FROM rust:1-slim AS luggage-builder
WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates'
FIXTURE_RUN='RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo build --release -p luggage --bin luggage'
FIXTURE_TAIL='FROM debian:trixie-slim AS base'

# fixture_violations <extra-instruction-text> [allowed-from-stages] —
# allowlist + cli-fetch hits for the minimal stage with the extra text inserted
# before the RUN. The optional second argument overrides the from-stage list.
fixture_violations() {
    local df ins
    df="$FIXTURE_HEAD
$1
$FIXTURE_RUN
$FIXTURE_TAIL"
    ins="$(instructions_of "$(stage_of "$df")")"
    stage_violations "$ins" "${2-$ALLOWED_COPY_FROM_STAGES}"
    cli_fetch_hits "$ins"
}

test_stage_of_survives_large_input() {
    # Regression for the SIGPIPE abort: 1 MiB of text AFTER the next FROM.
    # The old `printf ... | awk '...{ exit }'` failed here every time
    # (padding at >=512 KiB, after the FROM; padding before the FROM never
    # fails, since awk reads it all first). Verified by splicing the exact
    # pre-fix stage_of back in: this test then FAILs 5/5. Run in a pipefail
    # subshell so a 141 is caught as a test failure, not a suite abort.
    local pad df rc=0 stage
    pad="$(printf '%*s' $((1024 * 1024)) '' | command tr ' ' 'x')"
    df="$FIXTURE_HEAD
$FIXTURE_RUN
$FIXTURE_TAIL
# $pad"
    stage="$(
        set -o pipefail
        stage_of "$df"
    )" || rc=$?
    assert_equals "0" "$rc" "stage_of must not fail on a >64 KiB Dockerfile (141 = SIGPIPE from an early awk exit)"
    assert_matches "$stage" 'COPY crates' "stage_of on large input must still return the luggage-builder stage"
}

test_fixture_baseline_is_clean() {
    local hits
    hits="$(fixture_violations '')"
    assert_empty "$hits" "the minimal fixture stage must itself be allowed (else every BAD case passes vacuously): $hits"
}

test_fixture_bad_cases() {
    # One case per line: a label, a tab, then the instruction (\n = newline).
    local cases failed=0 label inst hits
    cases="$(
        command cat <<'EOF'
copy-dot-cargo	COPY .cargo ./.cargo
copy-whole-context	COPY --chown=1000 . .
copy-json-dot	COPY [".", "/workspace"]
copy-json-dot-cargo	COPY [".cargo", "./.cargo"]
copy-continued-dot-cargo	COPY Cargo.toml \\n    .cargo/ ./x/
copy-glob	COPY * ./
copy-dot-not-first	COPY Cargo.toml . ./
copy-json-dot-not-first	COPY ["Cargo.lock", ".", "./"]
copy-continued-trailing-space	COPY \  \n    . ./
copy-unlisted-source	COPY src ./src
copy-lowercase	copy . ./
copy-from-unlisted	COPY --from=builder /x /y
copy-from-space-form	COPY --from builder /x /y
copy-from-upper-flag	COPY --FROM=builder /x /y
copy-from-after-other-flag	COPY --chown=1 --from=builder /x /y
add	ADD Cargo.toml ./x
env-cli-fetch	ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
config-cli-fetch	RUN cargo build --config net.git-fetch-with-cli=true
mount-bind	RUN --mount=type=bind,source=.,target=/workspace true
mount-no-type	RUN --mount=source=.cargo,target=/workspace/.cargo true
mount-no-type-reordered	RUN --mount=target=/workspace/.cargo,source=.cargo true
mount-space-form	RUN --mount type=bind,source=.,target=/workspace true
mount-cache-dup-type	RUN --mount=type=cache,type=bind,target=/x true
mount-cache-dup-type-upper	RUN --mount=type=cache,TYPE=bind,source=.cargo,target=/w/.cargo true
mount-dup-type-both-cache	RUN --mount=type=cache,TYPE=cache,target=/x true
mount-dup-from-allowed-type	RUN --mount=type=cache,from=x,FROM=y,target=/x true
mount-upper-type-bind	RUN --mount=TYPE=bind,source=.cargo,target=/w/.cargo true
mount-cache-from	RUN --mount=type=cache,from=x,source=.cargo,target=/w/.cargo true
mount-cache-from-first	RUN --mount=from=x,type=cache,source=.cargo,target=/w/.cargo true
mount-cache-from-upper	RUN --mount=FROM=x,type=cache,source=.cargo,target=/w/.cargo true
mount-cache-from-quoted	RUN --mount=type=cache,"from=x",source=.cargo,target=/w/.cargo true
mount-cache-type-quoted-bind	RUN --mount="type=bind",source=.cargo,target=/w/.cargo true
mount-upper-flag	RUN --MOUNT=type=bind,source=.,target=/w true
EOF
    )"
    while IFS=$'\t' read -r label inst; do
        [ -n "$label" ] || continue
        inst="${inst//\\n/$'\n'}"
        hits="$(fixture_violations "$inst")"
        if [ -z "$hits" ]; then
            echo "    BAD case not caught: $label: $inst"
            failed=$((failed + 1))
        fi
    done <<<"$cases"
    assert_equals "0" "$failed" "every BAD fixture must produce a violation ($failed slipped through)"
}

test_fixture_good_cases() {
    local cases failed=0 label inst hits
    cases="$(
        command cat <<'EOF'
git-cache-mount	RUN --mount=type=cache,target=/usr/local/cargo/git true
cache-mount-id-sharing	RUN --mount=type=cache,id=cargo-git,sharing=locked,target=/usr/local/cargo/git true
cache-mount-upper-key	RUN --mount=TYPE=cache,target=/usr/local/cargo/git true
copy-multi-allowed	COPY Cargo.toml Cargo.lock ./crates/ ./
copy-json-allowed	COPY ["Cargo.toml", "./crates", "/w/"]
EOF
    )"
    while IFS=$'\t' read -r label inst; do
        [ -n "$label" ] || continue
        hits="$(fixture_violations "$inst")"
        if [ -n "$hits" ]; then
            echo "    GOOD case rejected: $label: $hits"
            failed=$((failed + 1))
        fi
    done <<<"$cases"
    assert_equals "0" "$failed" "every GOOD fixture must be allowed ($failed rejected)"
}

test_fixture_allowlisted_stage_cases() {
    # ALLOWED_COPY_FROM_STAGES is empty in production, so the allow side of the
    # from-stage check would otherwise never run. Pass an allowlist of
    # "builder" and require: the allowlisted stage is accepted (both COPY
    # --from and --mount from=, in each spelling), and a different stage is
    # still rejected (so the override does not simply disable the check).
    local inst hits failed=0
    for inst in \
        'COPY --from=builder /x /y' \
        'COPY --from builder /x /y' \
        'COPY --FROM=builder /x /y' \
        'RUN --mount=type=cache,from=builder,target=/x true' \
        'RUN --mount=type=cache,FROM=builder,target=/x true'; do
        hits="$(fixture_violations "$inst" "builder")"
        if [ -n "$hits" ]; then
            echo "    allowlisted stage rejected: $inst: $hits"
            failed=$((failed + 1))
        fi
    done
    for inst in \
        'COPY --from=other /x /y' \
        'RUN --mount=type=cache,from=other,target=/x true'; do
        hits="$(fixture_violations "$inst" "builder")"
        if [ -z "$hits" ]; then
            echo "    unlisted stage accepted: $inst"
            failed=$((failed + 1))
        fi
    done
    assert_equals "0" "$failed" "allowlisted from-stages must pass and others must still fail ($failed wrong)"
}

run_test test_stage_exists "luggage-builder stage exists and builds luggage"
run_test test_instructions_parsed "luggage-builder instruction filter keeps the COPY and build lines"
run_test test_copy_and_mount_allowlist "luggage-builder COPY sources and mount types are allowlisted"
run_test test_no_cli_fetch "luggage-builder does not turn on git-fetch-with-cli"
run_test test_stage_documents_git_fetch "luggage-builder documents the git-fetch caveat"
run_test test_fixture_baseline_is_clean "fixture: minimal allowed stage has no violations"
run_test test_fixture_bad_cases "fixture: every broken stage is rejected"
run_test test_fixture_good_cases "fixture: every legitimate stage is allowed"
run_test test_fixture_allowlisted_stage_cases "fixture: allowlisted from-stage passes, others still fail"
run_test test_stage_of_survives_large_input "stage_of survives a >64 KiB Dockerfile (no SIGPIPE abort)"

generate_report
