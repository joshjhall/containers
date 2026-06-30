---
name: ubi-minimal-no-nologin-use-false
description: ubi-minimal ships no nologin; hardening deny-shell must fall back to /usr/bin/false
metadata:
  node_type: memory
  type: feedback
  originSessionId: d391ee17-3d6d-49e5-b73c-9bf2cbda689c
---

`registry.access.redhat.com/ubi9/ubi-minimal` does NOT ship `/usr/sbin/nologin`
(nor `/sbin/nologin`). It lives in `util-linux-core`, which is NOT installed by
default — and installing `util-linux-core` did NOT add it either (#435 CI proved
this twice). So a `harden_service_users` that hard-requires nologin (`return 1`
when absent) fails the Docker build under `set -e`.

**Fix (deterministic, no package guessing):** make the deny-login shell a
first-available pick that bottoms out at `/usr/bin/false`:

```sh
local nologin=""
for candidate in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
    [ -x "$candidate" ] && { nologin="$candidate"; break; }
done
[ -z "$nologin" ] && { warn "..."; return 0; }   # never hard-fail the build
```

`/usr/bin/false` is provided by `coreutils-single` (core to ubi-minimal, always
present), is a valid non-login shell, and the hardening invariant explicitly
allows a "distro equivalent" — both `harden_service_users` and `verify()`
already treat `*/false` as hardened. The debian/alpine siblings only pass
because nologin happens to exist there; on a truly minimal image you need the
`/usr/bin/false` floor.

**Why it bit:** caught ONLY by the real Docker build in CI (no Docker locally;
hadolint/structure-test/shellcheck all pass with the broken version). Took 3 CI
iterations on #435 (tag → util-linux-core → false-fallback). Lesson: when a
base-image hardening step depends on a binary, don't assume the package or path
— make the logic fall back to a guaranteed-present coreutils binary. The
`rhel/9/arm64` tuple (#436) reuses this same `base-images/rhel/hardening.sh`, so
it inherits the fix. Pairs with [[ubi-image-tag-verify-registry]] and
[[alpine-hardening-no-coreutils-paths]].
