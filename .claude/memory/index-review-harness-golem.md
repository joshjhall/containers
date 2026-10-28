# Review harness & golem internals

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when driving golems, the ship-issue/next-issue review harness, PR/merge automation, or host monitors.

- [Golem feed event classification](golem-feed-event-classification.md) — feed events gate|idle
- [Golem launch bare slash-command fails](golem-launch-bare-slash-command-fails.md) — golem-launch.sh passes bare /next-issue but plugin registers
- [Golem teardown trips on own scaffolding](golem-teardown-untracked-scaffolding.md) — worktree-rm refuses on copied settings.local.json + staged harness
- [Handoff relaunch refuses dim suggestion](handoff-relaunch-refuses-dim-suggestion.md) — type /clear directly when the composer holds only the dim suggestion (librarian#1223)
- [Harness placeholder args fake a review](harness-placeholder-args-fake-review.md) — a stand-in or cross-repo-omitted `args.diff` returns clean:true on the wrong bytes
- [Harness resume replays a fake review](harness-resume-replays-fake-review.md) — resumeFromRunId on the next cycle replays cache: 0 tokens, stale clean
- [Ship review harness agent-type missing](ship-review-harness-agent-type-missing.md) — ship-issue review harness hardcodes dev-core:code-reviewer
- [Ship review harness provider error](ship-review-harness-provider-error.md) — harness/code-reviewer 400 on Sonnet provider
- [Ship review reads whole files](ship-review-whole-file-scope.md) — ship review flags pre-existing main code
- [prComments need real id](pr-comments-need-real-id.md) — id-less PR comment forces harness clean:false despite 0 findings; convergence may still say stop
- [Post-PR review is pr-attempt*.json](post-pr-review-artifact-is-pr-attempt.md) — glob *attempt*.json before holding a merge for a missing post-PR review
- [File follow-ups before teardown](file-followups-before-teardown.md) — subagent spawned in a golem worktree is stranded when Phase D removes it
- [workflow.js must be readable in-worktree](workflow-js-must-be-readable-in-worktree.md) — stage via harness-stage.sh (librarian v0.15.0+)
- [PR link closes despite Refs](pr-link-closes-despite-refs.md) — a linked PR closes its issue on merge even with only `Refs #N`; check closedByPullRequestsReferences first
- [PR-tier rerun keeps old labels](pr-tier-rerun-keeps-old-labels.md) — label at create time, not rerun
- [gh pr checks JSON state is uppercase](gh-pr-checks-json-state-uppercase.md) — filter CI monitors on `bucket` (lowercase), not `state` (UPPERCASE)
- [Refusal tests reach real gh](refusal-tests-reach-real-gh.md) — a guard that silently misses falls through to real `gh` (#424)
- [Host hooks fallback parity](host-hooks-fallback-parity.md) — the two host hooks share an identity ladder
- [Host activity line shows pipeline phase](host-activity-line-shows-pipeline-phase.md) — golem host activity line sources from next-issue phase
- [Host monitor state forwarding (#735)](host-monitor-state-forwarding-735.md) — Forward container golem state to host menu-bar monitors
- [Parallel automation (golem) initiative](parallel-automation-golem-initiative.md) — golem = per-issue sub-orchestrator
- [Review harness destructive rm (#746)](review-harness-destructive-rm-746.md) — ship-issue pre-PR review subagent ran `rm -rf` with unresolved `..`
- [worktree-rm blocked by held build artifacts](worktree-rm-blocked-by-held-build-artifacts.md) — leftover cargo artifacts held open by rust-analyzer
- [Fine-grained PAT lacks admin](fine-grained-pat-lacks-admin.md) — repo-settings writes 403 despite permissions.admin=true
- [Stale repo-local git identity](stale-repo-local-git-identity.md) — `.git/config` `t <t@t.t>` shadows the 1Password global identity
