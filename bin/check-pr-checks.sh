#!/usr/bin/env bash
# check-pr-checks — decide whether a PR's check-run rollup permits a merge,
# with ZERO CHECKS treated as NOT PASSING rather than NOT FAILING.
#
# Issue #854. PR #848 was reported as "pull_request never fired — zero checks,
# indefinitely". The premise was false: four pull_request runs exist for
# feature/issue-832, created 2026-08-26T16:59:30Z against a PR opened at
# 16:45:44Z. The events were not lost, they were QUEUED — 13m46s late. PR #847,
# cited in that report as the healthy control, was 17m44s late in the same
# 35-minute window. PRs on either side of the window (#834, #855) and the
# current baseline (#896/#895/#893) arrive in 3-4 SECONDS. Repo Actions
# settings (allowed_actions=all), ci.yml concurrency (none), and pull_request
# path filters (none) were all ruled out. Root cause: a transient GitHub
# Actions event-delivery backlog. Nothing in this repo caused it and nothing
# here can prevent it.
#
# What CAN be prevented is the consequence. During those ~14 minutes the PR
# presented as zero checks, and zero checks is ambiguous between "has not
# started YET" and "will NEVER start". Every gate keyed on "no failures"
# resolves that ambiguity the dangerous way: `gh pr checks` prints the
# reassuring "no checks reported on the 'X' branch", the ship-issue CI poll
# waits "until no checks have state: pending" — which an EMPTY list satisfies
# instantly — and main has no branch protection to backstop it. A merge in that
# window is green-lit by the absence of evidence.
#
# The only thing that disambiguates not-yet from never is ELAPSED TIME, so this
# script is a clock plus a classifier:
#
#   effective_checks = total - skipping
#       Raw counts cannot be used. 13 of PR #896's 23 checks sit in the
#       `skipping` bucket, and that is the healthy steady state here, so a
#       "count > 0" guard would pass a PR on which nothing actually ran.
#       `cancel` folds into `failing` — a cancelled check did not report
#       success.
#
#   effective_checks == 0 and age <= grace  -> pending  (normal 3-4s window)
#   effective_checks == 0 and age >  grace  -> absent   (#854: NOT passing)
#
# Subcommand (emits `key=value` lines to stdout):
#   verdict --age-sec S [--rollup-json <file|->]
#   verdict --age-sec S --total N --failing N --pending N --skipping N
#           [--cancelled N] [--now EPOCH]
#     -> verdict          pass | fail | absent | pending
#        mergeable        true only for `pass`
#        effective_checks total - skipping
#        total_checks failing pending skipping age_sec grace_sec
#        reason          checks_passed | checks_failed |
#                        zero_checks_past_grace | zero_checks_within_grace |
#                        checks_still_running
#
# --rollup-json consumes `gh pr view <N> --json createdAt,statusCheckRollup`
# from a file or stdin (`-`). That GraphQL shape has NO `bucket` field — that
# one belongs to `gh pr checks` — and spells every outcome in UPPERCASE via
# .status/.conclusion (CheckRun) or .state (StatusContext). See the classifier
# below for the mapping.
#
# This script does NOT call gh and does NOT poll. gh runs in the model runtime;
# this owns the DECISION and the bucket CLASSIFICATION so that neither is
# re-derived by hand on each poll (the #588 drift shape: a documented knob wired
# to no code). It is orthogonal to the ship-issue CI wait timer: that one bounds
# how LONG to wait, this one decides whether what you are looking at may be
# merged. `absent` does not mean stop waiting; it means do not auto-merge.
#
# The grace boundary is strict: age == grace is still `pending`; only
# age > grace becomes `absent`.
#
# Usage: check-pr-checks.sh verdict --age-sec S [--rollup-json <file|->]
#                                   [--total N --failing N --pending N
#                                    --skipping N --cancelled N --now EPOCH]
# Env:   PR_CHECKS_GRACE_SEC  seconds before zero checks become `absent`,
#                             default 300 (~75x the measured 3-4s baseline,
#                             well inside the 13m46s #854 incident).
# Exit:  0 pass, 1 fail, 2 usage/IO error, 3 absent (zero checks past grace),
#        4 pending. Exit 0 means MERGEABLE and nothing else.

set -uo pipefail

GRACE_DEFAULT=300

