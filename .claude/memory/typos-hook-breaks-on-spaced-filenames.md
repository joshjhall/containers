---
name: typos-hook-breaks-on-spaced-filenames
description: lefthook typos pre-push hook word-split filenames with spaces (GitLab issue templates) until fixed with xargs -d
metadata:
  node_type: memory
  type: project
  originSessionId: e606a9d4-f9c8-4021-a911-809022c2aed3
---

The `typos` pre-push hook in `lefthook.yml` ran `typos $files` with an
**unquoted** expansion, so any pushed path containing a space was word-split
into two bad arguments (`argument '.gitlab/issue_templates/Bug' is not found`,
exit 64). GitLab issue templates conventionally use spaces (the filename is the
dropdown label), e.g. `Bug Report.md`, `Feature Request.md` — these were the
first spaced tracked files in the repo, so the latent bug only surfaced with
issue #298.

**Why:** `$files` (a newline-separated list from `printf '%s\n' {push_files}`)
undergoes shell word-splitting on IFS (spaces included) when passed unquoted.

**How to apply:** feed the list via `/usr/bin/printf '%s\n' "$files" |
/usr/bin/xargs -d '\n' typos` so only newlines delimit args. Fixed in #298/PR
\#718. If adding more spaced filenames, this pattern is the reason it works;
watch other hooks that expand `{push_files}`/`{staged_files}` unquoted for the
same latent bug. Related: [[worktree-push-hooks-gitignore]].
