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

# Returns 0 (and prints the reason) when $1 is a placeholder email.
placeholder_reason() {
    local email="$1" local_part domain tld
    case "$email" in
        *@*) ;;
        *)
            echo "no @domain"
            return 0
            ;;
    esac
    local_part="${email%@*}"
    domain="${email##*@}"
    domain="${domain,,}"
    [ -n "$local_part" ] || {
        echo "empty local part"
        return 0
    }
    # Also catches git's auto-guessed `user@host.(none)` when no email is set.
    if [[ ! "$domain" =~ ^[a-z0-9.-]+$ ]]; then
        echo "domain '$domain' is not a valid hostname"
        return 0
    fi
    case "$domain" in
        *.*) ;;
        *)
            echo "domain '$domain' has no dot"
            return 0
            ;;
    esac
    tld="${domain##*.}"
    if [ "${#tld}" -lt 2 ]; then
        echo "top-level domain '.$tld' is not real"
        return 0
    fi
    # RFC 2606 / RFC 6761 reserved names, plus test.com (a real, claimable
    # domain that test fixtures habitually use).
    case "$domain" in
        example.com | example.org | example.net | *.example.com | *.example.org | *.example.net | \
            *.example | *.test | *.invalid | *.localhost | *.local | *.localdomain | \
            test.com)
            echo "domain '$domain' is reserved for testing/examples"
            return 0
            ;;
    esac
    return 1
}

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
