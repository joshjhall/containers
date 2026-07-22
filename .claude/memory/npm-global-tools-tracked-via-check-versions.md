---
name: npm-global-tools-tracked-via-check-versions
description: "This repo has no dependabot; npm-global tools (agnix) pin + bump via check-versions.sh + auto-patch, with a check_npm helper"
metadata:
  node_type: memory
  type: project
  originSessionId: cbf80b8a-6805-4c14-9411-d41c4c0154ec
  modified: 2026-07-22T03:29:46.778Z
---

Issues (#769) sometimes say "route npm bumps via dependabot" — but this repo
has **no `.github/dependabot.yml`**. Every pinned tool (languages, GitHub-release
binaries, cargo crates, and now npm globals) is tracked by
`bin/check-versions.sh` plus the weekly auto-patch sweep. The dependabot
instruction maps to "wire it into check-versions.sh."

**How an npm-global tool gets pinned + tracked (agnix, #769/PR#770):**

1. `AGNIX_VERSION="${AGNIX_VERSION:-0.40.0}"` in `lib/features/dev-tools.sh`
   (defined there, consumed by the sourced `lib/.../install-binary-tools.sh` as
   `agnix@${AGNIX_VERSION}` — NOT `@latest`).
2. `_add_feature_version AGNIX_VERSION "agnix" "dev-tools.sh"` in
   `check-versions.sh::extract_all_versions`.
3. Dispatch case `agnix) check_npm "agnix" ;;` — new generic `check_npm` helper
   in `bin/lib/check-versions/checks.sh` reads
   `registry.npmjs.org/<pkg>` → `.["dist-tags"].latest` (mirrors `check_crates_io`).
4. Writeback case in `bin/lib/update-versions/updaters.sh` (`*.sh` block,
   `script_path=lib/features/dev-tools.sh`) — two `sed_inplace` lines handling
   `${VAR:-x}` and bare forms, exactly like the `codegraph)` case.
5. Doc line in `docs/reference/versions.md`.

Note: `jsonc-parser` is npm but checked via `check_github_release`
(microsoft/node-jsonc-parser) since it mirrors a GH repo. agnix has no GH
mirror → npm-registry check is correct. `hadolint`/`actionlint` are defined in
dev-tools.sh + checked but have NO updater case (latent gap, not agnix's
concern). Keep agnix in lockstep with the librarian consumers' `.agnix.toml`
pin (joshjhall/librarian#398). See [[rust-toolchain-pin-sync]] for the general
"pin lives in N places" pattern.
