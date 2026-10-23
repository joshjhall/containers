#!/usr/bin/env bash
# Merge one evidence row into a containers-db version file's tested[] array.
#
# Shared by bin/ingest-evidence.sh (one row, manual) and
# bin/ingest-evidence-batch.sh (every row of a run, one PR), so the dedup
# policy has exactly one implementation.
#
# Policy (docs/operations/evidence-runs.md, Merge policy): rows with the same
# (os, os_version, arch, image_digest) are replaced by the new row; everything
# else is preserved. If an existing row matches that dedup key AND is
# identical on every non-volatile field, the new row carries no fresh signal
# (same content-addressed image, same result), only a newer timestamp, so the
# file is left untouched. Volatile fields: tested_at, ci_run, duration_seconds.
#
# Except for a `fail` row (#1326): its tested_at is the last attempt, which the
# evidence matrix's fail cooldown reads. A no-op there would freeze the first
# failure's timestamp, so after one cooldown a persistent failure would be
# retried on every push. A repeated failure with a newer tested_at therefore
# refreshes the row in place (row order kept). One that is not newer (a
# byte-identical re-run, or an older saved row) is still a no-op, so tested_at
# never moves backwards.
#
# Requires jq.

# Repeated-failure ordering uses the same tested_at parse as the evidence
# matrix's fail cooldown.
# shellcheck source=bin/lib/evidence-epoch.sh
source "$(dirname "${BASH_SOURCE[0]}")/evidence-epoch.sh"

# merge_evidence_row <version-file> <row-json>
#
# Rewrites <version-file> in place (trailing newline kept). Byte-stable for
# identical inputs, so callers detect a no-op with `git diff --quiet`.
# Returns 2 when the row is not valid JSON or lacks os/arch/result.
merge_evidence_row() {
    local file="$1" row="$2" tmp
    command jq -e . >/dev/null 2>&1 <<<"$row" || {
        command echo "merge_evidence_row: row is not valid JSON" >&2
        return 2
    }
    local os ov arch digest result
    os="$(command jq -r '.os // ""' <<<"$row")"
    ov="$(command jq -r '.os_version // ""' <<<"$row")"
    arch="$(command jq -r '.arch // ""' <<<"$row")"
    digest="$(command jq -r '.image_digest // ""' <<<"$row")"
    result="$(command jq -r '.result // ""' <<<"$row")"
    if [ -z "$os" ] || [ -z "$arch" ] || [ -z "$result" ]; then
        command echo "merge_evidence_row: row missing required .os/.arch/.result" >&2
        return 2
    fi

    tmp="$(command mktemp)" || return 1
    if ! command jq \
        --argjson new "$row" \
        --arg os "$os" \
        --arg ov "$ov" \
        --arg arch "$arch" \
        --arg digest "$digest" \
        "$_EVIDENCE_EPOCH_JQ"'
        def dedup_match:
            (.os // "") == $os
            and (.os_version // "") == $ov
            and (.arch // "") == $arch
            and (.image_digest // "") == $digest;
        def strip_volatile: del(.tested_at, .ci_run, .duration_seconds);
        ($new | strip_volatile) as $new_core
        | (.tested // []) as $rows
        | ($rows | map(select(dedup_match))) as $matches
        | if ($matches | any(strip_volatile == $new_core)) | not then
              .tested = (($rows | map(select(dedup_match | not))) + [$new])
          elif $new.result != "fail" then .
          # an older repeated failure (a saved row re-ingested late) must not
          # move tested_at backwards and cut the cooldown short
          elif ($new | evidence_epoch) <= ([ $matches[] | select(strip_volatile == $new_core) | evidence_epoch ] | max)
          then .
          # a newer repeated failure refreshes its row in place, keeping row
          # order, so only tested_at/ci_run/duration_seconds show up in the diff
          else .tested = (reduce $rows[] as $r ({out: [], done: false};
                   if ($r | dedup_match) then
                       (if .done then . else .out += [$new] | .done = true end)
                   else .out += [$r] end) | .out)
          end
        ' "$file" >"$tmp"; then
        command rm -f "$tmp"
        return 1
    fi
    command cp "$tmp" "$file"
    command echo "" >>"$file"
    command rm -f "$tmp"
}

# evidence_tuple_slug <row-json> — `os-os_version-arch` (or `os-arch`).
evidence_tuple_slug() {
    command jq -r 'if (.os_version // "") != "" then "\(.os)-\(.os_version)-\(.arch)" else "\(.os)-\(.arch)" end' <<<"$1"
}
