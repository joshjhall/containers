#!/usr/bin/env bash
# Structural lint for Claude Code agent and skill definitions
#
# Validates:
# - Every skill dir has SKILL.md + metadata.yml
# - Every agent dir has <name>.md with valid frontmatter
# - check-*/loop-*/context-* skills have required companion files
# - Cross-references between docs and filesystem
# - patterns.sh files are executable
#
# No Docker required — pure filesystem checks against templates directory.

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# Key directories
TEMPLATES_DIR="$CONTAINERS_DIR/lib/features/templates/claude"
AGENTS_DIR="$TEMPLATES_DIR/agents"
SKILLS_DIR="$TEMPLATES_DIR/skills"
DOCS_FILE="$CONTAINERS_DIR/docs/claude-code/skills-and-agents.md"

# Define test suite
test_suite "Claude Agent/Skill Structural Lint"

# Valid values for frontmatter fields
VALID_MODELS="opus sonnet haiku"
VALID_TOOLS="Read Write Edit Bash Grep Glob Task WebFetch WebSearch"

# --- Helper Functions ---

# Extract YAML frontmatter value from a file
# Usage: get_frontmatter_field <file> <field>
get_frontmatter_field() {
    local file="$1"
    local field="$2"
    # Read between --- delimiters, find the field
    /usr/bin/sed -n '/^---$/,/^---$/p' "$file" |
        command grep "^${field}:" |
        command sed "s/^${field}:[[:space:]]*//"
}

# Check if a value is in a space-separated list
# Usage: is_valid_value <value> <list>
is_valid_value() {
    local value="$1"
    local list="$2"
    local item
    for item in $list; do
        [ "$value" = "$item" ] && return 0
    done
    return 1
}

# Report pure-literal violations in a workflow.js file's `export const meta`
# block, one token per line: "concat" (string concatenation) and/or "interp"
# (template interpolation). Empty output means the meta block is a pure literal.
#
# The Workflow tool rejects a meta object containing any non-literal node
# (variables, calls, spreads, template interpolation, or string concatenation)
# with "meta must be a pure literal" — and silently disables the harness at load
# time (see #561). This is the single detector implementation shared by both the
# live sweep (test_workflow_meta_pure_literal) and the negative-fixture self-test
# (test_workflow_meta_guard_detects_violations), so the self-test proves the same
# regexes the live sweep relies on actually fire.
workflow_meta_violations() {
    local wf_file="$1"

    # Extract the meta object by brace-counting: start at the line holding
    # `export const meta`, track { vs } depth, stop when depth returns to zero.
    # Robust against nested object literals in `phases` (a naive
    # "first }-at-column-0" match could stop early on a future layout). Held in a
    # variable — no temp file to leak on an assertion failure.
    local meta_block
    meta_block="$(/usr/bin/awk '
        /export const meta/ { capturing = 1 }
        capturing {
            print
            depth += gsub(/{/, "{")
            depth -= gsub(/}/, "}")
            if (started && depth <= 0) exit
            if (depth > 0) started = 1
        }
    ' "$wf_file")"

    # A pure-literal meta has no string concatenation (a `+` operator adjacent to
    # a quote — single OR double) and no template interpolation (${...}).
    if printf '%s\n' "$meta_block" |
        command grep -qE "['\"][[:space:]]*[+]|[+][[:space:]]*['\"]"; then
        printf 'concat\n'
    fi
    if printf '%s\n' "$meta_block" | command grep -qF '${'; then
        printf 'interp\n'
    fi
}

# --- Agent Tests ---

# Test: Every agent directory has a correctly named .md file
test_agent_files_exist() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        assert_file_exists "$agent_file" "Agent $agent_name missing ${agent_name}.md"
    done
}

# Test: Every agent has required frontmatter fields
test_agent_frontmatter_fields() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        # Check required fields exist
        local name_val description_val tools_val model_val
        name_val="$(get_frontmatter_field "$agent_file" "name")"
        description_val="$(get_frontmatter_field "$agent_file" "description")"
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        model_val="$(get_frontmatter_field "$agent_file" "model")"

        assert_not_empty "$name_val" "Agent $agent_name: missing 'name' in frontmatter"
        assert_not_empty "$description_val" "Agent $agent_name: missing 'description' in frontmatter"
        assert_not_empty "$tools_val" "Agent $agent_name: missing 'tools' in frontmatter"
        assert_not_empty "$model_val" "Agent $agent_name: missing 'model' in frontmatter"

        # Validate name matches directory
        assert_equals "$name_val" "$agent_name" "Agent $agent_name: frontmatter name mismatch"
    done
}

