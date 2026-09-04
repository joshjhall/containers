---
name: fixture-state-hides-vectors
description: A single fixture state can hide whole classes of vector; sweep every state where the answer could differ
metadata:
  type: feedback
---

An exhaustive-looking sweep can be blind to its own members if the fixture sits
in one state. On #894 a sweep of git config-injection vectors ran against a repo
that already had `core.ignorecase=false` set locally. Repo-local config beats
`GIT_CONFIG_GLOBAL`/`_SYSTEM`, so both registered as INERT and were written up as
non-vectors — in a comment that claimed to close the space.

**Why:** "measure, don't reason by category" was applied to the variables but not
to the fixture. The measurement was real; the state it ran in could not express
two of the answers.

**How to apply:** before calling a sweep exhaustive, ask which fixture states
could change any result — value present vs absent, file exists vs missing, flag
set vs unset — and run all of them. Related trap from the same run: pointing
`GIT_OBJECT_DIRECTORY` at a *nonexistent* path makes every probe look bent, but
that is git failing outright, not a real vector. A "positive" result needs the
same scrutiny as a negative one.

See [[git-env-neutralization-boundary]] and [[assertions-must-discriminate]].
