---
name: gpg-keyboxd-ignores-keyring-flag
description: Under use-keyboxd (GnuPG 2.4.1+) gpg ignores --keyring and writes public-keys.d/ instead of a .kbx; pin an empty common.conf and assert the file exists
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4b169ba1-136d-473b-b15c-e43b539107ff
  modified: 2026-10-26T03:54:54.452Z
---

A test fixture that builds an empty keybox with
`gpg --no-default-keyring --keyring "$dir/pubring.kbx" --list-keys` is **not**
keyboxd-safe. Measured on gpg 2.4.7: when the homedir's `common.conf` contains
`use-keyboxd`, gpg ignores `--keyring` entirely and creates `public-keys.d/`,
so no `.kbx` exists and the next `cp` fails with an unrelated-looking error.
`--no-options` does not help — it skips `gpg.conf`, not `common.conf`. gpg has
no `--no-use-keyboxd`.

**Why:** found on #1433 (PR #1453) building the empty-keyring fixture for the
`update_nodejs_keys` / `count_keyring_keys` tests. GnuPG 2.4.1+ can enable
keyboxd for a fresh homedir, so the old "copy whatever pubring.kbx gpg made"
fixture broke silently depending on distro defaults.

**How to apply:** write an explicit empty `common.conf` into the test homedir
before invoking gpg (that overrides a homedir-level keyboxd default), then
assert the `.kbx` file exists and fail with a message naming system-wide
keyboxd if it doesn't — the one case a per-homedir override can't reach is
`/etc/gnupg/common.conf`. The shared helper is `make_empty_keybox` in
`tests/lib/gpg-keyring-fixtures.sh` (#1456). Related:
[[mock-fidelity-gates-assertions]].