# Test: Agent model values are valid
test_agent_model_values() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        local model_val
        model_val="$(get_frontmatter_field "$agent_file" "model")"
        [ -z "$model_val" ] && continue

        if ! is_valid_value "$model_val" "$VALID_MODELS"; then
            assert_true false "Agent $agent_name: invalid model '$model_val' (expected: $VALID_MODELS)"
        fi
    done
}

# Test: Agent tools values are valid
test_agent_tool_values() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        local tools_val
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        [ -z "$tools_val" ] && continue

        # Split comma-separated tools and validate each
        local tool
        while IFS=',' read -ra TOOLS_ARRAY; do
            for tool in "${TOOLS_ARRAY[@]}"; do
                tool="$(echo "$tool" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [ -z "$tool" ] && continue
                if ! is_valid_value "$tool" "$VALID_TOOLS"; then
                    assert_true false "Agent $agent_name: invalid tool '$tool' (expected: $VALID_TOOLS)"
                fi
            done
        done <<<"$tools_val"
    done
}

# Test: Every agent has a Restrictions section
test_agent_restrictions_section() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '## Restrictions' '$agent_file'" \
            "Agent $agent_name: missing '## Restrictions' section"
    done
}

# Test: Every agent has skills field in frontmatter
test_agent_skills_field() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '^skills:' '$agent_file'" \
            "Agent $agent_name: missing 'skills' field in frontmatter"
    done
}

# Test: Every agent has a Tool Rationale section
test_agent_tool_rationale_section() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '## Tool Rationale' '$agent_file'" \
            "Agent $agent_name: missing '## Tool Rationale' section"
    done
}

# --- Skill Tests ---

# Test: Every skill directory has SKILL.md
test_skill_files_exist() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        assert_file_exists "$skill_dir/SKILL.md" "Skill $skill_name missing SKILL.md"
    done
}

# Test: Every skill has a description in frontmatter
test_skill_frontmatter() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local skill_file="$skill_dir/SKILL.md"
        [ -f "$skill_file" ] || continue

        local desc_val
        desc_val="$(get_frontmatter_field "$skill_file" "description")"
        assert_not_empty "$desc_val" "Skill $skill_name: missing 'description' in SKILL.md frontmatter"
    done
}

# Test: Every skill directory has metadata.yml
test_skill_metadata_exists() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        # container-environment is dynamically generated — skip metadata check
        [ "$skill_name" = "container-environment" ] && continue
        assert_file_exists "$skill_dir/metadata.yml" "Skill $skill_name missing metadata.yml"
    done
}

# Test: metadata.yml name matches directory name
test_skill_metadata_name_match() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local meta_file="$skill_dir/metadata.yml"
        [ -f "$meta_file" ] || continue

        local meta_name
        meta_name="$(command grep '^name:' "$meta_file" | command sed 's/^name:[[:space:]]*//')"
        [ -z "$meta_name" ] && continue
        assert_equals "$meta_name" "$skill_name" "Skill $skill_name: metadata.yml name mismatch"
    done
}

