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

# The recipes above check the sibling containers-db checkout. This one checks
# crates/luggage/testdata/catalog — which the Dockerfile COPYs to
# /opt/containers-db, making it the copy every `luggage install` resolves
# against. It was unvalidated until issue #815, and had already drifted:
# missing install_methods[].invoke.env and every rhel support-matrix row.
#
# Three parts, in increasing order of what they catch:
#   1. schema   — both catalogs' entries satisfy tool/version.schema.json
#   2. drift    — shared tool+version entries match containers-db exactly
#   3. negative — the planted bad fixtures are actually REJECTED, so a
#                 vacuously-passing check can't masquerade as a clean one
#
# Validate the vendored catalog (schema + drift vs containers-db + negatives).
db-validate-vendored: db-compile
    #!/usr/bin/env bash
    set -euo pipefail
    VENDORED="{{ justfile_directory() }}/crates/luggage/testdata/catalog"
    FIXTURES="{{ justfile_directory() }}/crates/luggage/testdata/fixtures-catalog"
    NEGATIVE="{{ justfile_directory() }}/crates/luggage/testdata/_negative"
    DRIFT="{{ justfile_directory() }}/bin/check-catalog-drift.sh"
    source "{{ justfile_directory() }}/bin/lib/vendored-only-target.sh"
    cd "{{ CONTAINERS_DB }}"
    ajv() {
        command npx --yes -p ajv-cli@{{ AJV_CLI_VERSION }} -p ajv-formats@{{ AJV_FORMATS_VERSION }} -- ajv "$@"
    }

    # 1. Schema. The fixtures catalog is checked too: it is no longer production
    # data, but it is still catalog-shaped, and a malformed fixture would make
    # crates/luggage/tests/cli.rs failures inscrutable.
    for catalog in "$VENDORED" "$FIXTURES"; do
        command echo "=== schema: $catalog ==="
        ajv validate {{ AJV_FLAGS }} -s schema/tool.schema.json -d "$catalog/tools/*/index.json"
        ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "$catalog/tools/*/versions/*.json"
    done

    # 2. Drift. Only the production copy — fixtures-catalog is exempt by design
    # (it carries edge cases upstream has no reason to hold).
    command echo "=== drift: vendored vs {{ CONTAINERS_DB }} ==="
    command bash "$DRIFT" --vendored "$VENDORED" --upstream "{{ CONTAINERS_DB }}" \
        --dockerfile "{{ justfile_directory() }}/Dockerfile"

    # 3. Negative fixtures. schema-* must fail ajv; drift-* are schema-VALID and
    # must fail only the drift comparison — staged into a temp copy of the
    # catalog so the real tree is never mutated.
    command echo "=== negative fixtures ==="
    shopt -s nullglob
    for fixture in "$NEGATIVE"/schema-*.json; do
        if ajv validate {{ AJV_FLAGS }} -s schema/version.schema.json -d "$fixture" 2>/dev/null; then
            command echo "ERROR: negative fixture $fixture was ACCEPTED by ajv" >&2
            exit 1
        fi
        command echo "correctly rejected by ajv: ${fixture##*/}"
    done
    # One scratch root for every drift fixture, removed once on exit — a
    # per-iteration trap would be re-registered each pass and only cleared on
    # the success path, so an unexpected error mid-loop leaked the rest.
    staged_root="$(command mktemp -d)"
    trap 'command rm -rf "$staged_root"' EXIT
    for fixture in "$NEGATIVE"/drift-*.json; do
        # Route each fixture to the catalog path it is meant to perturb:
        # drift-index-* replaces a tool index (exercising compare_index's
        # field-by-field branches), everything else replaces a version file
        # (exercising canonical_diff). Staging them all at one path would
        # leave one of the two comparison paths unproven. drift-vendored-only-*
        # is staged as a NEW file named for its own .version — a version neither
        # catalog holds and that is not the live pin — exercising the live-pin
        # gate rather than overwriting an existing entry.
        expect=""
        case "${fixture##*/}" in
            drift-index-*) target="tools/rust/index.json" ;;
            drift-vendored-only-*)
                # Routing is shared with tests/unit/vendored-catalog.sh (CI
                # runs only the test), so refuse rather than pass vacuously
                # with the reason it gives. Pin parsed like live_pin.
                pin="$(command sed -n -E 's/^ARG RUST_VERSION="?([^"[:space:]]+)"?[[:space:]]*$/\1/p' \
                    "{{ justfile_directory() }}/Dockerfile" | command sed -n '1p')"
                rc=0
                target="$(vendored_only_target "$fixture" "$VENDORED" "{{ CONTAINERS_DB }}" "$pin")" || rc=$?
                if [ "$rc" -eq 2 ]; then
                    command echo "ERROR: $fixture .version must be a plain version token (got '$(command jq -r .version "$fixture")')" >&2
                    exit 1
                elif [ "$rc" -ne 0 ]; then
                    command echo "ERROR: $fixture must name a version in neither catalog and not the live pin $pin (got '$(command jq -r .version "$fixture")')" >&2
                    exit 1
                fi
                expect="${target#tools/}: vendored-only and not the live pin"
                ;;
            *) target="tools/rust/versions/1.96.0.json" ;;
        esac
        staged="$staged_root/$(command basename "$fixture" .json)"
        command mkdir -p "$staged"
        command cp -r "$VENDORED"/. "$staged/"
        command cp "$fixture" "$staged/$target"
        # Same --dockerfile as step 2, so a fixture is rejected under the flags
        # the real check runs with — not merely because no pin source was given.
        if output="$(command bash "$DRIFT" --vendored "$staged" --upstream "{{ CONTAINERS_DB }}" \
            --dockerfile "{{ justfile_directory() }}/Dockerfile" --quiet 2>&1)"; then
            command echo "ERROR: negative fixture $fixture did NOT trip the drift check (staged at $target)" >&2
            exit 1
        fi
        # Any drift exits 1; a fixture with an expected reason must trip THAT gate.
        if [ -n "$expect" ] && [[ "$output" != *"$expect"* ]]; then
            command echo "ERROR: negative fixture $fixture was rejected for the wrong reason:" >&2
            command printf '%s\n' "$output" >&2
            exit 1
        fi
        command echo "correctly rejected by drift check: ${fixture##*/} (via $target)"
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
