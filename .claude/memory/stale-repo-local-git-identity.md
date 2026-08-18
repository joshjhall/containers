---
name: stale-repo-local-git-identity
description: "Repo-local .git/config user.name/email (\"t <t@t.t>\") shadows the 1Password global identity; unset the local scope"
metadata:
  node_type: memory
  type: project
  originSessionId: 1d2ee9f2-91fb-4c3e-86fa-a0de57fbb891
  modified: 2026-08-18T18:10:51.008Z
---

The workspace's `.git/config` can carry a stale repo-local identity
(`user.name = t`, `user.email = t@t.t`) that silently shadows the correct
global identity `setup-git` writes to `~/.gitconfig` from
`OP_GIT_USER_NAME_REF` / `OP_GIT_USER_EMAIL_REF`. Because `.git/config` lives
in the bind-mounted workspace, it survives container rebuilds, so
re-running `setup-git` never fixes it.

**Why:** `git config --get user.name` reads the most specific scope. Local
wins over global, so commits get authored as `t <t@t.t>` even though
`setup-git` reports `OK: git identity: Joshua Hall <josh@yaplabs.com>`.

**How to apply:** Diagnose with `git config --show-origin --get user.name`
(not plain `--get`) — it names the file. Fix with
`git config --local --unset user.name && git config --local --unset user.email`.
Verify signing end-to-end in a throwaway repo:
`git init /tmp/x && git -C /tmp/x commit --allow-empty -m t && git -C /tmp/x log --show-signature -1`.
Related: [[entrypoint-uid-agnostic-user-detection]].
