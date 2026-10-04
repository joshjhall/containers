#!/bin/bash
# Rust toolchain pin sync for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on its sed_inplace() (dry-run aware) and
#   PROJECT_ROOT, both resolved at call time.

# sync_rust_minor_pins - Rewrite every X.Y-granularity Rust toolchain pin.
#
# Arguments:
#   $1 - full Rust version (X.Y.Z); only its X.Y prefix is written
#
# Description:
#   tests/unit/rust-version-sync.sh requires these to equal the Dockerfile
#   RUST_VERSION's X.Y: the luggage-builder base image tag, Cargo.toml
#   rust-version (MSRV), clippy.toml msrv, and every explicit CI
#   `toolchain: "X.Y"` pin. A patch bump leaves them unchanged (same X.Y).
#   Writes go through sed_inplace, so a dry run touches nothing.
sync_rust_minor_pins() {
    local minor
    minor="$(printf '%s' "$1" | command grep -oE '^[0-9]+\.[0-9]+')"
    [ -n "$minor" ] || return 1

    sed_inplace "s/^FROM rust:[0-9][0-9.]*-/FROM rust:$minor-/" "$PROJECT_ROOT/Dockerfile" || return 1
    if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
        sed_inplace "s/^rust-version = \"[0-9][^\"]*\"/rust-version = \"$minor\"/" "$PROJECT_ROOT/Cargo.toml" || return 1
    fi
    if [ -f "$PROJECT_ROOT/clippy.toml" ]; then
        sed_inplace "s/^msrv = \"[0-9][^\"]*\"/msrv = \"$minor\"/" "$PROJECT_ROOT/clippy.toml" || return 1
    fi

    local wf
    for wf in "$PROJECT_ROOT"/.github/workflows/*.yml "$PROJECT_ROOT"/.github/workflows/*.yaml; do
        [ -f "$wf" ] || continue
        command grep -qE '^[[:space:]]*toolchain: *"?[0-9]+\.[0-9]+' "$wf" || continue
        sed_inplace "s/^\([[:space:]]*toolchain: *\"\{0,1\}\)[0-9][0-9]*\.[0-9][0-9]*/\1$minor/" "$wf" || return 1
    done
}
