---
name: ci-stays-on-github-hosted-runners
description: "CI stays on GitHub-hosted runners so the repo stays usable as open source; ubuntu queue starvation is managed by deduping runs, not by moving to self-hosted"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: f20d3756-7c11-4435-8999-907b51540891
  modified: 2026-11-02T01:55:45.452Z
---

This repo's CI stays on GitHub-hosted Actions runners on purpose. The user has local GitLab runners,
limited only by CPU/RAM, but chose to keep CI on GitHub so the project stays open source and anyone
can run it (user, 2026-11-02).

GitHub-hosted **Linux** capacity is the bottleneck. On 2026-11-01/02, `ubuntu-latest` jobs sat
queued for 30+ minutes with no runner assigned, while macOS and Windows jobs on the same run were
picked up. There were about 9 runs queued and 0 in progress. githubstatus showed Actions as
operational, so this looks like free-account or throttling capacity, not an outage.

**Why:** a golem PR's wall-clock time is set by the CI queue, not by how fast the golem works. Each
review-fix push queues another full pipeline, so superseded runs compound the wait.

**How to apply:**

- Do NOT propose moving CI to self-hosted or GitLab runners as the fix.
- Reduce load instead. The user gave standing approval (2026-11-02) to cancel superseded runs,
  meaning queued or in-progress runs for a PR branch whose `head_sha` is no longer the PR's head
  (`gh run cancel <id>`).
- Never cancel `main`/`v5`/`auto-patch/**`/tag runs; release and auto-patch read them. Never cancel
  `evidence-run.yml`, which serializes ingest on purpose.
- The lasting fix is a `concurrency` group in `ci.yml`/`test-pr.yml` (#1560).
- When a golem's ship-issue CI wait times out under this queue, that's a clean hand-off, not a
  stall. Nudge it to merge once CI is green on the current head SHA. Check the SHA, because the PR
  rollup can show an old head's green checks after a push.

Related: [[zero-checks-is-not-green]], [[feedback_golem_autonomy_contract]].
