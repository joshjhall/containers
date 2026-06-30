---
name: plugin-agents-must-be-flat-md
description: "Claude Code plugin agents must be flat agents/<name>.md files, not nested subdirs"
metadata:
  node_type: memory
  type: reference
  originSessionId: dfd33545-fc90-4541-b7d2-a92cba476798
---

Claude Code discovers plugin agents ONLY as **flat markdown files directly
under `agents/`** — `agents/<name>.md`. A nested `agents/<name>/<name>.md`
layout is NOT discovered (the plugin shows `Agents (0)`). Skills are the
opposite: directory form `skills/<name>/SKILL.md` is correct.

This bit the librarian migration (see [[librarian-plugin-extraction]]): the
containers repo stored agents nested as `agents/<name>/<name>.md` (its own
installer flattened them at install time), so copying that layout verbatim
into the plugin made all 18 agents invisible.

**If an agent ships a `workflow.js` harness companion:** keep the flat
`agents/<name>.md` AND put the harness in a same-named sibling subdir
`agents/<name>/workflow.js`. Agent discovery ignores the subdir; the harness
and any `${CLAUDE_PLUGIN_ROOT}/agents/<name>/workflow.js` references still
resolve. Both can coexist (verified empirically).

`plugin.json` has an `agents` array field, but it does NOT rescue nested
single-file paths for discovery — flat `.md` is the reliable layout. The
`agents` manifest key *replaces* the default `agents/` scan when present.

**Always verify plugin packaging with a clean `claude plugin marketplace add
<path>` + `claude plugin details <name>@<mkt>`** (check the `Agents (N)` /
`Skills (N)` counts) before declaring a migration done — manifest validation
alone does not exercise component discovery.
