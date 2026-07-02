---
name: librarian-signature-verification
description: "Build verifies the librarian marketplace via a signed release tarball (cosign), not the git tag; signing starts at v0.4.0"
metadata:
  node_type: memory
  type: project
  originSessionId: 9964f0f6-1002-4498-bf45-c73810371dc8
---

Issue #671: the build no longer `git clone`s the librarian marketplace — it
downloads
the **signed release tarball** `librarian-<ver>.tar.gz` + its cosign keyless
Sigstore bundle `.sigstore.json`, runs `cosign verify-blob` (fail-closed,
`exit 1`), then `tar --strip-components=1` into `/opt/librarian`
(`lib/features/claude-code-setup.sh`).

**Why:** the librarian signature (joshjhall/librarian#130) covers a
`git archive` tarball, NOT the git tree we used to clone. So verification forced
switching clone→tarball-fetch. Signing is **additive from v0.4.0** — v0.3.0 and
earlier have no bundle, so the default `LIBRARIAN_REF` had to move v0.3.0→v0.4.0
and `LIBRARIAN_REF` must now be a signed release *tag* (branches/pre-v0.4.0 tags
fail closed).

**How to apply:**

- Reuse `verify_sigstore_signature()` in `lib/base/sigstore-verify.sh` (handles
  `--bundle` + `--certificate-identity` + `--certificate-oidc-issuer`, greps
  `Verified OK`). cosign is installed in base `setup.sh` before features run.
- Trust anchor is pinned + overridable: `LIBRARIAN_SIGNER_IDENTITY` (default
  `<repo>/.github/workflows/release.yml@refs/tags/<ref>`) and
  `LIBRARIAN_SIGNER_ISSUER` (`https://token.actions.githubusercontent.com`).
- This is the **pilot** for signed catalog entries in the planned v5
  containers-db / tooldb work (see [[luggage-tooldb-design]]) — sign-on-release
  / verify-on-consume on a component we fully control.
- Fail-closed test: `test_librarian_unsigned_fails_closed` builds `v0.3.0` and
  asserts `assert_build_fails` (404 on assets → download step exits 1).
