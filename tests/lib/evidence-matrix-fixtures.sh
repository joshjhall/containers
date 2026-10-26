#!/usr/bin/env bash
# Shared fixtures for the evidence-matrix suites (#1381):
# tests/unit/bin/lib/evidence-matrix.sh (one tool),
# tests/unit/bin/lib/evidence-matrix-published.sh (unreadable published
# evidence, #1464) and tests/unit/bin/lib/evidence-matrix-all.sh (every
# tool). Sourced only — it
# lives outside tests/unit/ so the unit runner does not execute it as a suite.
# Callers source tests/framework.sh first: _fixture writes under TEST_TEMP_DIR.

# _version <dir> <version> <tuples-csv> [passing-tuple] [tool]
# One version file claiming each `os-osv-arch` in tuples-csv supported, with an
# optional passing evidence row for passing-tuple. tool defaults to rust.
_version() {
    local dir="$1" v="$2" tuples="$3" pass="${4:-}" tool="${5:-rust}"
    command jq -n --arg v "$v" --arg t "$tuples" --arg p "$pass" --arg tool "$tool" '
        def cell: split("-") as $x | {os: $x[0], os_version: $x[1], arch: $x[2]};
        {schemaVersion: 1, tool: $tool, version: $v,
         support_matrix: [ $t | split(",")[] | cell + {status: "supported"} ],
         tested: (if $p == "" then [] else [ ($p | cell) + {tested_at: "2026-10-01T00:00:00Z", result: "pass"} ] end)}
    ' >"$dir/tools/$tool/versions/$v.json"
}

# _tool <catalog> <tool> <floor> — add another luggage tool to a fixture.
_tool() {
    command mkdir -p "$1/tools/$2/versions"
    command printf '{"id":"%s","minimum_recommended":"%s"}\n' "$2" "$3" >"$1/tools/$2/index.json"
}

# _fixture <floor> — fresh catalog + base-images root; echoes its path.
_fixture() {
    local root
    root="$(command mktemp -d "$TEST_TEMP_DIR/em.XXXXXX")"
    command mkdir -p "$root/catalog/tools/rust/versions"
    command printf '{"id":"rust","minimum_recommended":"%s"}\n' "$1" >"$root/catalog/tools/rust/index.json"
    local t
    for t in debian/13/amd64 debian/13/arm64 alpine/3.24/amd64; do
        command mkdir -p "$root/base-images/$t"
        command touch "$root/base-images/$t/Dockerfile"
    done
    command echo "$root"
}

# _cells <matrix-json> — "version tuple" per cell, sorted.
_cells() {
    command jq -r '.include[] | "\(.version) \(.tuple)"' <<<"$1" | command sort
}

# _db_version <db_root> <version> <pass-csv> [fail-csv] [failed-at] — a published
# containers-db version file with a passing row per pass-csv tuple and a
# failing row per fail-csv tuple. failed-at (ISO 8601) stamps the fail rows'
# tested_at; without it they carry none, which reads as a stale failure.
_db_version() {
    local db="$1" v="$2" pass="$3" fail="${4:-}" at="${5:-}" tool="${6:-rust}"
    command mkdir -p "$db/tools/$tool/versions"
    command jq -n --arg v "$v" --arg p "$pass" --arg f "$fail" --arg at "$at" --arg tool "$tool" '
        def cell: split("-") as $x | {os: $x[0], os_version: $x[1], arch: $x[2]};
        def rows($csv; $r): $csv | select(. != "") | split(",")[] | cell + {result: $r};
        def stamp: if $at == "" then . else . + {tested_at: $at} end;
        {schemaVersion: 1, tool: $tool, version: $v,
         tested: [ rows($p; "pass"), (rows($f; "fail") | stamp) ]}
    ' >"$db/tools/$tool/versions/$v.json"
}

# Fixed clock for the fail-cooldown tests: 2026-10-21T00:00:00Z.
_NOW=1792540800

# _tool_cells <matrix-json> — "tool version tuple" per cell, in matrix order.
_tool_cells() {
    command jq -r '.include[] | "\(.tool) \(.version) \(.tuple)"' <<<"$1"
}
