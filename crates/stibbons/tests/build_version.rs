//! Unit tests for the build script's version-resolution logic (#697).
//!
//! `build.rs` is not compiled as a test target, so its version logic was
//! extracted into `../build_version.rs` and is `include!`d here as well. These
//! tests exercise it directly against temp directory trees — no build run
//! needed.

// Pull in the same source the build script uses. The included file provides
// `find_version_file` and `resolve_version_from` plus its own `use` of
// `std::path::{Path, PathBuf}`.
include!("../build_version.rs");

use std::fs;
use tempfile::tempdir;

/// A `VERSION` file directly in the manifest dir is found.
#[test]
fn find_version_file_in_same_dir() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join("VERSION"), "1.2.3\n").unwrap();

    let found = find_version_file(dir.path()).expect("VERSION should be found");
    assert_eq!(found, dir.path().join("VERSION"));
}

/// A `VERSION` file at an ancestor is found when walking up from a nested dir.
#[test]
fn find_version_file_walks_up_to_ancestor() {
    let root = tempdir().unwrap();
    fs::write(root.path().join("VERSION"), "4.5.6\n").unwrap();
    let nested = root.path().join("crates").join("stibbons");
    fs::create_dir_all(&nested).unwrap();

    let found = find_version_file(&nested).expect("VERSION should be found at ancestor");
    assert_eq!(found, root.path().join("VERSION"));
}

/// A `VERSION` directory (not a regular file) up the tree is ignored — the
/// walk only accepts a regular file, and stops at the first real one.
#[test]
fn find_version_file_ignores_non_file_and_finds_nearest() {
    let root = tempdir().unwrap();
    // A `VERSION` *directory* at the top must be skipped (is_file() == false).
    fs::create_dir(root.path().join("VERSION")).unwrap();
    let mid = root.path().join("mid");
    fs::create_dir_all(&mid).unwrap();
    // A real VERSION file closer to the start must win.
    fs::write(mid.join("VERSION"), "3.3.3\n").unwrap();
    let start = mid.join("deep");
    fs::create_dir_all(&start).unwrap();

    let found = find_version_file(&start).expect("nearest regular VERSION file wins");
    assert_eq!(found, mid.join("VERSION"));
}

/// When a `VERSION` file is present, its trimmed contents win over the
/// `CARGO_PKG_VERSION` fallback, and the rerun hook fires with its path.
#[test]
fn resolve_prefers_version_file_and_emits_rerun() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join("VERSION"), "  9.9.9\n").unwrap();

    let mut rerun_paths: Vec<std::path::PathBuf> = Vec::new();
    let version = resolve_version_from(dir.path().to_str().unwrap(), "0.0.0-fallback", &mut |p| {
        rerun_paths.push(p.to_path_buf());
    });

    assert_eq!(version, "9.9.9", "trimmed VERSION contents are used");
    assert_eq!(
        rerun_paths,
        vec![dir.path().join("VERSION")],
        "the rerun hook fires exactly once with the VERSION path"
    );
}

/// With no `VERSION` file, resolution falls back to the provided
/// `CARGO_PKG_VERSION`, and the rerun hook is never called.
#[test]
fn resolve_falls_back_to_pkg_version() {
    let dir = tempdir().unwrap();
    let nested = dir.path().join("no").join("version").join("here");
    fs::create_dir_all(&nested).unwrap();

    let mut rerun_called = false;
    let version = resolve_version_from(nested.to_str().unwrap(), "7.7.7-crate", &mut |_p| {
        rerun_called = true;
    });

    // Only valid when the temp subtree has no ancestor VERSION (see note above);
    // when true, the fallback must be the crate version.
    if find_version_file(&nested).is_none() {
        assert_eq!(version, "7.7.7-crate", "falls back to CARGO_PKG_VERSION");
        assert!(!rerun_called, "no rerun hook when falling back");
    }
}
