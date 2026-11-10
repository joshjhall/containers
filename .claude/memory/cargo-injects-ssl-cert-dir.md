---
name: cargo-injects-ssl-cert-dir
description: "cargo sets SSL_CERT_DIR for test processes, so an empty SSL_CERT_FILE does not simulate a host without CA roots"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: 007a8903-4687-45ac-a174-24cf8c65c237
  modified: 2026-10-28T15:59:33.354Z
---

`cargo test` hands the test binary `SSL_CERT_DIR=/usr/lib/ssl/certs` (cargo's own openssl-probe
leaking into its children), even when the shell never set it. On this host, `SSL_CERT_FILE=<empty>
cargo test` therefore still finds the system roots. The "no CA bundle" failure only shows up when
you run the test binary directly, or when you also set `SSL_CERT_DIR=<empty dir>`.

**Why:** In containers-db #510 this hid 84 root-dependent scanner tests. The issue thought exactly
one was affected, and the parent's "with host roots" contrast step looked like it passed.

**How to apply:** To reproduce a host without roots, set **both** `SSL_CERT_FILE=<empty file>` and
`SSL_CERT_DIR=<empty dir>`. To see what the binary actually receives, use a `--config
'target.<triple>.runner="<script>"'` that dumps `env`. Related to
[[mutation-checks-on-scratch-copies]]: when you restore a mutant with `mv file.orig file`, the old
mtime comes back with it. Cargo then reuses the stale mutant binary, and a later non-source mutant
(such as a fixture) gets credited with kills it didn't make. `touch` the restored file.
