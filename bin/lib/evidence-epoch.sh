#!/usr/bin/env bash
# The one parse of an evidence row's tested_at into epoch seconds (#1355).
#
# Shared by bin/lib/evidence-matrix.sh (the fail cooldown) and
# bin/lib/evidence-merge.sh (whether a repeated failure is newer). Both must
# order rows the same way, so the def lives here once instead of as two
# copies that only their own callers exercise.
#
# _EVIDENCE_EPOCH_JQ defines `evidence_epoch`: applied to a row, it yields
# epoch seconds for `.tested_at`, or 0 when that is missing or unparsable — a
# stale timestamp, never a recent one, so an unreadable age cannot hide a
# failure forever. Accepted forms (#1349): a calendar-valid
# YYYY-MM-DDTHH:MM:SS with optional fractional seconds, then `Z` or a
# `+HH:MM`/`-HH:MM` offset within -12:00..+14:00. fromdateiso8601 takes only
# whole-second `Z`, so the fraction is dropped, the base parsed as UTC, and
# the offset subtracted. libc normalizes a date like Feb 30 into March, so the
# base must also round-trip through todate unchanged.
#
# Callers order rows with `evidence_epoch_at($now)` instead (#1356): the same
# parse, but a stamp more than 300 s (clock-skew allowance) after $now also
# reads as 0. A future tested_at would otherwise win every `max` / "is it
# newer" comparison: it would hold a failing cell out of the matrix until the
# date passes, and make every genuine repeat failure an ingest no-op. Reading
# it as stale (not clamping to $now) lets the next real attempt replace it.
#
# Prepend it to a jq program: command jq "$_EVIDENCE_EPOCH_JQ"'...'
#
# Requires jq.

_EVIDENCE_EPOCH_JQ='
def evidence_epoch: ((.tested_at // "" | capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
    | select(.z == "Z" or ((.m | tonumber) < 60 and (.h | tonumber) * 60 + (.m | tonumber) <= (if .s == "+" then 840 else 720 end)))
    | ((.b + "Z") as $u | $u | fromdateiso8601 | select(todate == $u))
      - (if .z == "Z" then 0 else (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end))? // 0);
def evidence_epoch_at($now): evidence_epoch | if . > $now + 300 then 0 else . end;
'
