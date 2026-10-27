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
- Signature (tier-1 GPG) and checksum (tiers 2–4) verification (see
  [Verification tiers](#verification-tiers))
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

### Two catalogs, one shipped

There are two catalog directories under `crates/luggage/testdata/`, and the
distinction matters:

| Directory           | Role                         | Drift-checked         |
| ------------------- | ---------------------------- | --------------------- |
| `catalog/`          | **Ships.** COPY'd into image | Yes — must mirror upstream |
| `fixtures-catalog/` | Hermetic test input only     | No — exempt by design |

`fixtures-catalog/` backs `crates/luggage/tests/cli.rs`. It carries edge cases
upstream has no reason to hold: an `unsupported` platform cell (to exercise the
exit-2 path), a distinctly-named `rustup-init-musl` method (to prove
per-platform method selection), and `1.84.x` entries (partial-version
resolution). Keeping them out of `catalog/` is what lets the shipped copy be a
strict mirror without weakening those assertions. **Never add a test-only edge
case to `catalog/`** — put it in `fixtures-catalog/`.

### Keeping the vendored catalog in sync

Two paths, depending on what changed:

1. **Version bumps — automated.** `luggage catalog add-version <tool>@<version>`
   ([`crates/luggage/src/catalog_gen.rs`][gen]) clones the tool's newest
   existing entry as a template and rewrites the version strings. The weekly
   auto-patch calls it via
   [`bin/lib/update-versions/updaters.sh`][updaters] so a Dockerfile pin can
   never outrun the catalog (#506). It is additive and idempotent.

   Two gotchas it does **not** handle, both of which the drift check now
   catches:

   - It templates from the **vendored** file, never from upstream. A field
     added upstream is therefore *not* picked up by a bump — it has to be
     mirrored across first, or every future generated entry inherits the gap.
   - It deliberately leaves `default_version` alone. After bumping to a new
     shipped pin, point `default_version` at it by hand.

2. **New tools, and any change to a shared field — by hand.** Copy the entry
   from the sibling `containers-db` checkout verbatim. Only `available[]`,
   `default_version`, and `minimum_recommended` may differ (they describe what
   this catalog holds); everything else must match after canonicalization.

   The comparison is deliberately **canonicalized** (`jq -S`), not
   byte-for-byte: this repo runs `dprint` over its JSON and containers-db does
   not, so a freshly-copied file may need reformatting (trailing newline, key
   indentation) before `just lint-docs` passes. Reformatting is safe — key
   order and whitespace never trip the drift check; only real content
   differences do.

Either way, verify with:

```bash
just db-validate-vendored     # schema + drift + negative fixtures
```

That recipe is the local form; `tests/unit/vendored-catalog.sh` runs the same
checks in CI's existing "Run Tests" job and in the pre-push hook. The drift
half needs only `jq` ([`bin/check-catalog-drift.sh`][drift]) so it keeps
working offline; only the `ajv` schema half needs the network.

A vendored version with no upstream entry is allowed in exactly one case: it is
the tool's live pin (`ARG RUST_VERSION=` in the `Dockerfile`, passed with
`--dockerfile`), which may briefly run ahead of the upstream scanner. That skip
passes with a `::warning::`. Any other vendored-only version fails with
`vendored-only and not the live pin; publish it upstream (containers-db) or
remove it`. The skip used to be unbounded: `1.97.0`–`1.98.1` sat vendored-only
for four months behind a stalled scanner (containers-db#90) while the check
reported `4 skipped, 0 drifted` and stayed green (#1102). To clear the failure,
get the version published upstream and re-mirror it, or delete the vendored
entry.

This check exists because hand-mirroring had already lost real data. None of it
was caught until issue #815 added the comparison:

- every vendored rust entry was missing `install_methods[].invoke.env`
  (`CARGO_HOME`/`RUSTUP_HOME`);
- all twelve `rhel` support-matrix rows were gone, along with the `debian`
  11/12 and several arm64 cells — so `luggage resolve rust --os rhel` failed
  against the shipped catalog;
- the shipped `1.97.x` entries had **no `post_install` at all** on the alpine
  install method, so an Alpine build installed `rustc`/`cargo` without
  `clippy`, `rustfmt`, or `rust-analyzer` — the #740 half-install footgun,
  live on one platform.

That last one also exposed a hole in `crates/luggage/tests/catalog_component_completeness.rs`,
which pooled components across a version's install methods: the complete
debian method masked the empty alpine one. It now checks each method
independently.

Note the recipes read the containers-db checkout from `$CONTAINERS_DB`
(default: the `../containers-db` sibling). Inside these dev containers that
variable is already set to `/opt/containers-db` — the image's own copy of the
vendored snapshot — so override it when running locally:

```bash
CONTAINERS_DB=/workspace/containers-db just db-validate-vendored
```

The unit test avoids the collision by reading `$CONTAINERS_DB_SRC` instead, and
skips cleanly when no upstream checkout is present.

[gen]: ../../crates/luggage/src/catalog_gen.rs
[updaters]: ../../bin/lib/update-versions/updaters.sh
[drift]: ../../bin/check-catalog-drift.sh

## Verification tiers

Every download luggage performs is verified at one of four tiers, declared per
tool in the catalog (`verification.tier`). The tiers mirror the bash model
documented in [Checksum Verification System](checksum-verification.md) — same
numbering, same meaning — so a tool's tier reads identically whichever engine
installs it.

| Tier | What it is                     | Status in luggage                       |
| ---- | ------------------------------ | --------------------------------------- |
| 1    | Signature (GPG / sigstore)     | GPG implemented; sigstore not (#1508)   |
| 2    | Pinned in-repo checksum        | Implemented (#849)                      |
| 3    | Publisher-served checksum file | Implemented                             |
| 4    | Trust-on-first-use (TOFU)      | Implemented                             |

A tier-1 sigstore entry returns a `NotImplemented` error; an unrecognized tier
number is a catalog error. The tier an install was actually verified at is
recorded as `verification_tier` in the install report and evidence row.

### Tier 1 — GPG against a pinned keyring

The signature is checked against an ASCII-armored keyring **committed to the
catalog** (`verification.gpg_keyring`, e.g. `keyrings/nodejs.asc`, resolved
against `--catalog`) — never a key fetched from the publisher at install time,
which would only be as trustworthy as the origin the signature is meant to
protect against. An entry with only `gpg_key_url` is refused, as is a keyring
path that is absolute, contains `..`, or resolves outside the catalog root.
Verification is pure Rust (the `pgp` crate); no `gpg` binary is needed.

Two shapes:

- **Detached** — `signature_url_template` covers the artifact (go's
  `go{version}.linux-{arch}.tar.gz.asc`). The artifact streams from disk
  through the check.
- **Signed manifest** — `checksum_url_template` + `checksum_manifest: true`
  plus a signature over the manifest (node's `SHASUMS256.txt.sig`). Once the
  manifest verifies, the artifact's line is selected by filename and compared
  against the sha256 computed during download, exactly as tier-3 manifest mode
  does.

`pgp` checks only the cryptography, so luggage enforces key policy itself,
judged at the **signature's creation time** (a key that expired or was retired
later still vouches for releases it signed while valid): the signing key or
subkey must carry the sign capability (subkeys: with a valid back-signature),
must not have expired or predate the signature, and must not be revoked. A
"superseded"/"retired" revocation only rejects later signatures; any other
reason — including none — is treated as a compromise and rejects all of them.
Only self-signatures and revocations that verify against the primary count.
Broken hashes (MD5, SHA-1, RIPEMD-160), text-mode and issuer-less signatures
are refused.

### Tier 4 — trust on first use

Tier 4 exists for publishers that serve no checksum at all (PyPA's
`get-pip.py`, for example). Luggage computes the digest from the bytes it just
downloaded and proceeds.

**What that establishes:** the artifact did not change between download and
use within this run.

**What it does not establish:** authenticity. Because the digest is derived
from the downloaded bytes rather than compared against anything the publisher
signed, a machine-in-the-middle, a compromised mirror, or a compromised
upstream would produce a digest that matches perfectly. Tier 4 is the weakest
tier and is not evidence that the artifact is genuine.

Two properties keep it honest:

- **Acceptance is never silent.** Every tier-4 install emits a warning naming
  the tool, version, algorithm, and digest, and stating both the guarantee and
  the non-guarantee above.
- **It fails closed.** The catalog entry must acknowledge TOFU explicitly
  (`tofu: true`), and a malformed digest is rejected rather than accepted.

### Refusing tier 4

Pass `--require-verified-downloads`, or set `REQUIRE_VERIFIED_DOWNLOADS=true`
(or `PRODUCTION_MODE=true`, which it defaults to). The full precedence — the
flag is one-way, and unrecognized values fall through to `PRODUCTION_MODE` — is
documented in
[Environment Variables](../reference/environment-variables.md#require_verified_downloads-precedence).

The refusal happens **before** the download rather than after it, so a strict
run never fetches an artifact it has already decided it cannot verify. It
surfaces as a verification failure — not a "not implemented" error — because it
is a policy refusal of a tier luggage does support.

### Where an acceptance is recorded

An operator auditing which images installed unverified artifacts has two
places to look:

- **`InstallReport.warnings[]`** — the structured warning, with `tier`, `tool`,
  `version`, `algorithm`, `digest`, and `message`. Written to the JSON report
  when luggage runs with `--json-report`, and omitted entirely from the
  serialized report when empty, so an ordinary verified install is unchanged.
- **The evidence row's `notes`** — the warning messages joined with `" | "`.
  `null` when there were no warnings, so a non-empty `notes` on a build is
  itself the signal. Note this is prose today: an audit greps it rather than
  querying it. Making acceptances queryable in the evidence schema is tracked
  separately (#850).

Each warning is also written to the per-feature build log as a `WARNING:` line
(falling back to the tracing logger if that log cannot be opened), so an
acceptance is visible during the build as well as after it.

## Porting recipe

For each feature script (e.g. `node.sh`, `python.sh`):

1. **Verify catalog coverage.** Confirm `tools/<id>/index.json` and at least
   one `versions/<v>.json` exist in `crates/luggage/testdata/catalog/`, that
   the requested version is in `available[]`, and that `post_install[]`
   covers every component the bash script currently adds explicitly. Then run
   `just db-validate-vendored` — a tool newly mirrored from containers-db is
   exactly the case the drift check is there to catch.
2. **Confirm install method support.** Check `install_methods[].platform`
   matches the target distros, and that each method's `method_kind` is one
   luggage implements. `method_kind` is the dispatch discriminant —
   `script-installer`, `binary-tarball`, `package-manager`, or
   `source-build`; the sibling `name` is a label for logs only and selects
   nothing. Rust used `script-installer` (rustup-init); go and node use
   `binary-tarball`; python uses `source-build`, whose ordered
   `build_steps[]` (`./configure …`, `make -j{nproc}`, `make install`) run
   in the extracted source tree as root, streaming output to the feature
   log. Build-dependency packages stay in the method's `dependencies`, not
   in `build_steps`. `package-manager` is not wired yet. If the kind isn't implemented
   yet, that's a luggage-side issue, not a port — and a kind luggage doesn't
   recognise (or a missing `method_kind`) fails as a catalog error rather
   than being inferred from the method name.
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
| `rust.sh` | #407 | Pilot. Channels (`stable`/`beta`/`nightly`) route through `--channel`. cargo dev tools (cargo-watch, mdbook suite) remain in bash. Callers no longer need to `export CARGO_HOME` / `RUSTUP_HOME` before invoking luggage — the validate subprocess now inherits them from the install (#463). |
| `golang.sh` | #811 | First `binary-tarball` port. Needed two luggage additions (#1345): an `{arch}` URL placeholder (go's artifact is `go{version}.linux-{arch}.tar.gz`) and a catalog-declared `version_args` (`go --version` exits 2; go declares `["version"]`). Verified at tier 3 against dl.google.com's digest-only `.sha256` when ported; since #1521 (containers-db#499) tier 1, Google's detached `.asc` against the catalog's pinned `keyrings/golang.asc`. debian/ubuntu amd64/arm64 only, matching the dpkg-only bash script and `docs/reference/supported-platforms.md`; the old script's armhf (`armv6l`) and i386 (`386`) arms covered platforms this project never built, and were dropped — luggage refuses them with "no install method … matches debian/armhf". Go < 1.22 is refused up front (the catalog floor). `git` stays an `apt_install` in bash — it is a runtime need of `go get`, not an install dependency. Follow-ups: containers-db go scanner adapter (containers-db#455), evidence matrix beyond rust (#1341), version-probe timeout (#1344). |
| `node.sh` | #812 | Second `binary-tarball` port — the reuse check — and it **needed no luggage changes** (`tarball.rs` untouched). First use of `.tar.xz` (decompressed in-process; no `xz-utils` needed for the install), `strip_components: 1` into the shared `/usr/local`, and tier-3 **manifest mode** against `SHASUMS256.txt` (`checksum_manifest: true`). node spells amd64 `x64` while `{arch}` substitutes the catalog arch verbatim, so each version carries **two install methods** (`node-tarball-amd64` / `node-tarball-arm64`) with literal URLs, picked by the resolver's first-match arch walk; manifest mode selects the line by that arch-specific filename, so an arch mismatch fails rather than verifying the wrong artifact (`crates/luggage/tests/node_catalog.rs`). The methods list **no `binaries`**: strip-1 already lands node/npm/npx/corepack in `/usr/local/bin`, and listing them would make the link step replace the tarball's `npm`/`npx` symlinks with self-referential ones (source dir == bin root). Default `--version` probe (`node --version` prints `v<version>`). Node < 18 is refused up front (the catalog floor, 18.0.0). Major-only (`22`) and partial (`22.12`) pins resolve via `luggage resolve node`. corepack/yarn/pnpm, the pnpm store-dir, cache dirs and `libatomic1` (a runtime link dep, #983) stay in bash. **Verification:** the bash path tried tier-1 GPG first. luggage now verifies tier 1 against a pinned keyring (#1508); node (signed `SHASUMS256.txt`) and go (detached `.asc`) moved from tier 3 to tier 1 with the catalog flip in containers-db#499, vendored with `keyrings/` in #1521. |
