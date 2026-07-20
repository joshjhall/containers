#!/usr/bin/env bash
# Unit tests for GitLab issue templates + label-automation policy (issue #298).
#
# These are the cheap structural guardrails that keep the GitLab web-UI filing
# path consistent with the taxonomy in docs/development/filing-issues.md and the
# scheduled `gitlab-triage` automation. They catch obvious regressions before a
# change lands — a template that drops its `type/*` quick action, a Triage block
# that loses a field, or a policy that stops covering a severity/effort value.
#
# Tested invariants:
#   - All three issue templates exist and are non-empty
#   - Each template carries its `/label ~"type/..."` quick action
#   - Each template contains the required H2 body anchors
#   - Each template embeds the machine-readable Triage block (Severity + Effort)
#   - The triage policy and CI include exist and are valid YAML
#   - The policy references needs-triage and every severity/* and effort/* value
#   - The CI include documents the GITLAB_API_TOKEN requirement
#   - The policy's severity/effort `ruby:` regexes, executed against each
#     template's real Triage block, match exactly that block's value and no
#     sibling value (functional, issue #717)
#   - Every severity/* and effort/* regex matches a synthetic description
#     carrying its value (true-positive path exercised even for values no
#     shipped template defaults to)
#   - A deliberately-broken anchor flips the regex result (the functional test
#     has teeth)
#
# The functional regex tests require a Ruby interpreter (the engine
# gitlab-triage uses) and yq; they skip gracefully when either is absent.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "GitLab issue templates and label automation"

GITLAB_DIR="$PROJECT_ROOT/.gitlab"
TEMPLATE_DIR="$GITLAB_DIR/issue_templates"
POLICY_FILE="$GITLAB_DIR/triage/triage-policies.yml"
CI_INCLUDE="$GITLAB_DIR/ci/triage.yml"

# Template file → the type/* quick action it must apply.
declare -A TEMPLATE_TYPE=(
    ["Bug Report.md"]="type/bug"
    ["Feature Request.md"]="type/feature"
    ["Refactor.md"]="type/refactor"
)

# H2 anchors every template must carry (parsed by /next-issue).
REQUIRED_ANCHORS=(
    "## Summary"
    "## Problem"
    "## Proposed Solution"
    "## Acceptance Criteria"
    "## Affected Files"
    "## Context"
)

# Type-specific H2 sections each template must carry, per the "Type-specific
# sections" rule in docs/development/filing-issues.md. Newline-separated so a
# template can require more than one.
declare -A TEMPLATE_SPECIFIC_ANCHORS=(
    ["Bug Report.md"]=$'## Steps to Reproduce\n## Expected Behavior'
    ["Feature Request.md"]=$'## User Story'
    ["Refactor.md"]=$'## Current State\n## Target State'
)

# Label values the policy must cover, one rule each.
SEVERITY_VALUES=(critical high medium low)
EFFORT_VALUES=(trivial small medium large)

test_templates_exist_and_nonempty() {
    local missing=0 name
    for name in "${!TEMPLATE_TYPE[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        if [ ! -s "$file" ]; then
            /usr/bin/echo "  missing or empty: $file"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        assert_true true "all three issue templates exist and are non-empty"
    else
        assert_true false "$missing template(s) missing or empty"
    fi
}

test_templates_have_type_quick_action() {
    local violations=0 name
    for name in "${!TEMPLATE_TYPE[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        local type="${TEMPLATE_TYPE[$name]}"
        [ -f "$file" ] || {
            violations=$((violations + 1))
            continue
        }
        # Quick action form: /label ~"type/bug"
        if ! /usr/bin/grep -qF "/label ~\"$type\"" "$file"; then
            /usr/bin/echo "  $name: missing /label quick action for $type"
            violations=$((violations + 1))
        fi
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "every template applies its type/* label via /label"
    else
        assert_true false "$violations template(s) missing their type/* quick action"
    fi
}

test_templates_have_required_anchors() {
    local violations=0 name anchor
    for name in "${!TEMPLATE_TYPE[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        [ -f "$file" ] || {
            violations=$((violations + 1))
            continue
        }
        for anchor in "${REQUIRED_ANCHORS[@]}"; do
            if ! /usr/bin/grep -qF "$anchor" "$file"; then
                /usr/bin/echo "  $name: missing anchor '$anchor'"
                violations=$((violations + 1))
            fi
        done
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "every template contains all required H2 anchors"
    else
        assert_true false "$violations missing anchor(s) across templates"
    fi
}