# Test: check-* skills have 5-file structure
test_check_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "check-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: loop-* skills have 5-file structure
test_loop_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/loop-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "loop-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: context-* skills have 3-file structure
test_context_skill_structure() {
    local required_files="SKILL.md context.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/context-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "context-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: patterns.sh files are executable
test_patterns_sh_executable() {
    local patterns_file
    while IFS= read -r patterns_file; do
        local skill_name
        skill_name="$(/usr/bin/basename "$(/usr/bin/dirname "$patterns_file")")"
        assert_true "[ -x '$patterns_file' ]" \
            "Skill $skill_name: patterns.sh is not executable"
    done < <(command find "$SKILLS_DIR" -name "patterns.sh" -type f 2>/dev/null | sort)
}

# --- Cross-Reference Tests ---

# Test: Every skill directory is listed in skills-and-agents.md
test_skills_in_docs() {
    [ -f "$DOCS_FILE" ] || return 0

    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        # Check if skill appears in the docs file (as backtick-wrapped name in table)
        assert_true "command grep -q '\`${skill_name}\`' '$DOCS_FILE'" \
            "Skill $skill_name not listed in skills-and-agents.md"
    done
}

# Test: Every agent directory is listed in skills-and-agents.md
test_agents_in_docs() {
    [ -f "$DOCS_FILE" ] || return 0

    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"

        assert_true "command grep -q '\`${agent_name}\`' '$DOCS_FILE'" \
            "Agent $agent_name not listed in skills-and-agents.md"
    done
}

# --- Workflow Harness Tests ---

# Test: Every workflow.js `export const meta` block is a pure literal.
# Multi-line `'...' + '...'` concatenation in meta.description is the common trap
# — a BinaryExpression, not a literal — and silently disables the harness at load
# time (see #561). Detection lives in the shared workflow_meta_violations helper.
test_workflow_meta_pure_literal() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -f "$wf_file" ] || continue
        local rel_name violations
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        violations="$(workflow_meta_violations "$wf_file")"

        # Each check is a self-contained boolean so one violation never aborts the
        # sweep over the remaining workflow.js files.
        if printf '%s\n' "$violations" | command grep -qx "concat"; then
            assert_true false \
                "Workflow $rel_name: meta uses string concatenation (must be a single literal — see #561)"
        else
            assert_true true "Workflow $rel_name: meta has no string concatenation"
        fi

        if printf '%s\n' "$violations" | command grep -qx "interp"; then
            assert_true false \
                "Workflow $rel_name: meta uses template interpolation (must be a pure literal)"
        else
            assert_true true "Workflow $rel_name: meta has no template interpolation"
        fi
    done < <(command find "$AGENTS_DIR" "$SKILLS_DIR" -name "workflow.js" -type f 2>/dev/null | /usr/bin/sort)
}

# Test: every bundled workflow.js parses with `node --check`. The meta
# pure-literal lint above catches the one syntactic trap the Workflow tool
# rejects (concat/interp in `meta`), but a stray syntax error elsewhere in the
# script would still break the harness at load time with no signal — exactly the
# drift class #574 calls out (a stale/broken installed workflow.js silently
# skips the adversarial review). A real parse is the cheapest complete guard.
# Skips gracefully when node is unavailable so the bash-only test host degrades
# instead of failing; container CI has node and enforces it.
test_workflow_js_node_check() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run 'node --check' on workflow.js files"
        return
    fi
    local wf_file
    while IFS= read -r wf_file; do
        [ -f "$wf_file" ] || continue
        local rel_name node_err
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        if node_err="$(command node --check "$wf_file" 2>&1)"; then
            assert_true true "Workflow $rel_name: workflow.js passes node --check"
        else
            assert_true false \
                "Workflow $rel_name: workflow.js has a syntax error: ${node_err}"
        fi
    done < <(command find "$AGENTS_DIR" "$SKILLS_DIR" -name "workflow.js" -type f 2>/dev/null | /usr/bin/sort)
}

# Test: the meta pure-literal detector actually FIRES on a known-bad input.
# Without this, the live sweep above only ever proves the happy path — if the
# detector regexes were wrong they would silently pass on the (already-clean)
# real workflow.js files, the same gap that let #561 through. The committed
# negative fixture carries BOTH violation classes in its meta block; we assert
# the shared helper reports each one (see #565).
test_workflow_meta_guard_detects_violations() {
    local fixture="$CONTAINERS_DIR/tests/fixtures/claude/workflow_meta_bad.js"
    assert_file_exists "$fixture" "Negative meta fixture exists"

    local violations
    violations="$(workflow_meta_violations "$fixture")"

    assert_contains "$violations" "concat" \
        "Detector flags string concatenation in the bad fixture's meta block"
    assert_contains "$violations" "interp" \
        "Detector flags template interpolation in the bad fixture's meta block"
}

