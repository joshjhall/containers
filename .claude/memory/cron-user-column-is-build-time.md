---
name: cron-user-column-is-build-time
description: /etc/cron.d user column is baked at build; run the job as root and resolve the container user at run time
metadata:
  node_type: memory
  type: project
  originSessionId: d7837678-6b9f-4041-849b-70d0422e6e1a
  modified: 2026-08-22T18:46:57.673Z
---

A `/etc/cron.d` entry's **user column is written at image build time**, but the
runtime container user is not knowable then — editors remap it (Zed adopts the
host UID, VS Code keeps 1000). A baked `${USERNAME}` there fails **silently**:
`lib/base/user.sh` always creates that user by name, so cron does not error — it
runs the job as the *wrong* user, which finds nothing under the wrong `HOME` and
exits 0. Fixed for the fs-health leg in #800; `cargo-sweep` (rust-dev.sh) and
`fuse-cleanup` (bindfs.sh) still bake it.

**How to apply:** put `root` in the user column and have the wrapper resolve the
user itself via `lib/runtime/lib/resolve-container-user.sh` (the shared ladder,
also used by the entrypoint), then `su -l` to it. Details that are load-bearing:

- `su -l`, not plain `su` — the login shell is what sets the right `HOME`.
- The re-exec loop guard must be an **argument** (`--as-user`), not an env var:
  `su -l` wipes the environment.
- Source the root-owned `/etc/container/cron-env` **before** resolving, or the
  ladder's `CONTAINER_UID` arm is unreachable. Never trust a user-writable file
  to decide which account a root process drops into.
- `CONTAINER_UID` is a runtime `docker run -e` value and `cron-env` is generated
  at build, so that arm is unpopulated today — the cron leg resolves by shape.

See [[entrypoint-uid-agnostic-user-detection]],
[[cron-legs-need-boot-env-snapshot]], [[logger-without-syslog-daemon]].
