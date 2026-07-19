// Version-resolution logic for the stibbons build script.
//
// Extracted from `build.rs` into a standalone file so it can be exercised by a
// unit test (`tests/build_version.rs`) as well as `include!`d by the build
// script — a build script is not itself compiled as a test target, so the
// logic has to live somewhere a normal test can reach it. Both includers share
// this single source; there is no separate crate or public API surface.
//
// NOTE: this file is `include!`d, not compiled as its own module, so it must
// use regular `//` comments (not inner `//!` doc comments, which are only legal
// at the top of a module/file).

use std::path::{Path, PathBuf};

/// Resolve the product version to stamp into the binary.
///
/// Prefers the repo-root `VERSION` file (walking up from `manifest_dir`); falls
/// back to `pkg_version` (the crate's own `CARGO_PKG_VERSION`) for standalone
/// (registry-style) builds where no `VERSION` file is present.
///
/// `emit_rerun` receives the located `VERSION` path so the caller can print a
/// `cargo:rerun-if-changed` line; it is a no-op for tests.
fn resolve_version_from(
    manifest_dir: &str,
    pkg_version: &str,
    emit_rerun: &mut dyn FnMut(&Path),
) -> String {
    if let Some(path) = find_version_file(Path::new(manifest_dir)) {
        emit_rerun(&path);
        return std::fs::read_to_string(&path)
            .expect("VERSION file located but unreadable")
            .trim()
            .to_string();
    }

    pkg_version.to_string()
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
