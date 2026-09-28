#!/usr/bin/env bash
# Unit tests for bin/regen-triage-lock.sh and its auto-patch wiring (issue #986)
#
# Background: the weekly auto-patch bumped the gitlab-triage pin in
# .gitlab/triage/Gemfile without regenerating Gemfile.lock, so every
# gitlab-triage release failed the Gemfile/lock sync test and blocked the whole
# release. The script regenerates the lock with bundler in the triage job's own
# image; the workflow reverts the bump into the skipped-updates hold gate when
# regeneration fails.
#
# The version readers are bin/lib/triage-gem.sh — the same ones the script
# uses. The docker stub below keeps its OWN Gemfile parse on purpose: it stands
# in for bundler, and reusing the code under test there would let a broken
# reader agree with itself.
#
# `docker` is a PATH stub that behaves like the real container would: it reads
# the tar stream on stdin, and in `ok` mode emits a lock resolving whatever
# version the STREAMED Gemfile pins. A stub that echoed a fixed version would
# let the "lock matches the pin" check pass on a state bundler never produces.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
# shellcheck source=bin/lib/triage-gem.sh
source "$PROJECT_ROOT/bin/lib/triage-gem.sh"

init_test_framework

test_suite "regen-triage-lock Tests"

SCRIPT="$PROJECT_ROOT/bin/regen-triage-lock.sh"
WORKFLOW="$PROJECT_ROOT/.github/workflows/auto-patch.yml"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# make_tree DIR VERSION IMAGE — a minimal project tree with a Gemfile pinned to
# VERSION, a lock still at 1.0.0, and a triage CI include naming IMAGE.
make_tree() {
    local dir="$1" version="$2" image="$3"
    command mkdir -p "$dir/.gitlab/triage" "$dir/.gitlab/ci"
    command cat >"$dir/.gitlab/triage/Gemfile" <<EOF
source "https://rubygems.org"

gem "gitlab-triage", "$version"
gem "racc"
EOF
    command cat >"$dir/.gitlab/triage/Gemfile.lock" <<'EOF'
GEM
  remote: https://rubygems.org/
  specs:
    gitlab-triage (1.0.0)

PLATFORMS
  ruby

DEPENDENCIES
  gitlab-triage (= 1.0.0)
EOF
    command cat >"$dir/.gitlab/ci/triage.yml" <<EOF
issue-triage:
  stage: .post
  image: $image
EOF
}

# make_docker_stub DIR — writes DIR/docker. Mode comes from STUB_MODE:
#   ok          lock resolving the streamed Gemfile's pin, both platforms
#   stale       lock still resolving 1.0.0 (bundler "succeeded" but no move)
#   noplatform  correct version, but no aarch64-linux platform
#   fail        exits non-zero, like a bundler resolution error
#   nogem       exits 0 but the lock has no gitlab-triage entry at all
# Every invocation's argv is appended to $STUB_LOG.
make_docker_stub() {
    local dir="$1"
    command mkdir -p "$dir"
    command cat >"$dir/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_LOG"
# Real `docker run` without -i hands the container an EMPTY stdin; mirror that
# so a script that dropped -i cannot pass by the stub reading the pipe anyway.
case " $* " in
    *" -i "*) ;;
    *) exec </dev/null ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xf -
version=$(grep -E '^gem "gitlab-triage"' "$work/Gemfile" |
    sed -E 's/.*,[[:space:]]*"([^"]+)".*/\1/')
case "${STUB_MODE:-ok}" in
    fail)
        echo "Could not find gem 'gitlab-triage'" >&2
        exit 1
        ;;
    stale) version=1.0.0 ;;
    nogem)
        printf 'GEM\n  specs:\n    racc (1.8.1)\n'
        exit 0
        ;;
esac
platforms="  aarch64-linux
  ruby
  x86_64-linux"
[ "${STUB_MODE:-ok}" = noplatform ] && platforms="  ruby
  x86_64-linux"
cat <<EOF
GEM
  remote: https://rubygems.org/
  specs:
    gitlab-triage ($version)

PLATFORMS
$platforms

DEPENDENCIES
  gitlab-triage (= $version)
EOF
STUB
    command chmod +x "$dir/docker"
}

# run_script TREE MODE — runs the script against TREE with the stub first on
# PATH. BASH_ENV is cleared: /etc/bash_env rebuilds PATH for non-interactive
# bash and would put the real docker back in front of the stub.
run_script() {
    local tree="$1" mode="$2"
    env -u BASH_ENV \
        PATH="$tree/stubs:$PATH" \
        STUB_MODE="$mode" \
        STUB_LOG="$tree/docker.log" \
        PROJECT_ROOT_OVERRIDE="$tree" \
        "$SCRIPT"
}

