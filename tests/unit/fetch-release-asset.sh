#!/usr/bin/env bash
# Unit tests for bin/fetch-release-asset.sh (#1607).
#
# CI fetches its pinned toolchain through this helper: cache first, then curl
# with retries on every transient error, then `gh release download` (the API
# asset path, which kept serving during the releases/download 504 outage).
# curl and gh are stubbed on PATH, so nothing touches the network. Each stub
# logs its argv to $TEST_TEMP_DIR/calls so the cases can assert which path
# actually ran — an exit code alone passes for the wrong reason.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "fetch-release-asset.sh (#1607)"

FETCH="$PROJECT_ROOT/bin/fetch-release-asset.sh"
URL="https://github.com/acme/widget/releases/download/v1.2.3/widget_linux_amd64.tar.gz"

# _stubs <curl_mode> <gh_mode> — write curl/gh stubs into $TEST_TEMP_DIR/bin.
#   ok   → write "<tool>-payload" to the -o/-O target and exit 0
#   fail → exit 22 (curl's -f HTTP error) without writing
_stubs() {
    local bin="$TEST_TEMP_DIR/bin"
    command mkdir -p "$bin"
    command cat >"$bin/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"$TEST_TEMP_DIR/calls"
[ "$1" = ok ] || exit 22
while [ \$# -gt 0 ]; do
    if [ "\$1" = -o ]; then printf 'curl-payload' >"\$2"; fi
    shift
done
EOF
    command cat >"$bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"$TEST_TEMP_DIR/calls"
[ "$2" = ok ] || exit 1
while [ \$# -gt 0 ]; do
    if [ "\$1" = -O ]; then printf 'gh-payload' >"\$2"; fi
    shift
done
EOF
    command chmod +x "$bin/curl" "$bin/gh"
    : >"$TEST_TEMP_DIR/calls"
}

# _fetch [url] — run the helper with the stubs first on PATH. BASH_ENV is
# cleared: /etc/bash_env rebuilds PATH for every non-interactive bash, which
# would silently drop the stubs and hit the network. Sets RC and OUT.
_fetch() {
    local url="${1:-$URL}"
    RC=0
    OUT=$(/usr/bin/env BASH_ENV='' \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        TOOLCHAIN_CACHE_DIR="${CACHE_DIR:-}" \
        FETCH_RETRY_DELAY=0 \
        bash "$FETCH" "$url" "$TEST_TEMP_DIR/out" 2>&1) || RC=$?
}

_calls() { command cat "$TEST_TEMP_DIR/calls"; }

test_curl_success_writes_dest() {
    _stubs ok ok
    CACHE_DIR=""
    _fetch
    assert_equals "0" "$RC" "helper exits 0 when curl succeeds"
    assert_equals "curl-payload" "$(command cat "$TEST_TEMP_DIR/out")" "DEST holds curl's download"
    assert_not_contains "$(_calls)" "gh " "gh fallback is not used when curl succeeds"
}

test_curl_retries_every_transient_error() {
    _stubs ok ok
    CACHE_DIR=""
    _fetch
    assert_contains "$(_calls)" "--retry 5" "curl retries 5 times by default"
    assert_contains "$(_calls)" "--retry-all-errors" "curl retries every transient error, 5xx included"
    assert_contains "$(_calls)" "-f" "curl fails on HTTP errors (so a 504 page is never saved as the asset)"
}

test_falls_back_to_gh_api_path() {
    _stubs fail ok
    CACHE_DIR=""
    _fetch
    assert_equals "0" "$RC" "helper recovers through gh when curl fails"
    assert_equals "gh-payload" "$(command cat "$TEST_TEMP_DIR/out")" "DEST holds gh's download"
    assert_contains "$(_calls)" "gh release download v1.2.3 -R acme/widget -p widget_linux_amd64.tar.gz" \
        "gh is asked for the same tag/repo/asset the URL names"
}

# A tag containing a slash (dprint's `@biomejs/biome@X` style) must keep the
# whole tag, not just its last segment.
test_fallback_keeps_slashed_tag() {
    _stubs fail ok
    CACHE_DIR=""
    _fetch "https://github.com/biomejs/biome/releases/download/@biomejs/biome@2.6.3/biome-linux-x64"
    assert_equals "0" "$RC" "helper recovers through gh for a slashed tag"
    assert_contains "$(_calls)" "gh release download @biomejs/biome@2.6.3 -R biomejs/biome -p biome-linux-x64" \
        "the full slashed tag reaches gh"
}

test_both_paths_fail() {
    _stubs fail fail
    CACHE_DIR=""
    _fetch
    assert_not_equals "0" "$RC" "helper fails when curl and gh both fail"
    assert_contains "$OUT" "::error::failed to download" "the failure is an annotated error"
    assert_file_not_exists "$TEST_TEMP_DIR/out" "no DEST is left behind on failure"
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR" -maxdepth 1 -name 'out.part.*')
    assert_empty "$leftovers" "no partial temp file is left behind"
}

test_non_github_url_has_no_fallback() {
    _stubs fail ok
    CACHE_DIR=""
    _fetch "https://example.com/files/tool.tar.gz"
    assert_not_equals "0" "$RC" "a non-GitHub URL fails when curl fails"
    assert_not_contains "$(_calls)" "gh " "gh is not tried for a non-GitHub URL"
}

test_download_populates_cache_and_second_fetch_hits() {
    _stubs ok ok
    CACHE_DIR="$TEST_TEMP_DIR/cache"
    _fetch
    assert_equals "0" "$RC" "first fetch succeeds"
    assert_contains "$OUT" "downloaded: widget_linux_amd64.tar.gz" "first fetch reports a download"

    : >"$TEST_TEMP_DIR/calls"
    command rm -f "$TEST_TEMP_DIR/out"
    _fetch
    assert_equals "0" "$RC" "second fetch succeeds"
    assert_contains "$OUT" "cache hit: widget_linux_amd64.tar.gz" "second fetch reports a cache hit"
    assert_empty "$(_calls)" "a cache hit runs neither curl nor gh"
    assert_equals "curl-payload" "$(command cat "$TEST_TEMP_DIR/out")" "the cached bytes land in DEST"
}

# Several pinned assets carry no version in their name (yq_linux_amd64), so
# the cache must key on the whole URL or a bump would reuse the old binary.
test_cache_is_keyed_by_url_not_name() {
    _stubs ok ok
    CACHE_DIR="$TEST_TEMP_DIR/cache"
    _fetch "https://github.com/mikefarah/yq/releases/download/v4.0.0/yq_linux_amd64"
    : >"$TEST_TEMP_DIR/calls"
    _fetch "https://github.com/mikefarah/yq/releases/download/v4.0.1/yq_linux_amd64"
    assert_equals "0" "$RC" "fetch of the bumped version succeeds"
    assert_not_contains "$OUT" "cache hit" "a different version of a same-named asset is not a cache hit"
    assert_contains "$(_calls)" "v4.0.1/yq_linux_amd64" "the bumped version is actually downloaded"
}

test_rejects_bad_usage() {
    RC=0
    OUT=$(bash "$FETCH" "$URL" 2>&1) || RC=$?
    assert_not_equals "0" "$RC" "a missing DEST is a usage error"
    assert_contains "$OUT" "usage:" "the usage error says how to call it"
}

run_test test_curl_success_writes_dest "curl success writes DEST without the gh fallback"
run_test test_curl_retries_every_transient_error "curl retries every transient error"
run_test test_falls_back_to_gh_api_path "a curl failure falls back to gh release download"
run_test test_fallback_keeps_slashed_tag "the gh fallback keeps a tag containing slashes"
run_test test_both_paths_fail "total failure exits non-zero and leaves nothing behind"
run_test test_non_github_url_has_no_fallback "a non-GitHub URL gets no gh fallback"
run_test test_download_populates_cache_and_second_fetch_hits "a download fills the cache; the next fetch is a hit"
run_test test_cache_is_keyed_by_url_not_name "a version bump of a same-named asset misses the cache"
run_test test_rejects_bad_usage "bad usage is rejected"

generate_report
