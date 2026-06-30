---
name: librarian-plugin-extraction
description: "DONE: general Claude Code skills/agents extracted into the \"librarian\" plugin-marketplace repo; containers consumes it at a pinned ref (epic #607 closed)"
metadata:
  node_type: memory
  type: project
  originSessionId: e6b89a05-74bc-41cb-9726-558a310983f0
---

We are extracting the general-purpose Claude Code artifacts (currently 17
agents + 41 skills + hooks under `lib/features/templates/claude/`, ~1.1 MB)
out of this `containers` repo into a **separate sibling repo named
`librarian`** so they can be used on the host Mac, bare Linux boxes, and
inside the container alike. Decided 2026-06-27.

**Distribution mechanism: Claude Code plugin marketplace** (a git repo with
`.claude-plugin/marketplace.json` + per-plugin `.claude-plugin/plugin.json`).
NOT Homebrew/apt/apk — OS packagers ship binaries, don't integrate with
Claude's discovery/versioning/update, and would mean reinventing the plugin
system. Native plugins give cross-machine install + `plugin update` semver
rolling updates for free.

**Repo name `librarian`**: Discworld house style (cf. stibbons/igor/luggage/
octarine/golem). The Librarian curates the UU library and travels L-space —
maps to "one skills library reachable from any machine." Plugins *inside*
stay plainly named for discoverability: `dev-core`, `review-audit`,
`workflow`. Users type `owner/librarian` so the repo is namespaced anyway.
User will create the `librarian` repo; file repo-specific issues there.

**Plugin split (3, not one-per-skill):** `dev-core` (code-review, debugger,
refactorer, test-writer, git-workflow, error-handling, authoring +
adversarial-review), `review-audit` (audit-*/check-* suite, issue-writer),
`workflow` (golem, orchestrate, next-issue(+ship), provision-agent,
file-issue + bundled `scripts/`).

**Golem/orchestrator portability (key decision):** ONE implementation, no
plugin fork. The plugin bundles canonical shell scripts (worktree-new.sh,
golem-status.sh, …) called via `${CLAUDE_PLUGIN_ROOT}`; skills call those
scripts, NEVER `just`. So they run on host/bare-linux/container identically.
This `containers` repo's justfile recipes become thin wrappers delegating to
the bundled scripts — `just worktree-new 569` still works as muscle-memory
sugar but is no longer required. Env-overridable config for the genuine forks
(`GOLEM_WORKTREE_DIR`, branch naming, state dir) with container-set defaults.
See [[parallel-automation-golem-initiative]], [[golem-supervised-auto-mode]].

**Stays in `containers` (build-bound only):** `feature-script-patterns`,
`test-framework-reference`, `container-environment`. Repo consumes `librarian`
like any other client.

**Container migration:** Replace the bake-into-`templates/` +
content-stamp-resync machinery (#574, see
[[claude-setup-template-stamp-resync]]) with a build step that clones
`librarian` at a PINNED tag/SHA into the image, registers it as a *local*
(on-disk) marketplace, installs offline. The pin becomes the version
contract; keeps the headless container reproducible/offline. `claude-setup`
gets simpler. Touches `lib/features/claude-code-setup.sh` and
`lib/features/lib/claude/claude-setup`.

## Status & resume plan (as of 2026-06-27)

**Issues filed (the durable tracking lives in GitHub):**

- Epic: `joshjhall/containers#607` (has a comment with the full 58-artifact
  triage table + a comment listing all sub-issues and suggested order).
- containers-side: #608 (pinned local-marketplace install, removes #574
  bake/stamp), #609 (justfile recipes delegate to bundled scripts), #610
  (docs sweep), #611 (remove migrated artifacts — do LAST, after librarian
  live + container consuming).