new_tree() {
    local tree
    tree=$(command mktemp -d)
    make_tree "$tree" "$@"
    make_docker_stub "$tree/stubs"
    : >"$tree/docker.log"
    command echo "$tree"
}

have_yq() { command -v yq >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Script behavior
# ---------------------------------------------------------------------------

test_regenerates_lock_to_gemfile_pin() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    local tree rc=0
    tree=$(new_tree 1.54.0 ruby:3.3.12-slim)
    run_script "$tree" ok >/dev/null 2>&1 || rc=$?

    local got
    got=$(triage_lock_version "$tree/.gitlab/triage/Gemfile.lock")
    command rm -rf "$tree"
    assert_equals "0:1.54.0" "$rc:$got" "lock regenerated to the Gemfile pin"
}

test_image_comes_from_triage_include() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    # A tag nothing else in the repo uses: if it reaches `docker run`, it can
    # only have come from the fixture's .gitlab/ci/triage.yml.
    local tree
    tree=$(new_tree 1.54.0 ruby:9.9.9-fixture)
    run_script "$tree" ok >/dev/null 2>&1 || true

    local ok=true
    command grep -q 'ruby:9.9.9-fixture' "$tree/docker.log" || {
        command echo "    docker was not run with the image from triage.yml"
        command cat "$tree/docker.log"
        ok=false
    }
    command grep -q 'ruby:3.3' "$tree/docker.log" && {
        command echo "    docker was run with a hardcoded Ruby image"
        ok=false
    }
    command rm -rf "$tree"
    assert_true "$ok" "resolver image is read from .gitlab/ci/triage.yml"
}

test_requests_both_platforms() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    local tree
    tree=$(new_tree 1.54.0 ruby:3.3.12-slim)
    run_script "$tree" ok >/dev/null 2>&1 || true

    local ok=true
    command grep -q -- '--add-platform x86_64-linux aarch64-linux' "$tree/docker.log" || ok=false
    command rm -rf "$tree"
    assert_true "$ok" "bundler is asked to add both x86_64 and aarch64 platforms"
}

# For each failure mode: non-zero exit AND the committed lock is untouched.
# The second half matters — a script that wrote the bad lock and then exited 1
# would leave the tree drifted for the workflow's revert to paper over.
assert_rejects_mode() {
    local mode="$1" label="$2" tree rc=0
    tree=$(new_tree 1.54.0 ruby:3.3.12-slim)
    run_script "$tree" "$mode" >/dev/null 2>&1 || rc=$?

    local got
    got=$(triage_lock_version "$tree/.gitlab/triage/Gemfile.lock")
    command rm -rf "$tree"
    if [ "$rc" -ne 0 ] && [ "$got" = "1.0.0" ]; then
        assert_true true "$label"
    else
        assert_true false "$label (rc=$rc, lock now at $got)"
    fi
}

test_fails_when_bundler_fails() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_rejects_mode fail "bundler failure exits non-zero and leaves the lock alone"
}

test_fails_when_lock_did_not_move() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_rejects_mode stale "a lock still at the old version is rejected"
}

test_fails_when_platform_missing() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_rejects_mode noplatform "a lock missing aarch64-linux is rejected"
}

test_fails_without_image() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    local tree rc=0
    tree=$(new_tree 1.54.0 ruby:3.3.12-slim)
    command printf 'issue-triage:\n  stage: .post\n' >"$tree/.gitlab/ci/triage.yml"
    run_script "$tree" ok >/dev/null 2>&1 || rc=$?

    local calls
    calls=$(command wc -l <"$tree/docker.log")
    command rm -rf "$tree"
    assert_equals "fail:0" "$([ "$rc" -ne 0 ] && echo fail || echo pass):$((calls))" \
        "missing image fails before docker is invoked"
}

test_missing_gem_is_diagnosed() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    # Under pipefail a grep miss inside the version helper used to abort the
    # assignment silently — non-zero, but with no ERROR line to say why.
    local tree output rc=0
    tree=$(new_tree 1.54.0 ruby:3.3.12-slim)
    output=$(run_script "$tree" nogem 2>&1) || rc=$?
    command rm -rf "$tree"
    if [ "$rc" -ne 0 ] && command grep -q "lock resolves gitlab-triage '<none>'" <<<"$output"; then
        assert_true true "a lock without gitlab-triage fails with an explanatory error"
    else
        command echo "    rc=$rc output: $output"
        assert_true false "a lock without gitlab-triage fails with an explanatory error"
    fi
}

# ---------------------------------------------------------------------------
# Workflow wiring — the snippet is EXTRACTED from auto-patch.yml and executed,
# so these tests exercise the shipped logic rather than pinning its text.
# ---------------------------------------------------------------------------