test_templates_have_type_specific_anchors() {
    local violations=0 name anchor
    for name in "${!TEMPLATE_SPECIFIC_ANCHORS[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        [ -f "$file" ] || {
            violations=$((violations + 1))
            continue
        }
        while IFS= read -r anchor; do
            [ -n "$anchor" ] || continue
            if ! /usr/bin/grep -qF "$anchor" "$file"; then
                /usr/bin/echo "  $name: missing type-specific anchor '$anchor'"
                violations=$((violations + 1))
            fi
        done <<<"${TEMPLATE_SPECIFIC_ANCHORS[$name]}"
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "every template contains its type-specific H2 sections"
    else
        assert_true false "$violations missing type-specific anchor(s)"
    fi
}

test_templates_have_triage_block() {
    local violations=0 name
    for name in "${!TEMPLATE_TYPE[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        [ -f "$file" ] || {
            violations=$((violations + 1))
            continue
        }
        # The machine-readable Triage block the policy parses. Extract the
        # committed default value and confirm it is a real taxonomy member —
        # a typo like "Severity: med" would otherwise match no policy regex and
        # silently skip the auto-label happy path.
        local sev eff
        sev=$(/usr/bin/grep -iE '^-[[:space:]]*Severity:' "$file" | /usr/bin/head -n1 |
            /usr/bin/sed -E 's/.*[Ss]everity:[[:space:]]*([a-zA-Z]+).*/\1/')
        eff=$(/usr/bin/grep -iE '^-[[:space:]]*Effort:' "$file" | /usr/bin/head -n1 |
            /usr/bin/sed -E 's/.*[Ee]ffort:[[:space:]]*([a-zA-Z]+).*/\1/')
        if [ -z "$sev" ]; then
            /usr/bin/echo "  $name: missing '- Severity:' Triage line"
            violations=$((violations + 1))
        elif ! /usr/bin/printf '%s\n' "${SEVERITY_VALUES[@]}" | /usr/bin/grep -qx "$sev"; then
            /usr/bin/echo "  $name: Severity default '$sev' not in taxonomy"
            violations=$((violations + 1))
        fi
        if [ -z "$eff" ]; then
            /usr/bin/echo "  $name: missing '- Effort:' Triage line"
            violations=$((violations + 1))
        elif ! /usr/bin/printf '%s\n' "${EFFORT_VALUES[@]}" | /usr/bin/grep -qx "$eff"; then
            /usr/bin/echo "  $name: Effort default '$eff' not in taxonomy"
            violations=$((violations + 1))
        fi
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "every template embeds a valid Severity/Effort Triage block"
    else
        assert_true false "$violations template(s) with missing/invalid Triage block"
    fi
}

test_policy_and_include_exist() {
    assert_true [ -f "$POLICY_FILE" ] "triage-policies.yml must exist"
    assert_true [ -f "$CI_INCLUDE" ] "ci/triage.yml include must exist"
}

test_yaml_is_valid() {
    if ! command -v yq >/dev/null 2>&1; then
        skip_test "yq not available — skipping YAML validity check"
        return
    fi
    local invalid=0 file
    for file in "$POLICY_FILE" "$CI_INCLUDE"; do
        [ -f "$file" ] || {
            invalid=$((invalid + 1))
            continue
        }
        if ! yq . "$file" >/dev/null 2>&1; then
            /usr/bin/echo "  invalid YAML: $file"
            invalid=$((invalid + 1))
        fi
    done
    if [ "$invalid" -eq 0 ]; then
        assert_true true "triage policy and CI include are valid YAML"
    else
        assert_true false "$invalid YAML file(s) failed to parse"
    fi
}

