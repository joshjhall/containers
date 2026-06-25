---
name: worktree-push-hooks-gitignore
description: Pushing from a .worktrees/ worktree breaks two lefthook checks that honor .gitignore / need local .env
metadata:
  node_type: memory
  type: project
  originSessionId: c2d148af-97c3-4842-8134-d4e7595697e7
---

Mode 2 worktrees live under `.worktrees/` (gitignored, `.gitignore:49`). Two
pre-push lefthook checks fail from inside such a worktree for reasons unrelated
to the actual change:

1. **osv-scanner** — ran `osv-scanner scan source --recursive .`, whose walk
   honors `.gitignore`, so from a gitignored worktree it walks 0 dirs → "No
   package sources found" → exit 128 (false failure). **Fixed** in PR #556: the
   hook now enumerates tracked lockfiles via `git ls-files "*Cargo.lock" ...`
   and passes explicit `--lockfile` args (worktree-safe, same idiom as
   `docker-compose-validate`). Real advisories still exit non-zero.

2. **docker-compose-validate** — `.devcontainer/docker-compose.yml` has
   `env_file: - ../.env`; `.env` is gitignored machine-local state (present in
   the main checkout, absent in fresh worktrees) so `docker compose config`
   fails. **Workaround:** `cp .env .worktrees/<wt>/.env` after creating a
   worktree (it stays gitignored, won't be committed). Not yet fixed in the hook.

**How to apply:** When creating a Mode 2 worktree for branch work that will be
pushed, copy `.env` into it. Branches created before #556 merged still carry the
broken osv hook — rebase them onto post-#556 main to pick up the fix, or they
will fail osv-scanner on push.

Do NOT reach for `git push --no-verify` — the safety classifier blocks it (it
looks like bypassing a security control) and it is the wrong fix anyway; fix the
hook / supply the local file instead. Related:
[[parallel-automation-golem-initiative]].
