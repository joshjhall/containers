# Evidence runs: compile cache for source-build cells

Companion to [evidence-runs.md](evidence-runs.md) (#1594).

A cell with `source_build` set compiles through **ccache**, and `actions/cache`
keeps the objects between runs. The 180-minute cap stops a cold build being
cancelled. The cache is what keeps a repeat build from paying that cost again.
Every other cell skips all of this and keeps the plain `docker run`.

How it is wired:

- **luggage opt-in.** `LUGGAGE_COMPILER_LAUNCHER=<program>` makes the
  `source-build` method prefix that program onto `CC`/`CXX` for every build step.
  It wraps the catalog's own `CC`/`CXX` if the method exports one, else a
  non-empty `CC`/`CXX` inherited from luggage's environment, else the first of
  `gcc`, `cc` (`g++`, `c++` for `CXX`) on `PATH`. That is the order autoconf's
  `AC_PROG_CC`/`AC_PROG_CXX` probe in, so caching never changes which compiler
  an autoconf build uses (#1613). node's `configure.py` defaults to `cc`/`c++`
  instead. Those are `gcc`/`g++` on the debian and alpine images, so node gets
  the same compiler; an image that points `cc` elsewhere should export
  `CC`/`CXX` explicitly. If none of those exists, the variable is left unset,
  so a C-only image never gets a `CXX` that names a missing compiler. A
  compiler that already starts with the launcher (`CC="ccache gcc"`) is kept
  as-is, not wrapped twice. When the variable is unset (the default, and every
  production install), the build env is exactly what the catalog wrote. These
  values are a hard error, never a silent "off": empty, multi-word, a relative
  path (`./ccache`; use a bare name or an absolute path), or a directory (`/`,
  `.`, `..`, `bin/`). Other install methods ignore it.
- **Nothing installed in the image under test.** A ccache *package* would
  pull in its own runtime libraries (`libstdc++`, `zstd`, `xxhash` on alpine).
  Those could mask a runtime dependency the catalog forgot, so a cell would
  pass that a clean install fails. Instead, the runner downloads a pinned
  upstream musl-static ccache release (`CCACHE_VERSION` in the workflow),
  verifies its sha256 per architecture, and bind-mounts the binary read-only
  at `/opt/evidence-ccache/ccache`. To bump it, update the version and both
  checksums from the release's asset digests.
- **In the container.** The cell mounts
  [`bin/lib/evidence-ccache-entry.sh`](../../bin/lib/evidence-ccache-entry.sh)
  and runs luggage through it. The script:
  1. checks that the mounted binary runs (`ccache --version`);
  2. zeroes the stats and puts the binary's directory on `PATH`;
  3. only then exports `LUGGAGE_COMPILER_LAUNCHER=ccache`;
  4. runs the install, writes `ccache -s` to `out/ccache-stats.txt`, and exits
     with luggage's status.

  If the binary cannot be fetched, fails its checksum, or will not run, the
  build runs uncached with a `::warning::`. Cache plumbing never decides a
  verdict (the stats and save steps are also `continue-on-error`), and nothing
  ccache-related ever reaches a production image.
- **Hashing.** luggage extracts each build into a random
  `/tmp/.../luggage-build-*` directory. `CCACHE_BASEDIR=/tmp` plus
  `CCACHE_NOHASHDIR=1` keep that path out of the hash. Without them every run
  would miss. `CCACHE_COMPILERCHECK=content` is set because the compiler is
  reinstalled into a fresh container each run, so its mtime proves nothing.
- **Key.** Each save writes `ccache-<tool>-<tuple>-<major>-<version>-<run_id>-<attempt>`.
  Cache entries are immutable, so a fixed key would freeze the first cold
  build's objects (even a timed-out, partial one) and no later run could add
  to them. Restore is prefix-only and returns the newest match: the same
  version first, then `ccache-<tool>-<tuple>-<major>-` (a new patch reuses most
  of the previous one's objects), then `ccache-<tool>-<tuple>-`. Tool and tuple
  lead the key, so no restore ever crosses tools or platforms. A version with
  no numeric major gets the major `x`, with a warning, rather than failing the
  cell.
- **Size.** `CCACHE_MAXSIZE=2G` per entry. GitHub's repository cache budget is
  10 GB and evicts least-recently-used entries past it. Since every run saves a
  new entry, superseded entries for the same cell age out first; ccache's own
  cap keeps any single entry at or under 2 GB.
- **Save.** Only main runs save: a `push` to main, or a `workflow_dispatch` on
  main (#1612). Pull-request dry runs restore and report stats, but never save.
  GitHub scopes a PR run's entries to its `refs/pull/N/merge` ref, so main
  never restores them, but they still count against the shared 10 GB budget
  and push main's entries out through LRU eviction. Saving only from main
  also keeps every entry built from merged code. On main the step runs under
  `always()`, so a cold build that fails or times out still keeps the objects
  it compiled.
- **Cancellation (#1595).** PR runs share a per-PR concurrency group with
  `cancel-in-progress`, so a new push or the PR closing cancels the old run.
  An `always()` step still runs after a cancel, but on a PR run the event gate
  skips the save, so a cancelled PR run never writes an entry. Concurrency
  never cancels a main run (main runs are serialized). A main run cancelled by
  hand still saves its partial objects under `always()`. That is intended: the
  key is run-unique, so the next run restores and extends that entry.

**Reading the result.** Each source-build cell adds a `ccache:` section to the
job summary. It shows which key was restored (`none (cold)` on a miss) and the
`ccache -s` output, including the hit rate. To force a cold build, delete the
entries:

```bash
gh cache list --key ccache-node- --limit 100
gh cache delete <key>
```
