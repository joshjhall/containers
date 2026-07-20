---
name: bash-env-breaks-path-stubs
description: This container sets BASH_ENV=/etc/bash_env which rebuilds PATH on every non-interactive bash; PATH-stub tests must clear BASH_ENV
metadata:
  node_type: memory
  type: project
  originSessionId: 93eb7efa-ab86-4b09-a924-c7947d3845d6
---

In this dev container, `BASH_ENV=/etc/bash_env` is set, so **every
non-interactive `bash` invocation sources `/etc/bash_env`, which REBUILDS
`PATH`** (prepends `/opt/fzf/bin`, restores `/usr/bin/...`, etc.).

Consequence for tests: a test that puts a **stub binary on PATH** to intercept a
command (e.g. a fake `tmux` for the workflow plugin's `golem-gate-watch.sh
--once-panes`, or the jq-absent stub in
`tests/unit/claude/test_golem_notify.sh`) will find its stub
**silently dropped** — the script under test re-resolves the real binary because
`/etc/bash_env` rebuilt PATH at the script's own bash startup. The symptom is
maddening: `command -v tmux` from the parent shell points at the stub, but the
child script still hits the real one.

**Fix:** clear `BASH_ENV` for the stubbed invocation. Either
`/usr/bin/env BASH_ENV='' PATH="$stub:$PATH" <script>` (note: `env VAR=''`, NOT a
bare `BASH_ENV=` bash-assignment prefix — shellcheck SC1007 flags the latter), or
`/usr/bin/env -i BASH_ENV= PATH="$stub" <script>` when you also need a pristine
environment. Verified while writing `tests/unit/bin/golem-gate-watch.sh` (#618).
Related: [[golem-supervised-auto-mode]].
