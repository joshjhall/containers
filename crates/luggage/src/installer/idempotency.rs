//! Idempotency pre-check: skip install when the tool is already at the
//! target version.
//!
//! For the rust pilot the convention is "`<bin_root>/<tool> --version`
//! contains `<version>`" — exactly what bash's `lib/features/rust.sh` does
//! with `command -v rustc && rustc --version | grep -q "$RUST_VERSION"`.
//!
//! When the catalog tool id and its primary binary name differ (e.g.
//! `rust` → `rustc`), [`primary_binary`] keeps a small in-code mapping.
//! This is a stopgap; a future catalog field (issue #404) will declare a
//! per-tool version-check command so each tool can decide what "already
//! installed" means.

use std::path::Path;
use std::process::Command;

/// Map a catalog tool id to the primary binary name luggage should
/// `--version`-check. Defaults to the tool id itself when no mapping
/// exists. Stopgap until catalog `validation_tiers` lands (issue #404).
#[must_use]
pub fn primary_binary(tool: &str) -> &str {
    match tool {
        "rust" => "rustc",
        _ => tool,
    }
}

/// Check whether `tool` at `version` is already on disk under `bin_root`.
///
/// Returns `false` for any reason it can't confirm — missing binary,
/// non-zero exit, output without the version literal, I/O error. The
/// caller must treat `false` as "go install"; only `true` should skip.
#[must_use]
pub fn already_installed(tool: &str, version: &str, bin_root: &Path) -> bool {
    let binary = bin_root.join(primary_binary(tool));
    if !binary.exists() {
        return false;
    }
    let Ok(output) = Command::new(&binary).arg("--version").output() else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    stdout.contains(version) || stderr.contains(version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

    #[cfg(unix)]
    fn write_shim(dir: &Path, name: &str, version_line: &str) {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\necho '{version_line}'\n")).unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
    }

    #[test]
    fn missing_binary_returns_false() {
        let dir = tempdir().unwrap();
        assert!(!already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    fn matching_version_returns_true() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        assert!(already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    fn nonmatching_version_returns_false() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.84.0 (abcdef0)");
        assert!(!already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    fn rust_tool_id_resolves_to_rustc_binary() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        assert!(
            already_installed("rust", "1.95.0", dir.path()),
            "catalog tool id `rust` should map to `rustc` binary",
        );
    }

    #[test]
    fn primary_binary_defaults_to_tool_id() {
        assert_eq!(primary_binary("node"), "node");
        assert_eq!(primary_binary("rust"), "rustc");
    }
}
