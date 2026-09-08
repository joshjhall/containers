---
name: build-time-chown-breaks-uid-remap
description: A build-time chown/mode on a runtime-accessed file breaks under editor UID remap; make the file UID-agnostic instead of reconciling it at boot
metadata:
  type: project
---

Any file created at **build** time but opened at **runtime** by the container
user must be UID-agnostic. Editors remap the container user's UID *after* the
image is built (Zed adopts the host UID; VS Code keeps the image-native one), so
a build-time `chown "$TARGET_USER"` bakes a number that is wrong for one of them.

Caught in #943 on `/etc/container/lock/claude-setup.lock`: installed `0644`
owned by the build-time user, it is **unopenable** by a remapped runtime user,
so `exec 200>` fails and `claude-setup` silently degrades to unlocked —
re-opening the `~/.claude/settings.json` race #784 closed. A companion
`[ ! -O "$path" ]` guard was worse than useless: it fires on the same remap, and
`-O` has no root bypass so it also breaks a `sudo` invocation.

**Two available fixes; prefer the second.** The established pattern is boot-time
reconciliation — `lib/runtime/lib/fix-run-permissions.sh` and
`fix-cache-permissions.sh` re-chown `/run` and `/cache` on every start for
exactly this reason. But for a single file needing no ownership semantics, make
it UID-agnostic by construction instead: root-owned `0666` inside a **root-owned
0755 directory**. Any UID can open it; nobody unprivileged can create, replace,
or unlink it, so the symlink-plant vector stays closed. That removes a boot-time
pass rather than adding one.

The generalization: put the access control on the **directory**, whose ownership
is a build-time constant, not on the file, whose usable owner is not knowable
until runtime.

**Why:** the failure is silent and environment-specific — it passes every test
and every VS Code container, then degrades only under Zed, in the one code path
whose whole job is preventing a race.

**How to apply:** when a build script `chown`s or `chmod`s something the runtime
user later opens, ask which UID will open it. If the answer is "depends on the
editor", drop the ownership assumption. Never write an ownership *check* against
a build-time-baked owner. Related: [[entrypoint-uid-agnostic-user-detection]],
[[tmpfs-uid-cannot-be-templated]], [[cron-user-column-is-build-time]].
