---
name: lint-couples-docs-to-templates
description: Lint AI Templates CI requires every templates/claude skill+agent be named in skills-and-agents.md
metadata:
  node_type: memory
  type: project
  originSessionId: c4975a39-e43b-460c-b6d1-b141e85c9def
---

`tests/unit/claude/lint_skills_agents.sh` (`test_skills_in_docs` /
`test_agents_in_docs`, run by the **Lint AI Templates** CI job) asserts every
directory under `lib/features/templates/claude/{skills,agents}/` appears
backtick-wrapped (`` `name` ``) in `docs/claude-code/skills-and-agents.md`.

**Why:** the doc is treated as a manifest of bundled artifacts. Deleting the
enumeration tables (as #610 did to point docs at `librarian`) breaks this lint
because the 41 skills + 17 agents still physically live under `templates/claude/`
until #611 removes them.

**How to apply:** while the templates still exist, keep every migrated artifact's
name present in `skills-and-agents.md` — #610 added a "Component index" section
(name → librarian plugin) for exactly this. When #611 removes the template dirs,
it must ALSO update/relax this test (it owns the coupling removal), or the index
section can shrink to only the build-bound skills. rumdl gotcha: a wrapped line
beginning with `#NNN` (an issue ref) trips MD018 (parsed as a heading) — keep a
word before issue refs at line starts. Related: [[ship-review-whole-file-scope]],
[[preexisting-osv-vuln-blocks-push]].
