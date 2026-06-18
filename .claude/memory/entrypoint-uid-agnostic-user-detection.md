---
name: entrypoint-uid-agnostic-user-detection
description: Why the runtime entrypoint must resolve the container user by shape, not by a fixed UID — Zed vs VS Code remap differently
metadata:
  type: project
---

`lib/runtime/entrypoint.sh` must NOT detect the non-root user by a hardcoded UID
(it used to do `getent passwd 1000`). The devcontainer CLI's `updateRemoteUserUID`
(default true) remaps the `vscode` user's UID differently per editor:

- **Zed** adopts the *host* UID (e.g. 501 on macOS) — lands in Debian's
  system-UID range (<1000)
- **VS Code on macOS** typically keeps the image-native UID (1000)

So a fixed-UID lookup AND a `UID >= 1000` range filter both fail under Zed.
The entrypoint now resolves by user *shape*: the single regular login user with
a `/home/...` home dir and a real shell (not nologin/false), honoring
`CONTAINER_UID` first if set. Relies on the devcontainer "exactly one regular
user" rule — so do NOT add a second non-system user to the base image.

**Why this matters:** when the lookup failed, the failure was a *silent exit 2*,
not a readable error. The `getent` miss happened inside a command substitution
under `set -euo pipefail`, so `set -e` aborted the script before the
`if [ -z "$USERNAME" ]` guard could print anything. Always use `|| true` on
`getent` substitutions in that file. Base image is correct as-is
(`mcr.microsoft.com/devcontainers/base:trixie`); do not switch to an Ubuntu base
(24.04 ships a second regular user and breaks UID remap).

Tests: `tests/unit/runtime/entrypoint.sh` — `test_user_detection_uid_agnostic`
and `test_user_detection_set_e_safe` guard both regressions.
Related: [[feedback_local_lint_scope]]
