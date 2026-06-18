---
name: luggage-release-deferred-until-v5
description: "Don't propose a luggage release pipeline (apt/Homebrew/cargo) until v5-of-containers is substantially complete; until then, callers build from source or mount the CI-built binary"
metadata:
  node_type: memory
  type: project
  originSessionId: fe747ba1-dff1-438d-aa8e-64542283ef81
---

Luggage will not get a release pipeline (apt package, Homebrew formula,
`cargo install` distribution channel, etc.) until v5-of-containers is
substantially complete — meaning the bash feature scripts in
`lib/features/` have been largely replaced by luggage + igor + stibbons.

**Why:** Publishing release artifacts creates a stability contract with
downstream consumers. Luggage's CLI surface, error taxonomy, and install
methods are still moving as features port from bash. Locking the
contract before the migration completes would force premature
backwards-compat shims (or churn for consumers). The user explicitly
chose to defer this on 2026-05-14 during evidence-runs design.

**How to apply:**

- When something needs luggage in a container or CI job, build it
  in-CI (`cargo build --release -p luggage`) and mount/copy the
  binary. Pattern used by joshjhall/containers#473 (evidence-runs).
- Do *not* suggest "publish luggage to apt / Homebrew / crates.io"
  in design discussions or issues. If the topic comes up, point at
  this memory and the v5 milestone.
- Do *not* file issues asking for a luggage `.deb`, `.rpm`, or
  Homebrew bottle — these are explicitly deferred.
- The release-pipeline question reopens when [[v5-architecture]] is
  near complete (most of `lib/features/*.sh` replaced).
