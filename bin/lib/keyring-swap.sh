#!/usr/bin/env bash
# Keyring validate + atomic stage/validate/swap transaction (#1426).
#
# Extracted from update_nodejs_keys in bin/update-gpg-keys.sh, which sources
# it. A keyring is replaced only by a staged copy that gpg has read cleanly,
# and the swap is a rename, so no failure or interrupt can leave the
# destination empty, half-written, or replaced by an unreadable keyring
# (#1410, #1436).
#
# Requires the caller to define log_error. Requires gpg, cmp, mktemp.
# Sets no shell options: a sourced lib's `set -e` leaks into its caller.
# Callers run these with set -e suspended, so every failure is checked
# explicitly.

# ============================================================================
# count_keyring_keys - Print the number of public keys in a keyring directory
#
# Reads a scratch copy so gpg never writes into the source directory, and
# fails (return 1) when gpg exits non-zero or lists no keys. gpg can print
# most of a keyring's keys before failing on a damaged record, so the exit
# status must be checked, not just the `pub` count (#1410).
# ============================================================================
#
# Optional $2: parent directory for the scratch copy, so a caller's interrupt
# trap that removes that directory also removes the scratch.
count_keyring_keys() {
    local src_dir="$1"
    local scratch_parent="${2:-${TMPDIR:-/tmp}}"
    local scratch output count
    # Every caller runs this with set -e suspended, so check mktemp explicitly:
    # an empty $scratch would turn `chmod 600 "$scratch"/*` into `chmod 600 /*`
    if ! scratch=$(mktemp -d "$scratch_parent/keyring-check.XXXXXX") || [ ! -d "$scratch" ]; then
        log_error "Could not create a scratch directory under $scratch_parent"
        return 1
    fi
    cp "$src_dir"/pubring.kbx "$scratch"/ || {
        rm -rf "$scratch"
        return 1
    }
    [ -f "$src_dir/trustdb.gpg" ] && cp "$src_dir/trustdb.gpg" "$scratch"/
    chmod 700 "$scratch"
    chmod 600 "$scratch"/*

    if ! output=$(GNUPGHOME="$scratch" gpg --batch --list-keys 2>&1); then
        rm -rf "$scratch"
        log_error "gpg cannot read keyring in $src_dir:"
        printf '%s\n' "$output" | command grep '^gpg:' >&2 || true
        return 1
    fi
    rm -rf "$scratch"

    count=$(printf '%s\n' "$output" | command grep -c '^pub' || true)
    if [ "${count:-0}" -eq 0 ]; then
        log_error "Keyring in $src_dir contains no public keys"
        return 1
    fi
    echo "$count"
}

# ============================================================================
# swap_keyring_atomic <src_dir> <dest_dir> <work_dir> <label>
#
# Replace the keyring at <dest_dir> with the one in <src_dir> (pubring.kbx,
# plus trustdb.gpg only when <src_dir> ships one, so the result mirrors the
# source exactly). The copy is staged beside <dest_dir> (same filesystem, so
# the swap is a rename) and validated there; <dest_dir> is not touched until
# the staged copy has passed. <label> names the keyring in error messages.
#
# <work_dir> is the caller's temp dir: the staged check's scratch goes under
# it, and an interrupt removes it along with the staging and holder dirs.
# On a non-interrupt failure <work_dir> is left for the caller to clean up.
#
# Replaces any INT/TERM traps for its duration and clears them on return. On
# INT/TERM it restores a moved-aside keyring and exits 130/143.
# Returns 0 once the new keyring is in place, 1 on any failure (the existing
# keyring kept or restored, or a stranded path reported).
# ============================================================================
swap_keyring_atomic() {
    local src_dir="$1" keyring_dir="$2" work_dir="$3" label="$4"

    mkdir -p "$(dirname "$keyring_dir")"
    local staging="" previous_dir="" previous=""
    # On interrupt: drop the staging dir and the work dir; if the swap below
    # had moved the existing keyring aside, put it back, otherwise drop the
    # moved-aside copy so nothing stray is left beside the keyring.
    # The holder dir is kept only when a restore fails, since it then holds
    # the sole copy of the previous keyring.
    # Installed BEFORE either mktemp so no interrupt can strand an empty
    # keyring.new.*/keyring.old.* dir (#1443). The paths do not exist yet, so
    # the trap reads these locals when it fires (every return clears it, so
    # it only fires in this scope) and skips any still empty. Bash defers a
    # signal that arrives inside a mktemp command substitution until the
    # assignment lands, so a created dir is always visible to the trap.
    local on_interrupt='[ -n "$staging" ] && rm -rf "$staging"
        if [ -n "$previous_dir" ]; then
            if [ -d "$keyring_dir" ]; then rm -rf "$previous_dir"
            elif [ -n "$previous" ] && [ -d "$previous" ]; then mv "$previous" "$keyring_dir" && rm -rf "$previous_dir"
            else rm -rf "$previous_dir"; fi
        fi
        rm -rf "$work_dir"'
    # Separate traps so the exit status names the signal (128+2 / 128+15)
    # shellcheck disable=SC2064 # embed the body now; its variables expand at fire time
    trap "$on_interrupt; exit 130" INT
    # shellcheck disable=SC2064 # embed the body now; its variables expand at fire time
    trap "$on_interrupt; exit 143" TERM

    if ! staging=$(mktemp -d "${keyring_dir}.new.XXXXXX") || [ ! -d "$staging" ]; then
        log_error "Could not create a staging directory beside $keyring_dir — keeping existing keyring"
        trap - INT TERM
        return 1
    fi
    # The existing keyring is moved aside into a fresh, empty holder dir rather
    # than to a fixed name: a leftover keyring.old.<pid> from a SIGKILLed run
    # would make the move-aside a move INTO it, and a restore would then
    # install the stale copy (#1436). Inside a new mktemp dir the target
    # cannot already exist, so the move-aside is always a rename.
    if ! previous_dir=$(mktemp -d "${keyring_dir}.old.XXXXXX") || [ ! -d "$previous_dir" ]; then
        log_error "Could not create a directory to move the existing keyring aside — keeping existing keyring"
        trap - INT TERM
        rm -rf "$staging"
        return 1
    fi
    previous="$previous_dir/keyring"

    # trustdb.gpg is optional (count_keyring_keys treats it the same way)
    local keyring_files=(pubring.kbx)
    [ -f "$src_dir/trustdb.gpg" ] && keyring_files+=(trustdb.gpg)
    local f staged_ok=true
    for f in "${keyring_files[@]}"; do
        if ! cp "$src_dir/$f" "$staging/" || ! cmp -s "$src_dir/$f" "$staging/$f"; then
            staged_ok=false
        fi
    done
    if ! chmod 700 "$staging" || ! chmod 600 "$staging"/*; then
        staged_ok=false
    fi
    # Scratch under $work_dir, so the interrupt trap's cleanup covers it
    if [ "$staged_ok" = true ] && ! count_keyring_keys "$staging" "$work_dir" >/dev/null; then
        staged_ok=false
    fi
    if [ "$staged_ok" != true ]; then
        log_error "Staged $label keyring does not match upstream or is unreadable — keeping existing keyring"
        trap - INT TERM
        rm -rf "$staging" "$previous_dir"
        return 1
    fi

    # Swap the validated keyring into place
    if [ -d "$keyring_dir" ] && ! mv "$keyring_dir" "$previous"; then
        log_error "Could not move the existing keyring aside — keeping it"
        trap - INT TERM
        rm -rf "$staging" "$previous_dir"
        return 1
    fi
    if ! mv "$staging" "$keyring_dir"; then
        log_error "Could not install the new keyring — restoring the existing one"
        if [ -d "$previous" ] && ! mv "$previous" "$keyring_dir"; then
            log_error "Restore failed — the previous keyring is at $previous; move it back to $keyring_dir by hand"
        else
            rm -rf "$previous_dir"
        fi
        trap - INT TERM
        rm -rf "$staging"
        return 1
    fi
    # Clear the moved-aside copy BEFORE dropping the trap, so an interrupt
    # here still removes it rather than leaving it beside the keyring
    rm -rf "$previous_dir"
    trap - INT TERM
    return 0
}
