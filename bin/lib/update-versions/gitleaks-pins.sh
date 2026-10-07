#!/bin/bash
# gitleaks pin bump for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on its sed_inplace() (dry-run aware),
#   RC_INVALID_VERSION and RC_UPDATE_FAILED, all resolved at call time.

# bump_gitleaks_pin - Rewrite the gitleaks version pin in dev-tools.sh.
#
# Arguments:
#   $1 - path to lib/features/dev-tools.sh
#   $2 - new gitleaks version (X.Y.Z)
#
# Description:
#   dev-tools.sh's GITLEAKS_VERSION default is the only gitleaks pin: CI's
#   checksum-verified scanner reads it at run time (#1064), so ci.yml needs
#   no matching edit. That run-time read builds the download URL, so only a
#   plain X.Y.Z is accepted (validate_version allows arbitrary suffixes).
#
# Returns:
#   0 on success; RC_INVALID_VERSION when the version is refused before any
#   write; RC_UPDATE_FAILED when a write fails.
bump_gitleaks_pin() {
    local script_path="$1" latest="$2"

    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo -e "${RED}    ERROR: refusing non-X.Y.Z gitleaks version '$latest'${NC}" >&2
        return "$RC_INVALID_VERSION"
    }

    sed_inplace "s/^GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-[^}]*}\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
    sed_inplace "s/^GITLEAKS_VERSION=\"[0-9][^\"]*\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
}
