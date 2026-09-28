#!/usr/bin/env bash
# Regenerate .gitlab/triage/Gemfile.lock with a real Ruby resolver
#
# The weekly auto-patch updater can rewrite the gitlab-triage pin in
# .gitlab/triage/Gemfile, but the lock must come from bundler itself — a
# hand-edited lock would checksum-verify against invented data. This script
# runs bundler inside the SAME image the scheduled triage job uses (read from
# .gitlab/ci/triage.yml, so there is no second copy of the tag to drift), then
# verifies the result actually resolves the version the Gemfile pins.
#
# Called by .github/workflows/auto-patch.yml whenever the Gemfile changed
# (issue #986); equally the maintainer's local command after a manual bump.
#
# Usage:
#   ./bin/regen-triage-lock.sh [--help]
#
# Environment:
#   PROJECT_ROOT_OVERRIDE  Operate on this tree instead of the repo (tests)
#
# Requires: docker, yq (mikefarah v4), tar
#
# Exit codes:
#   0  lock regenerated and matches the Gemfile pin
#   1  any failure (missing tool/file, bundler failure, lock still drifted)

set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(dirname "$BIN_DIR")}"
# shellcheck source=bin/lib/triage-gem.sh
source "${BIN_DIR}/lib/triage-gem.sh"

TRIAGE_DIR="$PROJECT_ROOT/.gitlab/triage"
CI_INCLUDE="$PROJECT_ROOT/.gitlab/ci/triage.yml"
GEMFILE="$TRIAGE_DIR/Gemfile"
LOCK="$TRIAGE_DIR/Gemfile.lock"

die() {
    command echo "ERROR: $*" >&2
    exit 1
}

case "${1:-}" in
    -h | --help)
        command sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1 (see --help)" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v yq >/dev/null 2>&1 || die "yq not found"
command -v tar >/dev/null 2>&1 || die "tar not found"
[ -f "$GEMFILE" ] || die "missing $GEMFILE"
[ -f "$CI_INCLUDE" ] || die "missing $CI_INCLUDE"

# The job's image is the resolver's image: the locked graph contains native
# extensions (bigdecimal), so resolving under a different Ruby could pick
# versions the job cannot install.
image=$(yq -r '.["issue-triage"].image // ""' "$CI_INCLUDE")
[ -n "$image" ] && [ "$image" != "null" ] ||
    die "could not read issue-triage.image from $CI_INCLUDE"

want=$(triage_gemfile_version "$GEMFILE")
[ -n "$want" ] || die "no gitlab-triage pin found in $GEMFILE"

command echo "Regenerating Gemfile.lock for gitlab-triage $want in $image"

# Stream the Gemfile (and the current lock, so bundler updates conservatively
# rather than re-resolving the whole graph) in over stdin and read the new lock
# back over stdout. No bind mount: that works identically on a CI runner and in
# a devcontainer talking to a host daemon (where container paths are not
# shareable), and there is no root-owned file left in the tree. Everything but
# the lock goes to stderr. build-essential: bigdecimal compiles during
# resolution (see the Gemfile header).
inputs=(Gemfile)
[ -f "$LOCK" ] && inputs+=(Gemfile.lock)

tmp_lock=$(command mktemp)
trap 'command rm -f "$tmp_lock"' EXIT

command tar -C "$TRIAGE_DIR" -cf - "${inputs[@]}" |
    docker run -i --rm "$image" bash -euo pipefail -c '
        mkdir /triage && cd /triage && tar -xf -
        {
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends build-essential
            bundle lock
            bundle lock --add-platform x86_64-linux aarch64-linux
        } >&2
        cat Gemfile.lock
    ' >"$tmp_lock" || die "bundler failed to regenerate the lock"

# A zero exit is not proof the lock moved — verify the outcome before it
# replaces the committed lock.
got=$(triage_lock_version "$tmp_lock")
[ "$got" = "$want" ] ||
    die "lock resolves gitlab-triage '${got:-<none>}', Gemfile pins '$want'"

for plat in x86_64-linux aarch64-linux; do
    command grep -qE "^[[:space:]]+${plat}\$" "$tmp_lock" ||
        die "lock does not register the $plat platform"
done

command cat "$tmp_lock" >"$LOCK"

command echo "Gemfile.lock regenerated: gitlab-triage $got"
