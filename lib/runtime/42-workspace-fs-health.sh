#!/bin/bash
# 42-workspace-fs-health.sh — Repair worktree damage caused by the host mount
#
# Runs on every container start. Two independent repairs, both idempotent,
# both non-destructive, neither ever fatal to startup:
#
#   1. git core.ignorecase alignment. Bind mounts from macOS/Windows hosts are
#      usually case-insensitive, but a repo cloned on a case-sensitive
#      filesystem carries core.ignorecase=false. Git then treats "Catalog.rs"
#      and "catalog.rs" — one inode, two cached dentry spellings — as two
#      files, so the uppercase spelling shows up as untracked. That is not
#      cosmetic: `git clean -fd` would "remove" the untracked spelling and
#      unlink the shared inode, destroying tracked source.
#
#   2. Stale symlink attributes. Long-lived symlinks on virtiofs can end up
#      cached with nlink=0/size=0 — impossible values for a live symlink. Git
#      compares the index's recorded size against st_size, so such a symlink
#      reports as permanently modified even though its target is byte-correct.
#      Rewriting the link in place with the same target restores sane metadata.
#
# Both repairs run against the superproject AND every initialized submodule,
# recursively (issue #827). `git ls-files` stops at a 160000 gitlink, so a
# superproject-only pass never even enumerates a submodule's symlinks — they
# decay forever. A submodule's core.ignorecase is likewise its own config.
#
# They also run against every LINKED WORKTREE of the project (issue #882). A
# worktree under .worktrees/ is neither the superproject nor a submodule: it has
# its own working tree and its own index, and it is not a gitlink in the
# superproject's index, so neither of the two enumerations above reaches it.
# Every freshly created golem worktree therefore arrived with its tracked
# symlinks already reading as modified.
#
# WHICH REPOS get scanned is a separate question from what is repaired within
# one, and the answer is the whole WORKSPACE, not one project (issue #828).
#
# This script used to resolve a single PROJECT_ROOT from $PWD — the Dockerfile's
# WORKDIR ${WORKING_DIR} — and exit 0 when that path was not a repo. WORKING_DIR
# is a BUILD ARG; it has no obligation to name a repo at run time. In a
# multi-repo workspace it routinely does not: with three mounts under /workspace
# and WORKING_DIR=/workspace/librarian pointing at an empty directory, the boot
# run inspected nothing, the two genuinely-decayed repos beside it were never
# looked at — and because that bail-out ALSO removed the cron env snapshot, the
# hourly leg was disabled for the life of the container. Both legs dead, no
# output, exit 0.
#
# So there are two scopes:
#
#   single    — PROJECT_ROOT supplied in the environment. Exactly one repo, and
#               a non-repo there clears the snapshot. This is what the on-demand
#               `workspace-fs-health <path>` command uses.
#   workspace — the default. Every git repo at depth 1 under WORKSPACE_ROOT
#               (default /workspace), plus WORKSPACE_ROOT itself when it is a
#               repo. Discovery re-runs on every invocation, so a repo mounted
#               after boot is picked up by the next hourly pass.
#
# WORKSPACE_ROOT itself is included on purpose: a single repo mounted directly
# at /workspace with WORKING_DIR=/workspace would otherwise be skipped, which
# would be a regression against the old $PWD behavior rather than a fix.
#
# Skip everything with:   SKIP_CASE_CHECK=true
# Detect and report, but never write:  SKIP_CASE_FIX=true
#
# Repair 2 fixes a *time-driven* decay, so a boot-only run is not enough: a
# container left up long enough re-accumulates the bad attributes with nothing
# to re-trigger the repair (issue #794). The same script therefore also runs
# hourly from cron via /usr/local/bin/workspace-fs-health-cron, and on demand
# as /usr/local/bin/workspace-fs-health.
#
# Cron sees none of the container environment, so the BOOT run records what the
# cron leg cannot re-derive — the SCOPE (an explicit PROJECT_ROOT, or the
# WORKSPACE_ROOT to re-discover under) and SKIP_CASE_FIX — into an env snapshot.
# Its ABSENCE is what disables the cron leg, which is why the skip gate removes
# it rather than leaving a stale copy behind.
#
# The snapshot records the workspace ROOT, never the discovered repo list: the
# cron leg re-runs discovery on every pass, so a repo mounted after boot is
# repaired without waiting for a restart (issue #828).
#
# Only the boot run maintains that snapshot. The cron and on-demand legs pass
# FS_HEALTH_UPDATE_ENV=false, because both run with an environment that would
# poison it: an on-demand run's PROJECT_ROOT is whatever directory the user
# happened to be in, and a run against a named non-repo exits before it could
# record anything useful.

# ============================================================================
# Environment snapshot for the cron leg
# ============================================================================
# Under $HOME rather than /run: fix_run_permissions sits inside the
# ENTRYPOINT_STARTUP_ONLY guard, so /run is not reliably user-writable on an
# editor's later boots (see .claude/memory/zed-every-boot-startup-replay.md).

FS_HEALTH_ENV_FILE="${FS_HEALTH_ENV_FILE:-${HOME:-/tmp}/.cache/container/fs-health.env}"
FS_HEALTH_UPDATE_ENV="${FS_HEALTH_UPDATE_ENV:-true}"

remove_env_snapshot() {
    [ "$FS_HEALTH_UPDATE_ENV" = "true" ] || return 0
    /usr/bin/rm -f "$FS_HEALTH_ENV_FILE" 2>/dev/null || true
}

