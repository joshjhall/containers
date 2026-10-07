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
sync_gitleaks_pins() {
    local script_path="$1" latest="$2"
    local ci="$PROJECT_ROOT/.github/workflows/ci.yml"

    # Check before any write, so a missing ci.yml never leaves dev-tools.sh
    # bumped alone.
    [ -f "$ci" ] || return 1

    sed_inplace "s/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-[^}]*}\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return 1
    sed_inplace "s/^GITLEAKS_VERSION=\"[0-9][^\"]*\"/GITLEAKS_VERSION=\"\${GITLEAKS_VERSION:-$latest}\"/" "$script_path" || return 1
    sed_inplace "s/^\([[:space:]]*GITLEAKS_VERSION: *\"\)[0-9][^\"]*\"/\1$latest\"/" "$ci" || return 1

    # sed exits 0 when nothing matched, so a reformatted pin line would pass
    # silently. Confirm the rewrite landed (nothing to confirm on a dry run).
    [ "${DRY_RUN:-false}" = true ] && return 0
    command grep -qE "^[[:space:]]*GITLEAKS_VERSION: *\"$latest\"" "$ci"
}
