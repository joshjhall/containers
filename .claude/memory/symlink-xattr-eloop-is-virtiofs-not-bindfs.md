---
name: symlink-xattr-eloop-is-virtiofs-not-bindfs
description: "ELOOP when listing a symlink's xattrs comes from the virtiofs lower (bindfs only relays it); fixed by bindfs --xattr-none, and only llistxattr discriminates"
metadata:
  node_type: memory
  type: project
  originSessionId: f1112367-31a7-43d7-8925-f028d27ce6bc
  modified: 2026-09-17T15:23:41.475Z
---

`/workspace/*` is a **two-layer stack** at one mountpoint (both appear in
`/proc/mounts`): **virtiofs** lower + a **bindfs** overlay.

Listing a **symlink's** xattrs returns **ELOOP (40)** there, which kills
BuildKit's context sender — every `docker build` from the repo root dies before
a build step, blocking all image-building integration tests (#977).

**The ELOOP is the virtiofs lower's; bindfs only relays it.** Proven by A/B:
bindfs over tmpfs answers the same call cleanly. So do not go looking for a
bindfs bug.

**Fix: `--xattr-none` on the bindfs overlay** — bindfs then answers `EOPNOTSUPP`
(95) itself, which BuildKit accepts as "no xattrs". `--xattr-ro` was measured
and **does not work** (still relays ELOOP for symlinks). Safe only because
nothing in these images reads xattrs; the sole xattr present is
`com.apple.provenance`, a macOS host artifact.

**Only the LISTING call discriminates.** Measured on the affected mount:

```text
llistxattr(symlink)           -> ELOOP   (40)   <- the condition
lgetxattr(symlink, "user.x")  -> ENODATA (61)
lgetxattr(regular, "user.x")  -> ENODATA (61)
```

A named fetch answers identically on a healthy file and an affected symlink, so
a probe built on it reports every mount clean. Use `os.listxattr(p,
follow_symlinks=False)`; `getfattr` is **not installed** in these images.

Two consequences worth remembering:

- The overlay is applied at **entrypoint**, so the fix lands only on container
  **restart** and on images built after it. `workspace-fs-health`'s
  `check_symlink_xattr` names the condition for that gap; it repairs nothing.
  Signature in that gap: `failed to xattr /workspace/containers/.codegraph: too
  many levels of symbolic links` from `just test-feature`. **Workaround without
  restarting:** build from an exported tree off the mount —
  `git archive HEAD | tar -x -C "$(mktemp -d)"`, delete the `.codegraph` symlink
  in the export, run `tests/test_feature.sh <feature>` there. `git archive HEAD`
  omits uncommitted edits, so commit first or you are testing the old tree.
- This is **not** the [[stale-symlink-attrs-virtiofs]] / #827 decay class. Those
  key on `nlink=0`/`size=0` and are fixed by relinking. These links are healthy
  (`nlink=1`), and a symlink created seconds ago fails identically — the
  condition belongs to the mount, not the link, so relinking cannot help.

Related: [[case-insensitive-mount-shared-inode]], [[virtiofs-ebadf-not-bindfs]].
