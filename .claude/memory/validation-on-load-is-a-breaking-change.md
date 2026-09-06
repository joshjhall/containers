---
name: validation-on-load-is-a-breaking-change
description: Adding an allow-list to a config loader breaks existing files and desyncs the writer; validate on save too and share one exported predicate
metadata:
  node_type: memory
  type: feedback
  originSessionId: 11d74818-fdfd-4893-b88b-57f13183da52
  modified: 2026-09-06T21:47:39.634Z
---

Adding a character allow-list to a config **loader** (`IgorConfig::load`, #924
QW2) is a breaking change twice over. Both halves shipped before review caught
them:

1. **Existing files start failing.** Every command that loads the config breaks
   at once, on data that worked yesterday. The trap here was `.`: not
   template-corrupting, already allowed by `validate_repo_name` for the *same*
   project name, and ordinary in a POSIX account name (`john.doe`).
2. **The writer desyncs from the reader.** Validating only on read lets the
   producer write a file the loader then refuses. `stibbons init` accepted a
   username, `save` wrote it, and every later command failed — with
   `init --non-interactive` unable to recover, since it loads first. The project
   is bricked until someone hand-edits the file.

**Why:** validation on one side of a read/write pair is not a constraint on the
data, it is a disagreement between two code paths. The wizard had used Unicode
`is_alphanumeric` against the loader's ASCII list and had no validator at all
for `username`/`containers_dir` — the lists were written separately, so they
drifted immediately.

**How to apply:** validate in `save`/write as well as `load`, so the failure
lands at the prompt that produced the value. Export the predicate
(`is_ident_char` etc.) and have every prompt and validator call that *same
function* rather than restating the class. Before adding a character class, grep
for other validators over the same value and confirm they agree.

The acceptance test that catches this is "a value the writer accepts still
loads", not "a bad value is rejected" — see [[assertions-must-discriminate]].
Found by the one review dimension that had silently failed to a 429, which is
also the lesson in [[degraded-review-gate-is-not-a-pass]].
