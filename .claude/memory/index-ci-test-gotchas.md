# CI & test-framework gotchas

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when a test or CI job fails oddly, flakes, or passes suspiciously.

- [Ambient injection misses ordering](ambient-injection-tests-miss-ordering.md) — to pin an unset-after-source ordering, the hostile value must come from the…
- [Discriminate rule has no fixed point on scaffolding](discriminate-rule-has-no-fixed-point-on-scaffolding.md) — #900→#903→#907→#913: each round's guards became the next round's undriven…
- [Fixture state hides vectors](fixture-state-hides-vectors.md) — an exhaustive sweep in one fixture state missed two of its own members
- [Grep pin is not behavioral coverage](grep-pin-is-not-behavioral-coverage.md) — pinning a guard's source text misses semantics
- [grep -q pipefail SIGPIPE needs load](grep-q-pipefail-sigpipe-needs-load.md) — `x | grep -q` flake only shows under scheduler pressure
- [Hermetic fixture tests need git identity](hermetic-fixture-tests-need-git-identity.md) — export GIT_*_NAME/EMAIL in committing tests (#606)
- [Mock fidelity gates assertions](mock-fidelity-gates-assertions.md) — a stub answering what the real tool could not lets tests pass on impossible…
- [Mutation scratch needs own target dir](mutation-scratch-needs-own-target-dir.md) — sharing CARGO_TARGET_DIR with a mutated copy makes real tests fail on correct…
- [Readdir order CI-only failure](readdir-order-ci-only-failure.md) — deterministic CI-only fail in an untouched suite can be find order (mutate-while-walking)
- [Report I/O decides suite exit](report-io-decides-suite-exit.md) — a suite's last command sets its status
- [Sibling suite split updates mapping test](sibling-suite-split-updates-mapping-test.md) — a new tests/unit/runtime/ sibling breaks run-changed-tests.sh's exact-count…
- [Skips render as passes](skips-render-as-passes.md) — interpreter-gated tests skipped silently in CI for months
- [Unit suites share tests/results/](tests-share-results-dir.md) — fixed TEST_TEMP_DIR names collide, unique ones leak
- [Trailing empty line hides a guard](trailing-empty-line-hides-guard.md) — $(...) strips trailing newlines
- [ETXTBSY held-fd is Linux-only](etxtbsy-held-fd-linux-only.md) — inducing ETXTBSY via a held write fd across exec works only on Linux
- [ETXTBSY test coverage split #676/#576](etxtbsy-test-coverage-split-676-576.md) — PR #575 ETXTBSY-retry test gaps split: #676 did exhaustion+stderr
- [Sourced lib set flags leak into caller](sourced-lib-set-flags-leak-into-caller.md) — a lib's `set -e` re-enables errexit in a no-`-e` sourcer
- [mawk drops literal NUL in printf](mawk-drops-literal-nul-in-printf.md) — use `printf "%s%c", str, 0`
- [CI lint fails on deleted paths](ci-lint-fails-on-deleted-paths.md) — Run Tests PR-lint fed deleted files to lefthook
- [Merge commit breaks conform CI](merge-commit-breaks-conform-ci.md) — a merge commit on a PR fails Run Tests at `conform enforce` (EOF, no FAIL line)
- [typos hook breaks on spaced filenames](typos-hook-breaks-on-spaced-filenames.md) — lefthook typos ran `typos $files` unquoted
- [Stale base re-adds bin/igor, breaks typos](stale-base-typos-bin-igor.md) — worktree cut before #690 carries deleted bin/igor in push range
- [Lint couples docs to templates](lint-couples-docs-to-templates.md) — Lint AI Templates CI requires every templates/claude skill+agent be
- [justfile delegation breaks content invariants](justfile-delegation-breaks-content-invariants.md) — thinning recipes into librarian wrappers breaks
- [Heuristic scanner: union of views](heuristic-scanner-union-of-views.md) — patching a lossy transform has no fixed point
- [clap `env` attr breaks bool flags](clap-env-attr-breaks-bool-flags.md) — `#[arg(env=...)]` on a bool makes it value-taking
- [Validation on load is a breaking change](validation-on-load-is-a-breaking-change.md) — a loader allow-list breaks existing files AND desyncs the
- [Unconsumed default status fails silently](unconsumed-default-status-fails-silently.md) — registered-but-unhandled lands in `unchecked`, which no stage reads
- [git flags need the oldest-base floor](git-flags-need-debian-11-floor.md) — a newer flag behind a `|| return 0` fail-safe no-ops the whole feature
- [git-cliff in a worktree empties CHANGELOG](git-cliff-worktree-empty-changelog.md) — pass --workdir; fixed in release.sh by #1423
