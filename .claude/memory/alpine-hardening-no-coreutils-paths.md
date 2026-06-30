---
name: alpine-hardening-no-coreutils-paths
description: "Alpine base-image scripts must use bare command names, not /usr/bin/<cmd> GNU coreutils paths"
metadata:
  node_type: memory
  type: feedback
  originSessionId: d391ee17-3d6d-49e5-b73c-9bf2cbda689c
---

In `base-images/alpine/hardening.sh` (and any Alpine build-time script), call
commands by **bare name** (`echo`, `cat`, `cut`, `grep`, `install`,
`addgroup`, `adduser`, `getent`, `usermod`) — NOT `/usr/bin/echo` etc. Alpine
is busybox: most applets live in `/bin`, and `/usr/bin/echo` does not exist, so
a hardcoded path fails the Docker build with `exit code 127` /
`/usr/bin/echo: No such file or directory` (caught only at the
`Build alpine-3.21-amd64` CI step, #433).

**Why:** CLAUDE.md's "always use full paths" rule targets *aliases* in host /
runtime interactive scripts (`lib/runtime/`). It does NOT mean hardcoding GNU
coreutils locations into a hermetic cross-distro image build — there are no
aliases inside `docker build`, and absolute paths are distro-specific. The
debian hardening.sh uses `/usr/bin/*` because Debian coreutils live there;
porting that verbatim to Alpine breaks. Legitimate absolute paths to KEEP in
Alpine: `-x` existence guards (`[ -x /bin/bash ]`), `/etc/shells` file content,
and the `/usr/sbin/nologin → /sbin/nologin` fallback (Alpine's nologin is at
`/sbin/nologin`).

**How to apply:** when writing a new per-distro `base-images/<distro>/hardening.sh`,
use bare command names for everything *executed*. Reserve absolute paths for
existence tests and file contents. Relates to [[ship-review-whole-file-scope]]
and the base-images work in [[evidence-run-arch-aware]].
