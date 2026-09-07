---
name: prove-unreachability-via-symbol-table
description: "For a CVE inside a third-party prebuilt Go binary, prove unreachability with nm against the shipped artifact rather than reasoning from call sites"
metadata:
  node_type: memory
  type: project
  originSessionId: a8a38858-6fdf-4d53-b563-5266cafd93a0
  modified: 2026-09-07T15:59:27.256Z
---

When a scanner flags a CVE inside a statically-linked third-party Go binary we
download (cosign, kubectl, …), make the reachability argument against **the
shipped artifact's symbol table**, not by enumerating our call sites. Go's
linker does dead-code elimination, so a vulnerable symbol no call path reaches
is usually **absent from the binary entirely** — direct evidence instead of
inference, and it answers "but what about transitive behaviour like registry
auth or KMS backends?" which a call-site survey cannot.

Method (#932, CVE-2026-56854 in cosign's embedded x/crypto):

1. Get the advisory's **exact symbols** from the OSV API, not a summary:
   `curl -s https://api.osv.dev/v1/vulns/<GO-ID>` →
   `affected[].ecosystem_specific.imports[].symbols`.
2. Confirm the binary you inspect **is** the shipped one: `sha256sum` against
   the pin in `lib/base/setup.sh`. Download the other arch and check it too —
   CI scans **amd64** while this dev container is arm64, and DCE is per-build.
3. `nm <binary> | grep -E '<pkg>\.(<Symbol1>|.*<Symbol2>)'` → expect no output.
4. **Paired positive control** — `nm <binary> | grep -c '<pkg>\.'` → non-zero.
   Without it the empty result is indistinguishable from a typo'd grep
   ([[assertions-must-discriminate]]). In #932 the package was linked (253
   symbols) with only the vulnerable server symbols stripped, so the control
   was the whole argument.

Put both commands in the suppression comment so the next reviewer re-runs them
instead of re-deriving the case.

**Check whether an existing suppression is still live before refreshing its
comment.** Grep the *unfiltered* scan output (Trivy's "detailed report" step,
not the filtered blocking one) for the CVE. In #932 two cosign entries had
silently met their own stated removal condition — the embedded Go and grpc had
moved past the TODO's thresholds — so the right edit was deletion, not a
version bump in prose. Tidying the comment would have left the allowlist wrong
in a quieter way.

Note `.trivyignore` entries are **global bare CVE IDs** — not per-binary or
per-image, and with no native expiry (unlike `.osv-scanner.toml`'s
`ignoreUntil`). So an expiry is only a `REVIEW BY:` comment the quarterly sweep
reads, and a suppression proven for one binary silently covers every other
binary in every scanned image. Say so in the entry when a second, older copy of
the same tool exists (`lib/base/cosign-install.sh` ships cosign 3.0.2 for the
kubernetes/docker features).

Related: [[embedded-only-advisory-suppression]] (the `cargo tree -i` analogue
for Rust), [[assertions-must-discriminate]].