write_env_snapshot() {
    [ "$FS_HEALTH_UPDATE_ENV" = "true" ] || return 0

    local dir
    dir=$(command dirname "$FS_HEALTH_ENV_FILE")
    /usr/bin/mkdir -p "$dir" 2>/dev/null || return 0

    # Single-quote the values so a path containing spaces round-trips, and
    # escape any embedded single quote via the standard '\'' idiom. Without the
    # escape, a project path like /workspace/my's-project would terminate the
    # quoting early and turn the rest of the line into shell syntax rather than
    # data — the reader parses these values, so unescaped input there is a code
    # path, not just a wrong string.
    # PROJECT_ROOT is written EMPTY in workspace scope, and that empty value is
    # meaningful rather than missing: it is what tells the cron leg to
    # re-discover repos under WORKSPACE_ROOT instead of repairing one fixed
    # path. A snapshot from an older image carries only a non-empty
    # PROJECT_ROOT, which the reader still honors as single scope, so an
    # upgrade-in-place keeps working until the next boot rewrites it.
    local escaped_root="${SNAPSHOT_PROJECT_ROOT//\'/\'\\\'\'}"
    local escaped_workspace="${WORKSPACE_ROOT//\'/\'\\\'\'}"
    local escaped_skip="${SKIP_CASE_FIX:-false}"
    escaped_skip="${escaped_skip//\'/\'\\\'\'}"

    # Write to a temp file and rename into place. The hourly cron leg may read
    # this while a fast container restart is rewriting it; rename is atomic on
    # the same filesystem, so the reader sees either the old or the new file,
    # never a half-written one.
    local tmp="${FS_HEALTH_ENV_FILE}.tmp.$$"
    {
        command echo "PROJECT_ROOT='${escaped_root}'"
        command echo "WORKSPACE_ROOT='${escaped_workspace}'"
        command echo "SKIP_CASE_FIX='${escaped_skip}'"
    } >"$tmp" 2>/dev/null || {
        /usr/bin/rm -f "$tmp" 2>/dev/null || true
        return 0
    }
    /usr/bin/mv -f "$tmp" "$FS_HEALTH_ENV_FILE" 2>/dev/null || {
        /usr/bin/rm -f "$tmp" 2>/dev/null || true
        return 0
    }
}

# ============================================================================
# Skip gate
# ============================================================================

if [ "${SKIP_CASE_CHECK:-false}" = "true" ]; then
    # Drop any snapshot from a boot before the opt-out was set — otherwise the
    # cron leg would keep repairing for a user who explicitly opted out.
    remove_env_snapshot
    exit 0
fi

# ============================================================================
# Configuration
# ============================================================================

# Scope resolution (issue #828).
#
# The DISTINCTION is whether PROJECT_ROOT was supplied, not what it contains —
# so an explicitly-named root that turns out not to be a repo still reports and
# clears the snapshot the way it always did, rather than silently widening to a
# workspace scan the caller did not ask for.
#
# `${PROJECT_ROOT+x}` (set, including empty) rather than `${PROJECT_ROOT:-}`:
# an exported-but-empty PROJECT_ROOT is a caller mistake, and treating it as
# "single scope on the empty path" surfaces that, where treating it as unset
# would quietly scan the whole workspace instead.
if [ -n "${PROJECT_ROOT+x}" ]; then
    FS_HEALTH_SCOPE=single
else
    FS_HEALTH_SCOPE=workspace
    PROJECT_ROOT=""
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

# What the snapshot records for PROJECT_ROOT: the single root in single scope,
# empty in workspace scope (see write_env_snapshot).
SNAPSHOT_PROJECT_ROOT="$PROJECT_ROOT"

CASE_DETECT_SCRIPT="${CASE_DETECT_SCRIPT:-/usr/local/bin/detect-case-sensitivity.sh}"
LOG_PREFIX="[fs-health]"

