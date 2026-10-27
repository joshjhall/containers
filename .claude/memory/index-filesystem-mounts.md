# Filesystem, virtiofs, FUSE & case-sensitivity

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open on wedged files, EBADF/ELOOP, stale symlinks, case-shadowed paths, or env leaking across process boundaries.

- [Case-insensitive mount shares inodes](case-insensitive-mount-shared-inode.md) — case-shadowed entries share an inode
- [Peel FUSE layers with unshare](peel-fuse-layers-with-unshare.md) — `sudo unshare -m` + `umount -l` to test raw virtiofs safely
- [Stale symlink attrs on virtiofs](stale-symlink-attrs-virtiofs.md) — nlink=0 symlinks read as permanently modified
- [Symlink xattr ELOOP is virtiofs, not bindfs](symlink-xattr-eloop-is-virtiofs-not-bindfs.md) — fixed by bindfs --xattr-none
- [virtiofs EBADF is not bindfs](virtiofs-ebadf-not-bindfs.md) — wedged worktree entries fail on the lower virtiofs too
- [git-env neutralization boundary](git-env-neutralization-boundary.md) — fs-health clears 8 git vars by measurement not name family
- [Env scrub is not a boundary (same uid)](env-scrub-not-a-boundary-same-uid.md) — child reads parent's /proc/PPID/environ
- [Worktree test Windows path separators](worktree-test-windows-path-separators.md) — worktree .git-pointer assertions must derive git dir via
