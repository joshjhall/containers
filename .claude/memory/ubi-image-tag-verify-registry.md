---
name: ubi-image-tag-verify-registry
description: "UBI base-image FROM tags must be verified against registry.access.redhat.com tags/list, not guessed"
metadata:
  node_type: memory
  type: feedback
  originSessionId: d391ee17-3d6d-49e5-b73c-9bf2cbda689c
---

When writing a `FROM registry.access.redhat.com/ubi9/ubi-minimal:<tag>` (or any
UBI image) in a base-image Dockerfile, VERIFY the tag against the registry's
real tag list before shipping — do not guess a minor and do not assume a bare
`:9` rolling tag exists. On `registry.access.redhat.com`:

- There is **NO bare `:9` floating tag** — `ubi-minimal:9` fails the build with
  `not found` (#435 CI). Only minor tags exist.
- The published **floating minor** tags cap at `9.5` (as of 2026-06):
  `9.0.0 9.1 9.1.0 9.2 9.3 9.4 9.5` + build-suffixed `9.8-<build>` digests.
  Confusingly the Red Hat *catalog* API (catalog.redhat.com) advertises `9.8`,
  but those are build-suffixed, not a floating `9.8` minor on the pull
  registry. Trust the pull registry, not the catalog page.
- Pick the **highest available floating minor** (e.g. `:9.5`) — it still rolls
  forward to the latest patch within that minor, keeping the Trivy CRITICAL/HIGH
  gate current without freezing on a stale build digest. Bump the minor when
  Red Hat publishes a higher one.

**How to verify (no auth needed):**

```text
curl -s https://registry.access.redhat.com/v2/ubi9/ubi-minimal/tags/list \
  | jq -r '.tags[]' | grep -E '^9\.[0-9]+$' | sort -V | tail
# and confirm the chosen tag resolves:
curl -s -o /dev/null -w '%{http_code}' \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  https://registry.access.redhat.com/v2/ubi9/ubi-minimal/manifests/9.5   # 200 = exists
```

**Why it bit:** an implementation agent pinned `:9.4` (plausible but a guess);
the pre-ship "fix" overcorrected to `:9` (doesn't exist); only the registry
tags/list gave ground truth. hadolint passes any syntactically-valid tag, so
this is caught ONLY by the real Docker build in CI. Pairs with
[[alpine-hardening-no-coreutils-paths]] — both are base-image facts that local
lint can't catch, only the CI build can. Relates to [[evidence-run-arch-aware]].
