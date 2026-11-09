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

test_audit_entries_have_reasons() {
    local bare
    bare="$(command grep -E '^[[:space:]]*"RUSTSEC-[0-9]{4}-[0-9]{4}",?[[:space:]]*(#[[:space:]]*)?$' "$AUDIT" || true)"
    assert_equals "" "$bare" ".cargo/audit.toml entries need a '# reason' comment"
}

# The guard must actually discriminate: dropping an id from a scratch copy of
# audit.toml has to surface exactly that id as missing.
test_mutation_dropped_id_detected() {
    local scratch="$TEST_SCRATCH_BASE/advisory-sync-mutation" dropped missing
    dropped="$(printf '%s\n' "$AUDIT_IDS" | command head -n 1)"
    /bin/mkdir -p "$scratch"
    command grep -v "\"$dropped\"" "$AUDIT" >"$scratch/audit.toml"
    missing="$(_missing "$DENY_IDS" "$(_audit_ids "$scratch/audit.toml")")"
    /bin/rm -rf "$scratch"
    assert_equals "$dropped" "$missing" \
        "removing $dropped from audit.toml must be reported as exactly that id missing"
}

run_test test_each_file_yields_ids "each config parses to a non-empty RUSTSEC list"
run_test test_parsers_find_known_entry "each parser finds a known entry"
run_test test_deny_ids_in_audit "deny.toml ignores are mirrored in .cargo/audit.toml"
run_test test_audit_ids_in_deny ".cargo/audit.toml ignores are backed by deny.toml"
run_test test_deny_ids_in_osv "deny.toml ignores are mirrored in .osv-scanner.toml"
run_test test_audit_entries_have_reasons ".cargo/audit.toml entries carry reason comments"
run_test test_mutation_dropped_id_detected "a dropped audit.toml id is detected"

generate_report
