---
name: hermetic-fixture-tests-need-git-identity
description: Unit tests that git-commit in a fixture must export a GIT_*_NAME/EMAIL identity — CI runners have none
metadata:
  node_type: memory
  type: feedback
  originSessionId: 092e4dc4-0903-43d5-9329-145d39be0727
---

A shell unit test that builds a throwaway git repo and runs `git commit` (e.g.
to model an origin → bare-host fetch) fails on a fresh CI runner with
`fatal: empty ident name ... not allowed`, because GitHub runners have NO global
git `user.name`/`user.email`. The whole suite then errors out as "Test suite
failed to run" — and it passes locally where you DO have a global identity, so it
slips through pre-push and only fails in CI (seen on #606 / PR #619 sync-host.sh
tests).

**Why:** the fixture's `git commit` aborts before creating any commit, so a
later `git rev-parse origin/main` finds nothing and every assertion that depends
on the committed ref fails.

**How to apply:** at the top of the test (alongside the `unset GIT_DIR …`
hermetic guard from [[git-env-leak-breaks-worktree-tests]]) export a self-
contained identity so the fixtures never touch the host's global config:

```bash
export GIT_AUTHOR_NAME="<suite>-test" GIT_AUTHOR_EMAIL="<suite>-test@example.com"
export GIT_COMMITTER_NAME="<suite>-test" GIT_COMMITTER_EMAIL="<suite>-test@example.com"
```

Verify locally by running under an empty HOME (`env -i HOME=/tmp/nohome PATH=$PATH
bash tests/unit/...`) to reproduce the no-identity CI condition before pushing.
