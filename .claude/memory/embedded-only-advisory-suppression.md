---
name: embedded-only-advisory-suppression
description: An advisory on an embedded-target-only crate needs cargo tree per shipped triple to prove unreachability — and suppression in BOTH deny.toml and .osv-scanner.toml
metadata:
  type: project
---

`cargo audit` / `cargo deny` / `osv-scanner` read the lockfile **without target
predicates**, so they flag crates that no target we build ever compiles. A
dependency declared only under embedded `cfg` predicates still appears.

Worked example: RUSTSEC-2023-0089 (`atomic-polyfill` unmaintained, upstream
archived, no successor version) entered via
`octarine -> phonenumber -> postcard -> heapless 0.7`. heapless declares
atomic-polyfill only for `thumbv6m-none-eabi`, `riscv32*`, `avr`, `xtensa`.

**Prove unreachability, don't assert it.** `cargo tree -i <crate>` per shipped
triple prints nothing when the crate is genuinely unreachable; it resolves only
under `--target all`. Check every triple in `release-binaries.yml` plus the
glibc container host. Also confirm there is no upgrade path from our side
before suppressing (here: postcard's newest release still pins heapless ^0.7).

**Suppress in both files or the gates disagree.** `deny.toml` `[advisories]
ignore` and `.osv-scanner.toml` `[[IgnoredVulns]]` are enforced by different
hooks (pre-push runs both; `just security-scan` runs all three scanners). One
without the other leaves a red gate that looks like a config bug.

**Rejected alternative worth knowing about:** `[graph] targets = [...]` in
deny.toml restricts the walk to real triples and drops the finding without any
ignore entry — cleaner-looking, but it also silenced the `webpki-root-certs`
license exception and the `r-efi` skip, trading one accurate suppression for
two blind spots. Prefer the narrow per-advisory ignore.

Verify each new skip/ignore is load-bearing by commenting it out and confirming
*that* check fails — see [[assertions-must-discriminate]]. Related:
[[preexisting-osv-vuln-blocks-push]], [[skips-render-as-passes]],
[[octarine-package-renamed-core]].
