#!/bin/bash
# gitleaks pin bump for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on its sed_inplace() (dry-run aware),
#   RC_INVALID_VERSION, RC_PIN_UNREWRITABLE and RC_UPDATE_FAILED, all
#   resolved at call time.

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
#   plain X.Y.Z is accepted (validate_version still allows -rc1/+build tails).
#
# Returns:
#   0 on success; RC_INVALID_VERSION when the version is refused, or
#   RC_PIN_UNREWRITABLE when the pin line's shape is refused (both before any
#   write); RC_UPDATE_FAILED when a write fails.
bump_gitleaks_pin() {
    local script_path="$1" latest="$2"

    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo -e "${RED}    ERROR: refusing non-X.Y.Z gitleaks version '$latest'${NC}" >&2
        return "$RC_INVALID_VERSION"
    }

    # sed exits 0 on no match, so a reformatted pin line would otherwise report
    # a successful bump that wrote nothing. Check the shape the seds expect.
    command grep -qE '^GITLEAKS_VERSION="(\$\{GITLEAKS_VERSION:-[^}]*\}|[0-9][^"]*)"' "$script_path" || {
        echo -e "${RED}    ERROR: no GITLEAKS_VERSION=\"...\" pin found in $script_path — leaving it unchanged${NC}" >&2
        return "$RC_PIN_UNREWRITABLE"
    }

    sed_inplace "s/^GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-[^}]*}\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
    sed_inplace "s/^GITLEAKS_VERSION=\"[0-9][^\"]*\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return "$RC_UPDATE_FAILED"
}
