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
    # Same CI rule as the Ruby-backed tests: a malformed triage.yml that only
    # ever gets skipped in CI is exactly the failure mode worth preventing here,
    # since nothing in this repo's pipeline executes the file itself.
    if ! command -v yq >/dev/null 2>&1; then
        if [ "${CI:-false}" = "true" ]; then
            assert_true false \
                "yq is required in CI — YAML validity check cannot silently skip (see .github/workflows/ci.yml)"
        else
            skip_test "yq not available — skipping YAML validity check"
        fi
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
#
# In CI these are NOT optional. A skip renders identically to a pass in the
# summary, which is exactly how these tests sat un-executed on every CI run
# (ubuntu-latest ships ruby but not yq, and no workflow step installed it) —
# the gap #768 was filed against. So under CI a missing interpreter is a
# FAILURE, not a skip; locally it stays a graceful skip, since not every
# contributor has Ruby installed.
_policy_regex_prereqs_ok() {
    command -v ruby >/dev/null 2>&1 && command -v yq >/dev/null 2>&1
}

# Handle absent prerequisites per the rule above. Returns 0 when the caller
# should proceed, 1 when it has already reported (skip locally / fail in CI).
_policy_prereq_gate() {
    local what="$1"
    if _policy_regex_prereqs_ok; then
        return 0
    fi
    if [ "${CI:-false}" = "true" ]; then
        assert_true false \
            "ruby and yq are required in CI — $what cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "ruby or yq not available — skipping $what"
    fi
    return 1
}

# Evaluate a needs-triage lifecycle rule's committed `ruby:` condition against a
# label set, exactly as gitlab-triage would. These two rules are the only ones
# expressed as pure logic rather than a regex, and they bind resource[:labels]
# rather than resource[:description] — hence a sibling of _policy_ruby_eval.
#
# $1 selects the rule by the action it performs, since one ADDS the label and
# the other REMOVES it: "add" reads .actions.labels[0], "clear" reads
# .actions.remove_labels[0].
#
# Same trust boundary as _policy_ruby_eval: the committed expression IS executed
# (evaluating a transcription would not test the real thing). Labels are passed
# through the environment as a newline-delimited list, never interpolated into
# the Ruby source.
_policy_labels_eval() {
    local which="$1" labels="$2" expr selector

    case "$which" in
        add) selector='.actions.labels[0] == "needs-triage"' ;;
        clear) selector='.actions.remove_labels[0] == "needs-triage"' ;;
        *) return 1 ;;
    esac

    expr=$(yq -r \
        ".resource_rules.issues.rules[] | select($selector) | .conditions.ruby" \
        "$POLICY_FILE" 2>/dev/null)
    [ -n "$expr" ] && [ "$expr" != "null" ] || return 1

    # NOTE: unlike the severity/effort regex conditions, these expressions are
    # TWO statements (`labels = Array(...); !(...)`). Wrapping them in
    # `print(...)` the way _policy_ruby_eval does is a syntax error, so evaluate
    # the whole thing as a block and print its value instead.
    _POLICY_LABELS="$labels" ruby -e \
        "resource = { labels: ENV['_POLICY_LABELS'].split(\"\n\").reject(&:empty?) }
         print(begin
           ${expr}
         end)" 2>/dev/null
}

test_policy_regex_matches_template_triage_blocks() {
    _policy_prereq_gate "functional regex test" || return
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
    _policy_prereq_gate "per-value regex test" || return
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
    _policy_prereq_gate "broken-anchor regex test" || return
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

# ============================================================================
# needs-triage lifecycle — functional (issue #768)
# ============================================================================
# test_policy_has_both_triage_rules above only greps that the two rules EXIST.
# Their conditions are pure Ruby against resource[:labels], so a logic slip
# (&& for ||, a dropped negation, a typo'd prefix) passes that grep untouched
# while silently flagging every issue or none. These tests execute the
# committed expressions across the full truth table.

test_needs_triage_add_rule_truth_table() {
    _policy_prereq_gate "needs-triage add-rule test" || return
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run needs-triage add-rule test"
        return
    }

    # The add rule fires when the issue lacks a severity/* OR an effort/* label.
    # Half-labeled counts as untriaged — that is what the && inside the negation
    # buys, and the case a || regression would silently break.
    # Parallel arrays rather than delimited strings: a label SET is itself
    # newline-delimited, so packing it into a "a|b|c" record and splitting with
    # cut mangles every multi-label case.
    local failures=0 got i
    local -a set_labels=(
        ""
        "severity/high"
        "effort/small"
        "severity/high"$'\n'"effort/small"
        "type/bug"$'\n'"component/ci"
        "severity/high"$'\n'"effort/small"$'\n'"type/bug"
    )
    local -a set_want=(true true true false true false)
    local -a set_desc=(
        "no labels at all"
        "severity only (effort missing)"
        "effort only (severity missing)"
        "both namespaces present"
        "unrelated labels only"
        "both present plus extras"
    )

    for i in "${!set_labels[@]}"; do
        got=$(_policy_labels_eval add "${set_labels[$i]}")
        if [ "$got" != "${set_want[$i]}" ]; then
            /usr/bin/echo "  add rule: ${set_desc[$i]} — expected ${set_want[$i]}, got '${got:-<none>}'"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -eq 0 ]; then
        assert_true true "needs-triage add rule fires exactly when a namespace is missing"
    else
        assert_true false "$failures needs-triage add-rule case(s) failed"
    fi
}

