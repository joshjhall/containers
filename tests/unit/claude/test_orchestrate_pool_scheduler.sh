#!/usr/bin/env bash
# Behavioral tests for the orchestrate worker-pool scheduler (#603).
#
# lint_skills_agents.sh::test_orchestrate_pool_invariants only checks that the
# pool tokens exist in workflow.js — it does NOT run the scheduler. This suite
# executes the REAL `mode: 'pool'` branch of orchestrate/workflow.js against
# synthetic `args` and asserts on the returned refill plan, covering the
# non-trivial logic: collision holds (vs in-flight AND vs an earlier pick this
# sweep), no-file candidates ranked last, draining/paused yielding no picks, and
# excess on a size shrink. It also regression-tests the shared `setsIntersect`
# helper via train mode's overlap graph.
#
# The harness globals (args, phase, log, budget, parallel, pipeline, agent) are
# stubbed exactly as the Workflow tool provides them, and the `export const meta`
# block is stripped (the tool reads it separately) — mirroring how the live tool
# evaluates the script body. No Docker, no network; node only.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "Orchestrate Worker-Pool Scheduler (#603)"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/../../.." && pwd)"
WF="$PROJECT_ROOT_REAL/lib/features/templates/claude/skills/orchestrate/workflow.js"

# Node-evaluate the real workflow.js body with stubbed harness globals, feeding
# it the JSON `args` on argv[2] and printing the JSON result on stdout.
# Module-scope temp dir (the framework's per-test TEST_TEMP_DIR is created in
# setup(), so use an independent one here and clean it up via trap).
RUNNER_DIR="$(mktemp -d -t "pool-sched-XXXXXX")"
RUNNER="$RUNNER_DIR/pool-runner.mjs"
trap 'rm -rf "$RUNNER_DIR"' EXIT

write_runner() {
    /usr/bin/cat >"$RUNNER" <<'EOF'
import { readFileSync } from 'node:fs'
const src = readFileSync(process.argv[2], 'utf8')
// Strip `export const meta = {...}` (the Workflow tool reads it separately) and
// run the remaining body as the tool does: an async fn with harness globals.
const body = src.replace(/export const meta = \{[\s\S]*?\n\}\n/, '')
const args = JSON.parse(process.argv[3])
const phase = () => {}
const log = () => {}
const budget = { total: null, spent: () => 0, remaining: () => Infinity }
const parallel = async (thunks) => Promise.all(thunks.map((t) => t()))
const pipeline = async () => []
const agent = async () => null
const fn = new Function(
  'args', 'phase', 'log', 'budget', 'parallel', 'pipeline', 'agent',
  `return (async () => { ${body} })()`,
)
const out = await fn(args, phase, log, budget, parallel, pipeline, agent)
process.stdout.write(JSON.stringify(out))
EOF
}

# Run the scheduler and emit a `jq`-extracted scalar/array for assertion.
# Usage: run_pool '<args-json>' '<jq-filter>'
run_pool() {
    local args_json="$1" jq_filter="$2"
    command node "$RUNNER" "$WF" "$args_json" | jq -c "$jq_filter"
}

# --- Guards ---

test_prereqs() {
    assert_command_exists node "node is available for behavioral scheduler tests"
    assert_command_exists jq "jq is available for result extraction"
    assert_file_exists "$WF" "orchestrate/workflow.js exists"
}

# --- Pool mode ---

# size=2, one in-flight golem on a.js; backlog [10:a.js, 11:b.js].
# Expect: free_slots=1, the a.js candidate held (collides with in-flight), the
# b.js candidate picked.
test_pool_collision_hold_vs_inflight() {
    write_runner
    local args='{"mode":"pool","pool":{"size":2,"accepting":"accepting"},
        "inflight":[{"issue":9,"golem":"golem-9","branch":"feature/issue-9","files":["a.js"]}],
        "backlog":[{"issue":10,"files":["a.js"]},{"issue":11,"files":["b.js"]}]}'
    assert_equals "1" "$(run_pool "$args" '.pool.free_slots')" \
        "free_slots = size(2) - inflight(1)"
    assert_equals "[11]" "$(run_pool "$args" '.pool.picks')" \
        "picks the b.js candidate (disjoint), holds the a.js one"
    assert_equals "10" "$(run_pool "$args" '.pool.held[0].issue')" \
        "issue 10 held on predicted overlap with in-flight a.js"
}

# Two free slots, both backlog candidates touch the same file. The second must
# be held against the FIRST PICK's claimed files, not just in-flight.
test_pool_cross_pick_collision() {
    write_runner
    local args='{"mode":"pool","pool":{"size":2,"accepting":"accepting"},
        "inflight":[],
        "backlog":[{"issue":7,"files":["shared"]},{"issue":8,"files":["shared"]}]}'
    assert_equals "[7]" "$(run_pool "$args" '.pool.picks')" \
        "second same-file candidate held against the first pick's claim"
    assert_equals "1" "$(run_pool "$args" '.pool.held_slots')" \
        "one slot held idle (only a colliding candidate remained)"
}