# Test: `node --check` actually FIRES on a syntax error — proves
# test_workflow_js_node_check is not passing vacuously (e.g. a node stub that
# always exits 0). Mirrors the meta-guard negative test above. Uses a throwaway
# temp file with a deliberate syntax error rather than a committed fixture (a
# broken .js under templates/ would itself trip the live sweep).
test_workflow_js_node_check_detects_syntax_error() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot prove node --check fires"
        return
    fi
    local bad
    bad="$(mktemp --suffix=.js)"
    # Unterminated function param list — a genuine parse error node rejects.
    printf 'function broken( {\n  return 1\n' >"$bad"
    local err rc=0
    err="$(command node --check "$bad" 2>&1)" || rc=$?
    command rm -f "$bad"
    assert_true "[ $rc -ne 0 ]" "node --check exits non-zero on a syntax error"
    assert_contains "$err" "SyntaxError" "node --check reports a SyntaxError"
}

# Test: cross-file invariants of the /next-issue --ship fast-path contract.
# PR #566 (#562) introduced --ship, whose correctness rests on prose invariants
# spread across four files. Structure is already linted above; this guards the
# CONTENT consistency that future edits could silently break (see #567). All
# static greps — no Docker.
test_next_issue_ship_invariants() {
    local ni_skill="$SKILLS_DIR/next-issue/SKILL.md"
    local ship_skill="$SKILLS_DIR/next-issue-ship/SKILL.md"
    local state_fmt="$SKILLS_DIR/next-issue/state-format.md"

    # Invariant 0: the four contract files exist (state-format + docs included).
    assert_file_exists "$ni_skill" "next-issue/SKILL.md exists"
    assert_file_exists "$ship_skill" "next-issue-ship/SKILL.md exists"
    assert_file_exists "$state_fmt" "next-issue/state-format.md exists"
    assert_file_exists "$DOCS_FILE" "skills-and-agents.md exists"

    # Invariant 1: --ship is NEVER autonomous. The Phase 1/2 state-file JSON
    # templates in next-issue/SKILL.md must parameterize autonomy as
    # `{true|false}`, never hardcode `"autonomous": true` (that was the
    # HIGH-severity bug the #566 review caught). Match only JSON-template field
    # lines — leading whitespace then the bare quoted key — so inline prose
    # mentions (which sit behind a backtick or mid-sentence) and the deliberately
    # autonomous example in state-format.md are not false positives.
    assert_file_not_contains "$ni_skill" '^[[:space:]]*"autonomous": true' \
        "next-issue/SKILL.md JSON templates never hardcode autonomous:true (#566)"
    assert_file_contains "$ni_skill" '"autonomous": {true|false}' \
        "next-issue/SKILL.md parameterizes autonomy as {true|false}"

    # Invariant 1b: every file mentioning --ship near autonomy asserts it stays
    # non-autonomous. Both SKILL.md files mention --ship; each must also carry an
    # autonomy-negation token so the "--ship is not autonomy" contract is local
    # to wherever --ship is described.
    local f
    for f in "$ni_skill" "$ship_skill"; do
        local rel
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/SKILL.md"
        if command grep -q -- '--ship' "$f"; then
            assert_true "command grep -qiE 'not autonom|NOT autonomous|leaves .autonomous. false|autonomous false' '$f'" \
                "$rel: --ship is stated to be non-autonomous"
        fi
    done

    # Invariant 2: effort-gate consistency — only trivial/small are --ship
    # eligible. Each of the four files names both tiers; none should be missing.
    for f in "$ni_skill" "$ship_skill" "$state_fmt" "$DOCS_FILE"; do
        assert_file_contains "$f" "trivial" \
            "$(/usr/bin/basename "$f"): names trivial as a --ship effort tier"
        assert_file_contains "$f" "small" \
            "$(/usr/bin/basename "$f"): names small as a --ship effort tier"
    done

    # Invariant 3: the plan-approval gate is preserved under --ship (the
    # EnterPlanMode/ExitPlanMode gate still runs — --ship only removes the
    # /clear boundary, not the approval).
    assert_file_contains "$ni_skill" "plan-approval gate" \
        "next-issue/SKILL.md states --ship keeps the plan-approval gate"
    assert_file_contains "$ni_skill" "EnterPlanMode" \
        "next-issue/SKILL.md still references EnterPlanMode"
    assert_file_contains "$ni_skill" "ExitPlanMode" \
        "next-issue/SKILL.md still references ExitPlanMode"

    # Invariant 4: the two skills are NOT merged — both remain separate skill
    # directories with their own SKILL.md (already asserted to exist above), and
    # neither file instructs merging them.
    for f in "$ni_skill" "$ship_skill"; do
        local rel
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/SKILL.md"
        assert_file_not_contains "$f" "merge the two skills" \
            "$rel: does not instruct merging the two skills"
    done

    # Docs-sync: the skills-and-agents.md next-issue row mentions --ship and the
    # pipeline blurb scopes the fast-path to trivial/small.
    assert_true "command grep -E 'next-issue' '$DOCS_FILE' | command grep -q -- '--ship'" \
        "skills-and-agents.md next-issue row mentions --ship"
    assert_true "command grep -- '--ship' '$DOCS_FILE' | command grep -qE 'trivial|small'" \
        "skills-and-agents.md scopes the --ship fast-path to trivial/small"
}

