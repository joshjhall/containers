#!/usr/bin/env bash
# Shared gpg fixtures for the keyring suites (#1456):
# tests/unit/bin/update-gpg-keys.sh, tests/unit/bin/lib/keyring-swap*.sh and
# tests/unit/gpg-keyrings-readable.sh.
# Sourced only — it lives outside tests/unit/ so the unit runner does not
# execute it as a suite. Callers source tests/framework.sh first: require_gpg
# reports through assert_true / skip_test.

# Returns 0 when gpg is usable; otherwise skips locally and fails in CI, so a
# missing gpg can never make these tests pass by skipping.
require_gpg() {
    if command -v gpg >/dev/null 2>&1; then
        return 0
    fi
    if [ "${CI:-false}" = "true" ]; then
        assert_true false "gpg is required in CI — keyring tests cannot silently skip"
    else
        skip_test "gpg not available — skipping locally"
    fi
    return 1
}

# make_empty_keybox <home> <kbx> — create a keybox holding no keys without
# relying on gpg's homedir defaults: an explicit empty common.conf keeps
# use-keyboxd off (GnuPG 2.4.1+ would otherwise write public-keys.d/ and no
# .kbx), and the keyring path is named rather than inferred (#1433)
make_empty_keybox() {
    command mkdir -p "$1"
    command chmod 700 "$1"
    : >"$1/common.conf"
    GNUPGHOME="$1" gpg --batch --no-default-keyring --keyring "$2" --list-keys >/dev/null 2>&1
    [ -f "$2" ]
}
