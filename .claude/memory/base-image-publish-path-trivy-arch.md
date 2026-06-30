---
name: base-image-publish-path-trivy-arch
description: Base-image PR CI scans a local single-arch image; only push-to-main scans the remote multi-arch digest — arm64 Trivy bugs are latent on PRs
metadata:
  node_type: memory
  type: project
  originSessionId: d391ee17-3d6d-49e5-b73c-9bf2cbda689c
---

`build-base-images.yml` has TWO scan paths, and a green PR does NOT prove the
publish path works:

- **PR path**: builds the image with "load locally for scan" → Trivy scans a
  single-arch local image by tag, finds it directly. Always passes regardless
  of arch.
- **Publish path (push to main)**: builds + pushes a multi-arch manifest, then
  Trivy scans the **remote manifest-list digest** (`${IMAGE}@${DIGEST}`). With
  no platform hint Trivy defaults to `linux/amd64` and fails on arm64-only
  tuples: `no child with platform linux/amd64 in index ...`.

So every arm64 base tuple (#432/#434/#436) merged green on its PR, then turned
`main` red on the merge run. Fixed in #663 by setting
`TRIVY_PLATFORM: ${{ matrix.platform }}` on the Trivy scan step (trivy-action
has no platform input, but its README documents passing unsupported flags via
`TRIVY_*` env vars; `--platform` → `TRIVY_PLATFORM`).

**It is NOT just Trivy — every publish-path tool that pulls image content by
digest has the same bug.** After the Trivy fix, the build advanced and `syft`
(SBOM gen) failed identically; fixed with `syft --platform "${PLATFORM}"`
(#664). The publish path is serial (Trivy → cosign sign → syft → cosign
attest), so fixing one tool just exposes the next — fix them ALL at once.
`cosign sign`/`attest` operate on the index by digest and don't pull a platform
child, so they're fine; only the content-pulling scanners (Trivy, syft) need
`--platform`. When touching this path, grep for every digest consumer
(trivy/syft/crane/skopeo/docker pull) and give each the matrix platform.

**How to apply:**

- When adding/altering a base-image tuple (esp. a NEW arch or distro), the PR
  going green is NOT sufficient. Watch the **post-merge push-to-main**
  `Build Base Images` run too — that's the only run that exercises publish,
  sign (cosign), SBOM (syft), and the remote-digest Trivy scan.
- More generally: if a workflow step is gated `if: ...publish == 'true'` or
  `if: github.event_name == 'push'`, PR CI never runs it. Check the merge run.
- cosign/syft handle multi-arch digests natively (they sign/scan the index or
  the right child); only Trivy needed the explicit platform.

Relates to [[ubi-image-tag-verify-registry]], [[ubi-minimal-no-nologin-use-false]],
[[alpine-hardening-no-coreutils-paths]] — all base-image facts that only the
real CI build surfaces, never local lint.
