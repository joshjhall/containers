---
name: git-env-leak-breaks-worktree-tests
description: Tests that git init/worktree-add in temp dirs fail under pre-push hooks because GIT_DIR/GIT_INDEX_FILE leak in; unset them in the test
metadata:
  node_type: memory
  type: project
  originSessionId: 34942ffc-3ee7-4583-a666-626c696bd720
---

A unit test that builds its own throwaway git repos (`git init` / `git worktree
add` in a `mktemp -d`) passes when run standalone but **fails when run from a
git pre-push / pre-commit hook**. Git exports `GIT_DIR`, `GIT_INDEX_FILE`,
`GIT_WORK_TREE`, and `GIT_COMMON_DIR` into the hook's environment; those leak
into the test's nested git commands and redirect them at the REAL repo instead
of the temp fixture, so the fixtures never build and assertions fail.

**Symptom seen (golem-587 push of #587):** `test_golem_notify.sh` reported 9/9
PASS run directly, but 6/9 FAIL under the `unit-tests` pre-push hook step (the
changed-file runner). Reproduce without pushing:

```sh
env GIT_DIR="$(git rev-parse --git-dir)" \
    GIT_INDEX_FILE="$(git rev-parse --git-path index)" \
    bash tests/unit/claude/test_golem_notify.sh   # -> 33% pass rate
```

**Fix:** unset the leaked vars before any nested git call in the test (top of
file, or per-subshell in the setup/run helpers):

```sh
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
```

Restores 9/9 even with the hook env present. **Lesson for review:** an
adversarial pre-PR review that runs a git-fixture test only *standalone* will
miss this — exercise such tests with `GIT_DIR` set, the way the push hook will.
A golem's honest "all tests pass" can still fail the push gate for this reason;
the supervised push gate is what caught it. Related:
[[worktree-push-hooks-gitignore]], [[golem-supervised-auto-mode]].
