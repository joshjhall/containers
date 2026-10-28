# Dependencies, advisories & version pinning

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when handling osv/cargo-deny advisories, version pins, auto-patch, checksums or signatures.

- [Pre-existing osv vuln blocks push](preexisting-osv-vuln-blocks-push.md) — whole-lockfile osv pre-push gate blocks ALL pushes on any Cargo.lock
- [Embedded-only advisory suppression](embedded-only-advisory-suppression.md) — prove unreachability with `cargo tree -i --target <triple>`
- [Prove unreachability via symbol table](prove-unreachability-via-symbol-table.md) — for a CVE in a prebuilt Go binary, use `nm` on the
- [YAML crate is serde-saphyr](yaml-crate-serde-saphyr.md) — serde_yaml forks (ng/norway/bw) still embed c2rust libyaml
- [cargo update -p churns transitives](cargo-update-p-reresolves-transitives.md) — a pin-only bump re-resolved serde-saphyr's base64; read lock hunks, not --stat
- [npm audit signatures exit-code ambiguity](npm-audit-signatures-exit-code-ambiguity.md) — non-zero means tampering OR can't-run
- [npm-global tools tracked via check-versions](npm-global-tools-tracked-via-check-versions.md) — no dependabot
- [Auto-patch inline checksums](auto-patch-inline-checksums.md) — inline *_SHA256 pins in setup.sh need TOOL_CHECKSUM_REGISTRY_INLINE
- [check-versions scrape pins nonexistent](check-versions-scrape-pins-nonexistent.md) — read downloadable artifact filenames, not scraped HTML
- [update-versions script](update-versions-script.md) — bin/update-versions.sh applies check-versions drift (not just-wired)
- [Rust toolchain pin sync](rust-toolchain-pin-sync.md) — split since #1111: build chain/MSRV frozen (deliberate PR), container default…
- [Octarine publishes as octarine-core](octarine-package-renamed-core.md) — `package =` rename since beta.5
- [Octarine Windows](octarine-windows.md) — Octarine doesn't compile on Windows yet, blocks stibbons Windows CI
- [Librarian signature verification](librarian-signature-verification.md) — #671: build verifies signed release tarball via cosign (not git clone)
- [gpg keyboxd ignores --keyring](gpg-keyboxd-ignores-keyring-flag.md) — under use-keyboxd no .kbx is created even with --keyring; pin an empty common.conf + assert the file
- [known_hosts seeded system-wide](known-hosts-seeded-system-wide.md) — pinned github/gitlab host keys → /etc/ssh/ssh_known_hosts at build