# extract_regen_block — prints the `if ! git diff --quiet -- .gitlab/triage/Gemfile`
# block from the apply-updates step, de-indented by yq.
extract_regen_block() {
    yq -r '.jobs["version-check"].steps[]
        | select(.name == "Create auto-patch branch and apply updates") | .run' \
        "$WORKFLOW" |
        command awk '
            /^if ! git diff --quiet -- \.gitlab\/triage\/Gemfile; then$/ { on = 1 }
            on { print }
            on && /^fi$/ { exit }
        '
}

# run_block MODE BUMP — in a scratch git repo holding a committed Gemfile/lock,
# optionally bump the Gemfile, then run the extracted block with a stub
# bin/regen-triage-lock.sh (MODE ok|fail). Prints
# "<UPDATE_SKIPS>:<gemfile pin>:<lock pin>:<regen calls>".
run_block() {
    local mode="$1" bump="$2" repo block
    block=$(extract_regen_block)
    repo=$(command mktemp -d)
    make_tree "$repo" 1.0.0 ruby:3.3.12-slim
    command mkdir -p "$repo/bin"
    command cat >"$repo/bin/regen-triage-lock.sh" <<'STUB'
#!/usr/bin/env bash
echo call >>"$REGEN_LOG"
sed -i 's/gitlab-triage (1.0.0)/gitlab-triage (2.0.0)/; s/gitlab-triage (= 1.0.0)/gitlab-triage (= 2.0.0)/' .gitlab/triage/Gemfile.lock
# Fail AFTER writing: the revert must restore the lock too, not just the Gemfile.
[ "$REGEN_MODE" = ok ] || { echo "resolver failed" >&2; exit 1; }
STUB
    command chmod +x "$repo/bin/regen-triage-lock.sh"
    : >"$repo/regen.log"
    (
        # The pre-push hook exports GIT_DIR; a leaked one points git at the
        # real repo instead of this scratch one.
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        cd "$repo"
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
        export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
        command git init -q .
        command git add .gitlab
        command git commit -q -m fixture
        [ "$bump" = yes ] &&
            command sed -i 's/"gitlab-triage", "1.0.0"/"gitlab-triage", "2.0.0"/' .gitlab/triage/Gemfile
        export REGEN_MODE="$mode" REGEN_LOG="$repo/regen.log"
        UPDATE_SKIPS=false
        eval "$block" >/dev/null 2>&1
        gem=$(triage_gemfile_version .gitlab/triage/Gemfile)
        command echo "$UPDATE_SKIPS:$gem:$(triage_lock_version .gitlab/triage/Gemfile.lock):$(command wc -l <regen.log)"
    )
    command rm -rf "$repo"
}

test_workflow_block_is_extractable() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    local block
    block=$(extract_regen_block)
    # Guards the tests below: an empty extraction would run nothing and
    # "pass" every no-change expectation.
    if command grep -q 'regen-triage-lock.sh' <<<"$block" &&
        command grep -q '^fi$' <<<"$block"; then
        assert_true true "auto-patch lock-regeneration block found"
    else
        assert_true false "could not extract the lock-regeneration block from auto-patch.yml"
    fi
}

test_workflow_success_keeps_bump() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_equals "false:2.0.0:2.0.0:1" "$(run_block ok yes)" \
        "successful regeneration keeps the bump and does not hold the PR"
}

test_workflow_failure_reverts_and_holds() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_equals "true:1.0.0:1.0.0:1" "$(run_block fail yes)" \
        "failed regeneration reverts Gemfile+lock and sets UPDATE_SKIPS"
}

test_workflow_skips_when_gemfile_unchanged() {
    have_yq || {
        skip_test "yq not available"
        return
    }
    assert_equals "false:1.0.0:1.0.0:0" "$(run_block ok no)" \
        "no Gemfile change means no regeneration"
}

run_test test_regenerates_lock_to_gemfile_pin "Regenerates the lock to the Gemfile pin"
run_test test_image_comes_from_triage_include "Resolver image comes from triage.yml"
run_test test_requests_both_platforms "Requests x86_64 and aarch64 platforms"
run_test test_fails_when_bundler_fails "Bundler failure is fatal and non-destructive"
run_test test_fails_when_lock_did_not_move "Stale lock is rejected"
run_test test_fails_when_platform_missing "Missing platform is rejected"
run_test test_missing_gem_is_diagnosed "Lock without the gem is diagnosed, not silent"
run_test test_fails_without_image "Missing image fails before docker runs"
run_test test_workflow_block_is_extractable "auto-patch block is extractable"
run_test test_workflow_success_keeps_bump "Workflow: success keeps the bump"
run_test test_workflow_failure_reverts_and_holds "Workflow: failure reverts and holds"
run_test test_workflow_skips_when_gemfile_unchanged "Workflow: unchanged Gemfile skips regeneration"

generate_report