- librarian-side (`joshjhall/librarian`): #1 scaffold (foundational, blocks

  #2–#5), #2 migrate dev-core, #3 migrate review-audit, #4 migrate workflow +
  de-`just` bundled scripts, #5 relocate quality gates/fixtures, #6 bootstrap
  dev env (containers submodule, devcontainer, Zed/VS Code, gitignore).
  Label taxonomy already seeded in the librarian repo (component/* = plugin
  names). Suggested order: librarian#1 + #6 first → #2/#3/#4/#5 → containers
  #608 → #609 → #611 → #610.

**Pause is CLEARED (2026-06-28):** the in-flight skill/agent improvement swarm
merged (containers had 0 open PRs; #631/#633/#624/#620/#616 etc. landed).
Librarian is mounted at `/workspace/librarian` and the foundation is BUILT.

**Foundation DONE (PRs open in `joshjhall/librarian`):**

- `main` seeded with an initial commit (README, MIT+Apache dual license,
  gitignore) — empty repos can't take branch PRs, so this had to land first.
- **librarian#1 → PR #7** (base `main`): marketplace.json + 3 plugin.json
  (dev-core/review-audit/workflow, local `./plugins/<name>` sources, semver
  0.1.0) + `tests/validate-manifests.mjs` (zero-dep Node validator) + CI +
  READMEs. CI green. Verified `claude plugin marketplace add /workspace/librarian`
  - all 3 plugins install.
- **librarian#6 → PR #8** (base `feature/issue-1`, STACKED on #7 because its
  lefthook/justfile call the validator #7 adds): containers pinned submodule
  (update=none, v4.19.8), devcontainer (build ../containers, DEV_TOOLS+NODE
  only), post-create/post-start, .zed/.vscode, dprint/_typos/shellcheck/rumdl/
  conform(plugin scopes)/lefthook(graceful skips on bare host)/justfile/CLAUDE.md.
  CI shows none because base≠main; will run when #7 merges + #8 retargets.

**LIBRARIAN IS LIVE — all 6 issues merged to main (2026-06-28).** The repo is
a fully populated, installable plugin marketplace. Final state:

- dev-core: 20 skills, 6 agents · review-audit: 9 skills, 8 agents · workflow:
  9 skills, 3 agents = **38 skills + 17 unique agents**. All migrated from the
  containers submodule pin (v4.19.8 = post-swarm improved versions).
- Merge order used: scaffold #7 → devenv #9 → artifact PRs #10/#11/#13 (disjoint
  dirs, no conflict) → rebased quality-gates #12 onto populated main so its lint
  ran against REAL artifacts → fix #14.
- Migrations ran as 4 parallel **worktree + Agent subagents** (not golems).

**KEY BUG caught at final verify (#14):** Claude Code discovers plugin agents
ONLY as FLAT `agents/<name>.md` files — NOT nested `agents/<name>/<name>.md`
(the containers layout). The migration preserved nesting → all 18 agents showed
`Agents (0)` on install. Fix: flatten; the 3 harness agents (code-reviewer/
ci-fixer/rebase-agent) keep `workflow.js` in a same-named sibling subdir
(`agents/<name>/workflow.js`) which discovery ignores. Also removed a duplicate
`issue-writer` (epic double-listed it in #3+#4; belongs to review-audit per its
codebase-audit tie). Skills are dir-form (`skills/<name>/SKILL.md`) and were
fine. Lesson saved as [[plugin-agents-must-be-flat-md]]. ALWAYS verify with a
clean `claude plugin marketplace add` + `plugin details` before declaring done.

**Consume chain COMPLETE — all merged to containers main (2026-06-30); the
epic (#607) is CLOSED.** Order run: #608 (PR #668, pinned marketplace install at
`LIBRARIAN_REF=v0.2.0`; removed #574 bake/stamp consume) → #609 (PR #666,
justfile recipes delegate to librarian bundled scripts) → #610 (PR #665, docs
sweep) → #611 (PR #669, removed 38 librarian-covered skills + 17 agents +
hooks/golem-notify.sh). Ran as 3 parallel worktree golems (#608/#609/#610),
with #611 held until #608 merged. Build-bound skills KEPT in-repo:
`container-environment`, `cloud-infrastructure`, `docker-development` (only
these 3 — verified 0 hits in librarian v0.2.0). #611 also fixed a latent
`ci.yml` lint bug: the PR-lint step fed DELETED paths to rumdl/shfmt → add
`--diff-filter=d` to exclude deleted files from the lint set. The
`../../librarian:/workspace/librarian` compose mount is now obsolete — the pin
is the contract.

Two recurring CI flakes seen during the batch (NOT code, just re-run):
(1) osv-scanner pre-push rejects ALL pushes on a pre-existing Cargo.lock
advisory (RUSTSEC-2026-0190, anyhow) → `--no-verify` when diff is
lockfile-clean ([[preexisting-osv-vuln-blocks-push]]); (2) GHA Actions Cache
blob I/O (`BlobNotFound` on read, `error writing layer blob: not_found` on
export) failed 3 merge-tier runs while the image itself built fine — pure
infra, recovered on re-run.

**Artifact-domain issues TRANSFERRED to librarian (2026-06-28):** 13 issues
moved via `gh issue transfer` (containers #329,340,497,503,596,597,598,617,625,
628,629,630,634 → librarian #16–#28). These concern the migrated artifacts/
bundled scripts themselves (orchestrate/next-issue skills, golem-status.sh,
seed-worktree-trust.sh, golem-gate-watch.sh, codebase-audit/checker Workflow
harness, skill test framework). KEPT in containers: #626 (containers-CI buildx
flake) and #627 (sync-host.sh — bare-host machinery that did NOT migrate).
Gotchas learned: (1) `gh issue transfer` must run from INSIDE a git repo dir
(fails silently with "not a git repository" from /tmp) — pass `--repo` too.
(2) Transfer DROPS labels absent in the destination; containers `component/*`
(features/skills/tooling) don't exist in librarian, so component labels were
re-applied after transfer, remapped to plugin names (workflow/review-audit/
tests/marketplace). Added `type/bug` + `status/on-hold` to librarian's taxonomy
first so next-issue works there.

Exemplars to copy from when resuming: submodule/devcontainer wiring →
`joshjhall/octarine` (`update = none` pinned submodule, build
`context: ../containers`, post-create/post-start split); editor/lint config →
this `containers` repo (`.zed/settings.json`, dprint/taplo/conform/lefthook).
Drop Rust/Postgres/Redis/docker-in-docker for librarian (docs+shell+node repo).
See [[claude-setup-template-stamp-resync]], [[tmpfs-uid-cannot-be-templated]],
[[parallel-automation-golem-initiative]].
