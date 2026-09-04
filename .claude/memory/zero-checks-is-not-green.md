---
name: zero-checks-is-not-green
description: check-runs can't tell "CI never fired" from "event delayed"; query actions/runs?branch= and treat zero effective checks past grace as failing
metadata:
  node_type: memory
  type: project
---

**Probing "did CI fire?" via check-runs on a commit gives a false negative
during a delivery delay.** `gh api commits/<sha>/check-runs` → `total_count: 0`
and `gh pr checks` → `no checks reported on the 'X' branch` look identical
whether the workflow will never run or the `pull_request` event is merely
queued. Ask the runs endpoint instead and compare timestamps:

```bash
gh api "repos/OWNER/REPO/actions/runs?branch=feature%2Fissue-N" \
  --jq '.workflow_runs[] | "\(.event) \(.name) \(.created_at)"'
```

Issue #854 reported `pull_request` "silently did not fire" for PR #848. It fired
**13m46s late** — four runs existed. PR #847, cited as the healthy control, was
**17m44s** late in the same ~35-min window (2026-08-26). Baseline here is
**3–4 seconds**. Root cause: transient GitHub Actions event-delivery backlog.
Repo Actions settings, `ci.yml` concurrency, and path filters were ruled out.

**Why it's dangerous, not just confusing:** the ship CI poll waits "until no
checks have `state: pending`", which an **empty list satisfies instantly**, and
`main` has no branch protection. Zero checks therefore reads as green.

`bin/check-pr-checks.sh` (+ `just check-pr-checks N`) is the guard: zero checks
past a 300s grace → `absent` / exit 3, never exit 0. Two traps it encodes,
both of which silently produce a *pass* when gotten wrong:

- **`effective = total - skipping`.** Majority-skipping is the healthy steady
  state (PR #896: 13 of 23), so `count > 0` passes a PR where nothing ran.
- **`statusCheckRollup` has NO `bucket` field** — that's `gh pr checks`. The
  rollup uses UPPERCASE `.status`/`.conclusion` (`CheckRun`) or `.state`
  (`StatusContext`). Matching lowercase counts zero everywhere → clean pass.
  Same family as [[gh-pr-checks-json-state-uppercase]].
- **Classify failure by exclusion, not by an allowlist of failure names.**
  Only explicit `SUCCESS` passes; a null conclusion or a status GitHub adds
  later must fail closed. An allowlist fails *open* — the unknown value matches
  no bucket, still counts as an effective check, and emerges as a pass.

Follow-up worth doing: required status checks on `main` (`Run Tests`,
`PR Tier`) would make this binding rather than advisory — see
[[preexisting-osv-vuln-blocks-push]] for how a repo-wide gate changes push
behavior before adding one.
