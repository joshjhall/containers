#!/usr/bin/env bash
# Lint .env files for drift against their .env.example siblings.
#
# Pairs checked (from the repo root):
#   .env         <-> .env.example
#   .env.secrets <-> .env.secrets.example
#
# Detects:
#   - Keys in .env that are undocumented in .env.example (warning; --strict errors)
#   - Duplicate keys within any file
#   - Real-looking secret prefixes uncommented in .example files
#
# Source files (.env, .env.secrets) are gitignored and may not exist on CI or
# on fresh clones; in that case only the example file is checked for
# duplicates and secret leaks.

set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "${BIN_DIR}/lib/common.sh"

# CHECK_ENV_DRIFT_ROOT overrides the scan root. Used by the unit tests to
# point at a fixture directory; unset in normal use.
PROJECT_ROOT="${CHECK_ENV_DRIFT_ROOT:-$(dirname "$BIN_DIR")}"

STRICT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)
            STRICT=1
            shift
            ;;
        --help | -h)
            /usr/bin/cat <<'EOF'
Usage: bin/check-env-drift.sh [--strict] [--help]

Lint .env files for drift against their .env.example siblings.

Pairs checked (from the repo root):
  .env         <-> .env.example
  .env.secrets <-> .env.secrets.example

Options:
  --strict    Treat missing-in-example keys as an error (non-zero exit)
  --help      Show this help
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Known real-secret prefixes. Matching any of these on an uncommented KEY=VALUE
# line in a *.example file triggers a hard failure. Intentionally narrow to
# avoid false positives on placeholder strings like "op://Vault/...".
readonly SECRET_PATTERN='(ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|ops_eyJ|sk-ant-|sk-proj-|sk_live_|AKIA[0-9A-Z]{16}|xox[pbao]-|-----BEGIN )'

# Extract KEY names from an env file. Matches both active (`KEY=...`) and
# commented (`# KEY=...`) lines, since .env.example documents keys by
# commenting them out. Prints one key per line, preserving source order.
extract_keys() {
    local file="$1"
    /usr/bin/awk '
        /^[[:space:]]*#?[[:space:]]*[A-Z][A-Z0-9_]*=/ {
            line = $0
            sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
            sub(/=.*$/, "", line)
            print line
        }
    ' "$file"
}

find_duplicates() {
    local file="$1"
    extract_keys "$file" | /usr/bin/sort | /usr/bin/uniq -d
}

# Print uncommented KEY=VALUE lines (with line numbers) whose value matches
# a known secret prefix. Silent if none found.
find_leaks() {
    local file="$1"
    /usr/bin/grep -nE "^[[:space:]]*[A-Z][A-Z0-9_]*=.*${SECRET_PATTERN}" "$file" 2>/dev/null || true
}

errors=0
warnings=0

check_file() {
    local file="$1"
    local kind="$2" # "source" or "example"
    local dup
    dup=$(find_duplicates "$file")
    if [ -n "$dup" ]; then
        log_error "Duplicate keys in $file:"
        /usr/bin/printf '%s\n' "$dup" | /usr/bin/sed 's/^/  /' >&2
        errors=$((errors + 1))
    fi

    if [ "$kind" = "example" ]; then
        local leaks
        leaks=$(find_leaks "$file")
        if [ -n "$leaks" ]; then
            log_error "Possible real secrets (uncommented) in $file:"
            /usr/bin/printf '%s\n' "$leaks" | /usr/bin/sed 's/^/  /' >&2
            errors=$((errors + 1))
        fi
    fi
}

check_pair() {
    local source_file="$1"
    local example_file="$2"

    log_info "Checking pair: $source_file <-> $example_file"

    if [ ! -f "$example_file" ]; then
        log_error "Missing example file: $example_file"
        errors=$((errors + 1))
        return
    fi

    check_file "$example_file" "example"

    if [ ! -f "$source_file" ]; then
        log_info "  $source_file not present — skipping drift check (expected on CI/fresh clone)"
        return
    fi

    check_file "$source_file" "source"

    local missing
    missing=$(/usr/bin/comm -23 \
        <(extract_keys "$source_file" | /usr/bin/sort -u) \
        <(extract_keys "$example_file" | /usr/bin/sort -u))

    if [ -n "$missing" ]; then
        if [ "$STRICT" -eq 1 ]; then
            log_error "Keys in $source_file missing from $example_file:"
            /usr/bin/printf '%s\n' "$missing" | /usr/bin/sed 's/^/  /' >&2
            errors=$((errors + 1))
        else
            log_warning "Keys in $source_file missing from $example_file (run with --strict to fail):"
            /usr/bin/printf '%s\n' "$missing" | /usr/bin/sed 's/^/  /' >&2
            warnings=$((warnings + 1))
        fi
    fi
}

cd "$PROJECT_ROOT" || exit 1

check_pair ".env" ".env.example"
check_pair ".env.secrets" ".env.secrets.example"

if [ "$errors" -gt 0 ]; then
    log_error "Env drift check failed: $errors error(s), $warnings warning(s)"
    exit 1
fi

if [ "$warnings" -gt 0 ]; then
    log_warning "Env drift check completed with $warnings warning(s)"
    exit 0
fi

log_success "Env drift check passed: .env files are in sync with examples"
