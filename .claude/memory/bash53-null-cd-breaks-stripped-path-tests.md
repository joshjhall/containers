---
name: bash53-null-cd-breaks-stripped-path-tests
description: ubuntu-26.04 runners (bash 5.3, shellcheck 0.11) broke CI — `cd ""` now errors and SC2232 flags `sudo command`; stripped-PATH tests had passed via a silent no-op
type: project
metadata:
  type: project
---

bash 5.3 turns `cd ""` into an error ("cd: null directory", exit 1). Bash 5.2 treated it as a no-op.
`ubuntu-latest` switched to ubuntu-26.04 (bash 5.3) around 2026-11, and the v4.22.1 auto-patch
release failed on this (PR #1598).

**Why:** Tests that run a script under `env -i PATH=<empty>` or with a no-op
`command_not_found_handle` make `$(dirname …)` or `$(some_helper)` return "". Under bash 5.2 the `cd
""` that follows does nothing, so the test passes for the wrong reason (see
[[assertions-must-discriminate]]).

**How to apply:** If a stripped-PATH test fails with "null directory", use `${BASH_SOURCE[0]%/*}` in
place of `dirname`, or stub the helper to return a real sandbox directory. Reproduce locally with
`docker run ubuntu:26.04` as a non-root user; the cosign harness refuses to run as root. A local
bash 5.2 will not reproduce it.

The same migration also moved apt shellcheck from 0.10.0 to 0.11.0, which adds SC2232 (`sudo command
X`). That failed the full-repo lefthook sweep on the next release run (PR #1599). Diff 0.10 against
0.11 across all `*.sh` files *with* `.shellcheckrc` included; without the rc file, hundreds of
already-suppressed warnings drown out the real one.