test_policy_covers_all_label_values() {
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot check label coverage"
        return
    }
    local missing=0 value
    for value in "${SEVERITY_VALUES[@]}"; do
        if ! /usr/bin/grep -qF "severity/$value" "$POLICY_FILE"; then
            /usr/bin/echo "  policy missing label severity/$value"
            missing=$((missing + 1))
        fi
    done
    for value in "${EFFORT_VALUES[@]}"; do
        if ! /usr/bin/grep -qF "effort/$value" "$POLICY_FILE"; then
            /usr/bin/echo "  policy missing label effort/$value"
            missing=$((missing + 1))
        fi
    done
    if ! /usr/bin/grep -qF "needs-triage" "$POLICY_FILE"; then
        /usr/bin/echo "  policy missing needs-triage handling"
        missing=$((missing + 1))
    fi
    if [ "$missing" -eq 0 ]; then
        assert_true true "policy covers every severity/*, effort/*, and needs-triage"
    else
        assert_true false "$missing label value(s) not covered by the policy"
    fi
}

test_policy_has_both_triage_rules() {
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot check triage rules"
        return
    }
    # The needs-triage lifecycle has two distinct halves: a rule that ADDS the
    # flag (labels: needs-triage) and one that CLEARS it (remove_labels:
    # needs-triage) once labeled. A single substring check for "needs-triage"
    # would stay green if either rule were deleted, so assert both actions.
    local missing=0
    if ! /usr/bin/grep -qE '^[[:space:]]*labels:' "$POLICY_FILE" ||
        ! /usr/bin/grep -qE '^[[:space:]]*-[[:space:]]*needs-triage' "$POLICY_FILE"; then
        /usr/bin/echo "  policy missing the add-needs-triage rule"
        missing=$((missing + 1))
    fi
    if ! /usr/bin/grep -qE '^[[:space:]]*remove_labels:' "$POLICY_FILE"; then
        /usr/bin/echo "  policy missing the clear-needs-triage (remove_labels) rule"
        missing=$((missing + 1))
    fi
    if [ "$missing" -eq 0 ]; then
        assert_true true "policy has both the add and clear needs-triage rules"
    else
        assert_true false "$missing needs-triage rule(s) missing from the policy"
    fi
}

test_ci_include_documents_token() {
    [ -f "$CI_INCLUDE" ] || {
        assert_true false "CI include missing — cannot check token docs"
        return
    }
    if /usr/bin/grep -qF "GITLAB_API_TOKEN" "$CI_INCLUDE"; then
        assert_true true "CI include references GITLAB_API_TOKEN"
    else
        assert_true false "CI include does not document GITLAB_API_TOKEN"
    fi
}

test_ci_include_is_schedule_gated() {
    [ -f "$CI_INCLUDE" ] || {
        assert_true false "CI include missing — cannot check schedule gate"
        return
    }
    # The job must only run on scheduled pipelines, never on push/MR.
    if /usr/bin/grep -qF 'CI_PIPELINE_SOURCE == "schedule"' "$CI_INCLUDE"; then
        assert_true true "triage job is gated to scheduled pipelines"
    else
        assert_true false "triage job is not gated to scheduled pipelines"
    fi
}

# --- Functional regex tests (issue #717) ----------------------------------
#
# The tests above are structural: they confirm the policy *mentions* every
# severity/effort label and that each template's Triage default is a taxonomy
# member. They never *execute* the policy's `ruby:` regexes, so an anchor slip,
# a bad escape, or a case mistake in a pattern would pass every check above yet
# silently break the real auto-labeling — the regex is the whole automation.
#
# These tests run the policy's own regexes (extracted from the YAML, not
# copied — so a policy edit is exercised automatically) with Ruby, the same
# engine gitlab-triage uses. POSIX `grep -E` is deliberately avoided: `\A`,
# `\b`, and the `//i` flag do not translate faithfully, so only Ruby gives a
# true-to-production result. Both tests skip gracefully when `ruby` (or `yq`)
# is unavailable.

