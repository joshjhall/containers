---
name: operator-priority-takes-next-free-slot
description: "when the operator bumps an issue to \"next free slot\", the very next freed lane must take it, ahead of that lane's own queue and any planned rebalance"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: f20d3756-7c11-4435-8999-907b51540891
  modified: 2026-11-10T04:41:45.141Z
---

When the operator says to prioritize an issue "on a 4th track or as next on whichever track opens up
next," the **first lane slot that frees up goes to that issue**, whatever lane it is in. That
outranks the lane's own queue and any rebalance already planned.

On 2026-11-02 I was told to do this for #1573 (signed evidence/auto-patch commits via the GitHub
API). I filed it into lane C behind PR #1571, because the two touch the same files. Then I gave the
next two freed slots to other issues: lane A got #1555 when #1560 merged, and lane B got #1565
when #1564 merged. The operator had to stop me to get it started.

**Why:** the operator raised the priority because #1573 blocks recording any new evidence.
containers-db `main` now requires signed commits, so ingest pushes are rejected. Each slot that goes
to lower-priority work keeps that evidence pipeline down for another cycle. I also over-claimed: I
said a green alpine cell on #1571 could close #1530 and #1550, but nothing is ingested until #1573
lands.

**How to apply:**

- A priority bump with "next free slot" means: dispatch it the moment any golem finishes, or start
  an extra lane at once.
- A file overlap with an in-flight PR is not a reason to wait. Start it anyway and tell the golem to
  `git merge origin/main` (never rebase or force-push) once the overlapping PR lands.
- Before claiming a fix "verifies" or "closes" something downstream, check that every link in the
  chain works, ingest included, not only the step I watched.

Related: [[feedback_golem_autonomy_contract]], [[ci-stays-on-github-hosted-runners]].
