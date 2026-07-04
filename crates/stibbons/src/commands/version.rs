//! `stibbons version` — print the stibbons and containers versions.
//!
//! Ported from the Go `igor version` command. The stibbons version is stamped
//! into the binary at build time from the repo-root `VERSION` file (see
//! `build.rs`), replacing the Go `-ldflags` injection. Unlike the Go binary,
//! stibbons carries no build-timestamp stamp, so the output is version-only.

use std::io::{self, Write};
use std::path::Path;

/// Writes the stibbons version and, when found, the containers submodule
/// version to `out`.
///
/// # Errors
///
/// Returns any I/O error from writing to `out`.
pub fn run(out: &mut impl Write) -> io::Result<()> {
    writeln!(out, "stibbons {}", env!("STIBBONS_VERSION"))?;

    if let Some(v) = detect_containers_version() {
        writeln!(out, "containers {v}")?;
    }
    Ok(())
}

/// Looks for a containers `VERSION` file near the current directory and returns
/// its trimmed contents.
#[must_use]
pub fn detect_containers_version() -> Option<String> {
    let cwd = std::env::current_dir().ok()?;
    detect_containers_version_in(&cwd)
}

/// Resolves the containers version relative to `base`.
///
/// Mirrors the Go predecessor's fixed candidate list: the project root
/// (submodule consumers keep `containers/` alongside their own tree), the
/// containers submodule itself, and the parent (when run from inside
/// `containers/`). The first readable file wins; its contents are trimmed.
fn detect_containers_version_in(base: &Path) -> Option<String> {
    const CANDIDATES: &[&str] = &["VERSION", "containers/VERSION", "../VERSION"];

    for candidate in CANDIDATES {
        if let Ok(data) = std::fs::read_to_string(base.join(candidate)) {
            return Some(data.trim().to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prints_stibbons_version() {
        let mut buf = Vec::new();
        run(&mut buf).unwrap();
        let out = String::from_utf8(buf).unwrap();

        assert!(out.starts_with("stibbons "), "output should start with `stibbons `, got: {out}");
        // The stamped version line is non-empty past the prefix.
        let version = out.lines().next().unwrap().trim_start_matches("stibbons ");
        assert!(!version.is_empty(), "version should be non-empty");
    }

    #[test]
    fn detects_version_from_root_file() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("VERSION"), "  4.19.12\n").unwrap();
        assert_eq!(detect_containers_version_in(tmp.path()).as_deref(), Some("4.19.12"));
    }

    #[test]
    fn detects_version_from_containers_subdir() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("containers")).unwrap();
        std::fs::write(tmp.path().join("containers/VERSION"), "5.0.0").unwrap();
        assert_eq!(detect_containers_version_in(tmp.path()).as_deref(), Some("5.0.0"));
    }

    #[test]
    fn missing_version_is_none() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(detect_containers_version_in(tmp.path()), None);
    }
}
