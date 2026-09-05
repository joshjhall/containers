# Plugin-count doc fixtures

Committed, read-only doc roots for the `DEFAULT_PLUGINS` doc-drift guard in
`tests/unit/features/claude-code-setup.sh`. One root per branch of
`_scan_docs_for_plugin_count`:

| root | drives |
| --- | --- |
| `clean/` | control — every doc agrees, so the scan must report nothing |
| `mismatched/` | a doc whose count disagrees with the code |
| `no-count/` | prose reworded past the scan's regex (`no-count-found`) |
| `missing/` | a doc the guard expects that no longer exists |

Each root holds all four `PLUGIN_COUNT_DOCS` entries (except `missing/`, which
omits `examples/env/dev-tools.env` — that omission IS its branch), so the tests
can assert the drift report by equality and thereby also prove the untouched
siblings were not reported.

The docs claim a synthetic count of **7**, deliberately unequal to the real
`DEFAULT_PLUGINS` count. That is what lets the tests pass a literal expected
count instead of deriving one from `claude-setup`: with no derived input there
is no input to guard, which is what removed the fixture-building machinery these
files replaced (#913).

The scan reads exactly one thing from a doc — a line matching
`(all )?[0-9]+ core plugins|all [0-9]+ defaults` — so a fixture doc is one line
of prose. Two details are load-bearing rather than decorative:

- `plugins-and-mcps.md` carries **two** matching lines, mirroring the real doc,
  so the scan's inner per-match loop is exercised and not just its first pass.
- `dev-tools.env` reproduces the real file's "13 static skills" / "11 default
  agents" decoys. They sit within ten lines of the plugin literal in the real
  file, which is why the scan's regex is narrow; a loosened regex must fail
  here the same way it would there.

`setup-stubs/*.setup` are stand-in `claude-setup` files for the counter's own
branches (absent assignment, empty first entry, single entry). The `.setup`
extension keeps them out of the lefthook `*.sh` shellcheck glob, where the
deliberately-unused `DEFAULT_PLUGINS` assignment would trip SC2034.
