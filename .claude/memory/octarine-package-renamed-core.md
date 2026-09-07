---
name: octarine-package-renamed-core
description: Octarine publishes as `octarine-core` since v0.3.0-beta.5; the dep spec needs `package =` while the import path stays `octarine`
metadata:
  type: project
---

Since octarine v0.3.0-beta.5 the crate publishes as **`octarine-core`** — the
bare `octarine` name on crates.io belongs to an unrelated crate (upstream
issue #655). The `[lib] name` is still `octarine`, so package and lib names
differ deliberately.

Any version bump crossing beta.5 must add the rename to the dep spec, or
resolution fails with a confusing "no matching package named `octarine`":

```toml
octarine = { package = "octarine-core", git = "...", tag = "v0.3.0-beta.7", features = ["full"] }
```

`use octarine::` is unaffected in either direction — the rename is invisible to
call sites, which is exactly why it is easy to miss when reading source rather
than the manifest.

Two more traps on the same upgrade path (v0.3.0-beta.3 -> beta.7, merged as
PR #928 on 2026-09-07):

- **beta.6 raised octarine's MSRV to 1.97.** Fine while this workspace is on
  1.98, but a future beta could outrun us. See [[rust-toolchain-pin-sync]].
- **`deny.toml` needs semantic maintenance, not a version-string bump.**
  Octarine's own dep modernization moved its AEAD/KDF stack to the digest 0.11
  generation, so the long-standing "octarine's AEAD stack" skip reasons became
  false: the digest 0.10 generation now arrives via two *leaf* crates instead
  (`bs58 0.5` -> sha2 0.10, `ml-kem 0.3` -> sha3 0.11). Re-derive each skip's
  cause with `cargo tree -i <crate>` rather than editing the version bound.

Octarine is declared in `crates/stibbons/Cargo.toml` but not yet called from
any Rust source, so upgrades are currently manifest/lockfile-only and no API
change is reachable. That stops being true the moment the first `use
octarine::` lands. See [[v5-architecture]], [[octarine-windows]].
