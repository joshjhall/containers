#!/usr/bin/env bash
# Unit tests: the three advisory gates agree on which RUSTSEC ids are accepted.
#
# `just security-scan` runs cargo deny (deny.toml), osv-scanner
# (.osv-scanner.toml) and cargo audit (.cargo/audit.toml). An advisory accepted
# in one but not another fails the scan on something already triaged. That's
# what broke the scheduled scan in #1576: cargo audit had no ignore list (#1592).
#
# Rules:
#   - deny.toml and .cargo/audit.toml ignore exactly the same RUSTSEC ids.
#   - Every deny.toml RUSTSEC id is also ignored in .osv-scanner.toml (osv also
#     carries GHSA-only entries with no RUSTSEC id, so it's a superset).
#   - Every .cargo/audit.toml entry carries a reason comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "advisory ignore-list sync tests (#1592)"

DENY="$PROJECT_ROOT/deny.toml"
AUDIT="$PROJECT_ROOT/.cargo/audit.toml"
OSV="$PROJECT_ROOT/.osv-scanner.toml"

# _deny_ids <file> — RUSTSEC ids from `{ id = "RUSTSEC-..." }` entries only, so
# ids mentioned in comments don't count.
_deny_ids() {
    command sed -nE 's/^[[:space:]]*\{[[:space:]]*id[[:space:]]*=[[:space:]]*"(RUSTSEC-[0-9]{4}-[0-9]{4})".*/\1/p' "$1" |
        command sort -u
}

# _audit_ids <file> — quoted RUSTSEC ids that open a line inside `ignore = [`.
_audit_ids() {
    command awk '
        /^[[:space:]]*ignore[[:space:]]*=[[:space:]]*\[/ { inside = 1; next }
        inside && /^[[:space:]]*\]/ { inside = 0 }
        inside { print }
    ' "$1" |
        command sed -nE 's/^[[:space:]]*"(RUSTSEC-[0-9]{4}-[0-9]{4})".*/\1/p' |
        command sort -u
}

# _osv_ids <file> — RUSTSEC ids from `id = "RUSTSEC-..."` lines.
_osv_ids() {
    command sed -nE 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"(RUSTSEC-[0-9]{4}-[0-9]{4})".*/\1/p' "$1" |
        command sort -u
}

