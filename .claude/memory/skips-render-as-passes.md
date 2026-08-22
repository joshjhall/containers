---
name: skips-render-as-passes
description: A test that skips on a missing interpreter looks identical to a pass in CI — gate the skip on CI and fail there instead
metadata:
  type: project
---

`tests/unit/gitlab-templates.sh` gated its Ruby-backed tests on
`command -v ruby && command -v yq`. `ubuntu-latest` ships ruby but **not** yq,
and no workflow step installed it — so those tests had been **skipping on every
CI run since they were written** (#768). Nothing was broken; the coverage just
silently did not exist. The summary line reads `Passed: N, Skipped: 3` and
nobody looks at the second number.

Rule for any test gated on an optional interpreter or binary:

```bash
if ! prereqs_ok; then
    if [ "${CI:-false}" = "true" ]; then
        assert_true false "X is required in CI — this test cannot silently skip"
    else
        skip_test "X not available — skipping locally"
    fi
    return
fi
```

Locally it still skips (not every contributor has ruby); in CI a missing
prerequisite is a hard failure naming the workflow step that should provide it.
Pair it with an actual install step — the gate alone just turns an invisible
skip into a red build.

Two related traps found the same day:

- **Verify the fix runs at all.** The yq install step wrote to `/usr/local/bin`
  without `sudo` while all six sibling installs in the same job use it. That
  would have failed on every PR, so the tests it exists to enable would still
  never have run. Check what the neighbours do.
- **osv-scanner `--config` is not auto-discovered across directories.** It looks
  for `.osv-scanner.toml` NEXT TO each scanned lockfile, so a repo-root config
  is ignored for `.gitlab/triage/Gemfile.lock`. Pass `--config` explicitly in
  both `lefthook.yml` and the `just security-scan` recipe, or the suppression
  looks configured while the gate stays red.

Landed in PR #803. Related: [[cron-legs-need-boot-env-snapshot]].
