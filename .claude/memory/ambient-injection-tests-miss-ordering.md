---
name: ambient-injection-tests-miss-ordering
description: Tests that inject a var through the ambient environment cannot discriminate where an unset sits relative to a `source`
metadata:
  type: project
---

When a script sources an env file and then `unset`s hostile variables, the
ordering is load-bearing: unsetting *before* the `source` leaves anything that
file sets intact.

A test that injects the variable through the **ambient environment** cannot see
that. An early `unset` strips the ambient value just as well as a late one, so
every such test passes against the wrong order. Measured on #953: four
per-variable cron-leg tests, all green with the `unset` moved above the
`source /etc/container/cron-env`.

**The only value that discriminates is one set by the sourced file itself**,
since that file is re-read after the too-early unset. So the fixture must plant
it there — substitute a temp path for the hardcoded env-file path in the
extracted script, write `export VAR=...` into it, and assert the consumer sees
`UNSET`.

Rewriting only *where* the env file is read from (never the order of the read
against the unset) keeps the property under test intact.

Generalizes past cron-env: any "sanitize after loading config" ordering needs
the hostile value to originate from the config, not from the caller's
environment.

Related: [[assertions-must-discriminate]], [[fixture-state-hides-vectors]] —
a sweep in one fixture state missing its own members is the same failure.
[[grep-pin-is-not-behavioral-coverage]].
