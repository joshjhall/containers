---
name: Minimal build philosophy
description: Container images and tooldb entries declare only the packages strictly required, dedupe across tools, and clean up build artifacts to keep image size down
type: feedback
originSessionId: f3bdee37-b9b4-4808-a0f5-8265562211bc
---

Builds — image generation, tooldb `system_packages`, feature scripts — must
install only what is strictly necessary, not "convenience" supersets.

**Why:** Image size is a first-order cost in this project. The user has
called this out repeatedly when reviewing tooldb data and feature scripts.
A `build-essential` install pulls in g++, make, dpkg-dev, etc. — most rust
toolchain installs only need `gcc` + `libc6-dev`. Bloat compounds across
features.

**How to apply:**

1. **Pick the smallest package set that satisfies the immediate need.**
   - Need a C linker for cargo? `gcc` + `libc6-dev`, not `build-essential`.
   - Need a TLS-trust store for an `https://` download? `ca-certificates`,
     not the full TLS dev stack.
   - When in doubt, name the specific subpackage and skip the meta-package.
2. **Push transitive needs to the consumer.**
   - If a downstream tool (e.g., a cargo crate that wants `pkg-config`)
     adds the dependency, that downstream tool's `system_packages` declares
     it. The base tool's `system_packages` should not pre-install in case
     someone might want it.
3. **Idempotency by composition.**
   - apt/apk/yum installs are themselves idempotent (re-installing a
     present package is a no-op), but the *list* declared per tool should
     overlap intentionally with other tools — luggage's resolver dedupes
     `system_packages` across the tools it installs in one run, so a
     well-factored catalog never installs `gcc` twice.
4. **Clean up after install.**
   - Feature scripts (and luggage's install engine, when it lands) must
     remove apt cache, yum metadata, build temp dirs, downloaded tarballs
     after use. Cargo / rustup caches under `/cache` are deliberately
     persisted; everything else is ephemeral.
5. **Prefer pre-built binaries over source builds** when the upstream
   publishes signed/checksummed binaries. Source builds drag in compilers
   that can't be removed without breaking debug.

Applies to: `lib/features/*.sh`, `tools/<id>/*.json` `system_packages` /
`post_install` arrays in `containers-db`, future luggage `install` recipes.
