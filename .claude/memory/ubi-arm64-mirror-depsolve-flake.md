---
name: ubi-arm64-mirror-depsolve-flake
description: "rhel-9-arm64 base-image build fails on transient microdnf glibc depsolve (partial UBI mirror sync); retry, don't code-fix"
metadata:
  node_type: memory
  type: project
  originSessionId: 1789110d-51a0-4c80-bb89-99f3777f0ebc
  modified: 2026-07-22T04:01:58.640Z
---

Release `Build Base Images` can fail on **`Build rhel-9-arm64` only** with a
`microdnf upgrade` depsolve error like:

```text
nothing provides glibc-common = 2.34-272.el9_8 needed by
glibc-minimal-langpack-2.34-272.el9_8.aarch64 from ubi-9-baseos-rpms
```

**Cause:** Red Hat's UBI aarch64 mirror is momentarily **partially synced** — a
newer `glibc`/`glibc-minimal-langpack` (e.g. `2.34-272/274.el9_8`) is published
but the matching `glibc-common` for aarch64 hasn't landed yet, so `microdnf
upgrade -y` can't resolve. The amd64 leg passes (its mirror is consistent);
only arm64 hits the race. Seen on v4.19.18 (2026-07-22, run 29889641012).

**Fix:** it's a transient upstream flake, **not** a repo bug — retry with
`gh run rerun <id> --failed` once the mirror catches up (minutes to hours). Do
NOT pin glibc versions or edit the base Dockerfile to chase it. Unrelated to
whatever diff triggered the release (here: librarian v0.8.0 + #759, which don't
touch RHEL packages).

Related: [[ubi-image-tag-verify-registry]], [[base-image-publish-path-trivy-arch]].
