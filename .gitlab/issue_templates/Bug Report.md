<!--
Bug Report template.

Fill in every H2 section below — the automated `/next-issue` workflow parses
these exact headers, so keep the names as-is. When you submit, the quick action
at the very bottom applies the `type/bug` label automatically.

Set the Triage block (Severity + Effort) at the end so the scheduled triage job
can apply the matching `severity/*` and `effort/*` labels. An issue that leaves
both unset gets a `needs-triage` label and a reminder note.

Full conventions: docs/development/filing-issues.md
-->

## Summary

<!-- 1-3 sentences: what is broken and the impact. -->

## Problem

<!-- What actually happens. Include error messages, logs, or screenshots. -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What should happen instead. -->

## Proposed Solution

<!-- Optional: your idea for the fix, if you have one. -->

## Acceptance Criteria

- [ ] <!-- One verifiable outcome per checkbox. -->
- [ ]

## Affected Files

- `path/to/file` — <!-- what changes -->

## Context

<!-- Environment, version, related issues (link with #N). -->

<!--
Triage — set both so /next-issue can prioritize this issue.
Severity expresses impact; Effort estimates size. See the tables in
docs/development/filing-issues.md if unsure. Edit the values in place.
-->

- Severity: medium <!-- critical | high | medium | low -->
- Effort: small <!-- trivial | small | medium | large -->

/label ~"type/bug"
