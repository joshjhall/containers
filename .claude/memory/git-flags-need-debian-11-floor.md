---
name: git-flags-need-debian-11-floor
description: "git flags newer than 2.30 break Debian 11 builds; in a `|| return 0` fail-safe the breakage is silent, not loud"
metadata:
  node_type: memory
  type: project
  originSessionId: 29f465fb-1fd6-4bb8-8f82-79b340c4bd6e
  modified: 2026-09-02T17:02:44.101Z
---

Debian 11 (Bullseye) is a supported base image and ships **git 2.30.2**, so any
`git` flag added after that is off-limits without a fallback. Hit in #884:
`rev-parse --path-format=absolute` (git 2.31+) was used to compare
`--git-dir` against `--git-common-dir`.

**Why it matters more than an ordinary compat bug:** the call sat behind a
`|| return 0` fail-safe. On Bullseye the flag is unrecognized, `rev-parse`
errors, the fallback fires, and the entire feature no-ops — **silently**, on one
of three supported distros, with no diagnostic to notice. The very design that
keeps a startup script from breaking `docker build` is what converts a
version-compat error into invisible dead code. Local tests all passed; the
container this ran in has git 2.55.

**How to apply:** before using any `git` flag in `lib/runtime/` or
`lib/features/`, check its introduced version against the 2.30 floor. Prefer
POSIX shell equivalents that predate the flag — `cd "$dir" && pwd -P` replaced
`--path-format=absolute` here and *also* normalized symlinked path components,
which the flag would not have. More generally: **a `|| return 0` guard around a
version-sensitive call needs a test that the guarded path is reachable at all**,
or the guard hides the very failure it was meant to survive.

Related: [[skips-render-as-passes]] (same shape — a safety mechanism turning a
failure into silence), [[stale-symlink-attrs-virtiofs]] (the #884 subject).
