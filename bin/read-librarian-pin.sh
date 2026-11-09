#!/usr/bin/env bash
# read-librarian-pin.sh — print the Dockerfile's librarian pin, fail-closed.
#
# Usage: bin/read-librarian-pin.sh [DOCKERFILE]   (default: ./Dockerfile)
#
# CI checks librarian out at the Dockerfile's `ARG LIBRARIAN_REF=` so its gates
# run the SAME librarian the dev image ships. Two ci.yml steps read that pin;
# both call this script so the rule lives in one place (#1555).
#
# Exactly one `ARG LIBRARIAN_REF=` line must exist. A bare `sed -n … | grep -q`
# accepted a Dockerfile with two such lines — `grep -q` passes if ANY line
# matches — and wrote a multi-line `ref=` into $GITHUB_OUTPUT. The value must
# also be a vX.Y.Z release tag (CLAUDE.md: LIBRARIAN_REF is a signed tag)
# before it reaches a checkout `ref:`.
#
# Supported form: one `ARG LIBRARIAN_REF=<tag>` per instruction, on one line
# (any case, any indent). A multi-key `ARG A=1 LIBRARIAN_REF=...` or a
# backslash-continued ARG that sets LIBRARIAN_REF is REJECTED (#1580): it is
# still a pin to Docker, so skipping it would let a second pin hide from the
# count. Fail closed and ask for the single-key form instead.
#
# Prints the ref on stdout and exits 0; prints a `::error::` line and exits 1
# otherwise.
set -euo pipefail

dockerfile="${1:-Dockerfile}"

if [ ! -r "$dockerfile" ]; then
    printf '::error::cannot read %s\n' "$dockerfile" >&2
    exit 1
fi

# Classify every ARG instruction that sets LIBRARIAN_REF. awk joins
# backslash continuations into logical instructions (as Docker does, dropping
# comment lines), so an `ENV ... LIBRARIAN_REF=${LIBRARIAN_REF} \` continuation
# line is seen as part of its ENV, not mistaken for an ARG. For each ARG:
#   PIN<TAB><value>  single-key, single-line `ARG LIBRARIAN_REF=<value>`
#                    (any case, any indent; the value is kept verbatim so
#                    trailing junk still fails the shape check below)
#   BAD<TAB><line>   LIBRARIAN_REF= set any other way (multi-key in either
#                    key order, or continued)
#   ESC<TAB><line>   an `# escape=` parser directive naming a character other
#                    than `\`: it changes the continuation character, so the
#                    joins above would no longer match Docker's. Fail closed.
# A bare `ARG LIBRARIAN_REF` (re-declaration, no `=`) sets no value and emits
# nothing. awk's END flush keeps an unterminated last line.
classify_args() {
    command awk -v directives=1 '
        function flush(   t, w, v) {
            if (!open) return
            open = 0
            t = inst
            sub(/^[[:space:]]+/, "", t)
            split(t, w, /[[:space:]]+/)
            if (toupper(w[1]) != "ARG") return
            if (nlines == 1 && match(first, /^[[:space:]]*[Aa][Rr][Gg][[:space:]]+LIBRARIAN_REF=/)) {
                v = substr(first, RLENGTH + 1)
                # `ARG LIBRARIAN_REF=v1.2.3 FOO=1`: a second key after the
                # pin. Bare trailing whitespace stays a PIN so it fails the
                # shape check with the value quoted.
                if (v ~ /[[:space:]]+[^[:space:]]/) print "BAD\t" start
                else print "PIN\t" v
            } else if (inst ~ /(^|[[:space:]])LIBRARIAN_REF=/) {
                print "BAD\t" start
            }
        }
        # Parser directives (`# key=value`) are only read before the first
        # comment, blank line or instruction.
        directives && /^#[[:space:]]*[A-Za-z]+[[:space:]]*=/ {
            d = $0
            sub(/^#[[:space:]]*/, "", d)
            split(d, kv, /[[:space:]]*=[[:space:]]*/)
            if (tolower(kv[1]) == "escape" && kv[2] !~ /^\\[[:space:]]*$/) print "ESC\t" NR
            next
        }
        { directives = 0 }
        # Docker skips comment and empty lines, even inside a continuation.
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            if (!open) {
                open = 1; start = NR; first = line; nlines = 0; inst = ""
            }
            nlines++
            if (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                inst = inst line " "
                next
            }
            inst = inst line
            flush()
        }
        END { flush() }
    ' "$1"
}

# A read loop rather than `mapfile` keeps this working on bash 3.2 (macOS).
# `|| [ -n "$line" ]` keeps a final line with no trailing newline.
refs=()
bad=()
esc=()
tab=$'\t'
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        "PIN$tab"*) refs+=("$(command printf '%s' "${line#PIN"$tab"}" | command tr -d '"')") ;;
        "BAD$tab"*) bad+=("${line#BAD"$tab"}") ;;
        "ESC$tab"*) esc+=("${line#ESC"$tab"}") ;;
    esac
done < <(classify_args "$dockerfile")

if [ "${#esc[@]}" -gt 0 ]; then
    printf "::error::unsupported '# escape=' parser directive in %s at line %s; only the default backslash escape is supported\n" \
        "$dockerfile" "${esc[*]}" >&2
    exit 1
fi

if [ "${#bad[@]}" -gt 0 ]; then
    printf "::error::unsupported ARG form for LIBRARIAN_REF in %s at line %s (multi-key or backslash-continued); use a single-key 'ARG LIBRARIAN_REF=vX.Y.Z' line\n" \
        "$dockerfile" "${bad[*]}" >&2
    exit 1
fi

count=${#refs[@]}
if [ "$count" -ne 1 ]; then
    printf '::error::expected exactly one ARG LIBRARIAN_REF line in %s, found %d\n' \
        "$dockerfile" "$count" >&2
    exit 1
fi

ref="${refs[0]}"
if ! [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "::error::ARG LIBRARIAN_REF in %s is not a vX.Y.Z tag: '%s'\n" \
        "$dockerfile" "$ref" >&2
    exit 1
fi

printf '%s\n' "$ref"
