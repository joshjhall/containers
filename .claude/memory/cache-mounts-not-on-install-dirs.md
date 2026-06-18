---
name: cache-mounts-not-on-install-dirs
description: Why BuildKit type=cache mounts must NOT cover /cache/cargo or /cache/r in the Dockerfile
metadata:
  node_type: memory
  type: project
  originSessionId: 559b336a-d05a-4ec4-abcd-7b6998955151
---

Do NOT add `--mount=type=cache,target=/cache/cargo` (or `/cache/r`) to the
Dockerfile rust/r RUN layers. For these features `/cache/*` is the **runtime
install location**, not just a build cache:

- rust installs binaries into `/cache/cargo/bin` (symlinked to `/usr/local/bin`,
  also on runtime PATH).
- r installs packages into `/cache/r/library` (runtime `R_LIBS_USER`/`R_LIBS_SITE`
  set in `/etc/R/Renviron.site`).

A `type=cache` mount is discarded when the layer commits → the installed
tools/packages vanish from the final image and symlinks dangle. Cache mounts are
only safe on purely transient paths like `/var/cache/apt`.

**Why:** discovered while implementing #517 — the issue proposed cache-mounting
these paths; doing so would silently break rust-dev/r-dev images.

**How to apply:** to speed up cold builds of cargo tools, use `cargo binstall`
(prebuilt binaries) instead — see [[rust-tools-use-cargo-binstall]]. Rationale is
documented in `docs/architecture/caching/buildkit-cache-mounts.md`.
