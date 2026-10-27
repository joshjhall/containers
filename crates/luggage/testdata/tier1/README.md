# Tier-1 test material

Real publisher keyrings and signatures for the `real_*` tests in
`src/installer/verify/tier1_tests.rs`. Nothing here is trusted at install
time; the production keyrings live in the catalog (`keyrings/*.asc`,
containers-db#486).

| File | Source |
| --- | --- |
| `nodejs.asc` | `gpg --export --armor` of `lib/gpg-keys/nodejs/keyring` (nodejs/release-keys @ 481637f8, fetched 2026-10-25) |
| `node-v22.23.4-SHASUMS256.txt{,.sig}` | `https://nodejs.org/dist/v22.23.4/` |
| `golang.asc` | copy of `lib/gpg-keys/golang/keys/google-linux-signing-key.asc` |
| `go1.27.3.linux-amd64.tar.gz.asc` | `https://dl.google.com/go/` (the 70 MB tarball it covers is not committed) |

Both signatures were cross-checked with `gpg --verify` (VALIDSIG
`5BE8A3F6C8A5C01D106C0AD820B1A390B168D356` and
`0E225917414670F4442C250DFD533C07C264648F`).
