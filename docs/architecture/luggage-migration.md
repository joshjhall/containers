# Luggage Migration Playbook

The bash feature scripts in `lib/features/*.sh` duplicate installer logic that
now lives in [`crates/luggage/`](../../crates/luggage/) plus the
[`containers-db`](https://github.com/joshjhall/containers-db) tool catalog.
This document is the recipe for porting a feature script to the luggage shim.
Pilot port: `lib/features/rust.sh` (issue #407).

For the why and the locked design choices, see
`.claude/memory/luggage-tooldb-design.md`. For the install engine internals,
see `crates/luggage/src/installer/`.

## What moves to luggage

- Upstream download URL templating
- Checksum fetch + tier-3 verification
- Installer execution under the target user (`su` wrapping)
- Catalog-declared `post_install` steps (e.g., `rustup component add` for rust)
- System-package dependency installation (the catalog's `dependencies[]`)

## What stays in bash

- Cache directory creation and ownership (`/cache/<tool>`)
- `bashrc.d/` fragments that export tool environment for runtime shells
- `/etc/environment` PATH contributions (`add_to_system_path`)
- `cargo install --locked` of dev tools — they're not in the catalog yet
- `apt_install` of build-time dependencies the catalog doesn't declare
  (e.g., `build-essential pkg-config` for cargo to link rust binaries)
- Feature logging (`log_feature_start`, `log_feature_summary`, `log_feature_end`)
- Final ownership fix-up and `log_feature_instructions`

The split is deliberate: luggage owns "what version of tool X installs and how
to verify it"; bash owns "how this image wires the tool into the shell
environment." The boundary stays at the install method's exit.

## Catalog source (interim)

Production builds copy `crates/luggage/testdata/catalog` into the image at
`/opt/containers-db` via `COPY` from the `luggage-builder` stage. This keeps
builds reproducible from `Cargo.lock` with no build-time network fetch.

A follow-up issue will swap this for a pinned `containers-db@vX.Y.Z` snapshot
(per the design memo's "main repo pins a snapshot SHA" decision). Until then,
the testdata is load-bearing for production — update it whenever a feature
needs a version the testdata doesn't list.

## Porting recipe

For each feature script (e.g. `node.sh`, `python.sh`):

1. **Verify catalog coverage.** Confirm `tools/<id>/index.json` and at least
   one `versions/<v>.json` exist in `crates/luggage/testdata/catalog/`, that
   the requested version is in `available[]`, and that `post_install[]`
   covers every component the bash script currently adds explicitly.
2. **Confirm install method support.** Check `install_methods[].platform`
   matches the target distros, and that `installer/methods/<kind>.rs`
   implements the variant. Rust used `script-installer` (rustup-init); other
   features may need `tarball-extract` or `apt-deb`. If the variant isn't
   implemented yet, that's a luggage-side issue, not a port.
3. **Strip the inline install.** Remove from the bash script: source lines
   for `checksum-fetch.sh` / `download-verify.sh` / `checksum-verification.sh`
   (no longer needed in this script), the download `curl` invocation, the
   `verify_download_or_fail` call, the installer `su -c` block, and any
   explicit component-add lines covered by catalog `post_install`.
4. **Add the luggage call.** Replace with one invocation:

   ```bash
   log_command "luggage install <tool>@${TOOL_VERSION}" \
       /usr/local/bin/luggage install "<tool>@${TOOL_VERSION}" \
           --catalog "${CONTAINERS_DB:-/opt/containers-db}" \
           --user "${USERNAME}" \
           --cache-root /cache \
           --log-dir /var/log/luggage
   ```

   Handle channel names (`stable`/`beta`/`nightly`) with a separate branch
   that uses `--channel "$value"` and bare `<tool>`. `set -euo pipefail`
   already gives fail-fast on luggage's non-zero exit — do not add `|| true`.
5. **Run the smoke and production tests.**
   - `just test-integration-one luggage_rust` — the fixture-only luggage
     smoke test (renamed for each feature once you add yours).
   - `just test-integration-one <feature>` — the production-path
     integration test that exercises the real `Dockerfile` build.
6. **Update this doc.** Add the feature to the "Ported features" list below.
   If the port surfaced a luggage-side limitation (channel resolution,
   unsupported install method, missing post_install variant), file a
   follow-up issue and link it.

## Ported features

| Feature | Issue | Notes |
| --- | --- | --- |
| `rust.sh` | #407 | Pilot. Channels (`stable`/`beta`/`nightly`) route through `--channel`. cargo dev tools (cargo-watch, mdbook suite) remain in bash. |