# _block_literal_count <file> — every RUSTSEC id literal inside the file's
# `ignore = [ ... ]` block, comments stripped. The parsers above each accept
# one entry shape; this counts ids in ANY shape (bare string, several per line,
# a single-line array), so an entry a parser skips makes the counts differ.
_block_literal_count() {
    command awk '
        /^[[:space:]]*ignore[[:space:]]*=[[:space:]]*\[/ { inside = 1 }
        inside {
            line = $0; sub(/#.*/, "", line); print line
            # Close on the code part only: a `]` inside a comment is not the end.
            if (line ~ /\][[:space:]]*$/) inside = 0
        }
    ' "$1" |
        command grep -oE 'RUSTSEC-[0-9]{4}-[0-9]{4}' |
        command sort -u |
        command wc -l |
        command tr -d '[:space:]'
}

# _count <list> — number of non-empty lines in a newline list.
_count() {
    printf '%s\n' "$1" | command sed '/^$/d' | command wc -l | command tr -d '[:space:]'
}

# _missing <want> <have> — ids in the newline list <want> absent from <have>.
_missing() {
    command comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | command sed '/^$/d'
}

DENY_IDS="$(_deny_ids "$DENY")"
AUDIT_IDS="$(_audit_ids "$AUDIT")"
OSV_IDS="$(_osv_ids "$OSV")"

# An empty parse makes every parity check below pass vacuously.
test_each_file_yields_ids() {
    assert_not_empty "$DENY_IDS" "deny.toml must parse to at least one RUSTSEC ignore"
    assert_not_empty "$AUDIT_IDS" ".cargo/audit.toml must parse to at least one RUSTSEC ignore"
    assert_not_empty "$OSV_IDS" ".osv-scanner.toml must parse to at least one RUSTSEC ignore"
}

# Pins one known id per parser, so a regex that matched the wrong thing
# (e.g. comment mentions) still has to find the real entry.
test_parsers_find_known_entry() {
    assert_contains "$DENY_IDS" "RUSTSEC-2023-0071" "deny.toml parser must find the rsa entry"
    assert_contains "$AUDIT_IDS" "RUSTSEC-2023-0071" "audit.toml parser must find the rsa entry"
    assert_contains "$OSV_IDS" "RUSTSEC-2023-0071" "osv parser must find the rsa entry"
}

# A parser that silently skips an entry written in another shape would let
# drift pass; the shape-agnostic literal count catches the shortfall.
test_parsers_see_every_entry() {
    assert_equals "$(_block_literal_count "$DENY")" "$(_count "$DENY_IDS")" \
        "deny.toml: every RUSTSEC id in the ignore block must be parsed (one '{ id = ... }' per line)"
    assert_equals "$(_block_literal_count "$AUDIT")" "$(_count "$AUDIT_IDS")" \
        ".cargo/audit.toml: every RUSTSEC id in the ignore block must be parsed (one quoted id per line)"
}

test_deny_ids_in_audit() {
    assert_equals "" "$(_missing "$DENY_IDS" "$AUDIT_IDS")" \
        "every deny.toml RUSTSEC ignore must also be in .cargo/audit.toml"
}

test_audit_ids_in_deny() {
    assert_equals "" "$(_missing "$AUDIT_IDS" "$DENY_IDS")" \
        "every .cargo/audit.toml ignore must also be in deny.toml (with its full reason)"
}

test_deny_ids_in_osv() {
    assert_equals "" "$(_missing "$DENY_IDS" "$OSV_IDS")" \
        "every deny.toml RUSTSEC ignore must also be in .osv-scanner.toml"
}

# _bare_entries <file> — audit.toml entry lines with no (or an empty) reason.
_bare_entries() {
    command grep -E '^[[:space:]]*"RUSTSEC-[0-9]{4}-[0-9]{4}",?[[:space:]]*(#[[:space:]]*)?$' "$1" || true
}

test_audit_entries_have_reasons() {
    assert_equals "" "$(_bare_entries "$AUDIT")" ".cargo/audit.toml entries need a '# reason' comment"
}

# The guard must actually discriminate: dropping an id from a scratch copy of
# audit.toml has to surface exactly that id as missing.
test_mutation_dropped_id_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation" dropped missing
    dropped="$(printf '%s\n' "$AUDIT_IDS" | command head -n 1)"
    assert_not_empty "$dropped" "need an audit.toml id to drop, or this mutation passes vacuously"
    /bin/mkdir -p "$scratch"
    command grep -v "\"$dropped\"" "$AUDIT" >"$scratch/audit.toml"
    missing="$(_missing "$DENY_IDS" "$(_audit_ids "$scratch/audit.toml")")"
    /bin/rm -rf "$scratch"
    assert_equals "$dropped" "$missing" \
        "removing $dropped from audit.toml must be reported as exactly that id missing"
}

# The reverse direction: an id dropped from deny.toml must surface as an
# audit.toml ignore that deny.toml no longer backs.
test_mutation_dropped_deny_id_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation-deny" dropped extra
    dropped="$(printf '%s\n' "$DENY_IDS" | command tail -n 1)"
    assert_not_empty "$dropped" "need a deny.toml id to drop, or this mutation passes vacuously"
    /bin/mkdir -p "$scratch"
    command grep -v "id = \"$dropped\"" "$DENY" >"$scratch/deny.toml"
    extra="$(_missing "$AUDIT_IDS" "$(_deny_ids "$scratch/deny.toml")")"
    /bin/rm -rf "$scratch"
    assert_equals "$dropped" "$extra" \
        "removing $dropped from deny.toml must be reported as exactly that id unbacked"
}