# Neutralize an inherited git environment before ANY git runs (issue #886).
#
# `git -C <dir>` does NOT win against these variables — git reads the
# environment first and `-C` only changes the working directory it starts from.
# So a caller that exported any of them redirects every probe below at a
# DIFFERENT repository, while the code still reads as if it were scoped to
# PROJECT_ROOT:
#
#   GIT_DIR / GIT_WORK_TREE  — repoint --git-dir and --show-toplevel, which can
#                              make repair_linked_worktrees' "am I the main
#                              worktree?" gate compare two paths that say
#                              nothing about PROJECT_ROOT. The gate is what
#                              keeps the walk loop-free, so a skewed answer
#                              either disables the #882 repair or enumerates
#                              some other repo's worktrees.
#   GIT_COMMON_DIR           — repoints the OTHER half of that same equality.
#   GIT_INDEX_FILE           — makes `ls-files` enumerate a foreign index, which
#                              is what check_symlinks and the submodule walk
#                              iterate. This one reaches past the worktree pass
#                              into the two original repairs.
#   GIT_OBJECT_DIRECTORY     — defense-in-depth ONLY, and deliberately untested.
#                              Measured against every probe this script makes
#                              (ls-files, rev-parse --git-dir/--show-toplevel,
#                              worktree list): a leak bends none of them, because
#                              they all read refs and the index, never object
#                              content. There is no observable behavior to
#                              regression-test, so unlike its four siblings it
#                              gets no immunity test — an absence to leave alone,
#                              not an oversight to fill.
#
# The CONFIG-REDIRECT family is cleared too (issue #894), for a different and
# more concrete reason than the identity vars above — and NOT the reason #886
# first gave for leaving them out.
#
#   GIT_CONFIG (the legacy singular form)
#   GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM
#   GIT_CONFIG_COUNT (+ its GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> pairs)
#   GIT_CONFIG_PARAMETERS
#
# #886 argued these bought "no security boundary" — anyone able to set them
# could run git directly — and left them alone. That framing was wrong, because
# the risk here is not an attacker. It is a SILENT NO-OP, the same class #886
# exists to fix. Measured end-to-end against this script:
#
#   clean run     -> "set core.ignorecase=true", repo-local value written
#   GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.ignorecase GIT_CONFIG_VALUE_0=true
#                 -> repo-local value NEVER written, and NOTHING printed
#
# check_ignorecase reads core.ignorecase, sees the injected `true`, and takes its
# "already correct — say nothing" early return. An inherited value from anywhere
# — a wrapper, a CI job, a developer's shell — therefore disables the repair
# with no diagnostic. What that repair prevents is in this file's own header: on
# a case-insensitive mount, `git clean -fd` unlinks the shared inode and destroys
# tracked source. `-C` does not protect the read; git resolves config from the
# environment first.
#
# Clearing GIT_CONFIG_COUNT alone neutralizes the indexed pairs — git ignores
# GIT_CONFIG_KEY_<n>/VALUE_<n> without a count — so no unbounded enumeration of
# _<n> names is needed.
#
# GIT_CONFIG_PARAMETERS is the MOST LIKELY of these to be set by accident, and
# the most dangerous. Git populates it ITSELF: any `git -c key=value ...`
# exports it to every child process, so an ancestor `git -c` anywhere — a hook,
# an alias, a wrapper, a CI step — reaches this script without anyone having
# deliberately exported a GIT_* variable. Measured:
#
#   GIT_CONFIG_PARAMETERS="'core.ignorecase'='true'"  -> read returns 'true'
#   git -c core.ignorecase=true <alias running a child git> -> child reads 'true'
#
# And unlike the file-redirect vars, `-c` values sit at the TOP of git's config
# precedence — above the repo-local file. So this one suppresses the repair even
# on a repo whose local core.ignorecase is explicitly `false`, which is exactly
# the state check_ignorecase exists to correct. Caught by the #894 review, not
# by the original sweep.
#
# GIT_CONFIG (singular, legacy) is the WORST of the set, and the only one whose
# failure is not silent. It affects just the `git config` subcommand — which is
# exactly what check_ignorecase uses, twice, with no --file — and it diverts the
# WRITE as well as the read. Measured end-to-end against this script, on a repo
# whose local core.ignorecase is `false`:
#
#   [fs-health] git core.ignorecase is 'false' (incorrect for this mount)
#   [fs-health] set core.ignorecase=true          <- reported as repaired
#   repo-local core.ignorecase afterwards: false  <- but never written
#
# So this one produces a FALSE SUCCESS: the operator is told the repair landed,
# the log says so, and the setting that `git clean -fd` actually consults is
# untouched. Every other variable here can only make the repair vanish quietly;
# this one makes it lie. Caught in the second #894 review cycle.
#
# NOT cleared: GIT_CONFIG_NOSYSTEM, despite belonging to the same name family.
# It is an opt-OUT, not a redirect: git reads /etc/gitconfig by default, and
# NOSYSTEM is how a caller DISABLES that. Unsetting it would not restore a
# default — it would re-enable a config source someone deliberately turned off,
# which is the opposite of this block's purpose and could itself pull in a
# system-level core.ignorecase. (This image does ship an /etc/gitconfig; it sets
# pager/diff options and no core.ignorecase today, but that is a fact about
# today's image, not a guarantee.) Dropped from the list after review.
#
# Safe to clear: nothing in this repo (script, test, wrapper, CI job, Dockerfile)
# supplies git config through the environment, and a normal config read is
# unaffected by the unset. Both verified by repo-wide grep in #894.
#
# NOT cleared: GIT_CEILING_DIRECTORIES. Measured inert against all three
# rev-parse probes here (--git-dir, --git-common-dir, --show-toplevel are
# unchanged under it) because `-C` supplies an absolute starting point, so no
# discovery walk crosses the ceiling. Reviewers listed it alongside the config
# family; measurement says it does not belong. Recorded rather than silently
# omitted, the same treatment GIT_OBJECT_DIRECTORY gets above.
#
# THE RULE, for anyone extending this list: a variable belongs here when it
# demonstrably bends a probe THIS script makes — verified by measurement, not by
# category. That is the boundary #894 settled. Both #894 review cycles found a
# variable the previous sweep had missed (GIT_CONFIG_PARAMETERS, then the legacy
# GIT_CONFIG), and in each case reasoning by name family is what missed it —
# measure the specific variable against the specific probe instead.
#
# THE SPACE IS CLOSED, as of #894 — this list is complete, not a running tally.
# Rather than keep discovering these one review cycle at a time, every git
# environment variable documented as touching config resolution, repo discovery,
# the index, or pathspecs was swept against every call shape this script makes:
# `config --get`, `config <k> <v>` (the write), `rev-parse --git-dir`,
# `rev-parse --git-common-dir`, `rev-parse --show-toplevel`,
# `worktree list --porcelain`, and `ls-files -s`.
#
# These are the variables that move at least one probe. Every one is cleared by
# the unset below; the last column says which pass added it, so the table needs
# no summary count to be checked against — read the rows.
#
#   GIT_DIR                 --git-dir, --git-common-dir                   #886
#   GIT_COMMON_DIR          --git-common-dir                              #886
#   GIT_WORK_TREE           --show-toplevel, --git-dir, --git-common-dir  #886
#   GIT_INDEX_FILE          ls-files                                      #886
#   GIT_CONFIG              config read AND WRITE  (beats repo-local)     #894
#   GIT_CONFIG_PARAMETERS   config read            (beats repo-local)     #894
#   GIT_CONFIG_COUNT        config read            (beats repo-local)     #894
#   GIT_CONFIG_GLOBAL       config read            (fills a gap only)     #894
#   GIT_CONFIG_SYSTEM       config read            (fills a gap only)     #894
#
# Deliberately NO total is stated here. Three separate review cycles caught a
# summary count in this comment drifting from the rows beneath it — first "five
# movers" (which silently omitted the gap-filling ones), then a "5 by #886 / 3
# by #894" split that matched neither the table nor the unset. A count is a
# second copy of the data that no test checks and every edit can falsify; the
# per-row annotation cannot drift, because it IS the data.
#
# Note #886 cleared five variables but only four appear here: GIT_OBJECT_DIRECTORY
# is inert against every probe (see its entry above) and was cleared for
# completeness, so it is not a mover.
#
# Measured INERT against all six shapes, and listed by name so a future reader
# can see they were checked rather than overlooked: GIT_CONFIG_NOSYSTEM,
# GIT_OBJECT_DIRECTORY, GIT_CEILING_DIRECTORIES, GIT_DISCOVERY_ACROSS_FILESYSTEM,
# GIT_ATTR_NOSYSTEM, GIT_NAMESPACE, GIT_ALTERNATE_OBJECT_DIRECTORIES, and all
# four pathspec toggles (GIT_GLOB_PATHSPECS, GIT_NOGLOB_PATHSPECS,
# GIT_LITERAL_PATHSPECS, GIT_ICASE_PATHSPECS).
#
# TWO SWEEP ARTIFACTS worth recording, because both produced a wrong answer the
# first time and would mislead anyone repeating this:
#
#   - Point GIT_OBJECT_DIRECTORY at a NONEXISTENT directory and every probe
#     appears to move — but that is git failing outright ("fatal: not a git
#     repository"), not a bent probe. Against a real directory it bends nothing,
#     which is what #886 measured and why it has no immunity test.
#   - Sweep the config probes on a fixture that ALREADY has a repo-local
#     core.ignorecase and the gap-filling movers vanish, because local wins.
#     A single fixture state cannot see the whole space; probe both.
#
# PRECEDENCE matters as much as membership, and splits the config movers in two:
#
#   GIT_CONFIG / GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT   beat the local value
#   GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM                   lose to it
#
# The first tier is the dangerous one: it masks an explicitly wrong
# core.ignorecase=false, precisely the state check_ignorecase exists to correct.
# The second can only suppress the repair on a repo with no local value yet.
# Both are worth clearing; only the first can hide a repo that is actively
# broken, and only GIT_CONFIG also diverts the WRITE.
#
# WHY ONLY THIS SCRIPT. As of #894 this is the only script under lib/runtime/
# that runs git against a repository, so the rule needs no cross-script rollout:
# 60-setup-git.sh delegates to the setup-git command, check-installed-versions.sh
# only runs `git --version`, and workspace-fs-health-cron.sh / -run.sh merely
# invoke this file. If another runtime script starts shelling out to git — in
# particular anything that reads or writes config — this same neutralization
# belongs there too, and it should be hoisted into a shared helper rather than
# copied.
#
# Unset ONCE here rather than wrapping each call in `env -u`: git is invoked
# from several functions, so per-call wrapping is one chance to miss per call
# site and leaves every future git line inheriting the bug by default. (#886
# said "nine call sites"; the real number was eight, and it has since changed
# again — which is the argument for the unset, not against it, and the reason
# this no longer quotes a number.) This is safe precisely because the script is EXEC'd, never sourced —
# the Dockerfile installs it to /etc/container/startup/ and both
# workspace-fs-health-cron.sh and workspace-fs-health-run.sh invoke it by path —
# so nothing but this process sees the cleared environment.
#
# This repo has hit the leak class before: GIT_DIR leaking into the pre-push
# hook failed 6/9 temp-repo tests (.claude/memory/git-env-leak-breaks-worktree-tests.md).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
    GIT_CONFIG_PARAMETERS