# A no-file ("unknown") candidate is dispatchable but ranked AFTER a known
# -disjoint one: backlog [5:(none), 6:z] with 2 slots picks [6,5].
test_pool_no_file_candidate_ranked_last() {
    write_runner
    local args='{"mode":"pool","pool":{"size":2,"accepting":"accepting"},
        "inflight":[],
        "backlog":[{"issue":5},{"issue":6,"files":["z"]}]}'
    assert_equals "[6,5]" "$(run_pool "$args" '.pool.picks')" \
        "known-disjoint (6) dispatched before unknown (5), but unknown not dropped"
}

# Draining: free slots exist but NOTHING is refilled; free_slots/excess still
# reported for display.
test_pool_draining_refills_nothing() {
    write_runner
    local args='{"mode":"pool","pool":{"size":3,"accepting":"draining"},
        "inflight":[{"issue":1,"files":["x"]}],
        "backlog":[{"issue":2,"files":["y"]}]}'
    assert_equals "[]" "$(run_pool "$args" '.pool.picks')" \
        "draining state refills nothing"
    assert_equals "2" "$(run_pool "$args" '.pool.free_slots')" \
        "draining still reports free_slots for display"
}

# Paused behaves like draining for refills (no picks).
test_pool_paused_refills_nothing() {
    write_runner
    local args='{"mode":"pool","pool":{"size":2,"accepting":"paused"},
        "inflight":[],
        "backlog":[{"issue":3,"files":["a"]}]}'
    assert_equals "[]" "$(run_pool "$args" '.pool.picks')" \
        "paused state refills nothing"
}

# Size shrank below the live count: excess reported (to drain), never picked,
# and free_slots clamps to 0.
test_pool_shrink_reports_excess() {
    write_runner
    local args='{"mode":"pool","pool":{"size":1,"accepting":"accepting"},
        "inflight":[{"issue":1,"golem":"g1","files":["x"]},{"issue":2,"golem":"g2","files":["y"]}],
        "backlog":[]}'
    assert_equals "0" "$(run_pool "$args" '.pool.free_slots')" \
        "over-capacity pool reports free_slots=0"
    assert_equals "[2]" "$(run_pool "$args" '[.pool.excess[].issue]')" \
        "the excess golem (issue 2) is surfaced to drain"
}

# Empty backlog with a free slot: no picks, the slot is held (idle by design).
test_pool_empty_backlog_holds_slot() {
    write_runner
    local args='{"mode":"pool","pool":{"size":2,"accepting":"accepting"},
        "inflight":[{"issue":1,"files":["x"]}],"backlog":[]}'
    assert_equals "[]" "$(run_pool "$args" '.pool.picks')" \
        "no picks when the backlog is empty"
    assert_equals "1" "$(run_pool "$args" '.pool.held_slots')" \
        "the free slot is held idle when the backlog is dry"
}

# --- Train mode (regression for the shared setsIntersect helper) ---

# Two PRs share a file -> one chain; a third is independent.
test_train_overlap_graph_after_shared_helper() {
    write_runner
    local args='{"mode":"train","prs":[
        {"number":1,"branch":"b1","issue":1,"files":["shared.js"]},
        {"number":2,"branch":"b2","issue":2,"files":["shared.js"]},
        {"number":3,"branch":"b3","issue":3,"files":["lonely.js"]}]}'
    assert_equals "[3]" "$(run_pool "$args" '.train.independents')" \
        "PR3 (lonely.js) is independent"
    assert_equals "[[1,2]]" "$(run_pool "$args" '.train.chains')" \
        "PR1 + PR2 (shared.js) form one ordered chain"
}

# --- Run ---

run_test test_prereqs "node + jq + workflow.js present"
run_test test_pool_collision_hold_vs_inflight "pool holds a candidate colliding with in-flight work"
run_test test_pool_cross_pick_collision "pool holds a candidate colliding with an earlier pick"
run_test test_pool_no_file_candidate_ranked_last "pool ranks no-file candidates last but still dispatches them"
run_test test_pool_draining_refills_nothing "draining yields zero picks, still reports free_slots"
run_test test_pool_paused_refills_nothing "paused yields zero picks"
run_test test_pool_shrink_reports_excess "size shrink reports excess golems to drain"
run_test test_pool_empty_backlog_holds_slot "empty backlog holds the free slot idle"
run_test test_train_overlap_graph_after_shared_helper "train overlap graph intact after shared setsIntersect"

generate_report
