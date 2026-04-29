---
name: Use file-issue skill for issue creation
description: When filing GitHub/GitLab issues, always invoke the file-issue skill rather than calling gh/glab directly
type: feedback
originSessionId: f3bdee37-b9b4-4808-a0f5-8265562211bc
---

When this project's workflow needs to file a new issue (follow-up item,
deferred acceptance criterion, scope creep that belongs separate, etc.),
**invoke the `/file-issue` skill** rather than crafting an issue body inline
or calling `gh issue create` directly.

**Why:** The skill enforces structured fields, auto-labeling
(severity/effort/component/type), scope boundaries, and the project's
issue body conventions. Hand-rolled issues drift from those conventions
and become noisier to triage. The user has flagged this directly when
plans referenced raw `gh issue create` invocations.

**How to apply:**

- In planning documents that say "file follow-up issue X" — the next step
  is `Skill(skill="file-issue", args="<short prompt describing the issue>")`,
  not bash + `gh`.
- The skill takes care of platform detection (gh vs glab), labels, and
  duplicate-checking.
- Cross-repo follow-ups (e.g., issues filed in `joshjhall/containers-db`
  while working in `joshjhall/containers`) still go through the skill;
  pass the repo as part of the prompt.
- This includes both deferred acceptance criteria and scope-creep items
  surfaced during planning.

Equivalent verbal cues to watch for: "file an issue", "file a follow-up",
"open an issue", "track this separately" — all should funnel through the
skill.