# Injection seam for the RESOLUTION PROBES in repair_linked_worktrees (#886).
#
# SCOPE, stated precisely because the name reads broader than the wiring: this
# substitutes the four git calls in repair_linked_worktrees (the three
# `rev-parse` probes and the `worktree list` enumeration) — NOT every git call
# in the file. check_ignorecase and check_symlinks keep calling `git` directly,
# because their failure modes are already observable through the config and the
# index, so they need no seam to be testable. Widen this only if a specific test
# needs it; a seam nothing drives is dead weight.
#
# WHY THOSE FOUR. They are guarded by `|| return 0` by design — this script must
# never be why a container fails to start — which makes their failure path
# invisible: exactly how the git-2.31 `--path-format=absolute` regression
# no-opped the whole #882 feature on Debian 11 (git 2.30.2) with no diagnostic.
# Substituting the binary is the only way to drive such a failure on demand.
#
# A PATH-shadowed stub does NOT work here: /etc/bash_env rebuilds PATH for
# non-interactive bash, so the stub is silently ignored inside this script's own
# bash invocation (.claude/memory/bash-env-breaks-path-stubs.md). Hence a seam,
# matching CASE_DETECT_SCRIPT / FS_HEALTH_STAT / FS_HEALTH_SU.
FS_HEALTH_GIT="${FS_HEALTH_GIT:-git}"

# Injection seam for the symlink staleness probe. Neither nlink=0 nor size=0 can
# be produced on demand — they are filesystem cache artifacts — so the only way
# to exercise the repair (rather than just its inaction) is to substitute the
# stat call. Matches the CASE_DETECT_SCRIPT / FS_HEALTH_SU seams already here.
FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"

# Submodule recursion depth cap. Purely a containment backstop: a gitlink graph
# is acyclic in practice, but this script must never be the reason a container
# fails to start, and 8 is far past any real nesting.
#
# Validated numeric because it is compared with `-lt`: a non-integer would make
# `[` write "integer expression expected" to stderr at every level AND evaluate
# false, silently disabling submodule traversal entirely. Falling back to the
# default is strictly better than half-failing on a typo.
FS_HEALTH_MAX_DEPTH="${FS_HEALTH_MAX_DEPTH:-8}"
case "$FS_HEALTH_MAX_DEPTH" in
    '' | *[!0-9]*) FS_HEALTH_MAX_DEPTH=8 ;;
esac

# Report-only mode: detect and warn, but make no changes.
FIX_ENABLED=true
if [ "${SKIP_CASE_FIX:-false}" = "true" ]; then
    FIX_ENABLED=false
fi

# ============================================================================
# git availability
# ============================================================================

# Nothing below can run without git, in either scope.
if ! command -v git >/dev/null 2>&1; then
    remove_env_snapshot
    exit 0
fi

# ============================================================================
# Filesystem case-sensitivity detection
# ============================================================================
# detect-case-sensitivity.sh exit codes: 0=case-sensitive, 1=case-insensitive,
# 2=error (missing path, not writable). An error is NOT evidence of either
# state, so it must not trigger a repair.
#
# Detected PER REPO rather than once for the whole run (issue #828). Under a
# workspace scan the roots are separate mounts by construction — that is what
# makes them separate entries under /workspace — and two mounts can genuinely
# differ in case-sensitivity. A single verdict sampled from whichever repo
# happened to be first would then be applied to the others as if it described
# them.
#
# FS_CASE_STATE remains an override so tests can force a verdict without a real
# case-insensitive filesystem: when it is already set in the environment,
# detection is skipped entirely and every root uses the forced value. Values:
# sensitive | insensitive | unknown.
FS_CASE_STATE_FORCED=false
if [ -n "${FS_CASE_STATE+x}" ]; then
    FS_CASE_STATE_FORCED=true
fi

# Args: $1 = repo root. Sets the global FS_CASE_STATE for that root.
detect_case_state() {
    local root="$1"

    [ "$FS_CASE_STATE_FORCED" = "true" ] && return 0

    FS_CASE_STATE=unknown
    if [ -x "$CASE_DETECT_SCRIPT" ] && [ -w "$root" ]; then
        QUIET=true "$CASE_DETECT_SCRIPT" "$root" >/dev/null 2>&1
        case "$?" in
            0) FS_CASE_STATE=sensitive ;;
            1) FS_CASE_STATE=insensitive ;;
            *) FS_CASE_STATE=unknown ;;
        esac
    fi

    return 0
}

