#!/usr/bin/env bash
# Guard: no `producer | grep -q` in tests/unit/ (issue #1097).
#
# THE BUG. Under `set -o pipefail`, `producer | grep -q P` races: grep -q exits
# on its first match, and a producer with output still unwritten takes SIGPIPE.
# The pipeline returns 141 and the assertion fails — or, behind `if !` or an
# error-detecting `if`, silently inverts. #1092 hit it in
# integration-ci-coverage.sh, and it surfaced only under scheduler load (the
# pre-push hook), never in an idle loop: 200 clean idle runs wrongly cleared it.
#
# WHY A BLANKET RULE, NOT A RISK JUDGMENT. Whether a given producer can exceed
# one pipe write depends on output it captures at run time; "small output, one
# write" is exactly the reasoning that cleared #1092. A rule with no exceptions
# is a one-line lint; a rule for "risky" sites needs a maintained exception
# list. The fix is mechanical and behavior-preserving:
#
#   command grep -q 'P' <<<"$x"                       # builtin echo/printf
#   body=$(producer || true); command grep -q 'P' <<<"$body"   # external
#
# NO EXCEPTIONS. The 180-odd original sites were converted one directory per PR
# (#1097 phases 1-6), behind a per-directory allowlist that emptied as each
# phase landed. Phase 7 deleted it: any site anywhere under tests/unit/ fails.
#
# Matched: `|` and `|&` into a grep -q, including one behind other words (env
# assignments, `env`, `!`) or opening a `{ ...; }` or `( ... )` group, with the consumer on the same
# logical line or on the next one after a trailing pipe (blank and comment
# lines between are skipped, as bash skips them), or at any later command
# inside a piped group. Backslash continuations are joined, and each file is
# scanned three ways: raw, without inline comments, and with quotes and
# substitutions masked (see pipe_grep_q_sites).
#
# Not matched: `grep -q X f || grep -q Y f` (no pipe, just `||`), comment lines,
# and the herestring idiom itself. This file builds its scanner fixtures from
# pieces, so it never contains the shape it rejects.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "grep -q pipefail guard"

UNIT_DIR="$PROJECT_ROOT/tests/unit"

