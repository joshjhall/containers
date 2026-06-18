---
name: tmpfs-uid-cannot-be-templated
description: "Why docker-compose tmpfs uid=/gid= options can't be made UID-agnostic and must be reconciled at container startup instead"
metadata:
  node_type: memory
  type: project
  originSessionId: 08006394-d459-4ec1-b0ad-40c04c6ab944
---

Docker-compose `tmpfs` mount `uid=`/`gid=` options are **literal numbers baked
at mount time** — compose cannot know the runtime user's UID, so you cannot
template them to be UID-agnostic. This is the same hardcoded-1000 bug class as
[[entrypoint-uid-agnostic-user-detection]], just hiding in YAML.

It matters because editors remap the container user's UID *after* build via the
devcontainer `updateRemoteUserUID` default: **Zed adopts the host UID** (e.g.
501 on macOS), **VS Code keeps the image-native 1000**. A baked `uid=1000` then
breaks under Zed — `/run` becomes unwritable by the runtime user, and the
1Password CLI errors hard on a secrets dir it doesn't own.

**The fix (PR #534, branch `fix/uid-agnostic-tmpfs`):** mount tmpfs **neutrally**
(drop `uid=`/`gid=`, keep `mode`/`size`) so it lands root-owned, then reconcile
ownership at startup against the user the entrypoint resolves by shape:

- Paths **under `/cache`** are handled for free by the existing
  `fix_cache_permissions` (`lib/runtime/lib/fix-cache-permissions.sh`) — e.g.
  `/cache/1password/secrets`. See [[cache-mounts-not-on-install-dirs]].
- Paths **outside `/cache`** (e.g. `/run`) need their own reconcile. Added
  `lib/runtime/lib/fix-run-permissions.sh` (`fix_run_permissions`) mirroring the
  cache helper: resolve uid/gid by name, chown by number, idempotent,
  sudo-aware. Sourced + called right after `fix_cache_permissions` in
  `entrypoint.sh`.

**Pattern to reuse:** any new persistent/tmpfs mount that the runtime user must
write should be mounted neutrally and reconciled at startup, NOT pinned to a UID
in compose.

Tests: `tests/unit/runtime/fix-run-permissions.sh` includes a regression guard
asserting the compose tmpfs lines stay UID-agnostic (no `uid=`).

Stale-comment note found during this work: the old `/run` tmpfs comment claimed
supervisor needs it for its socket/pidfile, but `supervisord.conf` redirects
those to `/tmp`. `/run` was kept + reconciled anyway (other Debian bits expect
`/run` writable); revisit whether the mount is needed at all.
