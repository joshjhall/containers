# stibbons setup standards

`stibbons setup standards` applies the repo baseline (git hooks, linter
configs, justfile, test runner, tool installer, GitHub or GitLab CI, and
starter docs and platform files) to any repository and reports when it drifts. The baseline is containers-db's
repo-baseline scaffold (`baseline/templates/`). This command is its
deterministic, non-LLM renderer: for the same selection it writes the same
bytes as containers-db's reference `render.sh`.

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
`baseline/templates` directory instead of the snapshot built into stibbons
(for example a local containers-db checkout, to try template changes before
they are pinned).

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
the selection, where the templates came from (`source`), the containers-db
commit of the built-in templates (`snapshot`; absent for a `--templates-dir`
run), and two hash maps:

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
| `kept`     | A create-only file that exists, whatever it now holds      | no    |
| `absent`   | A create-only file that is not on disk                     | no    |

When the recorded `snapshot` differs from the one this stibbons was built with,
`check` prints `note: templates moved on since init: containers-db <old> ->
<new>` before the per-file lines. That note is not drift by itself: the files
the new templates change show up as `stale`, apart from any you edited
(`modified`).

### Create-only files

Some targets are starter files you are meant to own: `README.md`, `CLAUDE.md`,
`docs/.gitkeep`, `CODEOWNERS`, and the issue and PR/MR templates. The manifest
marks them `once`. `AGENTS.md` is a `link` target: a symlink to `CLAUDE.md`.
`init` creates these only when nothing is at the path (a dangling symlink
counts as something) and never overwrites them, even with `--force`. They carry
no hash, `check` never reports them as drift, and `accept` has nothing to
record for them. Delete one and the next `init` creates it again.

The templates mark lines you are expected to change with `# per-repo:`. Make
those edits, run `accept`, and `check` stays green until the file changes
again.

## Template source

The templates come from containers-db's `baseline/templates/`, through the
`repo-baseline` crate. stibbons depends on it as a git dependency pinned to a
full commit SHA in the workspace `Cargo.toml`:

```toml
repo-baseline = { git = "https://github.com/joshjhall/containers-db", rev = "<40-hex sha>" }
```

The crate embeds every template file at build time, so `brew`, `apt`, and
`cargo` installs need no containers-db checkout at run time. The rev is the
only pin: there is no vendored copy and no local patch. `build.rs` reads the
SHA from `Cargo.lock`, refuses to build if it disagrees with the rev, and
stamps it into the binary as the `snapshot` that `init` records.

To move the pin to a new containers-db commit:

```bash
# edit the rev in Cargo.toml to the new full SHA, then:
cargo update -p repo-baseline
cargo test -p stibbons
```

The manifest format is containers-db's contract (`baseline/templates/README.md`):
rows filtered by slice and CI, concatenated per target in manifest order,
`*.sh` targets made executable, and the `once` and `link` modes above.
`matches_baseline_render_sh` in `crates/stibbons/tests/standards_templates.rs`
checks that stibbons writes the same bytes and links as containers-db's
`render.sh`. It runs that script from the pinned crate's own checkout
(`repo_baseline::TEMPLATES_DIR`), the same commit the templates are built from,
so it never skips.
