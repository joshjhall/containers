---
name: assertions-must-discriminate
description: An assertion must fail for the reason it claims; exit codes and substring fragments routinely pass for the wrong reason
metadata:
  type: feedback
---

A test that passes is not evidence until it has been seen to fail for the reason
it names. Two live examples from the #886/#894 chain, both of which nearly
shipped as coverage that was not:

- **Substring too loose.** An out-of-tree log assertion matched the fragment
  `"is outside the project root"`. It passed while the line actually rendered
  `/path/wt/is outside…` — the path had run into the sentence. Fixed by asserting
  the path and separating space together.
- **Exit code cannot discriminate.** A guard test asserted a non-zero exit for
  the input `9FOO`. With the guard's leading-digit pattern deleted, the name was
  accepted, interpolated, and the generated stub then died on
  `${9FOO-}: bad substitution` — also non-zero. The assertion could never have
  failed for the reason it claimed. Fixed by keying on the guard's own
  diagnostic string, which only the guard emits.

**Why:** both were the *obvious* assertion for the property. The obvious
assertion is exactly where this hides, because it looks right and passes.

**How to apply:** for each new test, delete the specific line of code it guards
and confirm THAT test fails — not merely that something fails. If the assertion
still passes, or fails for an unrelated reason (a crash, a different guard), it
is not coverage yet. Prefer asserting on a signal only the code under test can
produce over a generic one like an exit status.

See [[fixture-state-hides-vectors]].
