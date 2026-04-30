# luggage

Catalog loader and version/platform resolver for the
[containers-db](https://github.com/joshjhall/containers-db) tool catalog.
Used by `stibbons` (project setup wizard) and `igor` (container runtime
manager). See the lib docs at `crates/luggage/src/lib.rs` for the API
surface and quick-start example.

## What it does

Given a tool id, a version request (latest / channel / exact / partial),
and a target platform, luggage answers *"what should I install and how
should I verify it?"* — returning a typed [`ResolvedInstall`] with the
chosen install method, verification metadata, dependencies, and any
non-fatal warnings. It does not (yet) execute installs.

## Activity-tier policy

Every tool in the catalog carries an [`ActivityScore`] in one of seven
buckets, scored by the upstream scanner. Resolution is gated by a
[`ResolutionPolicy`] that decides which tiers to accept, whether to refuse
versions below the tool's `minimum_recommended`, and whether to warn on
borderline tiers.

Three preset bundles cover the common consumers:

| Tier          | `Stibbons` (default) | `Igor`     | `Permissive` |
| ------------- | -------------------- | ---------- | ------------ |
| `very-active` | accept               | accept     | accept       |
| `active`      | accept               | accept     | accept       |
| `maintained`  | accept               | accept     | accept       |
| `slow`        | refuse               | accept     | accept       |
| `stale`       | refuse               | accept     | accept       |
| `dormant`     | refuse               | refuse     | accept       |
| `abandoned`   | refuse               | refuse     | accept       |
| `unknown`     | refuse               | refuse     | accept       |

`Stibbons` additionally warns when the policy *does* admit a `slow` or
`stale` tool (i.e. when a caller has lowered `min_activity` but kept
`warn_on_slow_or_stale = true`). `Igor` and `Permissive` suppress these
warnings by default.

## `minimum_recommended`

When a tool sets `minimum_recommended`, resolution refuses versions below
it unless the policy enables `allow_below_min_recommended`, in which case
the result carries a [`ResolutionWarning::BelowMinimumRecommended`] entry
instead. This protects the wizard from quietly recommending a stale pin
while still letting `igor` honor an explicit user pin.

## CLI

```text
luggage resolve <tool> [--version <v> | --channel <name>]
                       [--policy stibbons|igor|permissive]
                       [--allow-abandoned]
                       [--allow-below-min-recommended]
                       [--os <distro>] [--os-version <ver>] [--arch <arch>]
                       [--catalog <path>] [--json]
```

- `--policy` selects the preset bundle. Defaults to `stibbons`.
- `--allow-abandoned` lowers `min_activity` to `Abandoned` regardless of
  preset (useful for one-off installs of a known-archived tool).
- `--allow-below-min-recommended` flips the bool on regardless of preset.
- Without `--os`/`--os-version`/`--arch`, the host is auto-detected from
  `/etc/os-release` and `std::env::consts::ARCH`.

Exit codes: `0` on success, `2` when the host platform is unsupported
(`UnsupportedPlatform`, `NoMatchingInstallMethod`), `1` for everything else
including policy violations. Bash callers can branch on `2` for an
"install if possible, skip otherwise" pattern.

## See also

- Catalog repo: <https://github.com/joshjhall/containers-db>
- Schema: `schema/tool.schema.json` and `schema/version.schema.json`
- Design notes: `.claude/memory/luggage-tooldb-design.md`

[`ActivityScore`]: ../containers-common/src/tooldb/tool.rs
[`ResolutionPolicy`]: src/policy.rs
[`ResolvedInstall`]: src/resolver.rs
[`ResolutionWarning::BelowMinimumRecommended`]: src/resolver.rs