# A shape the parser does not accept (a second id on an existing line) must
# trip the literal-count guard rather than vanish.
test_mutation_unparsed_shape_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation-shape" parsed literal
    /bin/mkdir -p "$scratch"
    command sed -E '0,/^[[:space:]]*"RUSTSEC-/s//  "RUSTSEC-9999-0001", "RUSTSEC-/' "$AUDIT" \
        >"$scratch/audit.toml"
    parsed="$(_count "$(_audit_ids "$scratch/audit.toml")")"
    literal="$(_block_literal_count "$scratch/audit.toml")"
    /bin/rm -rf "$scratch"
    assert_equals "$((parsed + 1))" "$literal" \
        "a second id on one line must make the literal count exceed the parsed count by exactly one"
}

# A `]` inside a comment within the block must not end the literal count early.
test_mutation_bracket_in_comment_ignored() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation-bracket" literal
    /bin/mkdir -p "$scratch"
    command sed -E '0,/^[[:space:]]*"RUSTSEC-/s/^([[:space:]]*"RUSTSEC-[^"]*",).*/\1 # see [notes]/' "$AUDIT" \
        >"$scratch/audit.toml"
    literal="$(_block_literal_count "$scratch/audit.toml")"
    /bin/rm -rf "$scratch"
    assert_equals "$(_count "$AUDIT_IDS")" "$literal" \
        "a ']' in an entry comment must not cut the ignore block short"
}

# The osv rule must be able to fail: an id dropped from .osv-scanner.toml is
# reported as exactly that id missing.
test_mutation_dropped_osv_id_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation-osv" dropped missing
    dropped="$(printf '%s\n' "$DENY_IDS" | command head -n 1)"
    assert_not_empty "$dropped" "need a deny.toml id to drop, or this mutation passes vacuously"
    /bin/mkdir -p "$scratch"
    command grep -v "^id = \"$dropped\"" "$OSV" >"$scratch/osv.toml"
    missing="$(_missing "$DENY_IDS" "$(_osv_ids "$scratch/osv.toml")")"
    /bin/rm -rf "$scratch"
    assert_equals "$dropped" "$missing" \
        "removing $dropped from .osv-scanner.toml must be reported as exactly that id missing"
}

# The reason rule must be able to fail: stripping one entry's comment makes
# _bare_entries return exactly that one line.
test_mutation_missing_reason_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation-reason" bare
    /bin/mkdir -p "$scratch"
    command sed -E '0,/^[[:space:]]*"RUSTSEC-.*#/s/,[[:space:]]*#.*$/,/' "$AUDIT" >"$scratch/audit.toml"
    bare="$(_bare_entries "$scratch/audit.toml")"
    /bin/rm -rf "$scratch"
    assert_equals "1" "$(_count "$bare")" \
        "an entry with its reason stripped must be reported (exactly one bare line)"
}

run_test test_each_file_yields_ids "each config parses to a non-empty RUSTSEC list"
run_test test_parsers_find_known_entry "each parser finds a known entry"
run_test test_parsers_see_every_entry "parsers see every RUSTSEC id in each ignore block"
run_test test_deny_ids_in_audit "deny.toml ignores are mirrored in .cargo/audit.toml"
run_test test_audit_ids_in_deny ".cargo/audit.toml ignores are backed by deny.toml"
run_test test_deny_ids_in_osv "deny.toml ignores are mirrored in .osv-scanner.toml"
run_test test_audit_entries_have_reasons ".cargo/audit.toml entries carry reason comments"
run_test test_mutation_dropped_id_detected "a dropped audit.toml id is detected"
run_test test_mutation_dropped_deny_id_detected "a dropped deny.toml id is detected"
run_test test_mutation_unparsed_shape_detected "an id in an unparsed shape trips the count guard"
run_test test_mutation_bracket_in_comment_ignored "a ']' in a comment does not end the block"
run_test test_mutation_dropped_osv_id_detected "a dropped .osv-scanner.toml id is detected"
run_test test_mutation_missing_reason_detected "an audit.toml entry without a reason is detected"

generate_report
