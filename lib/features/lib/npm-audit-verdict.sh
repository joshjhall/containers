#!/bin/bash
# npm-audit-verdict.sh — classify `npm audit signatures --json` output
#
# Shared by every build-time npm install that verifies the registry signature
# before installing: agnix (dev-tools, #814) and corepack (node, #985). One
# classifier, so a fix to the parsing reaches both sites and the tests call
# the shipped code rather than a copy of it.
#
# Usage:
#   source /tmp/build-scripts/features/lib/npm-audit-verdict.sh
#   verdict=$(npm_audit_verdict "$audit_stdout")          # agnix
#   verdict=$(npm_audit_verdict "$audit_stdout" strict)   # corepack
#
# Requirements:
#   - jq (installed by lib/base/setup.sh)

# npm_audit_verdict — classify `npm audit signatures --json` stdout.
#
# Echoes exactly one of: fatal | install | skip | unsigned
#   fatal   — the audit RAN and reported a signature mismatch (populated
#             invalid[]). The tarball is not what its publisher signed.
#   install — the audit ran and found nothing invalid (in strict mode: and
#             nothing missing either).
#   unsigned — strict mode only: the audit ran, nothing invalid, but missing[]
#             is non-empty or not an array — the registry served the package
#             with NO signature, so there was nothing to verify. Decided on the
#             same selected body as the other verdicts, so prose around the JSON
#             cannot turn a clean audit into a refusal (#985 review).
#   skip    — the audit could not be read (outage, nothing auditable,
#             unparsable output). UNVERIFIABLE, which is not the same as
#             tampering and must never be reported as such.
#
# A standalone function so the tests can call THIS code rather than a
# hand-copied mirror of it (#817).
#
# The selection rule is SHAPE, and the value is bounded at BOTH ends by jq
# itself. Four narrower rules each shipped a fail-open where a real mismatch
# read as a benign skip, every one of them a guess about text nobody controls:
#   1. anchor on `^{`         -> broke on prose sharing the line with the brace
#   2. anchor on any `{`      -> broke on a brace inside the prose
#   3. first value that PARSES -> broke on a stray VALID value (a lone `{}`),
#                                 which has no invalid[] and so reads as skip
#   4. shape-select over a brace-to-EOF span -> broke on anything TRAILING the
#                                 body, because the span carried the junk too
# The lesson each time was the same: do not guess where the value starts or
# stops. jq is the only thing that actually knows, so it decides both ends
# (see `jq -c .` below), and shape decides which of the values it found is the
# audit result.
#
# `-s` slurps every top-level value, which also removes a trap found while
# fixing this: jq streams multiple values, so a two-value stdout produced TWO
# verdict lines and the captured "skip\nfatal" matched neither branch and fell
# through to skip — a real mismatch, silently downgraded. Slurping makes that
# impossible by construction. Of the audit-shaped values the LAST wins: npm's
# real result terminates stdout.
npm_audit_verdict() {
    local raw="$1" mode="${2:-}" verdict brace_line candidate
    local strict=false
    [ "$mode" = "strict" ] && strict=true
    local filter='
        map(select(type == "object"
            and ((.invalid | type) == "array"
                 or (.error | type) == "object")))
        | if length == 0 then "skip"
          else (last
            | if (.invalid | type) != "array" then "skip"
              elif (.invalid | length) > 0 then "fatal"
              elif $strict and ((.missing | type) != "array"
                                or (.missing | length) > 0) then "unsigned"
              else "install" end)
          end'

    # Empty is decided here: jq exits 0 printing nothing for empty input, so it
    # cannot report this case itself.
    if [ -z "$raw" ]; then
        command echo "skip"
        return 0
    fi

    # Pass 1 — the whole stdout. The normal case (stdout is pure JSON) and the
    # multi-value case both resolve here.
    #
    # `jq -c .` is what bounds the END of the value, and it is the piece four
    # earlier attempts were missing. jq consumes values greedily, EMITS each one
    # it parsed on stdout, and reports only the unparsable remainder on stderr.
    # Discarding stderr therefore yields exactly the values jq could read, no
    # matter what trails them — so a `npm notice ...` line after the body no
    # longer poisons the whole parse. Feeding a span from a brace to
    # end-of-input to `jq -s` directly is all-or-nothing and was the actual bug:
    # every candidate carried the trailing junk along with the body.
    verdict=$(command printf '%s' "$raw" | command jq -c . 2>/dev/null |
        command jq -s -r --argjson strict "$strict" "$filter" 2>/dev/null || true)
    case "$verdict" in
        fatal | install | unsigned)
            command echo "$verdict"
            return 0
            ;;
    esac

    # Pass 2 — prose may PRECEDE the JSON, which stops jq before it reads
    # anything, so pass 1 yields nothing at all. Retry from each brace with any
    # same-line prose ahead of it removed; the `jq -c .` stage still bounds the
    # far end. Only a real verdict ends the search; a "skip" keeps looking, so
    # an unreadable candidate cannot terminate it early.
    for brace_line in $(command printf '%s' "$raw" | command grep -n '{' | command cut -d: -f1); do
        candidate=$(command printf '%s' "$raw" |
            command tail -n "+${brace_line}" | command sed '1s/^[^{]*//')
        verdict=$(command printf '%s' "$candidate" | command jq -c . 2>/dev/null |
            command jq -s -r --argjson strict "$strict" "$filter" 2>/dev/null || true)
        case "$verdict" in
            fatal | install | unsigned)
                command echo "$verdict"
                return 0
                ;;
        esac
    done

    command echo "skip"
}
