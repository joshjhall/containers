---
name: npm-audit-signatures-exit-code-ambiguity
description: "npm audit signatures exits non-zero for BOTH tampering and can't-run; classify on --json invalid[], never on the exit code"
metadata:
  node_type: memory
  type: project
  originSessionId: 5a660d70-0c9f-4e56-8853-4a046932c007
  modified: 2026-08-22T22:24:35.593Z
---

`npm audit signatures` exits **non-zero for two categorically different
events**: a real signature mismatch, and the audit being unable to run at all
(registry 5xx, `ECONNREFUSED`, DNS failure, nothing auditable). Branching on the
exit code — or on a stderr substring — conflates them.

Getting this wrong is bad in both directions: a network blip gets reported as a
supply-chain attack, and an operator who learns to re-run past that message
during outages will wave through the one time it is real.

**Classify on the positive signal.** `--json` returns
`{"invalid":[...],"missing":[...]}` when the audit ran and `{"error":{...}}`
when it could not. Only a populated `invalid[]` is a mismatch (fatal);
everything else is *unverifiable* → warn and skip. This mirrors
`verify_download_or_fail()` in `lib/base/checksum-verification.sh`, which
hard-fails only on rc 1 (verification ran and failed) and falls through when
verification was unavailable — the house rule for this whole class.

Other facts, each probed against the live registry (#814 / PR #816):

- It **cannot** follow `npm install -g` — npm refuses with `EAUDITGLOBAL`
  because the audit needs a `package.json`/`package-lock.json` pair that only a
  **local** tree has. Hence: scratch install → audit → global install *from the
  verified directory*.
- `--ignore-scripts` on the scratch install is load-bearing; without it a
  tampered `postinstall` runs *before* the audit, which is the same as not
  auditing.
- Install the verified **path**, not the pin — re-resolving is a second,
  unaudited fetch, and `-g` is where `postinstall` runs.
- `npm install -g <local-dir>` **packs** the directory and a pack excludes
  `node_modules`, so this covers the full closure only for a **dependency-free**
  package. Re-check with `npm install -g --offline` from the verified tree — it
  fails the moment a byte must be fetched.
- It attests the **registry tarball**, not the unpacked tree: editing a file
  under `node_modules` after install does *not* populate `invalid[]`.
- The registry signs retroactively, so package age does not produce the
  missing-signature case.

Shell gotcha found in the same work: under `set -euo pipefail` (which
`dev-tools.sh` sets), a standalone `dir=$(helper)` assignment aborts the script
on helper failure *before* any following guard runs — making a
"warn and continue" fallback dead code. Make the assignment the `if` condition
itself. See [[cargo-path-missing-luggage-rust]] for another shell-context trap.

Related: [[preexisting-osv-vuln-blocks-push]] (the other supply-chain gate),
[[npm-global-tools-tracked-via-check-versions]] (how these pins get bumped).
