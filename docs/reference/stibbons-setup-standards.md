# stibbons setup standards

`stibbons setup standards` applies the repo baseline (git hooks, linter
configs, justfile, test runner, tool installer, and GitHub or GitLab CI) to any
repository and reports when it drifts. The baseline is librarian's
`repo-baseline` scaffold (`plugins/dev-core/skills/repo-baseline/`). This
command is its deterministic, non-LLM renderer: for the same selection it
writes the same bytes as librarian's reference `render.sh`.

No devcontainer or `.igor.yml` is required.

## Commands

```bash
stibbons setup standards init                   # detect languages + CI, write the baseline
stibbons setup standards init --lang shell,python --ci github,gitlab
stibbons setup standards init --dry-run         # show the plan, write nothing
stibbons setup standards init --force           # also overwrite locally edited files
stibbons setup standards check                  # exit 1 on drift (CI-usable)
stibbons setup standards accept                 # record every modified file as reviewed
stibbons setup standards accept ruff.toml       # ...or just the named ones
```

Every subcommand also takes `--templates-dir DIR` to read a
`repo-baseline/templates` directory instead of the copy built into stibbons
(for example a newer `/opt/librarian/plugins/dev-core/skills/repo-baseline/templates`).

## Selection

- **Languages** (`--lang`): the manifest's language slices, currently `shell`
  and `python`. If you don't pass `--lang`, `init` reuses the previous run's
  selection. On a first run it detects them from `git ls-files`, or from a
  directory walk outside git:
  - `*.sh`, `*.bash`, or a `bin/` script with an `sh`/`bash` shebang selects
    `shell`.
  - `*.py` or `pyproject.toml` selects `python`.
- **CI** (`--ci`): `github`, `gitlab`, or both. If you don't pass `--ci`, `init`
  reuses the previous selection. Otherwise it uses the host of the `origin`
  remote, and falls back to `github`.

## State and drift

`init` writes `.stibbons-standards.yml` at the repo root. Commit it. It records
the selection, where the templates came from, and two hash maps:

- `files`: what stibbons last wrote. `init` updates a file only while it still
  matches this, so a local edit is never overwritten without `--force`. A file
  that already existed before the first `init` is treated as a local edit.
- `accepted`: local edits you reviewed with `accept`.

`check` re-renders the recorded selection and classifies each file:

| State      | Meaning                                                    | Drift |
| ---------- | ---------------------------------------------------------- | ----- |
| `ok`       | Matches the templates                                      | no    |
| `accepted` | Matches an edit recorded with `accept`                     | no    |
| `missing`  | Not on disk                                                | yes   |
| `modified` | Edited and not accepted                                    | yes   |
| `stale`    | Unedited, but the current templates render different bytes | yes   |

The templates mark lines you are expected to change with `# per-repo:`. Make
those edits, run `accept`, and `check` stays green until the file changes
again.

## Template source

The templates are vendored into `crates/stibbons/assets/repo-baseline/` and
compiled into the binary, so `brew`, `apt`, and `cargo` installs need no
librarian checkout. `SOURCE` in that directory records which librarian release
they came from, plus a `+suffix` for any local patch carried on top. The one
patch today pins `pygments>=2.20.0` in the Python slice's
`tests/requirements.txt`, which librarian 0.18.0 does not yet do (see the
header of `bin/sync-repo-baseline.sh`). To refresh them after a librarian bump:

```bash
just sync-repo-baseline            # from /opt/librarian
just sync-repo-baseline ../librarian
```

The manifest format is librarian's contract (`templates/README.md` there):
rows filtered by slice and CI, concatenated per target in manifest order, and
`*.sh` targets made executable. `crates/stibbons/tests/standards_integration.rs`
checks byte parity with librarian's `render.sh` whenever `/opt/librarian` is
present.
