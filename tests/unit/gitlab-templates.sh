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

generate_report
