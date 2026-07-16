---
name: zed-every-boot-startup-replay
description: Under Zed the image ENTRYPOINT is replaced, so every-boot startup scripts must be replayed by recover-entrypoint on every start — not just first
metadata:
  type: project
---

Zed's native devcontainer impl replaces the image `ENTRYPOINT` with a
`sleep infinity` stub even with `"overrideCommand": false` (upstream
[zed-industries/zed#56357](https://github.com/zed-industries/zed/issues/56357)).
So NONE of the entrypoint's setup runs as PID 1: one-time privileged work
(cache chown, bindfs, cron, OP secret resolution) AND the every-boot phase
(`/etc/container/startup/*`: secret refresh, claude-auth-watcher, project health
check, codegraph index sync).

`recover-entrypoint` (wired as the first link of `postStartCommand`) replays it,
but the key rule: **it must re-run the every-boot phase on EVERY start, not just
the first.** It branches on the `~/.container-initialized` marker:

- Marker missing (first start): full replay — one-time setup + all startup
  scripts, writes marker.
- Marker present (every later start): `ENTRYPOINT_STARTUP_ONLY=true` replay —
  entrypoint runs ONLY `/etc/container/startup/*` and skips the expensive
  one-time privileged block. This restores VS Code parity, where the PID-1
  entrypoint re-runs those scripts every boot.

The old code did `[ -f "$MARKER" ] && exit 0`, so later Zed starts silently ran
no every-boot scripts at all — the bug that left a stale/absent codegraph index.

`ENTRYPOINT_STARTUP_ONLY` is a plain `if [ ... != "true" ]; then` guard in
`entrypoint.sh` wrapping the Sequential-Init + Cron + First-Time blocks, closing
right before the Every-Boot block.

Gotchas for anything that must be fresh each boot under Zed:

- Make it an every-boot `/etc/container/startup/NN-*.sh` script, NOT
  `first-startup/` — first-startup only runs inside the full (first) replay.
- Background jobs must `setsid`-detach (redirect all fds). A bare `&` child is
  reaped when the transient `recover-entrypoint` replay process exits under Zed.
  This is why codegraph moved to `startup/55-codegraph-index.sh` (init-when-empty
  / `sync`-when-present, setsid-detached).
- Runtime env: bake needed vars as `ENV` in the Dockerfile. `WORKING_DIR` was
  build-ARG-only and unset at runtime until `ENV WORKING_DIR` was added.
- Startup scripts re-run every boot, so each must be idempotent (skip gates /
  marker files) — most already are.

Landed in PR #732 (`fix(runtime)`). Tests: `tests/unit/runtime/entrypoint.sh`
(`test_startup_only_*`), `tests/unit/runtime/recover-entrypoint.sh`,
`tests/unit/features/dev-tools.sh` (codegraph every-boot/setsid wiring).
Related: [[entrypoint-uid-agnostic-user-detection]], [[tmpfs-uid-cannot-be-templated]]
