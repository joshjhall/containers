#!/usr/bin/env bash
# Matrix update for version compatibility testing
#
# Description:
#   Updates the version compatibility matrix JSON file with test results.
#
# Functions:
#   update_matrix() - Update compatibility matrix with a test result
#
# Dependencies:
#   - timestamp(), log_info(), log_success(), log_failure() must be available
#   - $MATRIX_FILE and $PROJECT_ROOT must be set
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/test-version-compat/matrix-update.sh"

# Header guard to prevent multiple sourcing
if [ -n "${_TEST_VERSION_COMPAT_MATRIX_UPDATE_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _TEST_VERSION_COMPAT_MATRIX_UPDATE_SH_INCLUDED=1

# Update compatibility matrix with test result
update_matrix() {
    local variant="$1"
    local status="$2" # "passing" or "failing"
    local notes="${3:-}"

    if [ ! -f "$MATRIX_FILE" ]; then
        log_info "Matrix file not found, skipping update"
        return
    fi

    log_info "Updating compatibility matrix for $variant (status: $status)"

    # Build version info
    local versions_json="{"
    local first=true

    for lang in python node rust go ruby java r mojo; do
        local version_var="${lang^^}_VERSION"
        local version="${!version_var:-}"
        if [ -n "$version" ]; then
            if [ "$first" = false ]; then
                versions_json+=","
            fi
            versions_json+="\"$lang\": \"$version\""
            first=false
        fi
    done

    versions_json+="}"

    # Create new entry
    local new_entry
    new_entry=$(
        command cat <<EOF
{
  "variant": "$variant",
  "base_image": "${BASE_IMAGE:-debian:13-slim}",
  "versions": $versions_json,
  "status": "$status",
  "tested_at": "$(timestamp)"$([ -n "$notes" ] && echo ",
  \"notes\": \"$notes\"" || echo "")
}
EOF
    )

    log_info "New compatibility entry:"
    echo "$new_entry"

    # Update the matrix JSON file using jq
    if ! command -v jq &>/dev/null; then
        log_info "jq not available, falling back to JSONL append"
        echo "$new_entry" >>"$PROJECT_ROOT/version-compat-results.jsonl"
        return
    fi

    # Update tested_combinations: replace existing entry or add new one
    local updated_matrix
    updated_matrix=$(jq \
        --argjson new_entry "$new_entry" \
        --arg timestamp "$(timestamp)" \
        '
        .last_updated = $timestamp |
        # Check if variant exists in tested_combinations
        if (.tested_combinations | map(.variant) | index($new_entry.variant)) then
            # Update existing entry
            .tested_combinations = [
                .tested_combinations[] |
                if .variant == $new_entry.variant then
                    $new_entry
                else
                    .
                end
            ]
        else
            # Add new entry
            .tested_combinations += [$new_entry]
        end |
        # Update language_versions.*.current with tested versions
        reduce ($new_entry.versions | to_entries[]) as $ver (
            .;
            if .language_versions[$ver.key] then
                .language_versions[$ver.key].current = $ver.value |
                # Add to tested array if not present
                if (.language_versions[$ver.key].tested | index($ver.value) | not) then
                    .language_versions[$ver.key].tested += [$ver.value]
                else
                    .
                end
            else
                .
            end
        )
        ' "$MATRIX_FILE")

    if [ -n "$updated_matrix" ]; then
        echo "$updated_matrix" >"$MATRIX_FILE"
        log_success "Matrix file updated"
    else
        log_failure "Failed to update matrix file"
        # Fallback to JSONL
        echo "$new_entry" >>"$PROJECT_ROOT/version-compat-results.jsonl"
    fi
}
