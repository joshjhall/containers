---
name: librarian-container-install
description: "Container installs librarian plugins offline from /opt/librarian local marketplace; clone at build, install at runtime (#608)"
metadata:
  node_type: memory
  type: project
  originSessionId: b279fdad-9bb9-4a18-8012-ff0601991b74
---

# 608 replaced the #574 bake-into-`templates/`+content-stamp re-sync with a

librarian plugin-marketplace install. Shipped on `feature/issue-608`.

**Load-bearing fact (verified live):** `claude plugin marketplace add <local-dir>`

- `claude plugin install <p>@librarian` succeed **offline with NO auth** — a
directory-sourced marketplace is a pure filesystem op (registered in
`~/.claude/plugins/known_marketplaces.json` as `{"source":"directory"}`). This is
what makes a network-free, no-auth, headless install viable.

**Split: clone at BUILD, install at RUNTIME.** `~/.claude` is volume-prone (the
whole claude-auth-watcher/first-startup machinery exists because of it). So:

- Build (`lib/features/claude-code-setup.sh`): `git clone --depth 1 --branch
  $LIBRARIAN_REF https://github.com/joshjhall/librarian /opt/librarian`, strip
  `.git`, `chmod a+rX`. **Fail hard** on a bad ref (the pin is the contract).
  `--branch` needs a tag/branch, NOT a bare SHA.
- Runtime (`lib/features/lib/claude/claude-setup`): unconditional offline block
  (before the auth-gated official-plugin section) registers `/opt/librarian` +
  installs `${CLAUDE_LIBRARIAN_PLUGINS:-dev-core,review-audit,workflow}`,
  idempotent via `has_plugin`. Self-heals a fresh home volume on every boot.

**Kept staged (decision B): the full `templates/claude` tree, minus the `.stamp`
write.** Deleting templates breaks `test_checker_workflow.sh` (reads
`claude-templates/skills` + `/agents/checker`) and the `CLAUDE_EXTRA_*` additive
loops. Template-file deletion is the SEPARATE issue **#611**. The build-bound
skills (container-environment/cloud-infrastructure dynamic, docker-development
static) still install from templates, now ABSENT-ONLY (`_buildbound_needs_install`
replaced the stamp gate; `--refresh` regenerates).

**Gotchas:**

- `claude-setup` lines that compute `SKILL_LIST`/`SKILL_LIST_IS_OVERRIDE` MUST
  stay — the docker/cloud build-bound conditionals consume them; deleting →
  unbound var under `set -euo pipefail` → abort.
- `LIBRARIAN_REF` stores the `v` prefix (load-bearing git ref). check-versions
  registers it with a BESPOKE extraction that strips `v` (`sed 's/^v//'`), NOT
  `_add_dockerfile_version` (which won't strip → always "outdated"); the updater
  re-adds `v` on writeback. Mirrors the trivy-action exemplar.
- `CLAUDE_LIBRARIAN_PLUGINS` persists to enabled-features.conf via
  persist-feature-flags.sh (`__UNSET__` sentinel) AND must be passed into BOTH
  the dev-tools RUN (where persist runs) and the claude-code-setup RUN.
- **Semantics change:** `CLAUDE_SKILLS`/`CLAUDE_AGENTS` per-skill filtering of
  *migrated* artifacts is lost — selection is now plugin-level
  (`CLAUDE_LIBRARIAN_PLUGINS`). `CLAUDE_SKILLS` still gates the 3 build-bound.

Supersedes [[claude-setup-template-stamp-resync]] for migrated artifacts. Next
in the consume chain: #609 (justfile wrappers), #611 (delete templates), #610
(docs). See [[librarian-plugin-extraction]], [[plugin-agents-must-be-flat-md]].