# Test: cross-file invariants of the /next-issue --auto chaining contract.
# Issue #572: autonomous /next-issue must INVOKE /next-issue-ship in the same
# turn (via the Skill tool), not merely print a "next step" and exit — otherwise
# a headless golem ships nothing. These static greps guard that the in-turn
# invocation instruction and the orchestrate `;`-chained resume backstop survive
# future prose edits. All static greps — no Docker.
test_next_issue_auto_invariants() {
    local ni_skill="$SKILLS_DIR/next-issue/SKILL.md"
    local ship_skill="$SKILLS_DIR/next-issue-ship/SKILL.md"
    local orch_skill="$SKILLS_DIR/orchestrate/SKILL.md"
    local mode_proto="$SKILLS_DIR/orchestrate/mode-protocol.md"

    # Invariant 0: the contract files exist.
    assert_file_exists "$ni_skill" "next-issue/SKILL.md exists"
    assert_file_exists "$ship_skill" "next-issue-ship/SKILL.md exists"
    assert_file_exists "$orch_skill" "orchestrate/SKILL.md exists"
    assert_file_exists "$mode_proto" "orchestrate/mode-protocol.md exists"

    # Invariant 1: autonomous /next-issue invokes the ship skill IN-TURN. The
    # central correctness property of #572 — the instruction must say to invoke
    # the Skill tool in the same turn, not just "hand off". Require both the
    # `Skill` tool reference and the "same turn" phrasing.
    assert_file_contains "$ni_skill" "Skill" \
        "next-issue/SKILL.md references the Skill tool for the autonomous handoff"
    assert_true "command grep -qiE 'in (the|this) same turn' '$ni_skill'" \
        "next-issue/SKILL.md states the ship invocation happens in the same turn"

    # Invariant 2: the autonomous handoff is an invocation, not a mere
    # suggestion — guard against a regression to the passive "prints a next step"
    # behavior the issue describes.
    assert_true "command grep -qiE 'do NOT (end the turn|stop after|merely print)' '$ni_skill'" \
        "next-issue/SKILL.md forbids ending the turn without invoking ship"

    # Invariant 3: the ship skill acknowledges it may be reached in-turn (so it
    # must not assume a fresh post-/clear context).
    assert_true "command grep -qiE 'in-turn|same turn' '$ship_skill'" \
        "next-issue-ship/SKILL.md acknowledges in-turn invocation"

    # Invariant 4: both env-var and flag activation paths are documented (the
    # contract covers NEXT_ISSUE_AUTONOMOUS=1 as well as --auto).
    assert_file_contains "$ni_skill" "NEXT_ISSUE_AUTONOMOUS" \
        "next-issue/SKILL.md documents the NEXT_ISSUE_AUTONOMOUS env-var activation"

    # Invariant 4b: env-var-triggered autonomy is announced (a manually-typed
    # /next-issue inheriting NEXT_ISSUE_AUTONOMOUS=1 must surface that gates are
    # off, so a silent leaked env var can't run unattended unnoticed).
    assert_true "command grep -qiE 'autonomous mode active|gates bypassed|gates are off' '$ni_skill'" \
        "next-issue/SKILL.md announces env-var-triggered autonomy"

    # Invariant 5: the orchestrate golem launch uses the `;`-chained resume
    # backstop, NOT `&&` (which would skip the backstop on the first prompt's
    # non-zero exit — the very case it exists for). Both orchestrate files must
    # carry the chained ship invocation so they cannot drift apart. The launch
    # now passes `--permission-mode auto` explicitly (#585), so match the ship
    # half of the chain with that flag present.
    for f in "$orch_skill" "$mode_proto"; do
        local rel
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/$(/usr/bin/basename "$f")"
        assert_true "command grep -qF '; claude --permission-mode auto \"/next-issue-ship --auto\"' '$f'" \
            "$rel: golem launch chains /next-issue-ship with ';' (resume backstop)"
        assert_file_not_contains "$f" '&& claude "/next-issue-ship --auto"' \
            "$rel: golem launch does not use '&&' for the ship backstop"
        assert_file_not_contains "$f" '&& claude --permission-mode auto "/next-issue-ship --auto"' \
            "$rel: golem launch does not use '&&' for the ship backstop (with flag)"
    done

    # Invariant 5b (#585): the orchestrate golem launch passes the harness
    # `--permission-mode auto` flag EXPLICITLY. A fresh worktree is untrusted, so
    # Claude Code does not load its copied settings.local.json `defaultMode: auto`
    # and would silently fall back to `default` and prompt-storm. The explicit
    # flag is distinct from the `/next-issue` `--auto` skill flag — both must be
    # present on the launch line. Guard both orchestrate files.
    # `rel` is already declared `local` in the Invariant 5 loop above; `local`
    # is function-scoped in bash, so re-using it here needs no new declaration.
    for f in "$orch_skill" "$mode_proto"; do
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/$(/usr/bin/basename "$f")"
        assert_true "command grep -qF 'claude --permission-mode auto \"/next-issue' '$f'" \
            "$rel: golem launch passes harness --permission-mode auto explicitly (#585)"
    done

    # Invariant 6: golems launch interactive (inherit `auto`), never headless
    # `claude -p` — per golem-supervised-auto-mode (#570). The launch lines that
    # invoke the next-issue pipeline must not use `claude -p`.
    for f in "$orch_skill" "$mode_proto"; do
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/$(/usr/bin/basename "$f")"
        assert_true "! command grep -qF 'claude -p \"/next-issue' '$f'" \
            "$rel: golem launch is interactive (no headless 'claude -p')"
    done

    # Invariant 7: the provision-agent container golem launch uses the same
    # ';'-not-'&&' resume backstop (the '&&' would skip ship when the first
    # prompt exits non-zero). Guards the container-golem launch against the
    # regression #572 fixed for the worktree path. Match the literal
    # "--auto' &&" (no trailing backslash — a trailing '\' makes an unreliable
    # regex) via grep -F so the '&&' is detected exactly where it would chain
    # the two prompts.
    local prov_skill="$SKILLS_DIR/provision-agent/SKILL.md"
    # Hard-fail on absence (mirrors Invariant 0) so the #585 assertions below
    # can't evaporate silently if the file is deleted or renamed.
    assert_file_exists "$prov_skill" "provision-agent/SKILL.md exists"
    # The #585 regression guards (explicit flag + interactive-not-headless) are
    # UNCONDITIONAL — like Invariants 5b/6 for the orchestrate files — so they
    # cannot vacate if the `next-issue.*--auto` pattern is later removed from the
    # file. Use `grep -F --` so a leading "--auto" is treated as a pattern, not
    # an option flag (the harness's grep is ripgrep-backed and rejects a bare
    # leading "--...").
    assert_true "command grep -qF -- \"claude --permission-mode auto '/next-issue\" '$prov_skill'" \
        "provision-agent/SKILL.md golem launch passes harness --permission-mode auto explicitly (#585)"
    assert_true "! command grep -qF \"claude -p '/next-issue\" '$prov_skill'" \
        "provision-agent/SKILL.md golem launch is interactive (no headless 'claude -p')"
    # The ';'-not-'&&' backstop chaining checks remain guarded on the file still
    # carrying a next-issue launch (they assert the shape of that launch).
    if command grep -q -- "next-issue.*--auto" "$prov_skill"; then
        assert_true "! command grep -qF -- \"--auto' &&\" '$prov_skill'" \
            "provision-agent/SKILL.md golem launch does not chain ship with '&&'"
        assert_true "command grep -qF -- \"--auto' ;\" '$prov_skill'" \
            "provision-agent/SKILL.md golem launch chains ship with ';' (resume backstop)"
        assert_true "command grep -qF -- 'next-issue-ship --auto' '$prov_skill'" \
            "provision-agent/SKILL.md ship backstop passes --auto"
    fi

    # Invariant 8 (#585): the justfile `worktree-new` printed launch hint passes
    # the harness `--permission-mode auto` flag AND keeps the `;`-chained ship
    # backstop. This is the human-facing string operators copy-paste; a
    # regression to the pre-#585 form (no flag) would silently reintroduce the
    # prompt-storm, and dropping the chain would lose premature-exit recovery.
    # Static text checks, no Docker. Hard-fail on an absent justfile rather than
    # skipping vacuously.
    local justfile="$CONTAINERS_DIR/justfile"
    assert_file_exists "$justfile" "justfile exists"
    assert_true "command grep -qF -- \"claude --permission-mode auto '/next-issue\" '$justfile'" \
        "justfile worktree-new launch hint passes harness --permission-mode auto explicitly (#585)"
    assert_true "command grep -qF -- \"; claude --permission-mode auto '/next-issue-ship --auto'\" '$justfile'" \
        "justfile worktree-new launch hint keeps the ';'-chained ship backstop"

    # Invariant 8b (#585): the orchestrate mode-protocol.md supervised-launch
    # code block (copy-paste-ready) must also carry the full chain, not just the
    # flag the file-level Invariants 5/5b check. Operators copy this block
    # directly, so a missing backstop here drops premature-exit recovery.
    assert_true "command grep -qF -- \"'/next-issue {N} --auto' ; claude --permission-mode auto '/next-issue-ship --auto'\" '$mode_proto'" \
        "mode-protocol.md supervised-launch block carries the full ';'-chained backstop"
}