# pipe_grep_q_sites ROOT — prints "relpath:line" for every pipe (`|` or `|&`)
# into a grep (or egrep/fgrep) whose short-option cluster carries q (or
# --quiet), optionally at a /usr/bin/ or /bin/ path, and preceded by any
# brace-group or subshell openers and any other words up to a shell separator
# (`{ LC_ALL=C command grep -q`). Backslash-continued physical lines are
# joined first, as bash does, and a site is reported at the last physical line
# of its logical line. A logical line ending in a pipe continues onto the next
# non-blank, non-comment line, which is checked as the consumer.
#
# THREE VIEWS, UNION. Each file is scanned three times in one pass: raw (only
# whole-line comments skipped), stripped (inline comments removed), and masked
# (quoted strings and substitutions blanked, piped groups walked; see mask and
# walk), and a site found by any is reported. Telling a comment # from a
# literal one needs a bash parser; this is a line heuristic. Raw alone misses
# a pipe whose continuation hides behind a comment (`producer | # why`);
# stripped alone hides a real site whenever stripping guesses wrong (a quote
# opened on an earlier line); neither sees past a ; inside a quoted prefix
# word, which only masking can. The union keeps every site raw text shows, so
# a stripping or masking mistake can only add a report, never remove one. The
# price is an occasional over-report, which fails the guard loudly instead of
# passing it silently.
pipe_grep_q_sites() {
    local root="$1"
    (cd "$root" && command find . -name '*.sh' -type f -exec /usr/bin/awk '
            # strip_comment: drop everything from the first # that is not
            # quoted or backslash-escaped on this physical line. It may strip
            # too much (`a#b` is one word in bash); the raw view covers that.
            function strip_comment(s,   i, n, c, sq, dq) {
                n = length(s); sq = 0; dq = 0
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    if (sq) { if (c == "\047") sq = 0 }
                    else if (c == "\\") i++
                    else if (dq) { if (c == "\"") dq = 0 }
                    else if (c == "\047") sq = 1
                    else if (c == "\"") dq = 1
                    else if (c == "#") return substr(s, 1, i - 1)
                }
                return s
            }
            # skip: s has an opener at i (a quote, a backtick, `$(` or `${`);
            # return the index of its closing char, or the end of s when it
            # is not closed on this logical line. Openers nest inside `"`,
            # `$(` and `${`, so `"$(a ")")"` closes at its last quote.
            function skip(s, i,   n, c, o, cl, d, k) {
                n = length(s); c = substr(s, i, 1)
                if (c == "\047") { k = index(substr(s, i + 1), "\047"); return k ? i + k : n }
                if (c == "`" || c == "\"") {
                    for (k = i + 1; k <= n; k++) {
                        o = substr(s, k, 1)
                        if (o == "\\") k++
                        else if (o == c) return k
                        else if (c == "\"" && (o == "`" || (o == "$" && substr(s, k + 1, 1) ~ /[({]/))) k = skip(s, k)
                    }
                    return n
                }
                o = substr(s, i + 1, 1); cl = (o == "(") ? ")" : "}"; d = 0
                for (k = i + 1; k <= n; k++) {
                    c = substr(s, k, 1)
                    if (c == "\\") k++
                    else if (c == "\047" || c == "\"" || c == "`" || (c == "$" && substr(s, k + 1, 1) ~ /[({]/)) k = skip(s, k)
                    else if (c == o) d++
                    else if (c == cl && --d == 0) return k
                }
                return n
            }
            # mask: the masked view of one logical line. Each quoted string,
            # substitution and escaped char becomes x, an & inside a redirect
            # (2>&1, &>f) becomes x, and a # opening a word ends the line. So
            # a ; & or | the shell reads as part of a word no longer ends the
            # consumer (`A="x;y" grep -q`). Quotes are paired per logical line
            # only: one opened on an earlier line fools this view, which is
            # why it adds to the union rather than replacing a view.
            function mask(s,   n, i, c, out, ws) {
                n = length(s); out = ""; ws = 1
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    if (c == "\\") { out = out "xx"; i++; ws = 0; continue }
                    if (c == "\047" || c == "\"" || c == "`" || (c == "$" && substr(s, i + 1, 1) ~ /[({]/)) {
                        i = skip(s, i); out = out "x"; ws = 0; continue
                    }
                    if (c == "#" && ws) return out
                    if (c == "&" && (substr(s, i - 1, 1) ~ /[<>]/ || substr(s, i + 1, 1) == ">")) c = "x"
                    out = out c; ws = (c ~ /[[:space:];&|()]/)
                }
                return out
            }
            # walk: track piped-group depth gd[v] through a masked line, and
            # report a grep -q at any command start inside the group, not just
            # the first (`producer | { read -r h; grep -q x; }`). A `{` word or
            # `(` at a command start opens a group: piped if a pipe precedes
            # it, nested if a piped group is already open. `}` at a command
            # start and `)` close one. A `(` elsewhere (`a=(x)`, `<(cmd)`)
            # pairs with its own `)` on the line. Depth carries across lines,
            # for a group opened on one line and closed on a later one.
            function walk(v, s, f, n,   m, i, c, t, cs, pipe, pd) {
                m = length(s); cs = 1; pipe = pending[v]; pd = 0
                for (i = 1; i <= m; i++) {
                    c = substr(s, i, 1); t = substr(s, i + 1, 1)
                    if (c ~ /[[:space:]]/) continue
                    if (cs) {
                        if (c == "(" || (c == "{" && (t == "" || t ~ /[[:space:]]/))) {
                            if (gd[v] > 0) gd[v]++; else if (pipe) gd[v] = 1
                            pipe = 0; continue
                        }
                        if (c == "}" && (t == "" || t ~ /[[:space:];&|)]/)) {
                            if (gd[v] > 0) gd[v]--
                            cs = 0; continue
                        }
                        if (gd[v] > 0 && substr(s, i) ~ ("^" grep_q)) report(f, n)
                        cs = 0
                    }
                    if (c == "(") pd++
                    else if (c == ")") { if (pd > 0) pd--; else if (gd[v] > 0) gd[v]-- }
                    else if (c == "|") { if (t == "|" || t == "&") i++; pipe = (t != "|"); cs = 1 }
                    else if (c == ";" || c == "&") { if (t == c) i++; pipe = 0; cs = 1 }
                }
            }
            # report: print a site once, though several views may find it.
            function report(f, n) {
                if (!((f, n) in seen)) { seen[f, n] = 1; print substr(f, 3) ":" n }
            }
            # check: match one logical line of view v, ending at line n of f.
            function check(v, line, f, n,   keep) {
                # View 2 sees the masked line, and walks its groups before
                # the pipe state below moves on to this line.
                if (v == 2) { line = mask(line); walk(v, line, f, n) }
                # A consumer line can itself end in a pipe, so it falls
                # through to the same-line and trailing checks. A line of bare
                # `{` or `(` openers keeps the pipe waiting for its consumer.
                keep = pending[v] && line ~ /^[[:space:]]*([{(][[:space:]]*)+(#.*)?$/
                if (pending[v] && line ~ ("^[[:space:]]*" grep_q)) report(f, n)
                pending[v] = keep
                # Same-line: a single | or |& (not ||) followed by the consumer.
                if (line ~ ("(^|[^|])[|]&?[[:space:]]*" grep_q)) report(f, n)
                # A trailing single | or |& continues the pipe onto the next
                # line. `|\` and `| \` arrive here already joined. A # tail
                # after the pipe counts whatever the quote state, because a
                # quote opened on an earlier line fools both views about it.
                # So does a pipe into group openers alone (`producer | {`).
                if (line ~ /(^|[^|])[|]&?[[:space:]]*([{(][[:space:]]*)*(#.*)?$/) pending[v] = 1
            }
            # step: feed one physical line to view v. Bash reads on across
            # blank and comment-only lines while a pipe awaits its consumer,
            # so they leave pending alone. An odd run of trailing backslashes
            # continues the line; bash deletes the backslash-newline pair,
            # inserting nothing. An even run is literal backslashes, and `\ `
            # escapes a space.
            function step(v, phys, f, n,   line) {
                if (buf[v] == "" && phys ~ /^[[:space:]]*(#.*)?$/) return
                line = buf[v] phys
                if (match(line, /\\+$/) && RLENGTH % 2 == 1) {
                    buf[v] = substr(line, 1, length(line) - 1)
                    return
                }
                buf[v] = ""
                check(v, line, f, n)
            }
            # flush: end of file. Bash runs a line still continued at EOF, and
            # neither a continuation nor a pipe carries into the next file.
            function flush(v) {
                if (buf[v] != "") check(v, buf[v], lastf, lastn)
                buf[v] = ""; pending[v] = 0; gd[v] = 0
            }
            # GREP_Q: a grep invocation whose flags include q, anchored where a
            # pipe consumer starts. No `|` precedes it in this regex; callers
            # supply that context. Any tokens may sit between grep and the q
            # flag (value-taking flags like -m1, -A 2, -e P), stopping at a
            # shell separator so a later command on the line is not blamed,
            # and at a word opening with #, which bash reads as a comment.
            # Ahead of it: any `(` openers (an operator, so `(grep` needs no
            # space), then ANY words up to a shell separator. That one rule
            # covers a `{ ` group opener (a reserved word, so `{grep` is one
            # word and does not count), `command`, NAME=value (quoted spaces
            # included), `env`, `!`, and `time` without listing them.
            # Enumerating prefixes was tried first and each review round found
            # a shape the list missed (#1314); this rule over-reports instead
            # (`| xargs grep -q`), which fails loudly rather than passing.
            # A separator inside a quoted or substituted prefix word
            # (`A="x;y"`, `2>&1`) is masked out of view 2 before this regex
            # runs, and walk applies it at every command start inside a
            # piped group (#1322). KNOWN MISSES: walk tracks only { } and
            # ( ) groups, so a grep -q inside a piped while/for/if body is
            # not seen, and a case-arm `)` inside a piped group closes it
            # early.
            BEGIN {
                grep_q = "([(][[:space:]]*)*([^|;&[:space:]#][^|;&[:space:]]*[[:space:]]+)*(/usr/bin/|/bin/)?[ef]?grep([[:space:]]+[^|;&[:space:]#][^|;&[:space:]]*)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet)([[:space:]]|$)"
            }
            FNR == 1 { flush(0); flush(1); flush(2) }
            {
                step(0, $0, FILENAME, FNR)
                step(1, strip_comment($0), FILENAME, FNR)
                step(2, $0, FILENAME, FNR)
                lastf = FILENAME; lastn = FNR
            }
            END { flush(0); flush(1); flush(2) }
        ' {} + || true)
}

# ---------------------------------------------------------------------------
# Test: the scanner flags each known shape and nothing else
#
# Guards the real-tree test from passing vacuously: the tree has zero sites, so
# if the regex stopped matching, that test would report a clean tree forever.
# Fixture lines are assembled from pieces so this file holds no literal site.
# ---------------------------------------------------------------------------
test_scanner_detects_known_shapes() {
    local dir got p g b
    dir=$(command mktemp -d)
    p='|'
    g='grep'
    b='\'
    {
        command printf 'echo "$x" %s command %s -q foo\n' "$p" "$g"                     # 1 flag
        command printf 'producer %s /usr/bin/%s -qxF foo\n' "$p" "$g"                   # 2 flag
        command printf 'producer %s %s -E -q foo\n' "$p" "$g"                           # 3 flag
        command printf 'producer %s %s --quiet foo\n' "$p" "$g"                         # 4 flag
        command printf 'if producer %s\n' "$p"                                          # 5
        command printf '    command %s -Fxq foo; then\n' "$g"                           # 6 flag
        command printf 'command %s -q a f %s%s command %s -q b f\n' "$g" "$p" "$p" "$g" # 7
        command printf '# echo x %s %s -q foo\n' "$p" "$g"                              # 8
        command printf 'command %s -q foo <<<"$x"\n' "$g"                               # 9
        command printf 'producer %s command %s -c foo\n' "$p" "$g"                      # 10
        command printf 'producer %s command %s -v foo\n' "$p" "$g"                      # 11
        command printf 'producer %s command %s -m1 -q foo\n' "$p" "$g"                  # 12 flag
        command printf 'producer %s command %s -A 2 -q foo\n' "$p" "$g"                 # 13 flag
        command printf 'producer %s command %s -e foo -q\n' "$p" "$g"                   # 14 flag
        command printf 'producer %s command %s -v "x -q"; y -q\n' "$p" "$g"             # 15
        command printf 'producer %s e%s -q foo\n' "$p" "$g"                             # 16 flag
        command printf 'producer %s /bin/f%s -q foo\n' "$p" "$g"                        # 17 flag
        command printf 'producer %s %s\n' "$p" "$b"                                     # 18
        command printf '    command %s -q foo\n' "$g"                                   # 19 flag
        command printf 'command %s -q a f %s%s %s\n' "$g" "$p" "$p" "$b"                # 20
        command printf '    command %s -q b f\n' "$g"                                   # 21
        command printf 'producer %s\n' "$b"                                             # 22
        command printf '    command %s -q foo\n' "$g"                                   # 23
        command printf 'producer %s %s \n' "$p" "$b"                                    # 24
        command printf '    command %s -q foo\n' "$g"                                   # 25
        command printf 'producer %s %s\n' "$p" "$b"                                     # 26
        command printf '    command e%s -q foo\n' "$g"                                  # 27 flag
        command printf 'producer %s command %s %s\n' "$p" "$g" "$b"                     # 28
        command printf '    -q foo\n'                                                   # 29 flag
        command printf 'producer %s& %s -q foo\n' "$p" "$g"                             # 30 flag
        command printf 'producer %s command /usr/bin/%s -q foo\n' "$p" "$g"             # 31 flag
        command printf 'producer %s command /bin/e%s -q foo\n' "$p" "$g"                # 32 flag
        command printf 'producer %s\n' "$p"                                             # 33
        command printf '\n'                                                             # 34
        command printf '    # comment\n'                                                # 35
        command printf '    command %s -q foo\n' "$g"                                   # 36 flag
        command printf 'producer %s%s\n' "$p" "$b"                                      # 37
        command printf '    command %s -q foo\n' "$g"                                   # 38 flag
        command printf 'producer %s e%s -c foo\n' "$p" "$g"                             # 39
        command printf 'producer %s f%s -v foo\n' "$p" "$g"                             # 40
        command printf 'producer %s\n' "$b"                                             # 41
        command printf '    %s command %s -q foo\n' "$p" "$g"                           # 42 flag
        command printf 'producer %s&\n' "$p"                                            # 43
        command printf '    command %s -q foo\n' "$g"                                   # 44 flag
        command printf 'producer %s command %s %s%s\n' "$p" "$g" "$b" "$b"              # 45
        command printf '    -q foo\n'                                                   # 46
        command printf 'producer %s # note\n' "$p"                                      # 47
        command printf '    command %s -q foo\n' "$g"                                   # 48 flag
        command printf 'producer %s\n' "$p"                                             # 49
        command printf '    command %s -q a f %s\n' "$g" "$p"                           # 50 flag
        command printf '    command %s -q b\n' "$g"                                     # 51 flag
        command printf 'producer %s\n' "$p"                                             # 52
        command printf '    command %s -q a f %s command %s -q b\n' "$g" "$p" "$g"      # 53 flag once
        command printf 'producer %s # note %s\n' "$p" "$b"                              # 54
        command printf '    command %s -q foo\n' "$g"                                   # 55 flag
        command printf 'producer %s %s -v x # note %s\n' "$p" "$g" "$b"                 # 56
        command printf '    command %s -q y f\n' "$g"                                   # 57
        command printf 'command %s -E "a%s#b" f\n' "$g" "$p"                            # 58
        command printf '    command %s -q foo\n' "$g"                                   # 59 flag (over-report)
        command printf 'echo a#b %s command %s -q foo\n' "$p" "$g"                      # 60 flag
        command printf 'producer %s%s # note\n' "$p" "$p"                               # 61
        command printf '    command %s -q foo\n' "$g"                                   # 62
        command printf "command %s -E 'a %s #b' f\n" "$g" "$p"                          # 63
        command printf '    command %s -q foo\n' "$g"                                   # 64 flag (over-report)
        command printf 'echo a%s #x %s\n' "$b" "$p"                                     # 65
        command printf '    command %s -q foo\n' "$g"                                   # 66 flag
        command printf 'echo a%s\n' "$b"                                                # 67
        command printf '#b %s command %s -q foo\n' "$p" "$g"                            # 68 flag
        command printf 'echo a %s\n' "$b"                                               # 69
        command printf '#b %s command %s -q foo\n' "$p" "$g"                            # 70 flag (over-report)
        command printf 'echo $(producer)#x %s command %s -q foo\n' "$p" "$g"            # 71 flag
        command printf 'x="abc\n'                                                       # 72
        command printf 'foo #" ; producer %s command %s -q foo\n' "$p" "$g"             # 73 flag
        command printf 'producer "a %s\n' "$b"                                          # 74
        command printf '#b" %s command %s -q foo\n' "$p" "$g"                           # 75 flag
        command printf 'producer %s# note\n' "$p"                                       # 76
        command printf '    command %s -q foo\n' "$g"                                   # 77 flag
        command printf 'producer %s&# note\n' "$p"                                      # 78
        command printf '    command %s -q foo\n' "$g"                                   # 79 flag
        command printf "echo %s' %s # c\n" "$b" "$p"                                    # 80
        command printf '    command %s -q foo\n' "$g"                                   # 81 flag
        command printf 'x="abc\n'                                                       # 82
        command printf 'def" %s # why\n' "$p"                                           # 83
        command printf '    command %s -q foo\n' "$g"                                   # 84 flag
        command printf "x='abc\n"                                                       # 85
        command printf "def' %s# why\n" "$p"                                            # 86
        command printf '    command %s -q foo\n' "$g"                                   # 87 flag
        command printf 'producer %s%s # why\n' "$p" "$p"                                # 88
        command printf '    command %s -q foo\n' "$g"                                   # 89
        command printf 'x="#"; producer %s # note %s\n' "$p" "$b"                       # 90
        command printf '    command %s -q foo\n' "$g"                                   # 91 flag
        command printf "x='#'; producer %s # note %s\n" "$p" "$b"                       # 92
        command printf '    command %s -q foo\n' "$g"                                   # 93 flag
        command printf 'x=%s#; producer %s # note %s\n' "$b" "$p" "$b"                  # 94
        command printf '    command %s -q foo\n' "$g"                                   # 95 flag
        command printf 'producer %s LC_ALL=C %s -q foo\n' "$p" "$g"                     # 96 flag
        command printf 'producer %s A=1 B="x" command %s -q foo\n' "$p" "$g"            # 97 flag
        command printf 'producer %s { %s -q foo; }\n' "$p" "$g"                         # 98 flag
        command printf 'producer %s ( command %s -q foo )\n' "$p" "$g"                  # 99 flag
        command printf 'producer %s (%s -q foo)\n' "$p" "$g"                            # 100 flag
        command printf 'producer %s { LC_ALL=C %s -q foo; }\n' "$p" "$g"                # 101 flag
        command printf 'producer %s\n' "$p"                                             # 102
        command printf '    { %s -q foo; }\n' "$g"                                      # 103 flag
        command printf 'producer %s { echo; } ; %s -q x f\n' "$p" "$g"                  # 104
        command printf 'producer %s FOO=bar echo; %s -q x f\n' "$p" "$g"                # 105
        command printf 'producer %s {%s -q foo; }\n' "$p" "$g"                          # 106
        command printf 'producer %s ( %s -v foo )\n' "$p" "$g"                          # 107
        command printf 'producer %s { %s -c foo; }\n' "$p" "$g"                         # 108
        command printf 'producer %s A="x y" %s -q foo\n' "$p" "$g"                      # 109 flag
        command printf "producer %s A='x y' B=1 %s -q foo\n" "$p" "$g"                  # 110 flag
        command printf 'producer %s A="x y" echo; %s -q x f\n' "$p" "$g"                # 111
        command printf 'producer %s {\n' "$p"                                           # 112
        command printf '    %s -q foo; }\n' "$g"                                        # 113 flag
        command printf 'producer %s\n' "$p"                                             # 114
        command printf '    (\n'                                                        # 115
        command printf '    command %s -q foo )\n' "$g"                                 # 116 flag
        command printf 'producer %s A=$(cmd arg) %s -q foo\n' "$p" "$g"                 # 117 flag
        command printf 'producer %s A=x%s y %s -q foo\n' "$p" "$b" "$g"                 # 118 flag
        command printf "producer %s A='x y' echo; %s -q x f\n" "$p" "$g"                # 119
        command printf 'producer %s { ( %s -q foo ); }\n' "$p" "$g"                     # 120 flag
        command printf 'producer %s {\n' "$p"                                           # 121
        command printf '    echo; }\n'                                                  # 122
        command printf '%s -q x f\n' "$g"                                               # 123
        command printf 'producer %s A="x%s"y z" %s -q foo\n' "$p" "$b" "$g"             # 124 flag
        command printf 'producer %s env LC_ALL=C %s -q foo\n' "$p" "$g"                 # 125 flag
        command printf 'producer %s ! %s -q foo\n' "$p" "$g"                            # 126 flag
        command printf 'producer %s time %s -q foo\n' "$p" "$g"                         # 127 flag
        command printf 'producer %s A+=x %s -q foo\n' "$p" "$g"                         # 128 flag
        command printf 'producer %s A=`date +x` %s -q foo\n' "$p" "$g"                  # 129 flag
        command printf 'producer %s& { LC_ALL=C %s -q foo; }\n' "$p" "$g"               # 130 flag
        command printf 'producer %s { # c\n' "$p"                                       # 131
        command printf '    command %s -q foo; }\n' "$g"                                # 132 flag
        command printf 'producer %s xargs %s -q foo\n' "$p" "$g"                        # 133 flag (over-report)
        command printf 'producer %s cat #c %s -q foo\n' "$p" "$g"                       # 134
        command printf 'producer %s A="x;y" %s -q foo\n' "$p" "$g"                      # 135 flag
        command printf 'producer %s 2>&1 %s -q foo\n' "$p" "$g"                         # 136 flag
        command printf 'producer %s { read -r h; %s -q foo; }\n' "$p" "$g"              # 137 flag
        command printf 'producer %s A=$(a; b) %s -q foo\n' "$p" "$g"                    # 138 flag
        command printf 'producer %s {\n' "$p"                                           # 139
        command printf '    head -1\n'                                                  # 140
        command printf '    %s -q x; }\n' "$g"                                          # 141 flag
        command printf 'producer %s { read -r h; } ; %s -q x f\n' "$p" "$g"             # 142
        command printf '{ read -r h; %s -q x f; }\n' "$g"                               # 143
        command printf 'producer %s { echo "; } "; %s -q x f; }\n' "$p" "$g"            # 144 flag
        command printf 'producer %s ( cd d && %s -q x f )\n' "$p" "$g"                  # 145 flag
        command printf 'producer %s &>/dev/null %s -q foo\n' "$p" "$g"                  # 146 flag
        command printf 'producer %s\n' "$p"                                             # 147
        command printf '    { read -r h; %s -q x f; }\n' "$g"                           # 148 flag
        command printf 'producer %s { # )\n' "$p"                                       # 149
        command printf '    read -r h; %s -q x f; }\n' "$g"                             # 150 flag
    } >"$dir/fixture.sh"
    got=$(pipe_grep_q_sites "$dir" | command tr '\n' ' ')
    command rm -rf "$dir"
    assert_equals "fixture.sh:1 fixture.sh:2 fixture.sh:3 fixture.sh:4 fixture.sh:6 fixture.sh:12 fixture.sh:13 fixture.sh:14 fixture.sh:16 fixture.sh:17 fixture.sh:19 fixture.sh:27 fixture.sh:29 fixture.sh:30 fixture.sh:31 fixture.sh:32 fixture.sh:36 fixture.sh:38 fixture.sh:42 fixture.sh:44 fixture.sh:48 fixture.sh:50 fixture.sh:51 fixture.sh:53 fixture.sh:55 fixture.sh:59 fixture.sh:60 fixture.sh:64 fixture.sh:66 fixture.sh:68 fixture.sh:70 fixture.sh:71 fixture.sh:73 fixture.sh:75 fixture.sh:77 fixture.sh:79 fixture.sh:81 fixture.sh:84 fixture.sh:87 fixture.sh:91 fixture.sh:93 fixture.sh:95 fixture.sh:96 fixture.sh:97 fixture.sh:98 fixture.sh:99 fixture.sh:100 fixture.sh:101 fixture.sh:103 fixture.sh:109 fixture.sh:110 fixture.sh:113 fixture.sh:116 fixture.sh:117 fixture.sh:118 fixture.sh:120 fixture.sh:124 fixture.sh:125 fixture.sh:126 fixture.sh:127 fixture.sh:128 fixture.sh:129 fixture.sh:130 fixture.sh:132 fixture.sh:133 fixture.sh:135 fixture.sh:136 fixture.sh:137 fixture.sh:138 fixture.sh:141 fixture.sh:144 fixture.sh:145 fixture.sh:146 fixture.sh:148 fixture.sh:150 " "$got" \
        "scanner flags same-line, |&, prefixed (incl. command + path, any leading words: env assignments however quoted or substituted, +=, env, !, time; and { or ( group openers, alone, nested, combined, after |&, or on their own line, even with a comment, before the consumer), --quiet, value-flag, egrep/fgrep, mid-word # (incl. across a \\ join and after \$(...)), a comment ending in \\ after a quoted or escaped #, a site after a quote closed on a later line (incl. across a \\ join, and a pipe plus comment closing it, double or single), and line-continued (incl. |\\, | \\, a leading | after \\, a \\ inside the flags, a trailing |&, a comment (even one ending in \\, or touching | or |&) after the pipe, an escaped quote before it, blank and comment lines before the consumer, a consumer that pipes on) pipes into $g -q; over-reports a word-start # after a \\ join, a quoted trailing |#, and a $g -q run by another command (xargs) (the documented cost); flags a ; or & a prefix word quotes, substitutes or redirects (A=\"x;y\", A=\$(a; b), 2>&1, &>f), and a $g -q at any command inside a piped { } or ( ) group (incl. one opened on an earlier line or after a pipe that ends one, past a quoted brace, and past a ) in a comment); ignores a $g -q after a piped group closes, one in an unpiped group, ||, || \\, || # c, a pipe-less trailing \\, an even \\\\ run, a \\ inside a comment, a # after an escaped space, an escaped space after |, comments, herestrings, quoted -q, a later command's -q (incl. after a group or an assignment-prefixed command), a {grep word that opens no group, a grep after a word-start # comment, and non-q greps (incl. egrep/fgrep, and inside a group)"
}

# ---------------------------------------------------------------------------
# Test: no state carries from one file into the next
#
# find -exec ... {} + hands many files to one awk, so a pending pipe or an open
# continuation at one file's end must not reach the next file's first line.
# Each pair of files is identical, so the check holds whatever order find
# picks. A single-file fixture cannot see either leak.
# ---------------------------------------------------------------------------
test_scanner_isolates_files() {
    local dir got p g b
    p='|'
    g='grep'
    b='\'
    dir=$(command mktemp -d)
    for f in a b; do
        command printf '    command %s -q foo\nproducer %s\n' "$g" "$p" >"$dir/$f.sh"
    done
    got=$(pipe_grep_q_sites "$dir")
    command rm -rf "$dir"
    assert_equals "" "$got" "a trailing pipe at one file's end does not pend into the next file"

    dir=$(command mktemp -d)
    for f in a b; do
        command printf '    -q foo\nproducer %s command %s %s\n' "$p" "$g" "$b" >"$dir/$f.sh"
    done
    got=$(pipe_grep_q_sites "$dir")
    command rm -rf "$dir"
    assert_equals "" "$got" "a continuation at one file's end does not join the next file's first line"

    dir=$(command mktemp -d)
    for f in a b; do
        command printf 'echo; command %s -q foo\nproducer %s {\n' "$g" "$p" >"$dir/$f.sh"
    done
    got=$(pipe_grep_q_sites "$dir")
    command rm -rf "$dir"
    assert_equals "" "$got" "a piped group open at one file's end does not reach into the next file"
}

# ---------------------------------------------------------------------------
# Test: a site still continued at end of file is reported
#
# Bash runs a final line that ends in a continuation backslash. Alone in the
# scan, the file's last logical line reaches only the END flush.
# ---------------------------------------------------------------------------
test_scanner_flushes_at_eof() {
    local dir got
    dir=$(command mktemp -d)
    command printf 'producer %s command %s -q foo %s\n' '|' 'grep' '\' >"$dir/eof.sh"
    got=$(pipe_grep_q_sites "$dir")
    command rm -rf "$dir"
    assert_equals "eof.sh:1" "$got" "scanner reports a site whose line is still continued at end of file"
}

# ---------------------------------------------------------------------------
# Test: the scanner descends into subdirectories
#
# Most of tests/unit lives in subdirectories (base/, bin/, features/, ...). The
# shapes test above uses a flat fixture, so it cannot catch a traversal change
# (a -maxdepth, a narrowed -name) that would leave those trees unscanned.
# ---------------------------------------------------------------------------
test_scanner_descends_into_subdirs() {
    local dir got
    dir=$(command mktemp -d)
    command mkdir -p "$dir/sub/deeper"
    command printf 'producer %s command %s -q foo\n' '|' 'grep' >"$dir/sub/deeper/nested.sh"
    got=$(pipe_grep_q_sites "$dir")
    command rm -rf "$dir"
    assert_equals "sub/deeper/nested.sh:1" "$got" \
        "scanner reports a site two directories below the scan root"
}

# ---------------------------------------------------------------------------
# Test: no pipe into grep -q anywhere under tests/unit
# ---------------------------------------------------------------------------
test_no_sites_in_tests_unit() {
    local site bad=""

    # The scanner swallows its own failures (`|| true`), so a bad UNIT_DIR or a
    # failed cd would yield an empty list that reads as a clean tree. Prove the
    # scan root is the real tree first: this suite must be inside it.
    if [ ! -f "$UNIT_DIR/grep-q-pipefail-guard.sh" ]; then
        tf_fail_assertion \
            "Scan root does not contain this suite: $UNIT_DIR" \
            "A clean result from it would be vacuous."
        return 1
    fi

    while IFS= read -r site; do
        [ -n "$site" ] || continue
        bad+="  tests/unit/$site"$'\n'
    done < <(pipe_grep_q_sites "$UNIT_DIR")

    if [ -n "$bad" ]; then
        tf_fail_assertion \
            "Pipe into grep -q under tests/unit (SIGPIPE race under pipefail, #1092):" \
            "$bad" \
            "Capture, then match via a herestring:" \
            "  command grep -q 'P' <<<\"\$x\"" \
            "  body=\$(producer || true); command grep -q 'P' <<<\"\$body\""
        return 1
    fi
    return 0
}

run_test "test_scanner_detects_known_shapes" "Scanner flags each pipe-into-grep-q shape and nothing else"
run_test "test_scanner_isolates_files" "Scanner carries no pipe or continuation across files"
run_test "test_scanner_flushes_at_eof" "Scanner reports a site continued at end of file"
run_test "test_scanner_descends_into_subdirs" "Scanner reports sites in nested subdirectories"
run_test "test_no_sites_in_tests_unit" "No pipe into grep -q anywhere under tests/unit"

# Generate report
generate_report
