---
name: peel-fuse-layers-with-unshare
description: to test raw virtiofs (or N bindfs layers) without touching the live container, `sudo unshare -m` + `umount -l` in a private namespace; use a /tmp clone as the control
metadata:
  type: reference
---

To attribute a filesystem bug to a layer of the workspace mount stack
(virtiofs → bindfs → bindfs), peel layers in a PRIVATE mount namespace. The live
container's mounts are untouched:

```bash
sudo -n unshare -m bash -c '
  cd /; mount --make-rprivate /
  umount -l /workspace/containers          # peel one layer (repeat for more)
  findmnt -n -T /workspace/containers -o FSTYPE
  su vscode -s /bin/bash -c "<experiment>"'
```

Start the inner shell with `cd /`, or getcwd errors leak out as layers vanish.
Use a clone under `/tmp` (overlayfs) as the control for any git/hook experiment:
in #1114 that control is what showed lefthook was innocent (0/5 in /tmp vs 5/5
on the mount, for both configs).

Note: on Docker Desktop macOS, raw virtiofs reports existing repo files as `0:0`
while new files are `1000:1000`, and writes still work (faked ownership).
Related: [[stale-git-index-lock]], [[symlink-xattr-eloop-is-virtiofs-not-bindfs]],
[[virtiofs-ebadf-not-bindfs]].
