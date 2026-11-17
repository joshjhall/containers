#!/usr/bin/env bash
# Pre-commit hook: refuse commits authored or committed under a placeholder
# email (t@t.t, *@example.com, *@localhost, ...).
#
# GitHub attributes a commit to whichever account has claimed its author
# email. 31 commits on main were authored as `t <t@t.t>` — a stale repo-local
# .git/config identity shadowing the real global one — and GitHub credited
# them to an unrelated account that had once claimed t@t.t. History can't be
# fixed without rewriting main, so stop it at commit time instead.
#
# Uses `git var`, which resolves the identity exactly as `git commit` will
# (GIT_AUTHOR_* / GIT_COMMITTER_* env, then local > global > system config).
set -euo pipefail

# placeholder_reason EMAIL — shared with setup-git (#1533) so the rules
# cannot drift; returns 0 and prints the reason for a placeholder email.
# shellcheck source=lib/runtime/commands/_git-email-placeholder
. "$(dirname "${BASH_SOURCE[0]}")/../lib/runtime/commands/_git-email-placeholder"

fail=0
for role in AUTHOR COMMITTER; do
    # No resolvable identity (e.g. a CI runner linting with `lefthook run`):
    # nothing can be misattributed, and a real `git commit` refuses on its own.
    ident=$(git var "GIT_${role}_IDENT" 2>/dev/null) || continue
    # "Name <email> 1700000000 -0500" → email
    email="${ident##*<}"
    email="${email%%>*}"
    if reason=$(placeholder_reason "$email"); then
        /usr/bin/printf 'ERROR: commit %s email <%s> is a placeholder (%s).\n' "${role,,}" "$email" "$reason" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    {
        /usr/bin/printf '\nGitHub credits commits to whoever has claimed the email, so this\n'
        /usr/bin/printf 'commit would be attributed to a stranger (or to nobody).\n\n'
        /usr/bin/printf 'Where the identity comes from:\n'
        git config --show-origin --get-all user.email 2>/dev/null | /usr/bin/sed 's/^/  /' || true
        env | /usr/bin/grep -E '^GIT_(AUTHOR|COMMITTER)_EMAIL=' | /usr/bin/sed 's/^/  env: /' || true
        /usr/bin/printf '\nA stale repo-local identity is the usual cause; clear it with:\n'
        /usr/bin/printf '  git config --local --unset user.name; git config --local --unset user.email\n'
    } >&2
    exit 1
fi
