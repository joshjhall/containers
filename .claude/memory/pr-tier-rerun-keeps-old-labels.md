---
name: pr-tier-rerun-keeps-old-labels
description: "Adding ci/full-build then `gh run rerun` still skips feature builds; the rerun replays the original event's labels"
metadata:
  node_type: memory
  type: project
  originSessionId: a30c922e-b5ff-4d13-8ad8-2315f0d9cbbe
  modified: 2026-09-28T19:43:26.077Z
---

Per-feature PR builds (`test-pr.yml`) are opt-in: they only run when the PR has the `ci/full-build`
label (#508). By default a feature-script PR goes green on code-level checks alone. The feature
image itself is never built.

Adding the label afterwards and running `gh run rerun` does **not** help. A rerun replays the
original `pull_request` event payload, so it still sees `LABELS: []` and skips the builds.
`test-pr.yml` also doesn't trigger on `labeled`. To get the build, push a new commit, even an empty
`ci(ci): …` one. Labeling at creation (`gh pr create --label ci/full-build`) does work (#993).

**The label still doesn't build skip-listed features.** `SKIP_LIST` in `test-pr.yml` (read it;
at #993 it was `rust-dev|java-dev`) filters both the per-feature path and the foundational `ALL`
fallback cluster. That cluster names `rust-dev` but not `rust`. So a `rust-dev.sh` change never
builds on the PR tier, and with a foundational file in the diff `rust.sh` doesn't either. The
merge tier covers them only after merge.

**Why:** on #984 (Node 26 corepack), the first green CI didn't include `Build node` at all. The
label-and-rerun attempt burned a cycle and still skipped it.

**How to apply:** for any change under `lib/features/`, add `ci/full-build` **before** the first
push, or push a fresh commit after labeling. Before treating a green PR as a real image-build
signal, check that `Build <feature>` actually shows up in `gh pr checks`. If the feature is
skip-listed, build it locally (`just test-feature rust-dev`) before merging; on a pre-restart
container see [/symlink-xattr-eloop-is-virtiofs-not-bindfs.md](/symlink-xattr-eloop-is-virtiofs-not-bindfs.md).
Related: [[zero-checks-is-not-green]], [[skips-render-as-passes]].
