# Rust Version Policy

Rust appears in this project in two roles that move **independently**. Most
confusion about "the Rust version" comes from treating them as one.

| Role | What it is | Where it's pinned | How it moves |
|---|---|---|---|
| **Build chain (MSRV)** | The toolchain `stibbons`, `luggage`, and the other workspace crates are compiled with, and the oldest Rust they promise to build on | `Cargo.toml` `rust-version`, `clippy.toml` `msrv`, every CI `toolchain:`, the `luggage-builder` `FROM rust:X.Y` image | **Deliberate PR only.** Currently **1.99**, held there for at least 6 months (until ~2027-04) |
| **Container Rust** | The Rust a *container* installs for the project it hosts | Dockerfile `ARG RUST_VERSION` (default), `lib/features/rust.sh` fallback, devcontainer `RUST_VERSION` | Default follows the newest stable via auto-patch, **no review hold**. Projects pick any supported version at setup |

`tests/unit/rust-version-sync.sh` enforces each role's internal consistency
and the single link between them: the container default must not be older
than the MSRV (the dev container builds the workspace with it).

## Build chain: MSRV is a decision, not a side effect

Until #1111 every minor Rust release raised the MSRV automatically and then
held the release for a human to approve a change nobody had asked for
(#1110). Now auto-patch never touches the build chain. It actively refuses
to: an auto-patch that edits `rust-version` or `msrv` fails.

Raise the MSRV when the workspace actually needs a newer compiler feature or
fix, not to follow releases:

1. Change `Cargo.toml` `rust-version`.
1. Run `tests/unit/rust-version-sync.sh`. It names every build-chain pin that
   still needs the same X.Y (`clippy.toml`, CI `toolchain:`, the
   `luggage-builder` image).
1. Fix any new lints the newer clippy reports. The non-blocking
   `rust-latest-stable` CI job has been listing them in advance.
1. Say why in the PR. A higher MSRV drops source builds (`cargo install
   stibbons`) on older toolchains. Prebuilt binaries (Homebrew, apt, GitHub
   Release assets) are unaffected.

## Container Rust: any supported version, newest patch wins

A container can install **any Rust from 1.82 up to the newest stable**. That's a
window of at least 2 years, which is the standard for major features.

- **Exact version** (`RUST_VERSION=1.85.1`) installs exactly that release.
- **Minor only** (`RUST_VERSION=1.85`) installs the **newest patch the catalog
  holds** for that minor: `1.85.2` is preferred over `1.85.1` and `1.85.0`.
  luggage resolves this against the vendored catalog (containers-db). There's
  no upstream lookup, so it works offline and never picks a patch the catalog
  lacks.
- **Channel** (`stable`, `beta`, `nightly`) is passed to luggage as a channel.
- **Outside the window** fails the build with a pointer to this page.

The catalog holds **every** release in the window, so exact pins to a
superseded patch keep working. Evidence runs target the newest patch of each
minor, which is what `X.Y` selects.

### The floor

The lower bound is a **fixed floor**, currently **1.82**. It's raised by a
deliberate, reviewed PR, never automatically. Keep it at least ~2 years behind
the newest stable. Raising it:

1. Update `minimum_recommended` in the vendored catalog's `tools/rust/index.json`
   (and upstream in containers-db).
1. Drop versions below the new floor from the evidence matrix (it's derived
   from the catalog, so this follows automatically).
1. Leave older catalog entries in place unless there's a reason to remove
   them. Being installable and being supported are separate questions.

Lowering it is a containers-db backfill:
`scanner backfill rust --from <new-floor>` (or dispatch `scan.yml` with
`backfill_from`).

## Related

- [Automated releases](../operations/automated-releases.md): what auto-patch
  bumps and which changes still hold a release for review
- [Evidence runs](../operations/evidence-runs.md): how `tested[]` rows are
  produced and reconciled
- #1111: the decision record
