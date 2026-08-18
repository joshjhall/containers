---
name: stale-symlink-attrs-virtiofs
description: "virtiofs can cache symlink attrs as nlink=0/size=0, making git report them permanently modified; relink with ln -sfn"
metadata:
  node_type: memory
  type: project
  originSessionId: 1d2ee9f2-91fb-4c3e-86fa-a0de57fbb891
  modified: 2026-08-18T21:11:17.779Z
---

Long-lived symlinks on a virtiofs bind mount can end up with cached attributes
of `nlink=0, size=0` — impossible for a live symlink. Git compares the index's
recorded blob size against `st_size`, so such a link shows as modified forever
even though `git hash-object` on its target matches the index exactly. Content
was never wrong; only the metadata.

**Why:** this is *not* a bindfs bug. Freshly created symlinks pass through
bindfs correctly, and bare virtiofs with no bindfs overlay
(`/workspace/containers-db`) behaves the same. Only specific long-lived inodes
go stale, and dropping caches doesn't clear it (`/proc/sys/vm/drop_caches` is
read-only in the container).

**How to apply:** detect with `stat -c '%h' <link>` — `0` is the signal, and it
is false-positive-free because a *broken* symlink still reports `nlink=1`.
Repair by rewriting in place with the same target:
`ln -sfn "$(readlink "$p")" "$p"`. The `-n` is load-bearing: without it,
relinking a symlink that points at a directory creates the new link *inside*
that directory. Enumerate candidates cheaply with
`git ls-files -s | awk -F'\t' '$1 ~ /^120000 / { print $2 }'`.

Automated at startup by `lib/runtime/42-workspace-fs-health.sh`.
Related: [[case-insensitive-mount-shared-inode]].
