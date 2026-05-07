# Base Images for v5 Evidence Runs

> **Status**: design tracker — see [issue #422](https://github.com/joshjhall/containers/issues/422).
> Pilot tuple `debian/12/amd64` ships with this spec; remaining tuples are
> filed as sub-issues per [Decomposition](#decomposition).

This directory tree defines the minimal hardened base images that v5
**evidence runs** install tools onto for per-tool CI testing. It exists as a
parallel image lineage to the user-facing dev-container `Dockerfile` at the
repo root — the dev container has a wide tool surface by design; evidence
base images are deliberately minimal so the tool under test is the only
major variable.

## Why this exists

[`containers-db#1`](https://github.com/joshjhall/containers-db/issues/1)
records `image_digest` per tool run so that "we tested rust 1.95.0 on
debian-12 amd64" is reproducible. That field is meaningless without a
known, hardened base image to anchor it to. Two failure modes this
directory closes:

1. **Non-reproducible attack surface.** Without a published base image,
   contributors building "the test image" independently get different
   kernel defaults, different dropped capabilities, and different
   `/etc/shells` state. A green CI run on an ad-hoc image proves nothing.
2. **Hardening was debian-only.** v4's hardening (`lib/base/shell-hardening.sh`,
   `lib/base/user.sh`, `lib/base/user-env.sh`) was scattered shell with no
   spec. It cannot be consumed by a multi-distro, multi-arch CI matrix as-is.

## Directory structure

```text
base-images/
  README.md                              # this file
  debian/
    hardening.sh                         # per-distro hardening library
    12/
      amd64/Dockerfile                   # pilot tuple
      arm64/Dockerfile                   # filed as sub-issue
    13/
      amd64/Dockerfile                   # filed as sub-issue
      arm64/Dockerfile                   # filed as sub-issue
  alpine/
    hardening.sh                         # filed as sub-issue
    3.21/
      amd64/Dockerfile
      arm64/Dockerfile
  rhel/
    hardening.sh                         # filed as sub-issue (UBI base)
    9/
      amd64/Dockerfile
      arm64/Dockerfile
.github/workflows/
  build-base-images.yml                  # build + publish per-tuple
```

Every `(distro, distro_version, arch)` triple is one Dockerfile. The
hardening library is per-distro (one `hardening.sh` shared across all
versions and arches of that distro) — distro-version differences are
rare enough that conditionals inside `hardening.sh` are cheaper than
forking the file.

## Hardening invariants

Every base image, regardless of distro/version/arch, MUST enforce:

| Invariant                         | v4 source                                   | v5 enforcement                                                                                                         |
| --------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Non-root user (UID/GID 1000)      | `lib/base/user.sh`                          | `<distro>/hardening.sh` `create_user`                                                                                  |
| `/etc/shells` restricted to bash  | `lib/base/shell-hardening.sh::restrict_shells` | `<distro>/hardening.sh::restrict_shells` (CIS Docker Benchmark 4.1, NIST 800-53 AC-6, PCI DSS 2.2.4, FedRAMP CM-7) |
| Service users → `nologin`         | `lib/base/shell-hardening.sh::harden_service_users` | `<distro>/hardening.sh::harden_service_users` (production mode)                                                |
| Passwordless sudo OFF by default  | `lib/base/user.sh` `ENABLE_PASSWORDLESS_SUDO=false` | `<distro>/hardening.sh::configure_sudo` (default secure)                                                       |
| `USER ${USERNAME}` final layer    | `Dockerfile:609`                            | Each per-tuple `Dockerfile` ends with `USER ${USERNAME}`                                                               |

These invariants are exercised by `tests/unit/base-images-structure.sh`,
which fails the build if any tuple drops one.

### Per-distro variation

Hardening is not a shim — the implementations diverge for genuine
technical reasons:

- **debian/ubuntu**: `apt-get`, `useradd --uid` / `groupadd --gid`,
  `usermod -aG sudo`, `/etc/sudoers.d/`, glibc.
- **alpine**: `apk add`, `adduser -D -u`, `addgroup -g`, `doas` instead of
  `sudo` (or `sudo` from `apk`), musl libc — different `nologin` path
  (`/sbin/nologin` only), different default shell (`/bin/ash`).
- **rhel/ubi**: `dnf` (microdnf for UBI minimal), `useradd`, `usermod`,
  SELinux contexts must be set during image build (not at runtime),
  `wheel` group convention instead of `sudo`.

`<distro>/hardening.sh` encapsulates that variation behind a stable
interface — every per-distro library exports the same four functions:
`create_user`, `restrict_shells`, `harden_service_users`,
`configure_sudo`.

### Architecture-specific notes

amd64 and arm64 ship the same hardening surface today. Differences that
may surface as we expand:

- **arm64**: `setcap` availability differs by base image; some kernel
  capability defaults differ. If a distro ships an arm64 image without
  `libcap`, the per-tuple Dockerfile must `apt-get install libcap2-bin`
  (or distro equivalent) before invoking hardening.
- **ppc64le / s390x**: not currently in scope. Add only if a real
  consumer asks.

## Registry & naming convention

Published images use **one image name per tuple**:

```text
ghcr.io/joshjhall/containers/base-<distro>-<distro_version>-<arch>:<image_version>
```

Examples:

```text
ghcr.io/joshjhall/containers/base-debian-12-amd64:v1.0.0
ghcr.io/joshjhall/containers/base-debian-12-amd64:latest
ghcr.io/joshjhall/containers/base-alpine-3.21-arm64:v1.0.0
```

### Why one image-name per tuple

Three options were considered (see issue #422 design thread). The
chosen convention pays a "many image names" cost upfront in exchange for:

- **Clean semver per tuple.** `:latest`, `:v1`, `:v1.2`, `:v1.2.0` all
  carry one meaning — the *image lineage version*. No tag-parsing in
  consumers.
- **Tooling simplicity.** `cosign sign`, `syft`, `trivy`, and
  `docker pull` operate cleanly on a single image reference; nothing has
  to know that "the part of the tag after `-arm64-`" is the version.
- **containers-db catalog clarity.** `image_ref` is the full repository
  path; `image_digest` is the sha256. A human reading the catalog can
  identify the tuple from `image_ref` alone — no decoding needed.
- **Independent retention.** Old `base-debian-11-*` images can be
  expired without touching `base-debian-12-*`.

The cost is registry browsing — listing "all base images" requires a
name prefix filter rather than a single tag listing. That's acceptable.

### Versioning the image lineage

`<image_version>` is **not** the v4 `VERSION` file (which tracks the
dev-container image). It is an **independent semver** for the
hardening + spec lineage. Bumps:

- **patch**: hardening tweaks, dependency-only changes
- **minor**: new optional behavior, new env-var knobs (additive)
- **major**: change in default invariants (e.g., flipping
  `PRODUCTION_MODE` default), removed knobs

Initial version: **v1.0.0**, set when the first tuple ships signed.

The image-lineage version lives in
`base-images/VERSION` (this directory) so it bumps independently of the
top-level `VERSION` file.

## Build / publish workflow

`.github/workflows/build-base-images.yml` builds every Dockerfile in the
matrix and, on `push: [main, tags v*]`, publishes signed images.

**Per build**:

1. `hadolint` lints the Dockerfile (warning threshold blocks).
2. `docker/build-push-action@v6` builds for the tuple's platform.
3. `trivy` scans the image (CRITICAL blocks; HIGH warns).
4. On `push`: `cosign sign --yes` (keyless OIDC), `syft -o cyclonedx-json`,
   `cosign attest --type cyclonedx`. SBOM and digest uploaded as release
   assets.
5. `image_ref` and `image_digest` are written to a build summary so
   evidence-run consumers can reference them.

PRs build and scan but **do not** publish. The publish step is gated
on `github.ref == 'refs/heads/main'` or a `v*` tag.

## v4 → v5 migration story

| What                                 | v4 location                                         | v5 location                                        | Status      |
| ------------------------------------ | --------------------------------------------------- | -------------------------------------------------- | ----------- |
| `/etc/shells` restriction            | `lib/base/shell-hardening.sh::restrict_shells`      | `base-images/<distro>/hardening.sh::restrict_shells` | **kept**, generalized |
| Service-user `nologin`               | `lib/base/shell-hardening.sh::harden_service_users` | `base-images/<distro>/hardening.sh::harden_service_users` | **kept**, generalized |
| Non-root user creation               | `lib/base/user.sh`                                  | `base-images/<distro>/hardening.sh::create_user`   | **kept**, generalized; UID/GID conflict resolution simplified (base images own the slot, no need to scan) |
| Modular `~/.bashrc.d`                | `lib/base/user.sh`                                  | n/a                                                | **dropped** for evidence base — too dev-container-specific |
| SSH agent persistence in `.bashrc`   | `lib/base/user.sh`                                  | n/a                                                | **dropped** for evidence base — not needed for non-interactive tool installs |
| `node_modules/.bin` PATH helper      | `lib/base/user.sh`                                  | n/a                                                | **dropped** — feature-specific, belongs in dev container only |
| `/cache` mount permission            | `lib/base/user.sh`                                  | n/a                                                | **dropped** — evidence runs do not mount `/cache`; tools install fresh per run |
| Passwordless-sudo gating             | `lib/base/user.sh` `ENABLE_PASSWORDLESS_SUDO`       | `base-images/<distro>/hardening.sh` (default OFF) | **kept**, default flipped to OFF (production-safe) |
| `os-validation.sh` (debian-only check) | `lib/base/os-validation.sh`                       | n/a                                                | **net-new replacement**: per-distro hardening is the explicit branch — no runtime "which distro?" check needed |
| Cosign signing + SBOM                | `.github/workflows/ci.yml` (release job)            | `.github/workflows/build-base-images.yml`          | **kept**, pattern copied per-tuple |

**Net-new in v5**:

- Per-distro hardening libraries with a stable function interface.
- Per-tuple Dockerfiles published independently.
- One image name per tuple (vs. v4's tag-suffix variant convention).
- An independent `base-images/VERSION` lineage.

**Explicitly NOT changing**:

- The dev-container `Dockerfile` at the repo root. It keeps its v4
  baseline. v4 hardening files in `lib/base/` stay as-is — the v5 base
  images do not consume them.

## Decomposition

Sub-issues filed against this design tracker, organized by tier:

### Tier 1 — Active matrix (file as sub-issues now)

| Tuple                  | Sub-issue                                                      |
| ---------------------- | -------------------------------------------------------------- |
| debian-12 amd64        | **pilot, this PR**                                             |
| debian-12 arm64        | (sub-issue: filed)                                             |
| debian-13 amd64        | (sub-issue: filed)                                             |
| debian-13 arm64        | (sub-issue: filed)                                             |
| alpine-3.21 amd64      | (sub-issue: filed)                                             |
| alpine-3.21 arm64      | (sub-issue: filed)                                             |
| ubi-9 amd64            | (sub-issue: filed)                                             |
| ubi-9 arm64            | (sub-issue: filed)                                             |

### Tier 2 — Likely-needed soon (defer to v2)

- debian-11 amd64+arm64 (Standard EOL was 2026-06-30; LTS until 2028 — keep on supported-with-warnings basis until LTS expires)
- ubuntu-22.04 LTS amd64+arm64 (LTS until 2027)
- ubuntu-24.04 LTS amd64+arm64 (LTS until 2029)
- ubi-10 amd64+arm64 (when GA)

### Tier 3 — Evaluate later

- amazon-linux-2023 amd64+arm64 (AWS Lambda / Graviton evidence target)
- nixos minimal amd64+arm64 — has its own appeal: native reproducibility,
  and its config language may inform our own (separate exploratory issue,
  not a base-image sub-issue)
- alpine-3.22 amd64+arm64 (when out)
- opensuse leap (enterprise SUSE shops)

### Out of scope

- Arch Linux (rolling — hard to pin a reproducible base)
- Fedora (community cadence; UBI is the right enterprise pick)
- Windows containers (entirely different attack surface — separate spec)
- ppc64le / s390x (only if a concrete consumer asks)

## How evidence runs consume these images

Once [#405](https://github.com/joshjhall/containers/issues/405) (luggage
install executor — merged) and #408 (tiered CI cadence) are both wired up,
a per-tool evidence run looks like:

```bash
docker run --rm \
  ghcr.io/joshjhall/containers/base-debian-12-amd64:v1.0.0 \
  /bin/bash -c "luggage install rust@1.95.0 && rustc --version"
```

The run captures:

- `image_ref`: `ghcr.io/joshjhall/containers/base-debian-12-amd64`
- `image_digest`: the resolved `sha256:...` (from `docker inspect`)
- `tool`: `rust`
- `tool_version`: `1.95.0`
- exit status, install duration, version output

These fields populate containers-db#1's `tested[]` schema. Because the
image is signed (cosign) and has an SBOM (syft), the evidence is
reproducible: any reviewer can pull the same digest, install the same
tool, and confirm the result.

## Contributing a new tuple

When implementing a sub-issue:

1. Create `base-images/<distro>/<distro_version>/<arch>/Dockerfile`
   using the pilot at `base-images/debian/12/amd64/Dockerfile` as
   reference.
2. If the distro is new, write `base-images/<distro>/hardening.sh`
   exporting `create_user`, `restrict_shells`, `harden_service_users`,
   `configure_sudo` — same interface as the debian library.
3. Register the new tuple in the matrix block at the top of
   `.github/workflows/build-base-images.yml`.
4. Add the tuple to the assertion list in
   `tests/unit/base-images-structure.sh`.
5. Run `just lint` and `just test` locally before opening a PR.
6. The first publish bumps `base-images/VERSION` (minor for net-new
   tuple; patch for tweaks to existing).

## Adjacent issues

- [#50, #137](https://github.com/joshjhall/containers/issues) (AppArmor /
  SELinux profiles, currently `status/on-hold`) — base images are the
  substrate they would be applied to. They may unhold once Tier 1 ships.
- A future containers-db issue may promote base images to a first-class
  catalog kind (`kind: "base_image"`) parallel to how `system_package`
  was promoted in containers-db#4. Deferred until real images exist and
  we know whether opaque `image_digest` strings are sufficient.