# ============================================================================
# Repair 1: align git core.ignorecase with the actual filesystem
# ============================================================================

# Args: $1 = repo root (superproject or a submodule worktree)
#
# The filesystem verdict is deliberately NOT re-detected per submodule: a
# submodule lives inside the superproject's worktree, so it is on the same
# mount by construction. Only the git config differs, and that is what this
# aligns — a submodule carries its own core.ignorecase, cloned from wherever it
# came from, and is equally wrong on a case-insensitive mount (#827).
check_ignorecase() {
    local root="$1"

    if [ "$FS_CASE_STATE" != "insensitive" ]; then
        return 0
    fi

    local current
    current=$(git -C "$root" config --get core.ignorecase 2>/dev/null) || true

    # Already correct — say nothing.
    if [ "$current" = "true" ]; then
        return 0
    fi

    local shown="${current:-unset}"
    command echo "$LOG_PREFIX $root is on a case-insensitive mount" >&2
    command echo "$LOG_PREFIX git core.ignorecase is '$shown' (incorrect for this mount)" >&2

    if [ "$FIX_ENABLED" != "true" ]; then
        command echo "$LOG_PREFIX SKIP_CASE_FIX=true — not changing it. To fix manually:" >&2
        command echo "$LOG_PREFIX   git -C $root config core.ignorecase true" >&2
        return 0
    fi

    if git -C "$root" config core.ignorecase true 2>/dev/null; then
        command echo "$LOG_PREFIX set core.ignorecase=true (opt out with SKIP_CASE_FIX=true)" >&2
    else
        command echo "$LOG_PREFIX Warning: could not write core.ignorecase (read-only .git?)" >&2
    fi
}

# ============================================================================
# Repair 2: refresh symlinks with stale filesystem attributes
# ============================================================================

# Classify a symlink's cached attributes.
#
# Args: $1 = absolute path to a symlink, $2 = its readlink target (non-empty)
# Prints the reason string and returns 0 when stale; returns 1 when healthy.
#
# Two independent arms, because the two observables decay for the same reason
# but are not known to decay together:
#
#   nlink=0    — impossible for a live symlink. A *broken* link (target does
#                not exist) still reports nlink=1, so this can never fire on
#                one, which is what makes it safe.
#
#   st_size=0  — what git actually keys on. It sizes a symlink from st_size
#                before reading the target, so a zero size makes git read zero
#                bytes and diff the link against the empty blob (issue #827
#                captured exactly that: ":120000 120000 681311eb 00000000 M").
#                A live symlink's st_size IS strlen(target), so size=0 paired
#                with a NON-EMPTY target is a self-contradiction — that pairing
#                is the whole guard, and it is why the caller resolves the
#                target before probing.
#
# #827 observed st_size=0 directly but relinked before sampling %h, so whether
# nlink had also decayed on those links is unconfirmed. Both arms are checked
# rather than assuming they move together: if they always do, the second arm
# costs one extra comparison; if they do not, it is the only thing that fires.
symlink_stale_reason() {
    local path="$1" target="$2"
    local nlink size

    # One stat for both values — the probe runs per tracked symlink per repo.
    read -r nlink size < <("$FS_HEALTH_STAT" -c '%h %s' "$path" 2>/dev/null) || return 1

    [ -n "$nlink" ] && [ -n "$size" ] || return 1

    if [ "$nlink" = "0" ]; then
        command printf '%s\n' "nlink=0"
        return 0
    fi

    if [ "$size" = "0" ] && [ -n "$target" ]; then
        command printf '%s\n' "st_size=0, target '$target'"
        return 0
    fi

    return 1
}

# Args: $1 = repo root, $2 = display prefix for log lines ("" for the
#       superproject, "containers/" for a submodule) so a path is unambiguous
#       once several roots are in play.
check_symlinks() {
    local root="$1" label_prefix="$2"
    local rel path target reason

    # Enumerate tracked symlinks straight from the index (mode 120000). Far
    # cheaper and more precise than walking the worktree, and it inherently
    # skips ignored/untracked links we have no business touching. `ls-files -s`
    # emits "<mode> <sha> <stage>\tpath", so the awk below splits on the tab to
    # keep paths containing spaces intact.
    #
    # This stops at a 160000 gitlink and does NOT descend into submodules —
    # that is the #827 bug. The caller supplies each submodule worktree as its
    # own root instead.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        path="${root}/${rel}"

        [ -L "$path" ] || continue

        # Resolve the target BEFORE the staleness probe: the st_size arm is only
        # meaningful against a non-empty target, and a link we cannot read is
        # one we must not rewrite.
        target=$(/usr/bin/readlink "$path" 2>/dev/null) || continue
        [ -n "$target" ] || continue

        reason=$(symlink_stale_reason "$path" "$target") || continue

        command echo "$LOG_PREFIX ${label_prefix}${rel}: stale symlink attributes ($reason)" >&2

        if [ "$FIX_ENABLED" != "true" ]; then
            command echo "$LOG_PREFIX SKIP_CASE_FIX=true — not repairing. To fix manually:" >&2
            command echo "$LOG_PREFIX   ln -sfn $target $path" >&2
            continue
        fi

        # -n is load-bearing: without it, relinking a symlink that points at a
        # directory would create the new link *inside* that directory.
        # The target is unchanged, so content and git blob identity are intact.
        if /usr/bin/ln -sfn "$target" "$path" 2>/dev/null; then
            command echo "$LOG_PREFIX refreshed ${label_prefix}${rel} -> $target" >&2
        else
            command echo "$LOG_PREFIX Warning: could not refresh ${label_prefix}${rel} (read-only mount?)" >&2
        fi
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }')

    return 0
}

# ============================================================================
# Repo traversal: superproject + every initialized submodule, recursively
# ============================================================================

