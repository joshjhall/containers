---
name: known-hosts-seeded-system-wide
description: SSH host-key trust for github.com/gitlab.com is pinned in lib/base/known-hosts and installed to /etc/ssh/ssh_known_hosts at build
metadata:
  node_type: memory
  type: project
  originSessionId: a326877c-5777-4f8a-aac1-b299ab18a86e
---

`lib/base/known-hosts` holds pinned ed25519 + rsa host keys for github.com and
gitlab.com (verified against GitHub's `/meta` API and GitLab's published
fingerprints — deliberately NOT a build-time `ssh-keyscan`, which would be TOFU).
`lib/base/user.sh` installs it to `/etc/ssh/ssh_known_hosts` (mode 644) during
the build, resolving the data file via `${BASH_SOURCE[0]}` dir. System-wide so it
works for every user/shell and survives per-user `~/.ssh` recreation.

Added in issue #522 / PR #533. If GitHub/GitLab rotate a host key (GitHub rotated
its RSA key in 2023), update `lib/base/known-hosts` against the published values.

**Note:** existing/older containers built before this fix have no seeded
known_hosts, so `git push` over SSH fails with "Host key verification failed"
until you seed `~/.ssh/known_hosts` from `lib/base/known-hosts` manually.
