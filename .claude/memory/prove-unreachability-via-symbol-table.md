---
name: prove-unreachability-via-symbol-table
description: "For a CVE inside a third-party prebuilt Go binary, prove unreachability with nm against the shipped artifact rather than reasoning from call sites"
metadata:
  node_type: memory
  type: project
  originSessionId: a8a38858-6fdf-4d53-b563-5266cafd93a0
  modified: 2026-09-07T17:42:40.164Z
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
binary in every scanned image. **State in the entry how many copies of the tool
the repo ships**, so the next reader can tell whether the proof still spans all
of them.

**Then check whether the second copy is real.** #932 flagged
`lib/base/cosign-install.sh` as shipping a second, older cosign (3.0.2) for the
kubernetes/docker features, and #935 was filed to prove or narrow the
suppression against it. It did not exist: `setup.sh` installs cosign in the
same Docker stage *before* the feature scripts, and `install_cosign()` opened
with `command -v cosign && return 0`, so the download never ran. The fix was to
delete the dead path (#938), not to prove a second binary. Establish that a
rival install is *reachable* — same stage? guarded? actually invoked? — before
building an argument about its symbol table, or the whole exercise is against
a binary nobody ships.

Related: [[embedded-only-advisory-suppression]] (the `cargo tree -i` analogue
for Rust), [[assertions-must-discriminate]].