# Run both repairs against one root, then recurse into its submodules.
#
# Args: $1 = repo root, $2 = display prefix for log lines, $3 = current depth
#
# Written as a manual gitlink walk rather than `git submodule foreach
# --recursive` on purpose: foreach spawns a shell per submodule, and both its
# failure semantics and its noise on uninitialized entries would need extra
# containment to satisfy "never fatal to startup, silent when healthy". This
# reuses the same `ls-files -s` idiom the symlink repair already relies on and
# keeps every failure path a local `continue`.
repair_repo_tree() {
    local root="$1" label_prefix="$2" depth="$3"
    local rel sub_root sub_resolved

    check_ignorecase "$root"
    check_symlinks "$root" "$label_prefix"

    # Containment backstop, not an expected condition.
    [ "$depth" -lt "$FS_HEALTH_MAX_DEPTH" ] || return 0

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        sub_root="${root}/${rel}"

        # The gitlink is in the index whether or not the submodule was ever
        # initialized. An uninitialized (or empty) one has no .git, and this
        # single check is what makes it a silent non-event — no warning, no
        # error, nothing to fix. A submodule worktree's .git is a *file*
        # pointing into the superproject's .git/modules, so test -e, not -d.
        [ -e "${sub_root}/.git" ] || continue

        # Dedup is BIDIRECTIONAL (issue #828). Claiming the path stops depth-1
        # discovery from later emitting it as an independent top-level project;
        # the seen-check stops the reverse, where discovery got there first and
        # this walk would repair it a second time. Which of the two runs first
        # is decided by readdir order, so only checking one direction leaves the
        # duplicate to chance.
        sub_resolved=$(fs_health_resolve "$sub_root")
        fs_health_seen "$sub_resolved" && continue
        fs_health_mark_scanned "$sub_resolved"

        repair_repo_tree "$sub_root" "${label_prefix}${rel}/" "$((depth + 1))"
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^160000 / { print $2 }')

    return 0
}

# ============================================================================
# Linked worktrees
# ============================================================================

