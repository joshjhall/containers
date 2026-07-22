---
name: jsonc-merge-helper-529
description: jsonc-merge Node CLI (jsonc-parser) for comment-preserving Zed settings.json merges; npm --prefix gotcha
metadata:
  node_type: memory
  type: project
  originSessionId: 0eeadc05-2467-4c23-a4ab-9833c4137fd7
  modified: 2026-07-22T03:29:05.757Z
---

Issue #529 shipped `lib/features/lib/dev-tools/jsonc-merge.js` — a Node CLI that
merges a JSON fragment (stdin) into a JSONC file **preserving comments**, backed
by vendored `jsonc-parser` (zero-dep, MIT; the Zed/VS Code parser). It replaces
the `jq` merge in the Zed first-startup scripts (40-zed-lsp-config /
41-zed-agent-config), which couldn't parse `//` comments and had forced strict
JSON (#519). Merge is **additive + idempotent** (never overwrites an existing
key); empty containers (`env:{}`, `args:[]`) are treated as leaf values so
flattening doesn't drop them.

**npm --prefix gotcha:** node.sh pins the npm global prefix to
`/cache/npm-global` (a droppable cache volume), so `npm install -g` (even with
`--prefix`) can silently no-op or land on the wrong volume. Install to a **fixed
prefix** `/usr/local/lib/jsonc-merge` via `npm install --prefix ... --no-save
--no-package-lock`, and have the helper `require()` jsonc-parser by absolute path
from there (`JSONC_MERGE_LIB` env overrides for tests). Related to
[[cargo-path-missing-luggage-rust]].

Node is an optional runtime guard (dev-tools requires only bindfs), so the
install is `command -v node && command -v npm`-gated; when absent, 40-/41- keep
their print-for-paste fallback. jsonc-parser version pinned + registered in
`bin/check-versions.sh` (source repo `microsoft/node-jsonc-parser`, GitHub
releases; `releases/latest` returns v3.3.1, skipping v4 prereleases).

Behavioral tests that exec node must clear/avoid the [[bash-env-breaks-path-stubs]]
trap: `/etc/bash_env` re-sources bashrc.d and resets PATH in non-interactive
child shells, so PATH stubs for `jsonc-merge` vanish — point the helper via
`JSONC_MERGE_LIB` and invoke `node <helper>` by path rather than relying on PATH.
