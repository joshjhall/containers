# check-\* Migration Status — Historical Pointer

> **This doc is a historical redirect.** The `audit-*` → `check-*` migration it
> once tracked in-repo is done _as an extraction_: the `check-*` skills no
> longer live in this repository. They — and their remaining coverage work —
> now ship from the sibling [`joshjhall/librarian`](https://github.com/joshjhall/librarian)
> repo. **Look there, not here, for current `check-*` status.**

## What moved, and where it went

The `check-*` skills (deterministic `patterns.sh` pre-scan + LLM judgment) and
the `audit-*` agents they incrementally replace were extracted into librarian's
**`review-audit`** plugin and removed from
`lib/features/templates/claude/skills/` in
[#669](https://github.com/joshjhall/containers/issues/669) (part of
[epic #607](https://github.com/joshjhall/containers/issues/607), which tracked
moving the general-purpose skills/agents out of this build).

The container installs these skills from the librarian marketplace at build
time; it no longer carries their source. For how that install works and the full
plugin inventory, see
[skills-and-agents.md § Source of Truth: the `librarian` marketplace](skills-and-agents.md#source-of-truth-the-librarian-marketplace).

## Where the remaining migration work is tracked

Ongoing `check-*` coverage (the domains that were only partially migrated —
security, code-health, ai-config — plus the not-yet-started test-gaps and
architecture domains) is now librarian work, tracked in the
[`joshjhall/librarian` issue tracker](https://github.com/joshjhall/librarian/issues),
not in this repo.

The sub-issues this doc formerly listed as `containers` migration tasks have
been superseded accordingly — for example
[#346](https://github.com/joshjhall/containers/issues/346) was closed here as
_moved_ and refiled as
[joshjhall/librarian#222](https://github.com/joshjhall/librarian/issues/222).
Do not treat any old `containers` migration sub-issue numbers as authoritative;
follow the librarian tracker instead.

## Why this doc still exists

It is kept (rather than deleted) so the inbound link from `skills-and-agents.md`
stays valid and so the extraction has a stable landing note. The detailed
per-domain gap analysis, completion criteria, and deprecation timeline that used
to live here were repo-local snapshots that went stale the moment the skills
left the repo; they are intentionally not reproduced. The authoritative,
versioned status lives with the code, in librarian.