AGE_SEC=""
ROLLUP_JSON=""
TOTAL=""
FAILING=""
PENDING=""
SKIPPING=""
CANCELLED="0"
NOW=""

# Print the Usage/Env/Exit block from this file's own header. Anchored on
# content rather than line numbers so editing the rationale above cannot
# silently truncate the help text.
usage() {
    command sed -n '/^# Usage: check-pr-checks/,/^#        4 pending/p' "$0" |
        command sed 's/^# \{0,1\}//'
}

die() {
    command echo "ERROR: $1" >&2
    exit 2
}

# A non-negative integer, and nothing else. Rejects empty, negative, decimal,
# whitespace, and leading-plus forms rather than letting bash arithmetic coerce
# them into a wrong verdict.
require_uint() {
    local value="$1" name="$2"
    case "$value" in
        '') die "$name is required" ;;
        *[!0-9]*) die "$name must be a non-negative integer, got '$value'" ;;
    esac
}

if [ $# -eq 0 ]; then
    usage
    exit 2
fi

case "$1" in
    verdict)
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        die "unknown subcommand '$1' (expected: verdict)"
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --age-sec | --rollup-json | --total | --failing | --pending | --skipping | --cancelled | --now)
            # Every one of these flags takes a value, so the arity check lives
            # here once rather than eight times. It is load-bearing, not
            # defensive: `shift 2` with only one positional left FAILS and, under
            # `set -uo pipefail` (no -e), leaves the positionals UNCHANGED. The
            # loop would then re-enter this same arm forever, spinning at 100%
            # CPU with no output — a trailing `--age-sec` used to hang until
            # killed instead of exiting 2.
            [ $# -ge 2 ] || die "$1 requires a value"
            case "$1" in
                --age-sec) AGE_SEC="$2" ;;
                --rollup-json) ROLLUP_JSON="$2" ;;
                --total) TOTAL="$2" ;;
                --failing) FAILING="$2" ;;
                --pending) PENDING="$2" ;;
                --skipping) SKIPPING="$2" ;;
                --cancelled) CANCELLED="$2" ;;
                --now) NOW="$2" ;;
            esac
            shift 2
            ;;
        *)
            die "unknown flag '$1'"
            ;;
    esac
done

# Grace is read from the environment on every run. If this read is removed the
# default silently wins and an operator-widened window has no effect — the
# exact failure shape #588 documented.
GRACE_SEC="${PR_CHECKS_GRACE_SEC:-$GRACE_DEFAULT}"
require_uint "$GRACE_SEC" "PR_CHECKS_GRACE_SEC"

