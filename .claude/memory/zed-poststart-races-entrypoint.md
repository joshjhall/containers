---
name: zed-poststart-races-entrypoint
description: "Zed fires postStartCommand concurrently with the entrypoint (~T+147ms vs T+3s), so secret-dependent setup can run before 1Password resolves"
metadata:
  node_type: memory
  type: project
  originSessionId: c0c3c93f-aaac-4a87-b135-d08561a7e8c0
  modified: 2026-08-21T21:32:34.928Z
---

Under **Zed**, `postStartCommand` starts ~147ms after container `StartedAt`,
while the entrypoint (which runs `45-op-secrets.sh` to resolve `OP_*_REF`) does
not finish for ~3s. They run **concurrently** — postStart does NOT wait.

Under VS Code this cannot happen: `"overrideCommand": false` makes the entrypoint
PID 1, so postStart waits for it. Zed ignores that setting — the same divergence
that motivated `recover-entrypoint` ([[zed-every-boot-startup-replay]]).

**Consequence:** anything in the postStart chain that consumes a 1Password secret
can run before the secret exists. Observed 2026-08-19: container booted with empty
`~/.ssh`, no git identity, no `gh` auth, every git-over-SSH call failing
`Permission denied (publickey)` — while `GIT_AUTH_SSH_KEY` was correctly populated
in the environment. Running `setup-git` by hand fixed it instantly.

**Why it was invisible** (fixed in #785 / PR #790, merged 2026-08-21):
`setup_auth_key` opened with `[ -n "${GIT_AUTH_SSH_KEY:-}" ] || return 0` — a
*silent* success on empty input, indistinguishable from "nothing to do". The whole
`&&` chain returned 0, so Zed recorded a clean postStart. The fix adds
`_warn_if_ref_unresolved` (warns when `OP_<NAME>_REF` is set but `<NAME>` is empty,
returns 0 so it doesn't break the chain) and makes `_wait-for-op-cache` source
`.env.secrets` itself instead of trusting the caller.

**The race still exists — it is only visible now, not prevented.** Anything added
to that postStart chain later inherits the hazard. The barrier fix (block postStart
until the entrypoint finishes) was deliberately left out of scope; it is the
natural follow-up if this recurs.

**Diagnosing this class of bug:** the container log is ground truth and outlives
the shell — `docker inspect <id> --format '{{.State.StartedAt}}'` vs
`stat -c %y ~/.devcontainer/.postStartCommandMarker` vs `docker logs <id>`.
Note postStart output does NOT appear in `docker logs` under Zed (it runs via
`docker exec`, not PID 1), so its absence there is expected, not evidence of failure.

**Two measurement traps that produced wrong conclusions here** — both cost a full
wrong hypothesis before evidence corrected them:

- `cmd | tail -3; echo $?` reports *tail's* status, not cmd's. Use
  `cmd >/tmp/out 2>/tmp/err; echo $?`.
- A `$( )` command substitution runs in a subshell, so `set -u` on an unbound var
  kills only that subshell — with `|| true` the parent still exits 0. An "unbound
  variable" line on stderr is NOT proof the script aborted.

Related: [[stale-repo-local-git-identity]], [[entrypoint-uid-agnostic-user-detection]]