# Evaluate the policy's committed `ruby:` condition for a label against a
# description, exactly as gitlab-triage would. Prints "true"/"false" on stdout;
# returns non-zero (no output) if the label's rule or its ruby scalar is
# missing. The description is passed via the environment, never interpolated
# into the Ruby source, so template text cannot break quoting or inject code.
#
# TRUST BOUNDARY: the `.conditions.ruby` string is executed as literal Ruby (it
# IS the production expression — evaluating a transcription would not test the
# real thing). This test therefore trusts the contents of triage-policies.yml;
# a change to that file can make `just test` run arbitrary Ruby in CI. That is
# acceptable because the policy file already ships the Ruby that the scheduled
# gitlab-triage job runs against every issue — anyone able to land a malicious
# regex there already controls that automation — but it means the file warrants
# the same review scrutiny as a script, not a plain config.
_policy_ruby_eval() {
    local label="$1" desc="$2" expr
    expr=$(yq -r \
        ".resource_rules.issues.rules[] | select(.actions.labels[0] == \"$label\") | .conditions.ruby" \
        "$POLICY_FILE" 2>/dev/null)
    [ -n "$expr" ] && [ "$expr" != "null" ] || return 1
    _POLICY_DESC="$desc" ruby -e "resource = { description: ENV['_POLICY_DESC'] }; print(${expr})" 2>/dev/null
}

# Guard: both tests need a Ruby interpreter and yq to read the policy.
_policy_regex_prereqs_ok() {
    command -v ruby >/dev/null 2>&1 && command -v yq >/dev/null 2>&1
}

test_policy_regex_matches_template_triage_blocks() {
    if ! _policy_regex_prereqs_ok; then
        skip_test "ruby or yq not available — skipping functional regex test"
        return
    fi
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run functional regex test"
        return
    }

    local violations=0 name
    for name in "${!TEMPLATE_TYPE[@]}"; do
        local file="$TEMPLATE_DIR/$name"
        [ -f "$file" ] || {
            violations=$((violations + 1))
            continue
        }
        local desc sev eff value
        desc=$(command cat "$file")
        # The template's committed defaults — same extraction idiom as
        # test_templates_have_triage_block.
        sev=$(/usr/bin/grep -iE '^-[[:space:]]*Severity:' "$file" | /usr/bin/head -n1 |
            /usr/bin/sed -E 's/.*[Ss]everity:[[:space:]]*([a-zA-Z]+).*/\1/')
        eff=$(/usr/bin/grep -iE '^-[[:space:]]*Effort:' "$file" | /usr/bin/head -n1 |
            /usr/bin/sed -E 's/.*[Ee]ffort:[[:space:]]*([a-zA-Z]+).*/\1/')

        # The template's own severity value must match; every other must not
        # (the HTML comment lists all four values, so a mis-anchored regex
        # would cross-match here).
        for value in "${SEVERITY_VALUES[@]}"; do
            local got want
            got=$(_policy_ruby_eval "severity/$value" "$desc")
            if [ "$value" = "$sev" ]; then want="true"; else want="false"; fi
            if [ "$got" != "$want" ]; then
                /usr/bin/echo "  $name: severity/$value regex returned '$got', expected '$want' (default: $sev)"
                violations=$((violations + 1))
            fi
        done
        for value in "${EFFORT_VALUES[@]}"; do
            local got want
            got=$(_policy_ruby_eval "effort/$value" "$desc")
            if [ "$value" = "$eff" ]; then want="true"; else want="false"; fi
            if [ "$got" != "$want" ]; then
                /usr/bin/echo "  $name: effort/$value regex returned '$got', expected '$want' (default: $eff)"
                violations=$((violations + 1))
            fi
        done
    done

    if [ "$violations" -eq 0 ]; then
        assert_true true "policy regexes match each template's Triage block and nothing else"
    else
        assert_true false "$violations policy-regex mismatch(es) against template Triage blocks"
    fi
}

