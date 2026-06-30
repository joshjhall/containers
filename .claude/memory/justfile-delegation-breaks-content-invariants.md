---
name: justfile-delegation-breaks-content-invariants
description: "Thinning justfile recipes into librarian bundled-script wrappers (#609) breaks lint_skills_agents content-greps; retarget to delegation + guard set -e"
metadata:
  node_type: memory
  type: project
  originSessionId: 348bb1f1-5ca0-4992-8732-51db565a8e10
---

When #609 converted the golem/worktree `just` recipes (`worktree-new`,
`worktree-rm`, `golems`, `golem-attach`, `golem-watch`) into thin wrappers over
the `librarian` `workflow` plugin's bundled scripts, two cross-file contract
suites in `tests/unit/claude/lint_skills_agents.sh` broke — they grep the
**justfile body** for logic that #609 deliberately MOVED into the bundled
scripts:

- `test_next_issue_chaining` Invariant 8 (#585): launch-hint
  `claude --permission-mode auto '/next-issue` + `;`-chained ship backstop.
- `test_orchestrate_pool_invariants` Invariant 7 (#603): pool.json row-glob
  exclusion (`[ "$f" = "$pool" ] && continue`) + `Pool: size=` header.

**Fix pattern (the post-delegation contract split):**

- Always-on assertion: the justfile DELEGATES — grep it for
  `bin/workflow-scripts-dir.sh` and the bundled script name (`worktree-new.sh`,
  `golem-status.sh`). This is the containers-side guard and runs everywhere.
- Source-of-truth assertion: resolve the bundled dir via
  `bin/workflow-scripts-dir.sh` and grep the migrated content THERE — but only
  when the plugin is resolvable; `skip_test` otherwise (CI has no librarian
  install, so those checks belong to librarian's own suite).

**CRITICAL set -e gotcha:** the suite runs `set -euo pipefail`. Resolving with
`v="$(bash bin/workflow-scripts-dir.sh)/suffix"` ABORTS THE WHOLE SUITE when the
resolver exits non-zero (plugin absent) — CI shows `✗ ERROR (Test suite failed
to run)`, not a normal FAIL. Capture the dir under `|| true` into its own var,
then append the filename only when non-empty:
`dir="$(... || true)"; [ -n "$dir" ] && script="$dir/golem-status.sh"`.

`bin/workflow-scripts-dir.sh` is the just-side analogue of
`${CLAUDE_PLUGIN_ROOT}` (unset outside Claude Code): override >
`$CLAUDE_PLUGIN_ROOT/scripts` > newest installed cache (`sort -V` with a
portable field-sort fallback for macOS BSD / Alpine busybox) > dev mount
(`/workspace/librarian/...`, overridable via `WORKFLOW_DEV_MOUNT`). Validity
gated on `config.sh` presence.

Watch for the same breakage in the remaining consume-chain issues
([[librarian-plugin-extraction]] #611 removes the migrated artifacts, #610 docs
sweep): any test/doc that greps a containers path for now-migrated content needs
the same retarget. Also recall pushes need `--no-verify`
([[preexisting-osv-vuln-blocks-push]]) and the worktree is offline-gated.