test_next_issue_plan_gate_invariants() {
    # #586: --auto plan-skipping is gated by effort/severity. The plan
    # checkpoint is skipped ONLY for effort/trivial|small non-critical issues;
    # medium/large/critical/no-effort-label runs stay plan-gated (keep the
    # ExitPlanMode human checkpoint). These static assertions guard the
    # cross-file contract against a future prose edit silently inverting the
    # gate polarity or dropping an override flag.
    local ni_skill="$SKILLS_DIR/next-issue/SKILL.md"
    local state_fmt="$SKILLS_DIR/next-issue/state-format.md"
    local schema="$SKILLS_DIR/next-issue/schemas/next-issue-state.schema.json"
    local mode_proto="$SKILLS_DIR/orchestrate/mode-protocol.md"
    local orch_skill="$SKILLS_DIR/orchestrate/SKILL.md"

    # Invariant 0: the contract files exist.
    assert_file_exists "$ni_skill" "next-issue/SKILL.md exists"
    assert_file_exists "$state_fmt" "next-issue/state-format.md exists"
    assert_file_exists "$schema" "next-issue-state.schema.json exists"
    assert_file_exists "$mode_proto" "orchestrate/mode-protocol.md exists"

    # Invariant 1: plan_gated is a documented state-file field, in both the
    # SKILL.md Phase 1/Phase 2 templates and the schema (additionalProperties is
    # false, so an undeclared field would be rejected at validation).
    assert_file_contains "$ni_skill" '"plan_gated": {true|false}' \
        "next-issue/SKILL.md writes plan_gated in the state-file template"
    assert_file_contains "$schema" '"plan_gated"' \
        "next-issue-state.schema.json declares the plan_gated property"
    assert_file_contains "$state_fmt" "plan_gated" \
        "state-format.md documents the plan_gated field"

    # Invariant 2: the fully-autonomous (skip-plan) tier is gated to
    # trivial/small AND excludes severity/critical. Require all three tokens.
    assert_true "command grep -qF 'effort/trivial' '$ni_skill'" \
        "next-issue/SKILL.md names effort/trivial in the plan-gate rule"
    assert_true "command grep -qF 'effort/small' '$ni_skill'" \
        "next-issue/SKILL.md names effort/small in the plan-gate rule"
    assert_true "command grep -qiE 'not .*severity/critical|severity/critical' '$ni_skill'" \
        "next-issue/SKILL.md excludes severity/critical from the skip-plan tier"

    # Invariant 3: medium, large, critical, and no-effort-label are all named as
    # plan-gated triggers in BOTH SKILL.md and mode-protocol.md (guard against
    # the two files drifting on which issues get a checkpoint).
    for f in "$ni_skill" "$mode_proto"; do
        local rel
        rel="$(/usr/bin/basename "$(/usr/bin/dirname "$f")")/$(/usr/bin/basename "$f")"
        assert_true "command grep -qF 'effort/medium' '$f'" \
            "$rel: names effort/medium as a plan-gated trigger"
        assert_true "command grep -qF 'effort/large' '$f'" \
            "$rel: names effort/large as a plan-gated trigger"
        assert_true "command grep -qiE 'no .*effort.*label|no-effort-label' '$f'" \
            "$rel: names the no-effort-label case as a plan-gated trigger"
    done

    # Invariant 4: both override flags are documented, with the conflict rule.
    assert_file_contains "$ni_skill" "--plan-gate" \
        "next-issue/SKILL.md documents the --plan-gate override"
    assert_file_contains "$ni_skill" "--force-auto" \
        "next-issue/SKILL.md documents the --force-auto override"
    assert_true "command grep -qiE '\\-\\-plan-gate.? wins' '$ni_skill'" \
        "next-issue/SKILL.md states --plan-gate wins when both overrides appear"

    # Invariant 5: the plan-gated path keeps the human checkpoint — it calls
    # ExitPlanMode and BLOCKS for approval (the property the issue is about).
    assert_file_contains "$ni_skill" "ExitPlanMode" \
        "next-issue/SKILL.md calls ExitPlanMode on the plan-gated path"
    assert_true "command grep -qiE 'plan-gated' '$ni_skill'" \
        "next-issue/SKILL.md describes the plan-gated path"

    # Invariant 6: orchestrate dispatch reads effort/severity to choose the
    # launch, so a medium+/critical golem is expected to block at the plan step.
    assert_true "command grep -qiE 'effort/\\*.*severity/\\*|effort.*severity' '$orch_skill'" \
        "orchestrate/SKILL.md dispatch reads effort/severity labels"
    assert_true "command grep -qiE 'BLOCK' '$orch_skill'" \
        "orchestrate/SKILL.md notes plan-gated golems block at the plan step"
}