test_needs_triage_clear_rule_truth_table() {
    _policy_prereq_gate "needs-triage clear-rule test" || return
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run needs-triage clear-rule test"
        return
    }

    # The clear rule is the exact negation of the add rule.
    # Parallel arrays — see the add-rule test for why.
    local failures=0 got i
    local -a set_labels=(
        ""
        "severity/high"
        "effort/small"
        "severity/high"$'\n'"effort/small"
        "severity/low"$'\n'"effort/large"$'\n'"type/bug"
    )
    local -a set_want=(false false false true true)
    local -a set_desc=(
        "no labels at all"
        "severity only (effort missing)"
        "effort only (severity missing)"
        "both namespaces present"
        "both present plus extras"
    )

    for i in "${!set_labels[@]}"; do
        got=$(_policy_labels_eval clear "${set_labels[$i]}")
        if [ "$got" != "${set_want[$i]}" ]; then
            /usr/bin/echo "  clear rule: ${set_desc[$i]} — expected ${set_want[$i]}, got '${got:-<none>}'"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -eq 0 ]; then
        assert_true true "needs-triage clear rule fires exactly when both namespaces are present"
    else
        assert_true false "$failures needs-triage clear-rule case(s) failed"
    fi
}

test_needs_triage_rules_are_exact_negations() {
    # The two rules must partition every label set between them: exactly one
    # fires for any input. If they ever drift apart, an issue could be flagged
    # and cleared on the same run (flapping) or fall through both and sit
    # unlabeled forever — neither of which the per-rule tables above would
    # catch, since each passes in isolation.
    _policy_prereq_gate "needs-triage negation test" || return
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run needs-triage negation test"
        return
    }

    local failures=0 add clear labels
    local -a label_sets=(
        ""
        "severity/high"
        "effort/small"
        "severity/high"$'\n'"effort/small"
        "type/bug"
        "severity/critical"$'\n'"effort/trivial"$'\n'"component/runtime"
    )

    for labels in "${label_sets[@]}"; do
        add=$(_policy_labels_eval add "$labels")
        clear=$(_policy_labels_eval clear "$labels")
        if [ -z "$add" ] || [ -z "$clear" ]; then
            /usr/bin/echo "  could not evaluate one of the rules for label set: ${labels//$'\n'/,}"
            failures=$((failures + 1))
            continue
        fi
        if [ "$add" = "$clear" ]; then
            /usr/bin/echo "  rules agreed (both '$add') for label set: ${labels//$'\n'/,} — they must be negations"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -eq 0 ]; then
        assert_true true "add and clear rules are exact negations across every label set"
    else
        assert_true false "$failures label set(s) broke the negation invariant"
    fi
}

