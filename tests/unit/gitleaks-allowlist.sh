#!/usr/bin/env bash
# Unit tests for the Gitleaks allowlist configuration (.gitleaks.toml).
#
# Background (issue #852): example Kubernetes manifests carry base64
# placeholders whose whole purpose is to show the shape of a Secret. A
# full-history `gitleaks detect` flagged five of them and exited non-zero,
# while ordinary `pull_request` CI stayed green because that event scans only
# the PR's own commits. The red state therefore appeared only on a manual
# workflow_dispatch — exactly when someone is already debugging something else.
#
# .gitleaks.toml exempts those placeholders. The risk such a file introduces is
# that it is easy to write one that passes by scanning for nothing: omitting
# `[extend] useDefault = true` silently REPLACES the entire default rule set,
# and a path-scoped global [allowlist] blinds the scanner to a whole directory.
# Both make every scan green, which looks identical to "fixed". These tests
# pin the properties that distinguish a scoped allowlist from a disabled
# scanner.
#
# The structural assertions run anywhere. The two behavioral tests need the
# gitleaks binary (shipped by the dev-tools feature) and are skipped without
# it, mirroring the optional-tool convention in lefthook-optional-tools.sh.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "gitleaks allowlist configuration (#852)"

GITLEAKS_CONFIG="$PROJECT_ROOT/.gitleaks.toml"
EXAMPLE_SECRET="$PROJECT_ROOT/examples/kubernetes/base/secrets.yaml"

# --- Structural: the config exists and cannot silently disable scanning ---

test_config_exists() {
    assert_file_exists "$GITLEAKS_CONFIG" \
        ".gitleaks.toml must exist at the repo root (CI and lefthook both discover it there)"
}

# The single most dangerous omission. Without useDefault, this file replaces
# the default rules instead of extending them, so every scan passes and no
# secret is ever detected again.
test_extends_the_default_ruleset() {
    assert_file_contains "$GITLEAKS_CONFIG" "useDefault = true" \
        "[extend] useDefault must be true, or this config REPLACES all default rules"
}

# A bare [allowlist] table applies globally. Combined with a paths entry it
# exempts an entire directory from every rule — measured during #852 to hide a
# planted AWS key and GitHub PAT. The scoped [[allowlists]] form is required.
test_uses_scoped_allowlists_not_a_global_one() {
    local bare_tables
    bare_tables=$(/usr/bin/grep -cE '^\[allowlist\]' "$GITLEAKS_CONFIG" || true)
    assert_equals "0" "$bare_tables" \
        "use scoped [[allowlists]] entries, not a global [allowlist] table (#852)"
}

# The path exemption must name the rule it applies to. Unscoped, it would also
# disable generic-api-key and every provider token rule under examples/.
test_path_exemption_is_rule_scoped() {
    assert_file_contains "$GITLEAKS_CONFIG" "targetRules" \
        "the examples/ path exemption must be scoped with targetRules to a named rule"
}

# --- Behavioral: exercise the real scanner ---

if ! command -v gitleaks >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: gitleaks and/or jq not available — install both to run scan-behavior tests"
    run_test test_config_exists ".gitleaks.toml exists at the repo root"
    run_test test_extends_the_default_ruleset "[extend] useDefault = true is present"
    run_test test_uses_scoped_allowlists_not_a_global_one "uses scoped [[allowlists]], not a global [allowlist]"
    run_test test_path_exemption_is_rule_scoped "the examples/ path exemption is rule-scoped"
    generate_report
    exit 0
fi

# AC1: the full-history scan that used to fail must now pass.
#
# This scans ALL history, which is the scenario #852 is about: the placeholders
# live in commit 184f4a3b, and only a scan that walks back to it sees them.
#
# Two narrower options were tried and rejected, both because they pass
# vacuously — measured, not assumed:
#
#   --log-opts=-1  scans only the tip commit's patch. Once this lands and later
#                  commits stop touching secrets.yaml, gitleaks has nothing to
#                  examine and reports clean. Verified: with the allowlist
#                  deliberately gutted, that form STILL reported no leaks, so it
#                  could not have caught a regression in the thing it tests.
#   --no-git       walks the filesystem, including gitignored build output whose
#                  compiled byte runs trip entropy rules, making the result
#                  depend on whether a cargo build happened to run first.
#
# The cost is ~1.5s against ~2000 commits. That is high for a unit test, and
# accepted deliberately: a fast test that cannot fail is worth less than a slow
# one that can.
test_full_history_scan_is_clean() {
    local out rc=0
    out=$(cd "$PROJECT_ROOT" && gitleaks detect --redact --no-banner \
        --exit-code=2 2>&1) || rc=$?
    assert_equals "0" "$rc" \
        "a full-history gitleaks scan must exit 0 on a clean checkout (#852 AC1): $out"
}

