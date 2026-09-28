---
name: mawk-drops-literal-nul-in-printf
description: "mawk (the default awk in these images) silently drops a literal \\0 from a printf format string; use printf \"%s%c\", str, 0 for a null separator"
metadata:
  node_type: memory
  type: project
  originSessionId: f1112367-31a7-43d7-8925-f028d27ce6bc
  modified: 2026-09-17T15:23:29.261Z
---

`awk` in these images is **mawk**, not gawk. It **silently drops a literal `\0`**
from a `printf` format string:

```text
printf "%s\0", $2     -> good.linkspaced name.link     (ZERO NULs emitted)
printf "%s%c", $2, 0  -> good.link\0spaced name.link\0 (correct, both awks)
```

So the idiomatic-looking `awk '{ printf "%s\0", $2 }' | xargs -0 rm -f` is worse
than the naive `awk '{ print $2 }' | xargs rm -f` it appears to improve on:
every path concatenates into one unsplittable argument, and `xargs -0` then
matches nothing, so the command removes **nothing at all** — for every path, not
just the ones with spaces. It fails **silently**, exiting 0.

Caught in #977 only because a test **executed** the generated command against a
fixture with a space in the path. A substring assertion on `"xargs -0"` passes
happily on the broken form — see [[grep-pin-is-not-behavioral-coverage]] and
[[assertions-must-discriminate]].

**Rule:** for a null separator in awk, write `printf "%s%c", str, 0`. And when
shell code *generates* a command for a human to paste (a diagnostic's suggested
remedy, a printed workaround), test it by **running** it, not by pattern-matching
its text — such a command is usually pasted mid-outage, where a silent no-op is
most expensive. Related: [[skips-render-as-passes]].
