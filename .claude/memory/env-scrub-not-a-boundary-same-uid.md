---
name: env-scrub-not-a-boundary-same-uid
description: "env_remove/env -u on a child does not hide a secret from it — a same-uid child reads the parent's /proc/PPID/environ"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 75086575-ccfc-45dd-929f-1e4cffd752c4
  modified: 2026-10-17T22:07:23.247Z
---

Stripping a token from a child process's env (`Command::env_remove`, `env -u`)
is NOT a secret boundary when parent and child share a uid: the child can read
the parent's exec-time env from `/proc/$PPID/environ`. Verified 2026-10-17 in
containers-db#416 with a two-script probe (var passed into the parent at exec
time — a var set *after* exec does not appear in environ, which makes a naive
probe falsely report "not readable").

**Why:** GitHub-hosted runners run every step as one uid with no isolation, so
any third-party code in a job that holds a token (npm packages, build.rs,
proc-macros, npx tools) can reach that token regardless of env scrubbing,
git-config pinning, or `--ignore-scripts`. Those are hardening, not a boundary,
and docs must not claim otherwise.

**How to apply:** for least-privilege CI secrets, the real boundary is the
**job**: run third-party code in a job that references no secret, and pass only
artifacts (binaries, generated files) to a job that holds the token and runs
nothing but first-party code + gh/git. Related: [[assertions-must-discriminate]]
(the naive probe passed for the wrong reason).
