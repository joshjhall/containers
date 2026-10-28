# Luggage, catalog, evidence & containers-db

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when touching luggage install methods, the vendored catalog, evidence runs, or containers-db schema.

- [Luggage install-method decomposition](luggage-install-method-decomposition.md) — #805-813 chain
- [Luggage InstallReport field → workspace test](luggage-installreport-field-workspace-test.md) — new InstallReport field breaks record-evidence
- [Luggage release deferred until v5](luggage-release-deferred-until-v5.md) — no apt/Homebrew/cargo release for luggage until v5 substantially
- [Vendored catalog drift gate](vendored-catalog-drift-gate.md) — shipped luggage catalog mirrors containers-db (#815)
- [Pooled invariant masks a per-variant gap](pooled-invariant-masks-per-variant-gap.md) — union-across-install-methods hid an alpine entry with no
- [Distro deps live in catalog](distro-deps-live-in-catalog.md) — system_package.platforms + `distro:release` selectors (#1164)
- [Cross-repo schema required-flip](cross-repo-schema-required-flip.md) — a REQUIRED catalog field needs 3 PRs (optional→consume→required)
- [containers-db scanner silent failure](containers-db-scanner-silent-failure.md) — scanner went green while PR-create failed for weeks
- [reconcile uses published evidence](reconcile-uses-published-evidence.md) — fetch tested[] from published db
- [Evidence batched ingest](evidence-batched-ingest.md) — one auto-merged db PR + one issue per run (#1249)
- [Evidence pending from published db](evidence-pending-from-published-db.md) — matrix subtracts containers-db tested[], not vendored (#1319)
- [Evidence-run arch-aware](evidence-run-arch-aware.md) — native arm64+amd64
- [Evidence-run validates live vs db main](evidence-run-validates-live-against-db-main.md) — new TestEntry field needs containers-db schema PR merged
- [Rust split triage by production LOC](rust-split-triage-by-production-loc.md) — rank .rs split candidates by production LOC; check test_excluded first (#874 miscount)
