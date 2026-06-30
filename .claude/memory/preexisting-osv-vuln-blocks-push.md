---
name: preexisting-osv-vuln-blocks-push
description: "Whole-lockfile osv-scanner pre-push gate rejects every push on any Cargo.lock advisory (the anyhow/RUSTSEC-2026-0190 case is RESOLVED); fix via standalone fix(deps) refresh, not --no-verify"
metadata:
  node_type: memory
  type: project
  originSessionId: f2ff0bfa-031a-4bc5-9965-69b4fad4cea8
---

**RESOLVED 2026-06-30** (commit `09491eb7`, `fix(deps)`): the `anyhow 1.0.102`
/ `RUSTSEC-2026-0190` advisory is cleared. `cargo update` refreshed `Cargo.lock`
to compatible latest versions, which dropped the orphaned
`wit-bindgen`/`wit-component`/`wasm-metadata` chain that was the *only* thing
pulling `anyhow` in — so anyhow left the tree entirely (415 → 389 packages),
not just bumped. `osv-scanner` pre-push now passes with NO `--no-verify`. The
history below is the general pattern, kept because it will recur with the next
advisory.

From ~2026-06-25 to 06-30, `Cargo.lock` on `main` carried `anyhow 1.0.102`,
flagged by the osv-scanner **pre-push** hook (`lefthook.yml` pre-push,
`osv-scanner` block). The hook exits non-zero on any advisory, so it rejected
**every** push from a branch — even one whose diff didn't touch `Cargo.lock`.

**Why:** the gate scans the whole lockfile, not the diff. A real but
pre-existing advisory blocks unrelated work (e.g. a CI-YAML/docs PR).

**Proper fix (do this, not `--no-verify`):** a standalone `fix(deps)` lockfile
refresh. Run `cargo update -p <crate>` (or full `cargo update` to also shed
orphaned transitive chains), then verify `cargo build/test/clippy --workspace`,
`cargo deny check advisories`, and `osv-scanner --lockfile=Cargo.lock` are all
clean before committing under the `deps` scope. Check whether the crate is a
direct dep first: `cargo tree -i <crate>` printing "nothing to print" means it's
orphaned/transitive and a refresh may remove it outright. Do NOT bundle a
lockfile bump into an unrelated feature PR.

**Stopgap only (when you can't fix the lockfile in that PR):** if a push is
rejected solely by a pre-existing advisory and your diff does not modify
`Cargo.lock`, confirm `git diff origin/main...HEAD --name-only | grep -i cargo`
is empty and the same version is already on `origin/main`, then push with
`git push --no-verify`. CI runs the full suite regardless, so the gate is not
lost. The weekly `security-scan.yml` tier (see [[evidence-run-arch-aware]]
sibling CI tiers) is what's meant to surface these.
