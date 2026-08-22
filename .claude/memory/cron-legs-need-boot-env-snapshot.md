---
name: cron-legs-need-boot-env-snapshot
description: A cron leg of a startup script inherits no container env — hand it a boot-written snapshot, and PARSE that file, never source it
metadata:
  type: project
---

When a `/etc/container/startup/*` repair also needs to run periodically (#794
made `42-workspace-fs-health.sh` hourly), the cron leg cannot see the container
environment. Two values usually have to cross that gap:

- `PROJECT_ROOT` — under cron `$PWD` is the user's home, never the workspace.
- The opt-out flag (`SKIP_CASE_FIX`) — a cron leg that ignored it would keep
  repairing for a user who explicitly opted out.

Pattern that works: the **boot run writes an env snapshot**
(`$HOME/.cache/container/<name>.env`), and the snapshot's **ABSENCE is what
disables the cron leg**. So every non-repairing exit path (`SKIP_CASE_CHECK`
gate, non-repo project root) must `rm -f` it rather than leave a stale copy.
Gate snapshot maintenance behind `FS_HEALTH_UPDATE_ENV` so ONLY the boot run
owns it — an on-demand run from an arbitrary cwd must not redirect the hourly
leg at whatever the user happened to `cd` into.

Two traps the adversarial review caught, both worth applying to any future
snapshot of this shape:

1. **Never `source` the snapshot.** Sourcing makes every byte in the file
   executable shell, so a project path containing `'` plus shell syntax runs as
   code on a timer. Write `KEY='value'` with embedded quotes escaped via the
   `'\''` idiom, and read it back with a restricted `grep -E "^KEY='.*'$"`
   parser that unescapes — values come back as strings, never code. Verify such
   a test is non-vacuous: the canary payload must actually execute under a
   `source`-based reader.
1. **Write via temp file + `mv`.** Rename is atomic on the same filesystem, so
   a cron read racing a fast container restart sees the old or new file, never
   a torn one.

Home, not `/run`: `fix_run_permissions` sits inside the
`ENTRYPOINT_STARTUP_ONLY` guard, so `/run` is not reliably user-writable on an
editor's later boots — see [[zed-every-boot-startup-replay]].

Landed in PR #798. Related: [[stale-symlink-attrs-virtiofs]],
[[case-insensitive-mount-shared-inode]].
