---
name: update-versions-script
description: bin/update-versions.sh applies check-versions drift (not just-wired); default cuts a patch release
metadata:
  node_type: memory
  type: reference
  originSessionId: 367eefaa-5e42-45d6-a492-56bf7619c1d4
  modified: 2026-07-24T16:46:55.226Z
---

`bin/update-versions.sh` auto-applies the drift found by `check-versions.sh --json` —
sed-edits the pins (Dockerfile ARG **and** each `lib/features/*.sh` `${VAR:-X.Y.Z}`
fallback, so it handles two-location pins like android-cmdline-tools correctly).

Use it — don't hand-edit pins. `just update-versions` wraps it with `--no-bump`
(bumps only, no release) and forwards extra args, e.g. `just update-versions --dry-run`
or `--no-commit`. See [[prefer-just-recipes]].

Gotchas:

- The raw script's **default cuts a full patch release** (`echo y | release.sh patch`).
  The `just` recipe pins `--no-bump` to avoid coupling a release into a deps bump.
  Flags: `--no-commit` skips committing, `--no-bump` skips the release, `--dry-run` previews.
- Updater lives in `bin/lib/update-versions/updaters.sh` (per-tool sed rules).
- Kubernetes tools + dev-tools.sh binaries use dynamic checksum fetching, so no
  inline SHA256 pins to update.
