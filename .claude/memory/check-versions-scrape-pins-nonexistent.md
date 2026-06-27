---
name: check-versions-scrape-pins-nonexistent
description: Auto-patcher version checks that scrape arbitrary version strings off HTML can mint pins with no download
metadata:
  node_type: memory
  type: project
  originSessionId: 6023e16a-29a1-479f-958a-637c9d70cfa3
---

`bin/lib/check-versions/checks.sh` checks must derive "latest" from an
artifact that maps 1:1 to something **downloadable** (release tarball
filename, API tag, dist file), NOT by grepping every `\d+.\d+.\d+`-shaped
string off a themed HTML index page.

**Why:** jdtls broke the java-dev merge-tier build (PR #582). The auto-patch
bumped `JDTLS_VERSION` to `1.58.0`, a version that scraped off the themed
Eclipse milestones page but had **no corresponding download** — the install
404'd and aborted the build. The page also stopped listing real version dirs
entirely, so the max-of-scraped-numbers picked up page-chrome noise.

**How to apply:** When adding/reviewing a `check_*` function, point it at the
same directory/endpoint the matching install script downloads from, and
extract the version from the artifact filename. For jdtls that's
`download.eclipse.org/jdtls/snapshots/` and `jdt-language-server-<ver>-<ts>.tar.gz`.
The auto-patcher merges on green CI but `java-dev` is skip-listed in the PR
tier (only built in the merge tier on push to main), so a bad pin can pass
PR checks and only break after merge. Related: [[auto-patch-inline-checksums]].