# Repair every linked worktree of one repo root (issue #882).
#
# Args: $1 = repo root to enumerate worktrees from.
#
# Takes the root as an argument rather than reading a global (issue #828): under
# a workspace scan this is called once per discovered repo, so a global would
# make every call after the first enumerate the wrong repository's worktrees.
#
# A linked worktree is invisible to both enumerations above: it is not in the
# superproject's index at all (so `ls-files` never names it), and it is not a
# gitlink (so the submodule walk never descends into it). It does have its own
# working tree and its own index, which is exactly what makes it a repo root in
# its own right — and what makes every fresh golem worktree start out with its
# tracked symlinks reading as modified.
#
# Each worktree is handed to repair_repo_tree at depth 0, so it gets BOTH
# repairs and its own submodules walked, and both opt-outs keep working with no
# new branches: SKIP_CASE_CHECK exited long before this point, and SKIP_CASE_FIX
# is read inside the same shared FIX_ENABLED the other roots use.
repair_linked_worktrees() {
    local project_root="$1"
    local root_prefix="${2:-}"
    local main_toplevel wt wt_listed rel label saved_state

    # ONLY enumerate from the main worktree. `git worktree list` is repo-GLOBAL:
    # asked from inside a linked worktree it returns the whole set, including
    # the caller, so this function would repair its own root a second time and
    # sweep in every sibling. Gating on the primary checkout makes the walk
    # loop-free by construction — and keeps `workspace-fs-health <a-worktree>`
    # scoped to the worktree the user actually named.
    #
    # `--git-dir` != `--git-common-dir` is the repo-standard linked-worktree
    # idiom (the golem nesting guard uses the same comparison).
    #
    # Both sides are resolved with `cd ... && pwd -P` rather than
    # `rev-parse --path-format=absolute`, for two independent reasons:
    #
    #   1. PORTABILITY. --path-format arrived in git 2.31, but Debian 11
    #      (Bullseye) — a supported base image — ships 2.30.2. There the flag is
    #      unrecognized, rev-parse errors, the `|| return 0` fires, and this
    #      whole function silently no-ops. It is designed to fail silent-and-safe,
    #      so that regression would surface as nothing at all: the #882 repair
    #      simply never running on one of the supported distros.
    #
    #   2. NORMALIZATION. --git-common-dir can come back relative, and `pwd -P`
    #      resolves symlinks on both sides — so a PROJECT_ROOT reached through a
    #      symlinked path component (exactly the environment this script exists
    #      for) cannot produce a false mismatch between the two forms.
    local git_dir common_dir
    git_dir=$("$FS_HEALTH_GIT" -C "$project_root" rev-parse --git-dir 2>/dev/null) || return 0
    common_dir=$("$FS_HEALTH_GIT" -C "$project_root" rev-parse --git-common-dir 2>/dev/null) || return 0

    # Relative outputs are relative to the repo root, so resolve from there.
    git_dir=$(cd "$project_root" 2>/dev/null && cd "$git_dir" 2>/dev/null && pwd -P) || return 0
    common_dir=$(cd "$project_root" 2>/dev/null && cd "$common_dir" 2>/dev/null && pwd -P) || return 0
    [ "$git_dir" = "$common_dir" ] || return 0

    # Resolve the main worktree's own path so its entry can be skipped below.
    # git lists it first, but keying off position would be fragile; comparing
    # paths is not.
    #
    # `pwd -P` for the same normalization reason as above: `--show-toplevel` and
    # the path recorded by `worktree list` need not be byte-identical when
    # PROJECT_ROOT sits behind a symlink. A false mismatch here is not fatal —
    # the main root would simply be walked a second time, mislabeled with an
    # absolute path — but it is a confusing duplicate diagnostic for the very
    # root the run already covered, so both sides are resolved the same way.
    main_toplevel=$("$FS_HEALTH_GIT" -C "$project_root" rev-parse --show-toplevel 2>/dev/null) || return 0
    main_toplevel=$(cd "$main_toplevel" 2>/dev/null && pwd -P) || return 0

    # `worktree list --porcelain` emits stanzas whose first line is
    # "worktree <path>". Cut after the first space rather than splitting on
    # whitespace, so a path containing spaces survives intact.
    while IFS= read -r wt; do
        [ -n "$wt" ] || continue

        # Canonicalize the listed path too, so the skip below compares like with
        # like. A path that cannot be entered (deleted worktree) keeps its
        # original form and is dropped by the .git check just after.
        #
        # The original is saved FIRST because `wt=$(...) || wt="$wt"` does not
        # work: bash performs the assignment before evaluating `||`, so on
        # failure $wt is already the empty string and the fallback restores
        # nothing. That spelling happens to behave here — `[ -e "/.git" ]` is
        # false, so the entry is still dropped — but only by luck, and the bug
        # would bite anywhere the empty path resolved to something real.
        wt_listed="$wt"
        wt=$(cd "$wt_listed" 2>/dev/null && pwd -P) || wt="$wt_listed"

        [ "$wt" != "$main_toplevel" ] || continue

        # No .git means nothing to repair here: a worktree whose directory was
        # deleted but not pruned, or a bare entry. Same silent non-event the
        # submodule walk makes of an uninitialized gitlink.
        [ -e "${wt}/.git" ] || continue

        # Label lines by the worktree's path relative to the project root
        # (".worktrees/issue-882/"), so a finding is unambiguous once worktrees
        # and submodules are both in play. A worktree living outside the project
        # root has no useful relative form, so it keeps its absolute path.
        # An IN-tree worktree takes the owning repo's prefix so the line names
        # which repo it belongs to under a workspace scan (issue #828) — the
        # prefix is empty in single scope, which keeps the original
        # ".worktrees/issue-882/AGENTS.md" form. An OUT-of-tree worktree already
        # carries its own absolute path, so prefixing it would name two
        # unrelated roots on one line.
        rel="${wt#"$main_toplevel"/}"
        if [ "$rel" = "$wt" ]; then
            label="${wt}/"
        else
            label="${root_prefix}${rel}/"
        fi

        # Dedup is BIDIRECTIONAL (issue #828). $wt is already `pwd -P`-resolved
        # above, so it compares directly against the ledger.
        #
        # Claiming it stops depth-1 discovery from later emitting this same
        # directory as an independent top-level project. The seen-check stops
        # the REVERSE, and that direction is the one readdir decides: a worktree
        # that is a SIBLING of its owning repo under the workspace root —
        # `git worktree add /workspace/repo-wt` when the repo is
        # /workspace/repo — is a depth-1 entry in its own right, so discovery
        # can reach it BEFORE the repo that owns it. It was then repaired once
        # bare and once labeled, which is the duplicate-and-mislabel symptom the
        # ledger exists to prevent, arriving by the other route.
        fs_health_seen "$wt" && continue
        fs_health_mark_scanned "$wt"

        # A worktree INSIDE the project root is on the project's mount by
        # construction, exactly like a submodule, so the verdict detected once at
        # startup describes it and its core.ignorecase is aligned normally.
        #
        # A worktree OUTSIDE it carries no such guarantee: `git worktree add
        # /some/other/volume/wt` can put it on a filesystem whose
        # case-sensitivity differs. The startup verdict is then evidence about
        # somewhere else — and, crucially, core.ignorecase is NOT per-worktree:
        # every worktree shares the repository's single .git/config, so
        # "aligning" one from a foreign mount's verdict would silently rewrite
        # the setting for the superproject and every sibling. Re-detecting per
        # root does not help for the same reason — there is still only one value
        # to write, and letting the outsider win is strictly worse than leaving
        # the project's own mount in charge.
        #
        # So an out-of-tree worktree gets the SYMLINK repair — which is genuinely
        # per-worktree, and is the actual subject of #882 — with the case verdict
        # downgraded to `unknown`, the existing value that makes check_ignorecase
        # return without writing.
        #
        # Save/restore around the call rather than an assignment prefix: a prefix
        # on a shell FUNCTION has scoping that differs between bash modes, so
        # leaking the downgraded verdict into later roots is a real risk.
        if [ "$rel" != "$wt" ]; then
            repair_repo_tree "$wt" "$label" 0
        else
            # ANNOUNCE the out-of-tree root before repairing it (issue #886).
            #
            # `git worktree add` accepts any path the caller can write to, and
            # this pass follows every registered entry — running `ln -sfn`
            # against it at every container start and hourly from cron. The
            # blast radius is bounded (the script runs as the container user,
            # and registering a worktree already requires equivalent write
            # access), so this is NOT a privilege-escalation path. What it is,
            # is an unattended repair whose reach silently extends outside the
            # project — worth one line an operator can notice or grep for.
            #
            # Rejected: an allowlist restricting repairs to PROJECT_ROOT. That
            # would silently stop repairing a legitimate
            # `git worktree add /other/volume/wt`, reintroducing the very #882
            # symptom this pass exists to fix, for the one user who most needs
            # it. The reach is intended; only its invisibility was the defect.
            #
            # Emitted unconditionally, not gated on FIX_ENABLED: under
            # SKIP_CASE_FIX the run is report-only, and "there is an out-of-tree
            # worktree here" is precisely the kind of thing a report should say.
            # `label` carries a TRAILING SLASH (it is built for prefixing a
            # relative path, as "${label_prefix}${rel}"), so it is trimmed here
            # rather than interpolated raw: "${wt}/is outside" reads as a path
            # component named "is" and breaks a grep for the worktree path.
            command echo "$LOG_PREFIX ${label%/} is outside the project root — repairing symlinks there (case verdict not applied)" >&2

            saved_state="$FS_CASE_STATE"
            FS_CASE_STATE=unknown
            repair_repo_tree "$wt" "$label" 0
            FS_CASE_STATE="$saved_state"
        fi
    done < <("$FS_HEALTH_GIT" -C "$project_root" worktree list --porcelain 2>/dev/null |
        /usr/bin/awk '/^worktree / { print substr($0, 10) }')

    return 0
}

# ============================================================================
# Repo discovery
# ============================================================================

# Roots already covered this run, newline-delimited and resolved with `pwd -P`.
# Consulted by scan_root to make a second visit to the same directory a no-op.
FS_HEALTH_SCANNED=""

# Resolve a path the way the ledger stores it. Falls back to the literal path
# when it cannot be entered, which keeps an unreadable root comparable to itself.
fs_health_resolve() {
    (cd "$1" 2>/dev/null && pwd -P) || command printf '%s' "$1"
}

# True when this root has already been covered this run.
fs_health_seen() {
    case "
${FS_HEALTH_SCANNED}" in
        *"
$1
"*) return 0 ;;
    esac
    return 1
}

# Record a root as covered. Called by the two in-repo walks as well as by
# scan_root: a submodule or linked worktree repaired from the root that OWNS it
# must be marked, or depth-1 discovery would later emit that same directory as
# an independent project and scan it a second time — the walks run first, so
# marking there is what makes the ledger win.
fs_health_mark_scanned() {
    FS_HEALTH_SCANNED="${FS_HEALTH_SCANNED}$1
"
}

