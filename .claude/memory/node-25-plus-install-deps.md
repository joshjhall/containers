---
name: node-25-plus-install-deps
description: Node >= 25 tarballs drop corepack; Node 26 arm64 also needs libatomic1. Stub unit tests caught neither; only a real build did
metadata:
  node_type: memory
  type: project
  originSessionId: a30c922e-b5ff-4d13-8ad8-2315f0d9cbbe
  modified: 2026-09-28T19:43:15.571Z
---

Node.js ≥ 25 release tarballs ship only `node`, `npm`, and `npx`, with no corepack. `node.sh` now
installs a pinned `corepack@${COREPACK_VERSION}` through `lib/features/lib/node/ensure-corepack.sh`
whenever corepack is absent (#983, PR #984).

The Node 26 arm64 binary also links `libatomic.so.1`, which the slim base image doesn't have.
Without it, `node` itself exits 127 — the **same symptom** as the missing corepack. `libatomic1` is
now in node.sh's apt list.

**Why:** the PATH-stub unit tests passed and the fix looked finished. Building `NODE_VERSION=26` for
real was the only thing that exposed the second exit-127 cause. amd64 Node doesn't need libatomic,
so an amd64-only CI run would never catch its removal. That's why
`tests/integration/builds/test_node_current.sh` asserts the package directly.

**How to apply:** when bumping the Node major or changing node.sh deps, run
`./tests/run_integration_tests.sh node_current` (on arm64 if possible). Run it from a clean tree
copy if the repo's `.codegraph` symlink breaks the Docker context
([[symlink-xattr-eloop-is-virtiofs-not-bindfs]]). Open follow-ups are in #985. Related:
[[mock-fidelity-gates-assertions]].