# --- Run All Tests ---

run_test test_agent_files_exist "Every agent has correctly named .md file"
run_test test_agent_frontmatter_fields "Every agent has required frontmatter fields"
run_test test_agent_model_values "Agent model values are valid (opus/sonnet/haiku)"
run_test test_agent_tool_values "Agent tool values are from valid set"
run_test test_agent_restrictions_section "Every agent has Restrictions section"
run_test test_agent_skills_field "Every agent has 'skills' field in frontmatter"
run_test test_agent_tool_rationale_section "Every agent has Tool Rationale section"
run_test test_skill_files_exist "Every skill has SKILL.md"
run_test test_skill_frontmatter "Every skill has description in frontmatter"
run_test test_skill_metadata_exists "Every skill has metadata.yml"
run_test test_skill_metadata_name_match "Skill metadata.yml name matches directory"
run_test test_check_skill_structure "check-* skills have 5-file structure"
run_test test_loop_skill_structure "loop-* skills have 5-file structure"
run_test test_context_skill_structure "context-* skills have 3-file structure"
run_test test_patterns_sh_executable "patterns.sh files are executable"
run_test test_skills_in_docs "Every skill listed in skills-and-agents.md"
run_test test_agents_in_docs "Every agent listed in skills-and-agents.md"
run_test test_workflow_meta_pure_literal "Every workflow.js meta is a pure literal (no concat/interpolation)"
run_test test_workflow_js_node_check "Every workflow.js passes node --check (syntax valid)"
run_test test_workflow_js_node_check_detects_syntax_error "node --check guard fires on a syntax error"
run_test test_workflow_meta_guard_detects_violations "Meta pure-literal guard fires on the negative fixture"
run_test test_next_issue_ship_invariants "next-issue --ship cross-file contract invariants hold"
run_test test_next_issue_auto_invariants "next-issue --auto chaining contract invariants hold"
run_test test_next_issue_plan_gate_invariants "next-issue --auto plan-gate effort/severity invariants hold"

# Generate test report
generate_report