# Scan one repo root: detect its case-sensitivity, run both repairs across it
# and its submodules, then walk its linked worktrees.
#
# Args: $1 = repo root, $2 = display prefix for log lines ("" for a top-level
#       root; a submodule/worktree prefix is supplied by the walks themselves)
#
# SKIPS a root already covered earlier in this run. Depth-1 discovery and the
# two in-repo walks can legitimately name the same directory: when WORKSPACE_ROOT
# is itself a repo, an initialized submodule or a linked worktree sitting beside
# it at depth 1 has a `.git` FILE — exactly the shape discovery accepts — so it
# is reached once from the root that owns it (correctly labeled) and once again
# as if it were its own project.
#
# The duplicate is not merely noisy. The second pass reports the same path with
# NO label prefix, so `wt/AGENTS.md` and a bare `AGENTS.md` name one file while
# reading as two, and it re-probes case-sensitivity against a root the owning
# repo deliberately does not re-detect (see detect_case_state's per-repo rule and
# check_ignorecase's submodule note: a submodule shares its parent's mount, and
# core.ignorecase is not per-worktree at all).
#
# Resolved with `pwd -P` on both sides so a symlinked path component cannot make
# the same directory look like two — the same normalization, for the same
# reason, that repair_linked_worktrees applies to its own comparisons.
scan_root() {
    local root="$1" label_prefix="${2:-}"
    local resolved

    resolved=$(fs_health_resolve "$root")
    fs_health_seen "$resolved" && return 0
    fs_health_mark_scanned "$resolved"

    detect_case_state "$root"
    repair_repo_tree "$root" "$label_prefix" 0
    repair_linked_worktrees "$root" "$label_prefix"

    return 0
}

# Emit every git repo to scan, one per line, for a workspace-scope run.
#
# The workspace root itself comes first when it is a repo, then each depth-1
# subdirectory that is one. Depth 1 deliberately, not a recursive walk:
# /workspace is where mounts are attached, and descending further would
# rediscover this repo's own submodules and linked worktrees as if they were
# separate projects — repair_repo_tree and repair_linked_worktrees already reach
# both, from the root that owns them and with the labeling that makes their
# output readable.
#
# A worktree's .git is a FILE pointing at the real git dir, so -e, not -d.
# Entries that are not repos, and directories that cannot be read, are simply
# not emitted — a workspace legitimately holds non-repo directories, and neither
# is an error.
discover_repos() {
    local entry

    [ -d "$WORKSPACE_ROOT" ] || return 0

    if [ -e "${WORKSPACE_ROOT}/.git" ]; then
        command printf '%s\n' "$WORKSPACE_ROOT"
    fi

    # `find -mindepth 1 -maxdepth 1` rather than a `for entry in "$ROOT"/*`
    # glob: the glob yields the unexpanded pattern itself when the directory is
    # empty, and silently skips a dotted mount. -print0 keeps paths containing
    # spaces or newlines intact.
    while IFS= read -r -d '' entry; do
        [ -d "$entry" ] || continue
        [ -e "${entry}/.git" ] || continue
        command printf '%s\n' "$entry"
    done < <(/usr/bin/find "$WORKSPACE_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    return 0
}

# ============================================================================
# Run
# ============================================================================

if [ "$FS_HEALTH_SCOPE" = "single" ]; then
    # A worktree's .git is a *file* pointing at the real git dir, not a
    # directory, so accept either shape.
    #
    # The bail-out clears the snapshot: there is nothing here for the cron leg
    # to repair, and a snapshot left from an earlier boot would point it at a
    # project that is no longer mounted. This is the ONE path that still does
    # so — a workspace-scope run that finds no repos writes the snapshot instead
    # (see below), because "no repos under the workspace right now" is not the
    # same claim as "the single root you named is gone".
    if [ ! -e "${PROJECT_ROOT}/.git" ]; then
        remove_env_snapshot
        exit 0
    fi

    scan_root "$PROJECT_ROOT"
else
    FS_HEALTH_REPO_COUNT=0
    while IFS= read -r fs_health_repo; do
        [ -n "$fs_health_repo" ] || continue
        FS_HEALTH_REPO_COUNT=$((FS_HEALTH_REPO_COUNT + 1))

        # Label every line with the repo it came from (issue #828). The symlink
        # repair reports a path RELATIVE to its repo, which was unambiguous when
        # only one repo was ever scanned — but across a workspace the same
        # relative path usually exists in several repos at once (`AGENTS.md`,
        # `.codegraph`; the very files in the issue's own repro), so the bare
        # form names one file while reading as any of them.
        #
        # check_ignorecase already prints an absolute root, so this closes the
        # gap for the OTHER repair. The prefix carries a trailing slash because
        # it is interpolated as "${label_prefix}${rel}", and it composes with the
        # submodule/worktree prefixes appended beneath it —
        # "/workspace/app/.worktrees/issue-1/AGENTS.md".
        scan_root "$fs_health_repo" "${fs_health_repo%/}/"
    done < <(discover_repos)

    if [ "$FS_HEALTH_REPO_COUNT" -eq 0 ]; then
        # REPORT rather than exit silently (issue #828). "Nothing to inspect"
        # and "everything is healthy" were previously the same observable —
        # exit 0, no output — which is exactly how a container spent its entire
        # life repairing nothing without anyone noticing.
        if [ -d "$WORKSPACE_ROOT" ]; then
            command echo "$LOG_PREFIX no git repositories found under $WORKSPACE_ROOT — nothing to inspect" >&2
        else
            command echo "$LOG_PREFIX workspace root $WORKSPACE_ROOT does not exist — nothing to inspect" >&2
        fi
    fi
fi

# Record the resolved environment so the hourly cron leg can re-run this same
# script with the same scope and the same opt-out. Written last, so the snapshot
# only ever describes a run that actually completed.
#
# Written even when a workspace scan found ZERO repos, which is the point of the
# #828 fix: discovery re-runs on every invocation, so an empty workspace today
# must still leave the hourly leg armed for a repo mounted an hour from now.
# Removing the snapshot there is what made the old bail-out permanent.
write_env_snapshot
