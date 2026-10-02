---
name: container-uid-fixed-not-remapped
description: "Container user stays image-native 1000:1000 via \"updateRemoteUserUID\": false; runtime remap rejected (no root in container, rootless hosts)"
metadata:
  node_type: memory
  type: project
  originSessionId: 3fbdf564-1266-4fbe-9dde-3ca7d4e3bef2
  modified: 2026-10-02T03:46:53.952Z
---

The container user's UID/GID is **fixed at the image-native 1000:1000** in every
editor. Generated `devcontainer.json` (template `devcontainer.json.j2`) and the
repo's `.devcontainer/` set `"updateRemoteUserUID": false`, so Zed no longer
remaps the user to the host UID (501 on macOS). Decided in #995 / PR #997
(2026-10-01).

**Why:** the user requires **no root inside the container** and support for
**rootless Docker/Podman on the host**. Every way of matching the host UID at
runtime breaks one of those:

- `usermod` in the entrypoint needs the container to start as root (the image
  ends `USER ${USERNAME}`, and usermod refuses a user with live processes).
- compose `user: "0:0"` was ruled out explicitly (breaks rootless).
- A setuid remap helper adds attack surface.
- Arbitrary-UID (OpenShift-style group perms + nss_wrapper) means reworking ~45
  build-time chowns. Possible later, but not for this.

**How to apply:**

- Never "fix" a UID mismatch by hardcoding a host UID in compose (`user:`,
  `CONTAINER_UID`, a `USER_UID` build arg). Turn the remap off instead. Downstream
  projects (e.g. meridian) had done exactly that.
- Bind mounts: Docker Desktop on macOS presents files as the accessing UID, so
  this just works. Rootless Podman uses `userns_mode: "keep-id:uid=1000,gid=1000"`.
  The one unsolved case is rootful Docker on a Linux host with a UID other than
  1000. Docs: `docs/troubleshooting/zed-devcontainer.md#uidgid-remapping`.
- Runtime code must still resolve the user by shape, never by number. A project
  can turn the remap back on. See [[entrypoint-uid-agnostic-user-detection]] and
  [[build-time-chown-breaks-uid-remap]].
