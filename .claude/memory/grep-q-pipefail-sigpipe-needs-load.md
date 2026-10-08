---
name: grep-q-pipefail-sigpipe-needs-load
description: "`producer | grep -q` under pipefail flakes only when the producer is descheduled between pipe writes; an idle loop \"disproves\" it falsely"
metadata:
  node_type: memory
  type: project
---

`cmd | grep -q pat` under `set -o pipefail` fails (rc 141) when grep -q exits on
an early match while `cmd` still has a pipe write pending. For output between
4 KiB and 64 KiB the producer issues several writes, and the race opens only if
it is descheduled between them. An idle 200x loop shows 0 failures; the
lefthook pre-push run (every suite at once) hits it. #1092's bindfs flake in
`tests/unit/integration-ci-coverage.sh` was this, after the issue had
"rejected" SIGPIPE on an unloaded loop.

**Why:** a hypothesis rejected under the wrong conditions sends the hunt
elsewhere.

**How to apply:** reproduce with a writer that sleeps between two writes
(`printf match; sleep .3; printf more`), or with a >64 KiB body that blocks
deterministically. Fix by capturing the producer's output and matching with
`grep -q <<<"$body"`. Precedent: `tests/unit/feature-test-scripts.sh:52`.
See [[assertions-must-discriminate]].
