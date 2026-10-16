#!/usr/bin/env bash
# Staging routing for drift-vendored-only-* negative fixtures (#1288).
#
# A drift-vendored-only fixture is staged as a NEW version file named for its
# own .version, so it exercises check-catalog-drift.sh's live-pin gate rather
# than canonical_diff. That only holds when the version is a plain token and
# names a version neither catalog holds and that is not the live pin.
#
# Sourced by `just db-validate-vendored` (just/db.just) and by
# tests/unit/vendored-catalog.sh, so the routing the test exercises is the one
# the recipe runs — CI runs only the test, never the recipe. Requires jq.
# Sets no shell options: a sourced lib's `set -e` leaks into its caller.

# vendored_only_target <fixture> <vendored> <upstream> <pin>
#
# Print the catalog-relative path the fixture is staged at and return 0, or
# print nothing and return:
#   2 — .version is not a plain version token. It becomes a path component,
#       so a value carrying `/` or `..` would point the existence checks at
#       one path and cp at another (or outside the staging dir). Also covers
#       empty and jq's `null`.
#   1 — a version either catalog holds (would route through canonical_diff,
#       and cp would overwrite a real entry) or the live pin (skipped by the
#       drift check, not rejected).
# Callers word their own error, so each can name its own context.
vendored_only_target() {
    local fixture="$1" vendored="$2" upstream="$3" pin="$4" version target
    version="$(command jq -r .version "$fixture")" || return 2
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9]+(\.[A-Za-z0-9]+)*)?(\+[A-Za-z0-9]+(\.[A-Za-z0-9]+)*)?$ ]] ||
        return 2
    target="tools/rust/versions/$version.json"
    if [ -e "$vendored/$target" ] || [ -e "$upstream/$target" ] ||
        [ "$version" = "$pin" ]; then
        return 1
    fi
    command printf '%s\n' "$target"
}
