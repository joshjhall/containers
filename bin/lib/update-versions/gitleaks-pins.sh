#!/bin/bash
# gitleaks pin sync for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on its sed_inplace() (dry-run aware) and
#   PROJECT_ROOT, both resolved at call time.

# sync_gitleaks_pins - Rewrite every gitleaks version pin together.
#
# Arguments:
#   $1 - path to lib/features/dev-tools.sh
#   $2 - new gitleaks version (X.Y.Z)
#
# Description:
#   dev-tools.sh's GITLEAKS_VERSION default is the source of truth. ci.yml's
#   gitleaks-action step pins the same scanner through its GITLEAKS_VERSION
#   env, and tests/unit/gitleaks-version-sync.sh requires the two to match
#   (#1050), so a bump must move both or the auto-patch branch goes red.
#   Writes go through sed_inplace, so a dry run touches nothing.
#
# Returns:
#   0 on success; RC_INVALID_VERSION when a preflight check refuses the bump
#   before any write (the tree stays consistent, so update-versions.sh holds
#   the tool instead of failing the whole run); RC_UPDATE_FAILED when a write
#   itself fails, which may leave the pins half-updated.
sync_gitleaks_pins() {
    local script_path="$1" latest="$2"
    local ci="$PROJECT_ROOT/.github/workflows/ci.yml"

    # $latest lands in a sed replacement and a quoted YAML value in ci.yml, so
    # accept a plain X.Y.Z only (validate_version allows arbitrary suffixes).
    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo -e "${RED}    ERROR: refusing non-X.Y.Z gitleaks version '$latest'${NC}" >&2
        return "$RC_INVALID_VERSION"
    }

    # Check both pin lines exist in the shape the seds below expect BEFORE any
    # write, so a missing or reformatted file fails the bump instead of leaving
    # one pin bumped alone (sed exits 0 on no match).
    command grep -qE '^GITLEAKS_VERSION="(\$\{GITLEAKS_VERSION:-[^}]*\}|[0-9][^"]*)"' "$script_path" || {
        echo -e "${RED}    ERROR: no GITLEAKS_VERSION=\"...\" pin found in $script_path — leaving both pins unchanged${NC}" >&2
        return "$RC_INVALID_VERSION"
    }
    command grep -qE '^[[:space:]]*GITLEAKS_VERSION: *"[0-9][^"]*"' "$ci" || {
        echo -e "${RED}    ERROR: no quoted GITLEAKS_VERSION: \"X.Y.Z\" pin found in $ci — leaving both pins unchanged${NC}" >&2
        return "$RC_INVALID_VERSION"
    }

    sed_inplace "s/^GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-[^}]*}\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
    sed_inplace "s/^GITLEAKS_VERSION=\"[0-9][^\"]*\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
    sed_inplace "s/^\([[:space:]]*GITLEAKS_VERSION: *\"\)[0-9][^\"]*\"/\1$latest\"/" "$ci" || return "$RC_UPDATE_FAILED"
}
