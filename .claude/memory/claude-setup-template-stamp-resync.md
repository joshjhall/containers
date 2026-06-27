---
name: claude-setup-template-stamp-resync
description: claude-setup re-syncs bundled ~/.claude skills/agents via a build-time content stamp; absent stamp = legacy absent-only
metadata:
  node_type: memory
  type: project
  originSessionId: 2aa0d851-77f1-4b25-bfb5-0414fd083419
---

`claude-setup` (lib/features/lib/claude/claude-setup) re-installs bundled
skills/agents into `~/.claude` using a **content stamp**, fixing the staleness
where a template fix never reached an already-built image (issue #574, PR #580).

**Mechanism:**

- Build (`lib/features/claude-code-setup.sh`) writes
  `/etc/container/config/claude-templates/.stamp` = sha256 over every staged
  file's path + contents (excludes `.stamp` itself, `xargs -r` for empty tree).
- Runtime records last-synced stamp at `~/.claude/.template-stamp`. The
  `_bundled_needs_sync` gate re-copies when: target absent, `--refresh` passed,
  OR staged stamp ≠ recorded stamp. Stamps match → fast-path skip (no churn).
- Covers the conditional/dynamic skills too (container-environment,
  docker-development, cloud-infrastructure). `CLAUDE_EXTRA_*` stay absent-only
  (never clobber a user edit).

**Non-obvious trap (caught in pre-PR review):** the sha256sum-unavailable
fallback must write **NO stamp**, not a constant like `no-sha256-build`. A
constant equals itself after the first sync → stamps always match → re-sync
never fires again, silently re-introducing the staleness. Absent stamp is safe
because the gate requires a non-empty `STAGED_STAMP` (legacy absent-only).

`claude-setup --refresh` forces a re-sync regardless of stamp (manual escape
hatch). Already-running pre-fix containers can't be retroactively fixed — only a
container started from a rebuilt image re-syncs.

Lint guard: `tests/unit/claude/lint_skills_agents.sh` runs `node --check` on
every bundled `workflow.js` (syntax) alongside the meta pure-literal lint
(rejects the #563 concat trap). Related: [[parallel-automation-golem-initiative]].
