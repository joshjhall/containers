---
name: fine-grained-pat-lacks-admin
description: The container gh token is a fine-grained PAT without repo Administration:write — branch-protection and other repo-settings writes 403 even though the API reports permissions.admin=true
metadata:
  node_type: memory
  type: project
  originSessionId: 59438cf8-7c97-4dc5-a847-9e8a04dada26
  modified: 2026-09-04T20:11:11.763Z
---

The `gh` token in this container is a **fine-grained PAT** (`github_pat_…`, empty
`x-oauth-scopes` header). It can read/write issues, PRs and code, but **cannot
write repo settings**:

```console
$ gh api -X PUT repos/joshjhall/containers/branches/main/protection --input …
{"message":"Resource not accessible by personal access token","status":"403"}
```

**The trap**: `gh api repos/OWNER/REPO --jq .permissions` reports
`{"admin": true, …}`. That is the **account's role on the repo**, not the
**token's grant** — for a fine-grained PAT the two diverge. Checking it before a
settings write gives false confidence; only the write itself, or the token's own
permission list in GitHub settings, tells you. Repo-settings writes need the
fine-grained permission **"Administration: Read and write"**, granted per-repo.

**How to plan around it**: when an issue's deliverable is a repo-settings change
(branch protection, rulesets, Actions permissions, environments), treat the apply
step as operator work from the start. Ship the in-repo half — a committed
manifest of the intended setting, a guard test, the docs — and say plainly that
the setting is *decided, not applied*. Documenting a setting as live when it is
not is worse than not documenting it: it retires the alarm that would get it
applied.

First hit on #904 (branch protection on `main`, PR #908): the work landed but the
issue stayed open as `status/blocked`. See
[[assertions-must-discriminate]] for the mutation-testing discipline used on that
PR's guard test.
