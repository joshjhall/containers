# Evidence runs: compile cache for source-build cells

Companion to [evidence-runs.md](evidence-runs.md) (#1594).

A cell with `source_build` set compiles through **ccache**, and `actions/cache`
keeps the objects between runs. The 180-minute cap stops a cold build being
cancelled. The cache is what keeps a repeat build from paying that cost again.
Every other cell skips all of this and keeps the plain `docker run`.

How it is wired:

- **luggage opt-in.** `LUGGAGE_COMPILER_LAUNCHER=<program>` makes the
  `source-build` method prefix that program onto `CC`/`CXX` for every build step.
  It wraps the catalog's own `CC`/`CXX` if the method exports one, or `cc`/`c++`
  otherwise. When the variable is unset (the default, and every production
  install), the build env is exactly what the catalog wrote. An empty or
  multi-word value is a hard error, never a silent "off". Other install methods
  ignore it.
- **In the container.** The cell mounts
  [`bin/lib/evidence-ccache-entry.sh`](../../bin/lib/evidence-ccache-entry.sh)
  and runs luggage through it. The script:
  1. installs `ccache` with the image's package manager (`apk`, `apt-get`,
     `dnf` or `microdnf`);
  2. zeroes the stats;
  3. only then exports `LUGGAGE_COMPILER_LAUNCHER=ccache`;
  4. runs the install, writes `ccache -s` to `out/ccache-stats.txt`, and exits
     with luggage's status.

  If ccache cannot be installed, the build runs uncached with a `::warning::`.
  Cache plumbing never decides a verdict, and nothing ccache-related ever
  reaches a production image.
- **Hashing.** luggage extracts each build into a random
  `/tmp/.../luggage-build-*` directory. `CCACHE_BASEDIR=/tmp` plus
  `CCACHE_NOHASHDIR=1` keep that path out of the hash. Without them every run
  would miss. `CCACHE_COMPILERCHECK=content` is set because the compiler is
  reinstalled into a fresh container each run, so its mtime proves nothing.
- **Key.** The key is `ccache-<tool>-<tuple>-<major>-<version>`. Restore tries an
  exact match first, then `ccache-<tool>-<tuple>-<major>-` (a new patch reuses
  most of the previous one's objects), then `ccache-<tool>-<tuple>-`. Tool and
  tuple lead the key, so no restore ever crosses tools or platforms. Version
  comes last, so the fallbacks are true prefixes.
- **Size.** `CCACHE_MAXSIZE=2G` per entry. GitHub's repository cache budget is
  10 GB and evicts least-recently-used entries past it. Keying per tool and tuple
  means a single node entry can never grow past its own 2 GB.
- **Save.** The save step runs under `always()`, so a cold build that fails or
  times out still keeps the objects it compiled.

**Reading the result.** Each source-build cell adds a `ccache:` section to the
job summary. It shows which key was restored (`none (cold)` on a miss) and the
`ccache -s` output, including the hit rate. To force a cold build, delete the
entries:

```bash
gh cache list --key ccache-node- --limit 100
gh cache delete <key>
```