# AC3: the load-bearing counter-test. A real credential planted in the very
# file the allowlist covers must still be caught — otherwise the allowlist is
# a disabled scanner wearing a scoped-looking hat.
#
# Token values are synthetic and well-formed only in shape. Note AKIA...EXAMPLE
# is deliberately NOT used: it is the canonical AWS documentation key, which
# stock gitleaks allowlists upstream, so it would prove nothing here.
test_real_secrets_are_still_detected() {
    local tmp_dir out rc=0 caught
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand tmp_dir now, not at trap time
    trap "/bin/rm -rf '$tmp_dir'" RETURN

    # The fixture must keep its repo-relative path: the rule-scoped allowlist
    # matches on `^examples/`, so a flat copy would be scanned as if it lived
    # outside examples/ and the exemption would (correctly) not apply.
    /bin/mkdir -p "$tmp_dir/examples/kubernetes/base"
    /bin/cp "$EXAMPLE_SECRET" "$tmp_dir/examples/kubernetes/base/secrets.yaml"
    /bin/cp "$GITLEAKS_CONFIG" "$tmp_dir/.gitleaks.toml"

    # The fixture tokens are ASSEMBLED AT RUNTIME rather than written as
    # literals. A complete `ghp_`/`xoxb-` token committed to the repo is
    # detected by GitHub Push Protection, which rejects the push outright —
    # the prefix is split from its body so no line here is a whole token.
    # They are synthetic either way (random hex; no corresponding workspace),
    # but a scanner cannot know that, and a test fixture is not worth an
    # allowlist exception on the hosting side.
    local gh_pfx='ghp' slack_pfx='xoxb'
    {
        /usr/bin/printf 'gh: %s_016C7B1DcE3aA9f2B4d5E6f7A8b9C0d1E2f3A4b5\n' "$gh_pfx"
        /usr/bin/printf 'slack: %s-263594206564-2343594206574-FGqxdvfKGwerCxdfVIBqweMs\n' "$slack_pfx"
    } >>"$tmp_dir/examples/kubernetes/base/secrets.yaml"

    # A JSON report is the stable interface for the rule names: without -v the
    # human-readable output prints only a "leaks found: N" count, so asserting
    # on rule names in stdout would be asserting on text that is never emitted.
    out=$(cd "$tmp_dir" && gitleaks detect --no-git --redact --no-banner \
        --exit-code=2 --config .gitleaks.toml \
        --report-format json --report-path findings.json 2>&1) || rc=$?

    assert_not_equals "0" "$rc" \
        "planted credentials in an allowlisted example file must still fail the scan (#852 AC3)"

    # `unique` already returns a sorted array, so no separate sort step is
    # needed — which also keeps the word "sort" out of this jq filter, where
    # the enforce-command-prefix hook would rewrite it to `command sort` and
    # break the expression.
    caught=$(jq -r '[.[].RuleID] | unique | join(",")' \
        "$tmp_dir/findings.json" 2>/dev/null || true)
    assert_equals "github-pat,slack-bot-token" "$caught" \
        "the planted github-pat and slack-bot-token must be exactly the findings reported: $out"
}

# The placeholders themselves must stay exempt — this is what #852 fixes. Run
# on an unmodified copy so the assertion is about the allowlist, not the tree.
test_placeholders_are_exempt() {
    local tmp_dir rc=0 out
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "/bin/rm -rf '$tmp_dir'" RETURN

    # Same path-fidelity requirement as the counter-test above.
    /bin/mkdir -p "$tmp_dir/examples/kubernetes/base"
    /bin/cp "$EXAMPLE_SECRET" "$tmp_dir/examples/kubernetes/base/secrets.yaml"
    /bin/cp "$GITLEAKS_CONFIG" "$tmp_dir/.gitleaks.toml"

    out=$(cd "$tmp_dir" && gitleaks detect --no-git --redact --no-banner \
        --exit-code=2 --config .gitleaks.toml 2>&1) || rc=$?
    assert_equals "0" "$rc" \
        "the example manifest's placeholder values must not be reported (#852): $out"
}

run_test test_config_exists ".gitleaks.toml exists at the repo root"
run_test test_extends_the_default_ruleset "[extend] useDefault = true is present"
run_test test_uses_scoped_allowlists_not_a_global_one "uses scoped [[allowlists]], not a global [allowlist]"
run_test test_path_exemption_is_rule_scoped "the examples/ path exemption is rule-scoped"
run_test test_full_history_scan_is_clean "a full-history scan exits 0 (AC1)"
run_test test_placeholders_are_exempt "example placeholder values are exempt"
run_test test_real_secrets_are_still_detected "planted real secrets are still caught (AC3)"

generate_report