test_policy_regex_matches_every_value() {
    if ! _policy_regex_prereqs_ok; then
        skip_test "ruby or yq not available — skipping per-value regex test"
        return
    fi
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run per-value regex test"
        return
    }

    # The template-driven test above only exercises the "must match" (true)
    # path for the severity/effort values the three shipped templates happen to
    # default to (medium/low, small/medium). Values like severity/critical or
    # effort/large are only ever checked on the "must NOT match" path there —
    # and a false result is trivially satisfied by _policy_ruby_eval failing
    # (e.g. a broken yq selector), so a broken regex for those values would go
    # unnoticed. Here we feed each value its own synthetic Triage block and
    # assert its regex fires, so all eight regexes are exercised true-positive.
    local violations=0 value got
    for value in "${SEVERITY_VALUES[@]}"; do
        got=$(_policy_ruby_eval "severity/$value" $'- Severity: '"$value"$'\n- Effort: small')
        if [ "$got" != "true" ]; then
            /usr/bin/echo "  severity/$value regex did not match its own value (got '$got')"
            violations=$((violations + 1))
        fi
    done
    for value in "${EFFORT_VALUES[@]}"; do
        got=$(_policy_ruby_eval "effort/$value" $'- Severity: low\n- Effort: '"$value")
        if [ "$got" != "true" ]; then
            /usr/bin/echo "  effort/$value regex did not match its own value (got '$got')"
            violations=$((violations + 1))
        fi
    done

    if [ "$violations" -eq 0 ]; then
        assert_true true "every severity/* and effort/* regex matches its own value"
    else
        assert_true false "$violations regex(es) failed to match their own value"
    fi
}

test_policy_regex_rejects_broken_anchor() {
    if ! _policy_regex_prereqs_ok; then
        skip_test "ruby or yq not available — skipping broken-anchor regex test"
        return
    fi
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run broken-anchor regex test"
        return
    }

    # A description whose Severity line is NOT the first line. The real regex
    # anchors each match to (\A|\n|\r) — a start-of-line, not start-of-string —
    # so it must still match. A broken variant anchored to \A alone (a common
    # regression) must miss it. This proves the functional test has teeth: a
    # loosened/tightened anchor flips the result.
    local desc
    desc=$'## Summary\n\nSome context.\n\n- Severity: medium\n- Effort: small'

    local real broken correct wrong
    real=$(yq -r \
        '.resource_rules.issues.rules[] | select(.actions.labels[0] == "severity/medium") | .conditions.ruby' \
        "$POLICY_FILE" 2>/dev/null)
    # Replace the multi-anchor group (\A|\n|\r) with \A only.
    broken=$(/usr/bin/printf '%s' "$real" | /usr/bin/sed -E 's/\(\\A\|\\n\|\\r\)/\\A/')

    correct=$(_POLICY_DESC="$desc" ruby -e "resource = { description: ENV['_POLICY_DESC'] }; print(${real})" 2>/dev/null)
    wrong=$(_POLICY_DESC="$desc" ruby -e "resource = { description: ENV['_POLICY_DESC'] }; print(${broken})" 2>/dev/null)

    local failures=0
    if [ "$broken" = "$real" ]; then
        /usr/bin/echo "  sed did not mutate the anchor — cannot exercise the broken variant"
        failures=$((failures + 1))
    fi
    if [ "$correct" != "true" ]; then
        /usr/bin/echo "  real severity/medium regex failed to match a non-first-line Triage block (got '$correct')"
        failures=$((failures + 1))
    fi
    if [ "$wrong" != "false" ]; then
        /usr/bin/echo "  broken-anchor variant still matched (got '$wrong') — the test would not catch this regression"
        failures=$((failures + 1))
    fi

    if [ "$failures" -eq 0 ]; then
        assert_true true "a broken anchor flips the regex result — the functional test has teeth"
    else
        assert_true false "$failures broken-anchor assertion(s) failed"
    fi
}

run_test test_templates_exist_and_nonempty "all three issue templates exist"
run_test test_templates_have_type_quick_action "templates apply type/* via /label"
run_test test_templates_have_required_anchors "templates contain required H2 anchors"
run_test test_templates_have_type_specific_anchors "templates contain type-specific H2 sections"
run_test test_templates_have_triage_block "templates embed the Triage block"
run_test test_policy_and_include_exist "triage policy and CI include exist"
run_test test_yaml_is_valid "triage policy and CI include are valid YAML"
run_test test_policy_covers_all_label_values "policy covers all severity/effort labels"
run_test test_policy_has_both_triage_rules "policy has add and clear needs-triage rules"
run_test test_ci_include_documents_token "CI include documents GITLAB_API_TOKEN"
run_test test_ci_include_is_schedule_gated "triage job is schedule-gated"
run_test test_policy_regex_matches_template_triage_blocks "policy regexes match template Triage blocks"
run_test test_policy_regex_matches_every_value "every severity/effort regex matches its own value"
run_test test_policy_regex_rejects_broken_anchor "broken anchor flips the regex result"

generate_report
