---
name: Luggage tool catalog design decisions
description: Locked design choices for the luggage tool catalog and crate scope — pilot tool is rust
type: project
originSessionId: e49b2398-d939-4fe9-9801-e3187e29987b
---

The "luggage" build engine is being built to replace bash-based version
pinning and install logic in `lib/features/*.sh`. Work splits into two
parts: (1) a tool catalog data model + repo, (2) the luggage Rust crate
that consumes it.

**Why:** Version maintenance across the bash feature scripts is burdensome.
Need finer granularity over which tools install (e.g., not every env wants
biome + dprint), per-distro support matrices, and activity-aware update
scheduling. Pilot tool is `rust` (exercises rustup + version pinning +
downstream cargo-install ordering).

**How to apply:** When working on luggage, tooldb, version management, or
porting any `lib/features/*.sh` script to Rust, follow these decisions.

## Locked decisions (2026-04-25)

1. **Catalog repo:** Separate `containers-tooldb` repo. Schema and data
   co-evolve there; main repo pins a snapshot SHA. Daily auto-scanner
   commits don't pollute main-repo history. PRs in tooldb stay small (one
   tool/version per file).

2. **Activity tiers (7):** `very-active`, `active`, `maintained`, `slow`,
   `stale`, `dormant`, `abandoned`. Stibbons recommends `maintained+`
   only; warns on `slow`/`stale`; refuses `dormant`/`abandoned`. Scan
   cadence decays with activity (1d / 7d / 30d / 90d).

3. **Support model:** Three separate fields per version — `support_matrix`
   (claimed compat), `tested` (CI evidence with timestamp + run URL), and
   `available[].last_known_good_for[distro]` (fossils for dropped
   support). Don't conflate claim with evidence.

4. **Luggage crate:** New `crates/luggage/` with both library and CLI from
   day one (`luggage resolve`, `luggage install`). Bash feature scripts
   call out via the CLI shim during the bash→rust migration to avoid a
   flag day.

## Catalog layout (strawman, pilot = rust)

```text
containers-tooldb/
├── schema/{tool,version}.schema.json
├── tools/<id>/
│   ├── index.json          # metadata, activity, available list
│   ├── versions/<v>.json   # support_matrix, tested[], install_methods
│   └── recipes/*.json      # shared install recipes (e.g., rustup)
├── catalog.json            # generated fast-lookup index
└── snapshots/YYYY-MM-DD.json  # frozen snapshots for client pinning
```

## 4-tier validation (carry over from bash, implement in luggage)

Tier 1 GPG/sigstore signatures → Tier 2 pinned checksums (git-tracked) →
Tier 3 published checksums → Tier 4 calculated TOFU. Existing
implementation: `lib/base/checksum-verification.sh`.

## Backfill target

Capture version data from January 2026 forward. Don't backfill older
versions unless needed for `last_known_good_for` records.

## Adjacent open issues (not blockers, but consumers)

- #222 auto-sync feature registry → becomes "luggage consumes registry"
- #179 API mocking for check-versions → obsolete once luggage owns
  version discovery
- #215 wizard tier for version pinning → consumes catalog
- #306 / #308 stibbons version + update commands → use luggage as backend

## Filed issues (2026-04-25)

- #400 Bootstrap containers-tooldb repo + JSON schemas (foundational)
- #401 Populate tools/rust/ pilot data
- #402 Specify 4-tier checksum validation encoding
- #403 Bootstrap crates/luggage + catalog loader (foundational)
- #404 Activity-aware version selection + recommendation gating
- #405 luggage install execution engine
- #406 Daily catalog scanner with per-tool cadence
- #407 Replace lib/features/rust.sh with luggage CLI shim
- #408 Tiered CI cadence (PR/merge/weekly/monthly/quarterly)
