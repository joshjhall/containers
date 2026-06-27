---
name: librarian-plugin-extraction
description: "Plan to extract general Claude Code skills/agents into a separate \"librarian\" plugin-marketplace repo, usable on host + container"
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

**Why we PAUSED (do not start the migration yet):** a separate swarm of
agents is in-flight improving these same skills/agents in the `containers`
repo. Starting the extraction now would conflict with their unmerged work.
WAIT until that work is merged before migrating, so librarian gets the
improved versions, not stale copies.

**Resume trigger / first step after rebuild:**

1. Confirm the in-flight skill/agent improvement PRs are merged to main.
2. Rebuild the devcontainer (`.devcontainer/rebuild.sh` or editor "Rebuild
   Container") — REQUIRED because the `../../librarian:/workspace/librarian`
   mount was added to `.devcontainer/docker-compose.yml` (line ~30) but the
   running container predates it, so `/workspace/librarian` is NOT yet
   reachable in-container. The librarian repo exists on GitHub (created, but
   empty/scaffold-pending).
3. With librarian mounted, pick up librarian#6 + #1, then migrate.
4. The mount is TEMPORARY — remove it from compose once librarian has the
   content and we work directly in that repo.

Exemplars to copy from when resuming: submodule/devcontainer wiring →
`joshjhall/octarine` (`update = none` pinned submodule, build
`context: ../containers`, post-create/post-start split); editor/lint config →
this `containers` repo (`.zed/settings.json`, dprint/taplo/conform/lefthook).
Drop Rust/Postgres/Redis/docker-in-docker for librarian (docs+shell+node repo).
See [[claude-setup-template-stamp-resync]], [[tmpfs-uid-cannot-be-templated]],
[[parallel-automation-golem-initiative]].
