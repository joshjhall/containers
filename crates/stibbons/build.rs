//! Build script: inject the product version into the stibbons binary.
//!
//! Replaces the Go `ldflags` version stamping used by the legacy igor binary.
//! The single source of truth is the repo-root `VERSION` file (also consumed
//! by `bin/release.sh` and the Dockerfile). We resolve it by walking up from
//! this crate's manifest directory so the lookup works from any build cwd,
//! including the release cross-compile legs in `release-binaries.yml`.
//!
//! Emits `STIBBONS_VERSION` for `env!()` use in `main.rs`. If the `VERSION`
//! file cannot be found (e.g. an isolated crate checkout published to a
//! registry), we fall back to the crate's own `CARGO_PKG_VERSION` so the build
//! still succeeds.

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rustc-env=STIBBONS_VERSION={}", resolve_version());
}

/// Resolve the product version to stamp into the binary.
///
/// Prefers the repo-root `VERSION` file; falls back to the crate's own
/// `CARGO_PKG_VERSION` for standalone (registry-style) builds.
fn resolve_version() -> String {
    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is always set by cargo");

    if let Some(path) = find_version_file(Path::new(&manifest_dir)) {
        // Re-run the build script when the VERSION file changes so the stamped
        // version stays in sync without a manual clean.
        println!("cargo:rerun-if-changed={}", path.display());
        return std::fs::read_to_string(&path)
            .expect("VERSION file located but unreadable")
            .trim()
            .to_string();
    }

    std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION is always set by cargo")
}

/// Walk up from `start` looking for a `VERSION` file at the repo root.
fn find_version_file(start: &Path) -> Option<PathBuf> {
    for dir in start.ancestors() {
        let candidate = dir.join("VERSION");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}
