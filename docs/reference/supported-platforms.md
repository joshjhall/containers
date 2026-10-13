# Supported Platforms

This page is the single list of OS versions that tools are supported, built,
and evidence-tested on, and the rule that picks them. Every version is built
for **amd64 and arm64**.

| Distro | Versions | Rule | Base image |
|---|---|---|---|
| Debian | **12**, **13** | The current stable releases still in Debian security or LTS support | `debian:<v>-slim` |
| Ubuntu | **24.04**, **26.04** | The two most recent **LTS** releases | `ubuntu:<v>` |
| Alpine | **3.22**, **3.23**, **3.24** | The **three newest** releases | `alpine:<v>` |
| RHEL | **9**, **10** | The two current majors, on UBI minimal | `ubi<v>/ubi-minimal:<newest minor>` |

That's 9 OS versions × 2 architectures = **18 tuples**, each a base image under
`base-images/<distro>/<version>/<arch>/` and a `support_matrix` row per tool
in containers-db.

## Why these rules

- **Alpine: three newest.** Alpine releases every ~6 months and supports each
  for ~2 years, so about four releases are in support at any time. The three
  newest cover all of that window except the release nearest its EOL, without
  carrying a version that's weeks from end of life.
- **Ubuntu: two LTS.** Interim releases live 9 months, too short to be worth
  evidence. Two LTS releases (5-year support each) mirror how Debian carries
  two stables, and capture dependency differences across a generation.
- **RHEL: two majors.** Each major lives ~10 years and enterprises lag, so the
  previous major stays important long after the new one ships. UBI minimal is
  the freely redistributable RHEL base.
- **Debian: current stables.** The release before is dropped when it can no
  longer be built. Debian 11 went when `bullseye-security` started returning
  404 (#933).

## How each version is keyed

containers-db keys platforms by `(os, os_version, arch)` and matches
`os_version` **exactly**. luggage normalizes the host's `/etc/os-release`
`VERSION_ID` to that granularity when auto-detecting:

| Distro | Reports | Keyed as |
|---|---|---|
| Debian | `13` | `13` |
| Ubuntu | `26.04` | `26.04` |
| Alpine | `3.24.2` | `3.24` (major.minor) |
| RHEL/UBI | `9.8`, `10.2` | `9`, `10` (major) |

## Adding or retiring a version

1. Add or remove `base-images/<distro>/<version>/{amd64,arm64}/Dockerfile`.
1. Update the `build-base-images.yml` matrix, the `evidence-run.yml` dispatch
   `tuple` options, and `REQUIRED_TUPLES` in
   `tests/unit/base-images-structure.sh`. That test fails until all four
   agree.
1. Add or remove the `support_matrix` rows in containers-db (every version of
   every tool claiming the platform). The vendored catalog mirrors them.
1. Run evidence for the new tuples: `evidence-run.yml` dispatch, or the image
   publish dispatches it automatically for tools that claim the tuple.

Check base-image tags against the registry before shipping. UBI in particular
publishes floating *minor* tags only, with no bare `:9`.

## Related

- [Rust version policy](rust-version-policy.md): which *tool* versions are
  supported, as opposed to which *platforms*
- [Evidence runs](../operations/evidence-runs.md)
- [`base-images/README.md`](../../base-images/README.md): image spec and
  hardening invariants
