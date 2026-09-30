---
name: sourced-lib-set-flags-leak-into-caller
description: "A sourced lib's `set -euo pipefail` re-enables errexit in a caller that deliberately runs without -e; check effective options after sourcing"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 087efad5-7289-4cb9-a206-cfa5db6cbde0
  modified: 2026-09-30T14:36:17.344Z
---

`set` in a sourced file changes the **sourcer's** shell. `bin/check-versions.sh`
runs `set -uo pipefail` (no `-e`) on purpose: a failed fetch should become a
per-tool `error` and the sweep should continue. But it sources `bin/lib/common.sh` and
`bin/lib/version-utils.sh`, which each `set -euo pipefail` at source time. So
errexit came back on silently, and one empty pipeline (the Rust forge-fallback
`grep`) aborted the whole sweep with rc=1 and **zero bytes of output**. It was fixed
with `set +e` after the source lines (#992).

**Why:** the script's own `set` line is not its effective state. Reading
the top of the file tells you the author's intent, not what runs. It went
unnoticed for as long as it did because nothing ever ran check-versions against a
failing endpoint. Only a PATH-stubbed `curl` failing just CRAN reproduced it.

**How to apply:** in any script that sources a lib and relies on *not* having
`-e`, re-assert the options after the last `source` and check them with
`[[ $- == *e* ]]`. When writing a lib, don't set shell options for the sourcer.
Several `bin/lib/*.sh` still do (`grep -l 'set -euo' bin/lib -r`). To test a
failure-tolerant sweep, make exactly one upstream fail and assert the others still
report. See [/skips-render-as-passes.md](/skips-render-as-passes.md) and
[/report-io-decides-suite-exit.md](/report-io-decides-suite-exit.md).
