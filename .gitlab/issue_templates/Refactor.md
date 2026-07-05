<!--
Refactor template.

Fill in every H2 section below — the automated `/next-issue` workflow parses
these exact headers, so keep the names as-is. When you submit, the quick action
at the very bottom applies the `type/refactor` label automatically.

Set the Triage block (Severity + Effort) at the end so the scheduled triage job
can apply the matching `severity/*` and `effort/*` labels. An issue that leaves
both unset gets a `needs-triage` label and a reminder note.

Full conventions: docs/development/filing-issues.md
-->

## Summary

<!-- 1-3 sentences: what to restructure and why (no behavior change). -->

## Problem

<!-- What's wrong with the current structure — coupling, duplication, clarity. -->

## Current State

<!-- How the code is organized today. -->

## Target State

<!-- The desired structure after the refactor. -->

## Proposed Solution

<!-- The steps to get from current to target, preserving behavior. -->

## Acceptance Criteria

- [ ] Behavior is unchanged (tests still pass).
- [ ] <!-- Additional verifiable outcomes. -->

## Affected Files

- `path/to/file` — <!-- what changes -->

## Context

<!-- Background, related discussions, constraints (link with #N). -->

<!--
Triage — set both so /next-issue can prioritize this issue.
Severity expresses impact; Effort estimates size. See the tables in
docs/development/filing-issues.md if unsure. Edit the values in place.
-->

- Severity: low <!-- critical | high | medium | low -->
- Effort: medium <!-- trivial | small | medium | large -->

/label ~"type/refactor"
