---
name: signed-commit-unknown-key-is-identity
description: "GitHub \"unknown_key\" on a locally-valid SSH-signed commit means the committer email isn't the key owner's, not that the key is unregistered"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0eb0901f-52e8-42b6-989d-27f55e443e43
  modified: 2026-11-02T05:12:48.440Z
---

A commit can show `%G?` = `G` locally yet GitHub reports `verified:false, reason:unknown_key`.
GitHub matches the signing key against the **committer's** account, so a commit signed with the
user's 1Password-loaded key but committed as `github-actions[bot]` fails. Cause seen 2026-11-01: a
repo-local `[user]` section in containers-db `.git/config` (origin unknown — nothing in either repo
writes it) overriding `~/.gitconfig`.

**Why:** with the `required_signatures` ruleset on containers-db main, that commit blocked PR #524;
I wrongly told the user to register a key that was already registered.

**How to apply:** on `unknown_key`, run `git config --show-origin --get-all user.email` and `git log
-1 --format='%ce'` before suspecting the key. Fix by removing the local `[user]` section and
recommitting with `--reset-author` (force-push may be blocked — open a replacement PR instead).
