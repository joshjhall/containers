---
name: dist-profile-scoping
description: "stibbons size tuning lives in [profile.dist], not workspace-wide [profile.release]"
metadata:
  node_type: memory
  type: project
  originSessionId: 29db9e5f-0569-49d6-9022-254269882a19
---

Stibbons distribution-binary size tuning (`strip`, `lto = "thin"`,
`codegen-units = 1`, `opt-level = "s"`) lives in a dedicated `[profile.dist]`
(`inherits = "release"`) in the root `Cargo.toml`, NOT workspace-wide
`[profile.release]` (#700, follow-up to #286/#690).

**Why:** a workspace-wide `[profile.release]` silently forces the size tuning on
every crate's release build, slowing CI-only binaries (luggage, record-evidence,
containers-common) and stripping their debug symbols for no benefit.

**How to apply:**

- Distribution builds use `cargo build --profile dist -p stibbons`; a custom
  profile outputs to `target/<triple>/dist/` (not `.../release/`), so
  `release-binaries.yml` packaging paths read from `dist/`.
- A `[profile.release.package.stibbons]` override CANNOT express `lto` — it's a
  profile-root-only setting — which is why a dedicated profile is required
  rather than a per-package override.
- Don't reintroduce a bare `[profile.release]` for stibbons size; put new
  distribution-only tuning under `[profile.dist]`.

Relates to [[stibbons-binary-distribution]].