test_needs_triage_logic_has_teeth() {
    # Mirrors test_policy_regex_rejects_broken_anchor: mutate the committed
    # expression and assert the result flips. Without this, the truth tables
    # above could pass against an expression that ignores its input entirely.
    _policy_prereq_gate "needs-triage teeth test" || return
    [ -f "$POLICY_FILE" ] || {
        assert_true false "policy file missing — cannot run needs-triage teeth test"
        return
    }

    local real broken correct wrong
    real=$(yq -r \
        '.resource_rules.issues.rules[] | select(.actions.labels[0] == "needs-triage") | .conditions.ruby' \
        "$POLICY_FILE" 2>/dev/null)

    # The regression this guards: && -> ||, which makes a half-labeled issue
    # (severity but no effort) stop being flagged.
    broken=$(/usr/bin/printf '%s' "$real" | /usr/bin/sed 's/&&/||/')

    # Same two-statement caveat as _policy_labels_eval — evaluate as a block.
    local labels="severity/high"
    correct=$(_POLICY_LABELS="$labels" ruby -e \
        "resource = { labels: ENV['_POLICY_LABELS'].split(\"\n\").reject(&:empty?) }
         print(begin
           ${real}
         end)" 2>/dev/null)
    wrong=$(_POLICY_LABELS="$labels" ruby -e \
        "resource = { labels: ENV['_POLICY_LABELS'].split(\"\n\").reject(&:empty?) }
         print(begin
           ${broken}
         end)" 2>/dev/null)

    local failures=0
    if [ "$broken" = "$real" ]; then
        /usr/bin/echo "  sed did not mutate the expression — cannot exercise the broken variant"
        failures=$((failures + 1))
    fi
    if [ "$correct" != "true" ]; then
        /usr/bin/echo "  real add rule failed to flag a half-labeled issue (got '$correct')"
        failures=$((failures + 1))
    fi
    if [ "$wrong" != "false" ]; then
        /usr/bin/echo "  && -> || variant still flagged (got '$wrong') — the truth table would not catch this"
        failures=$((failures + 1))
    fi

    if [ "$failures" -eq 0 ]; then
        assert_true true "an && -> || slip flips the result — the needs-triage tests have teeth"
    else
        assert_true false "$failures needs-triage teeth assertion(s) failed"
    fi
}

# ============================================================================
# Gemfile / CI include consistency (issue #764)
# ============================================================================

test_gemfile_and_lock_exist() {
    local gemfile="$GITLAB_DIR/triage/Gemfile"
    local lock="$GITLAB_DIR/triage/Gemfile.lock"
    local failures=0

    [ -f "$gemfile" ] || {
        /usr/bin/echo "  missing $gemfile"
        failures=$((failures + 1))
    }
    [ -f "$lock" ] || {
        /usr/bin/echo "  missing $lock"
        failures=$((failures + 1))
    }

    # A lock without the transitive graph defeats the point of committing it.
    if [ -f "$lock" ] && ! /usr/bin/grep -q '^GEM' "$lock"; then
        /usr/bin/echo "  Gemfile.lock has no GEM section — not a resolved lock"
        failures=$((failures + 1))
    fi

    # The job runs on Linux runners of either architecture; a lock missing a
    # platform fails there in deployment mode.
    if [ -f "$lock" ]; then
        local plat
        for plat in x86_64-linux aarch64-linux; do
            if ! /usr/bin/grep -q "$plat" "$lock"; then
                /usr/bin/echo "  Gemfile.lock does not register the $plat platform"
                failures=$((failures + 1))
            fi
        done
    fi

    if [ "$failures" -eq 0 ]; then
        assert_true true "triage Gemfile and resolved multi-platform Gemfile.lock are committed"
    else
        assert_true false "$failures Gemfile/Gemfile.lock problem(s)"
    fi
}

test_gem_version_has_one_source_of_truth() {
    # The gem version must live ONLY in the Gemfile. A duplicate in the CI
    # include would have to be kept in step by the weekly auto-patch updater,
    # which bumps only the Gemfile — so the copy would go stale on the very next
    # bump and fail the lock-sync assertion below (#764).
    [ -f "$CI_INCLUDE" ] || {
        assert_true false "CI include missing — cannot check for a duplicate pin"
        return
    }

    if /usr/bin/grep -qE '^\s*GITLAB_TRIAGE_VERSION:' "$CI_INCLUDE"; then
        assert_true false \
            "CI include redeclares GITLAB_TRIAGE_VERSION — the Gemfile is the single source of truth"
    else
        assert_true true "gem version has a single source of truth (the Gemfile)"
    fi
}

test_gemfile_and_lock_agree() {
    # `bundle install` runs in deployment (frozen) mode, which REFUSES to
    # resolve when the Gemfile and Gemfile.lock disagree — so a bump that
    # touches only one of them breaks the scheduled job. The weekly auto-patch
    # updater can rewrite the Gemfile pin but cannot regenerate the lock (that
    # needs a real Ruby resolver), so this assertion is what catches the drift
    # at commit time instead of at the next schedule.
    local gemfile="$GITLAB_DIR/triage/Gemfile"
    local lock="$GITLAB_DIR/triage/Gemfile.lock"
    [ -f "$gemfile" ] && [ -f "$lock" ] || {
        assert_true false "Gemfile or Gemfile.lock missing — cannot compare pins"
        return
    }

    local gem_version lock_version
    gem_version=$(/usr/bin/grep -E '^gem "gitlab-triage"' "$gemfile" |
        /usr/bin/sed -E 's/.*,[[:space:]]*"([^"]+)".*/\1/')
    # The lock records the resolved version as `    gitlab-triage (X.Y.Z)`.
    lock_version=$(/usr/bin/grep -E '^[[:space:]]+gitlab-triage \(' "$lock" |
        /usr/bin/head -1 |
        /usr/bin/sed -E 's/.*\(([^)]+)\).*/\1/')

    if [ -n "$gem_version" ] && [ "$gem_version" = "$lock_version" ]; then
        assert_true true "Gemfile pin ($gem_version) matches the resolved Gemfile.lock"
    else
        assert_true false \
            "Gemfile/lock drift: Gemfile has '${gem_version:-<none>}', lock has '${lock_version:-<none>}' — regenerate the lock (see the Gemfile header)"
    fi
}

test_triage_job_uses_bundler() {
    [ -f "$CI_INCLUDE" ] || {
        assert_true false "CI include missing — cannot check bundler wiring"
        return
    }

    local failures=0

    # deployment mode is the whole point: it re-verifies every gem against the
    # committed lock regardless of cache state (#764).
    if ! /usr/bin/grep -q 'bundle config set --local deployment true' "$CI_INCLUDE"; then
        /usr/bin/echo "  job does not enable bundler deployment mode"
        failures=$((failures + 1))
    fi
    if ! /usr/bin/grep -q 'bundle exec gitlab-triage' "$CI_INCLUDE"; then
        /usr/bin/echo "  job does not invoke gitlab-triage through the bundle"
        failures=$((failures + 1))
    fi
    # The old path is what left a warm cache unverified — it must not come back.
    if /usr/bin/grep -qE '^\s*-\s*gem install gitlab-triage' "$CI_INCLUDE"; then
        /usr/bin/echo "  job still uses 'gem install' — bypasses lock verification"
        failures=$((failures + 1))
    fi
    # The locked graph contains native extensions and the -slim image has no
    # compiler; verified empirically that the install fails without this.
    if ! /usr/bin/grep -q 'build-essential' "$CI_INCLUDE"; then
        /usr/bin/echo "  job does not install build-essential (native gems will fail to build)"
        failures=$((failures + 1))
    fi

    if [ "$failures" -eq 0 ]; then
        assert_true true "triage job installs via bundler in deployment mode"
    else
        assert_true false "$failures bundler-wiring problem(s) in the CI include"
    fi
}

test_cache_key_scoped_to_lock_and_image() {
    # Two independent invalidation triggers (#764 item 3):
    #   - the Gemfile.lock's checksum, so ANY change to the resolved graph
    #     (not just the top-level pin) busts the cache automatically;
    #   - the Ruby image tag, because the graph contains native extensions
    #     (bigdecimal) whose build is ABI-specific.
    [ -f "$CI_INCLUDE" ] || {
        assert_true false "CI include missing — cannot check cache key"
        return
    }

    local prefix image_tag failures=0
    prefix=$(/usr/bin/grep -E '^\s*prefix:\s*"gitlab-triage' "$CI_INCLUDE" |
        /usr/bin/sed -E 's/.*"([^"]+)".*/\1/')
    image_tag=$(/usr/bin/grep -E '^\s*image:\s*ruby:' "$CI_INCLUDE" |
        /usr/bin/sed -E 's/.*ruby:([0-9.]+).*/\1/')

    # The key must hash the lock file itself.
    if ! /usr/bin/grep -q 'Gemfile.lock' "$CI_INCLUDE"; then
        /usr/bin/echo "  cache key does not hash .gitlab/triage/Gemfile.lock"
        failures=$((failures + 1))
    fi

    if [ -z "$prefix" ] || [ -z "$image_tag" ]; then
        /usr/bin/echo "  could not read the cache prefix or image tag"
        failures=$((failures + 1))
    else
        local prefix_digits="${prefix//[^0-9]/}"
        local tag_digits="${image_tag//[^0-9]/}"
        if [ "${prefix_digits#*"$tag_digits"}" = "$prefix_digits" ]; then
            /usr/bin/echo "  cache prefix '$prefix' omits the Ruby image tag '$image_tag'"
            failures=$((failures + 1))
        fi
    fi

    if [ "$failures" -eq 0 ]; then
        assert_true true "cache key is scoped to the lock checksum and the Ruby image tag"
    else
        assert_true false "$failures cache-key scoping problem(s)"
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
run_test test_needs_triage_add_rule_truth_table "needs-triage add rule fires on a missing namespace"
run_test test_needs_triage_clear_rule_truth_table "needs-triage clear rule fires only when fully labeled"
run_test test_needs_triage_rules_are_exact_negations "needs-triage add/clear rules are exact negations"
run_test test_needs_triage_logic_has_teeth "an && -> || slip flips the needs-triage result"
run_test test_gemfile_and_lock_exist "triage Gemfile and multi-platform lock are committed"
run_test test_gem_version_has_one_source_of_truth "gem version lives only in the Gemfile"
run_test test_gemfile_and_lock_agree "Gemfile pin matches the resolved Gemfile.lock"
run_test test_triage_job_uses_bundler "triage job installs via bundler in deployment mode"
run_test test_cache_key_scoped_to_lock_and_image "cache key is scoped to the lock and Ruby image"

generate_report
