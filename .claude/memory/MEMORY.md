<!-- rumdl-disable MD013 -->
<!-- This index is intentionally one line per memory (a title link + a short
     hook). Those lines routinely exceed 120 chars; MD013 is disabled for this
     file only. Individual memory files keep the line-length check. -->

- [v5 Architecture](v5-architecture.md) — Three executables (stibbons/igor/luggage), manifest-driven installs…
- [Luggage Tooldb Design](luggage-tooldb-design.md) — Tool catalog: separate containers-tooldb repo, 7-tier activity, luggage crate
- [Minimal build philosophy](minimal-build-philosophy.md) — Install minimal package sets
- [Prefer just recipes](prefer-just-recipes.md) — Use `just <recipe>` over bare cargo/shell when one exists
- [Use file-issue skill](use-file-issue-skill.md) — Always file new issues via `/file-issue`, not raw `gh issue create`
- [PR merge + prune is the default ship](feedback_pr_merge_default.md) — `/next-issue-ship` Option 1 ends at merged + branch deleted, not at "PR open"
- [Auto-merge needs explicit consent](feedback_auto_merge_consent.md) — gh pr merge --auto needs per-turn authorization, separate from default-ship
- [Golem autonomy contract](feedback_golem_autonomy_contract.md) — auto-approve push/PR-create + auto-merge green PRs
- [Skip all-files lint](feedback_local_lint_scope.md) — `just lint` scans the whole repo
- [Full review before merge](feedback-full-review-before-merge.md) — a cap-stop on a narrow clean cycle isn't mergeable
- [Assertions must discriminate](assertions-must-discriminate.md) — exit codes and substring fragments pass for the wrong reason
- [Mutation checks on scratch copies](mutation-checks-on-scratch-copies.md) — prove a guard by mutating a mktemp copy, never sed -i/cp over a tracked file +…
- [Rebase before blaming your own change](rebase-before-blaming-your-change.md) — a CI failure in files your branch never touched usually means main
- [BASH_ENV breaks PATH stubs](bash-env-breaks-path-stubs.md) — /etc/bash_env rebuilds PATH on non-interactive bash
- [FUSE scratch breaks write-then-read](fuse-scratch-breaks-write-then-read.md) — test scratch AND cargo target/ on the FUSE-mounted repo lose coherency
- [git env leak breaks worktree tests](git-env-leak-breaks-worktree-tests.md) — GIT_DIR leaks into pre-push hook
- [Shellcheck policy + bash deprecation](shellcheck-policy-and-bash-deprecation.md) — Enforced at --severity=warning
- [Worktree push hooks vs gitignore](worktree-push-hooks-gitignore.md) — pushing from .worktrees/ breaks osv-scanner (#556) + compose-validate
- [Degraded review gate is not a pass](degraded-review-gate-is-not-a-pass.md) — a review dimension that dies on a 429 returns no verdict
- [Empty review dimension is not a pass](empty-review-dimension-is-not-a-pass.md) — reviewers submit {findings:[]} unread (21% Sonnet, 17 security)
- [Review-fix commit scope](review-fix-commit-scope.md) — conform rejects `fix(review)`; use the component scope (e.g. `test(luggage)`)
- [Golem supervised auto mode](golem-supervised-auto-mode.md) — pass `--permission-mode auto` EXPLICITLY
- [Golem push gate under auto](golem-push-gate-under-auto.md) — `auto` auto-approves push/PR-create
- [Luggage vendored catalog](luggage-vendored-catalog.md) — builds read vendored snapshot (crates/luggage/testdata/catalog), not sibling…
- [tests/results/ is on an incoherent FUSE mount](results-dir-fuse-incoherent.md) — writes succeed, report success, then aren't readable
- [Worktree guard blocks eval + heredocs](worktree-guard-blocks-eval-and-heredocs.md) — refuses the literal `eval` (incl. `yq eval`) and `golem-work.sh complete`…
- [Staged harness blocks worktree-rm](staged-harness-blocks-worktree-rm.md) — leftover `.claude/tmp/harness/*.workflow.js` makes teardown refuse; delete it if it's the only entry
- [Pre-push skips network tests](pre-push-skips-network-tests.md) — SKIP_NETWORK_TESTS=1 keeps the push gate offline
- [Zero checks is not green](zero-checks-is-not-green.md) — check-runs can't tell "never fired" from "delayed"
- [Stale git index.lock](stale-git-index-lock.md) — host↔container git index ping-pong under Zed (zed#52265)
- [Fetch before releasing](fetch-before-release-bot-owns-main.md) — auto-patch bot pushes releases+tags to main on a schedule

## Topic indexes

- [Review harness & golem internals](index-review-harness-golem.md) — open when driving golems, the ship-issue/next-issue review harness, PR/merge automation, or host monitors (25)
- [Filesystem, virtiofs, FUSE & case-sensitivity](index-filesystem-mounts.md) — open on wedged files, EBADF/ELOOP, stale symlinks, case-shadowed paths, or env leaking across process boundaries (8)
- [CI & test-framework gotchas](index-ci-test-gotchas.md) — open when a test or CI job fails oddly, flakes, or passes suspiciously (30)
- [Dependencies, advisories & version pinning](index-deps-security.md) — open when handling osv/cargo-deny advisories, version pins, auto-patch, checksums or signatures (16)
- [Luggage, catalog, evidence & containers-db](index-luggage-catalog-evidence.md) — open when touching luggage install methods, the vendored catalog, evidence runs, or containers-db schema (14)
- [Container runtime, entrypoint, Zed & permissions](index-runtime-devcontainer.md) — open when debugging the entrypoint, UID handling, Zed/devcontainer startup, cron or logging inside the image (11)
- [Build & feature-script specifics](index-build-features.md) — open when editing Dockerfile/base-image layers, per-language feature scripts, or stibbons packaging (15)
- [Resolved, historical & superseded](index-historical.md) — open only for the background of a finished extraction or plugin-wiring change; these are done (4)
