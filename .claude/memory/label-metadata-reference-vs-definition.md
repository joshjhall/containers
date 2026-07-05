---
name: label-metadata-reference-vs-definition
description: Skill metadata.yml labels split into definitions (with color) vs name-only references; stibbons labels sync must not let a reference blank a real label
metadata:
  node_type: memory
  type: project
  originSessionId: 99b46dff-3a2b-45a0-b920-be6557b1fafb
---

`stibbons labels sync` (#289) reads label defs from skill `metadata.yml` files.
Two structural facts that are NOT obvious from the stibbons code alone:

1. **Label defs moved to librarian.** In-repo template skills
   (`lib/features/templates/claude/skills/*/metadata.yml`) now carry
   `labels: []` after the librarian extraction (#669). The real ~30 definitions
   live under `/opt/librarian/plugins/*/skills/*/metadata.yml` (e.g.
   `workflow/next-issue`, `review-audit/codebase-audit`, `workflow/ship-issue`).
   Default scan roots therefore = in-repo templates **and** `/opt/librarian/plugins`.

2. **Name-only entries are references, not definitions.** Some skills list a
   label with only `name:` (no `color`/`description`) to declare a *dependency*
   on it — e.g. `orchestrate/metadata.yml` references `status/pr-pending` /
   `status/commit-pending`, which `ship-issue` actually *defines*. Aggregation
   processes files alphabetically, so a naive first-wins would let the empty
   `orchestrate` entry win and a non-dry-run would **blank the real color** on
   the tracker. Fix: treat empty-color entries as references — they never
   override a definition and never seed an empty label; a name only ever
   referenced (never defined) is skipped with a warning.

Related: [[stibbons-binary-distribution]], [[librarian-plugin-extraction]].