if [ -n "$ROLLUP_JSON" ]; then
    command -v jq >/dev/null 2>&1 || die "--rollup-json requires jq"

    if [ "$ROLLUP_JSON" = "-" ]; then
        payload="$(command cat)"
    else
        [ -f "$ROLLUP_JSON" ] || die "rollup file not found: $ROLLUP_JSON"
        payload="$(command cat "$ROLLUP_JSON")"
    fi

    command printf '%s' "$payload" | jq -e . >/dev/null 2>&1 ||
        die "--rollup-json input is not valid JSON"

    # `gh pr view --json statusCheckRollup` is the GraphQL shape and carries NO
    # `bucket` field — that one belongs to `gh pr checks`. Two node types appear
    # here and they spell their outcome differently:
    #   CheckRun      -> .status (QUEUED|IN_PROGRESS|COMPLETED)
    #                    .conclusion (SUCCESS|FAILURE|SKIPPED|CANCELLED|...)
    #   StatusContext -> .state (SUCCESS|FAILURE|PENDING|ERROR)
    # All values are UPPERCASE. Matching lowercase here silently counts zero for
    # every category, which reads as a clean pass — the precise failure this
    # script exists to prevent, so the classification is pinned by tests.
    ROLLUP_CLASS='
      [ .statusCheckRollup[]? | (
          if .__typename == "StatusContext" then
            (.state // "")
          elif (.status // "") != "COMPLETED" then
            "PENDING"
          else
            (.conclusion // "")
          end
      ) ]'

    TOTAL="$(command printf '%s' "$payload" | jq "$ROLLUP_CLASS | length")"
    SKIPPING="$(command printf '%s' "$payload" | jq "$ROLLUP_CLASS | map(select(. == \"SKIPPED\" or . == \"NEUTRAL\")) | length")"
    PENDING="$(command printf '%s' "$payload" | jq "$ROLLUP_CLASS | map(select(. == \"PENDING\" or . == \"EXPECTED\")) | length")"
    CANCELLED="$(command printf '%s' "$payload" | jq "$ROLLUP_CLASS | map(select(. == \"CANCELLED\")) | length")"

    # Failing is computed by EXCLUSION, not by enumerating failure names. An
    # allowlist of failure strings fails OPEN: a value this script does not
    # recognize — a null conclusion on a COMPLETED run, a status GitHub adds
    # later, an unfamiliar __typename — would land in none of the buckets, still
    # count toward effective_checks, and emerge as `pass`. That is the precise
    # shape of the bug this whole script exists to prevent, so the unknown case
    # must resolve to "not a success" rather than "not a failure". Only an
    # explicit SUCCESS counts as passing.
    FAILING="$(command printf '%s' "$payload" | jq "$ROLLUP_CLASS | map(select(
        . != \"SUCCESS\"
        and . != \"SKIPPED\" and . != \"NEUTRAL\"
        and . != \"PENDING\" and . != \"EXPECTED\"
        and . != \"CANCELLED\"
    )) | length")"

    # Derive age from createdAt when the caller did not pass one explicitly, so
    # a single `gh pr view --json createdAt,statusCheckRollup` is enough input.
    if [ -z "$AGE_SEC" ]; then
        created="$(command printf '%s' "$payload" | jq -r '.createdAt // empty')"
        [ -n "$created" ] || die "--age-sec omitted and rollup JSON has no createdAt"

        created_epoch="$(command date -u -d "$created" +%s 2>/dev/null)" ||
            die "could not parse createdAt '$created'"

        now_epoch="${NOW:-$(command date -u +%s)}"
        require_uint "$now_epoch" "--now"

        if [ "$now_epoch" -lt "$created_epoch" ]; then
            die "--now ($now_epoch) precedes createdAt ($created_epoch)"
        fi
        AGE_SEC=$((now_epoch - created_epoch))
    fi
fi

require_uint "$AGE_SEC" "--age-sec"
require_uint "$TOTAL" "--total"
require_uint "$FAILING" "--failing"
require_uint "$PENDING" "--pending"
require_uint "$SKIPPING" "--skipping"
require_uint "$CANCELLED" "--cancelled"

if [ "$SKIPPING" -gt "$TOTAL" ]; then
    die "--skipping ($SKIPPING) exceeds --total ($TOTAL)"
fi

# A cancelled check did not report success, so it counts against the merge
# exactly as a failure does.
FAILING_TOTAL=$((FAILING + CANCELLED))

# Skipped checks are not evidence that anything ran. On this repo the healthy
# steady state is majority-skipping, so subtracting them is what makes the
# zero-check test meaningful at all.
EFFECTIVE=$((TOTAL - SKIPPING))

if [ "$FAILING_TOTAL" -gt 0 ]; then
    VERDICT="fail"
    REASON="checks_failed"
    CODE=1
elif [ "$EFFECTIVE" -eq 0 ]; then
    if [ "$AGE_SEC" -gt "$GRACE_SEC" ]; then
        VERDICT="absent"
        REASON="zero_checks_past_grace"
        CODE=3
    else
        VERDICT="pending"
        REASON="zero_checks_within_grace"
        CODE=4
    fi
elif [ "$PENDING" -gt 0 ]; then
    VERDICT="pending"
    REASON="checks_still_running"
    CODE=4
else
    VERDICT="pass"
    REASON="checks_passed"
    CODE=0
fi

if [ "$VERDICT" = "pass" ]; then
    MERGEABLE="true"
else
    MERGEABLE="false"
fi

command echo "verdict=$VERDICT"
command echo "mergeable=$MERGEABLE"
command echo "effective_checks=$EFFECTIVE"
command echo "total_checks=$TOTAL"
command echo "failing=$FAILING_TOTAL"
command echo "pending=$PENDING"
command echo "skipping=$SKIPPING"
command echo "age_sec=$AGE_SEC"
command echo "grace_sec=$GRACE_SEC"
command echo "reason=$REASON"

exit "$CODE"
