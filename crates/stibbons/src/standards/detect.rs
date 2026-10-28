//! Detect which repo-baseline language slices apply to a repository.
//!
//! The file list comes from `git ls-files` (tracked + untracked-but-not-ignored)
//! so vendored and build output the repo already ignores never votes; outside a
//! git repo it falls back to a bounded directory walk that skips the usual
//! heavy directories. Classification is pure and unit-tested separately.

use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

/// Directories the fallback walk never descends into.
const SKIP_DIRS: &[&str] = &[".git", "target", "node_modules", ".venv", "venv", ".worktrees"];

/// Upper bound on files the fallback walk visits, so a huge non-git tree
/// cannot stall `init`.
const WALK_LIMIT: usize = 50_000;

/// Detect the language slices present under `root`, restricted to `known`
/// (the slices the manifest defines).
#[must_use]
pub fn detect_slices(root: &Path, known: &BTreeSet<String>) -> BTreeSet<String> {
    let files = git_files(root).unwrap_or_else(|| walk_files(root));
    classify(root, &files).into_iter().filter(|s| known.contains(s)).collect()
}

/// Map repo-relative file paths to language slices.
///
/// - `shell`: a `*.sh`/`*.bash` file, or an extensionless file under `bin/`
///   whose first line is a `sh`/`bash` shebang.
/// - `python`: a `*.py` file, or `pyproject.toml`.
#[must_use]
pub fn classify(root: &Path, files: &[String]) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for f in files {
        let name = f.rsplit('/').next().unwrap_or(f);
        let ext = Path::new(name).extension().and_then(|e| e.to_str());
        match ext {
            Some("sh" | "bash") => {
                found.insert("shell".to_string());
            }
            Some("py") => {
                found.insert("python".to_string());
            }
            Some("toml") if name == "pyproject.toml" => {
                found.insert("python".to_string());
            }
            None if f.starts_with("bin/") && has_shell_shebang(&root.join(f)) => {
                found.insert("shell".to_string());
            }
            _ => {}
        }
    }
    found
}

/// Bytes read when probing a shebang: a `#!` line is far shorter, and a cap
/// keeps a hostile repo (huge file, `/dev/zero` behind a link) from stalling us.
const SHEBANG_PROBE_BYTES: u64 = 256;

/// Whether `path`'s first line is a `sh`/`bash` shebang. Only a regular file
/// (not a symlink, FIFO, or device) is opened, and only its first
/// [`SHEBANG_PROBE_BYTES`] are read.
fn has_shell_shebang(path: &Path) -> bool {
    use std::io::Read as _;
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_file() => {}
        _ => return false,
    }
    let Ok(file) = std::fs::File::open(path) else { return false };
    let mut bytes = Vec::new();
    if file.take(SHEBANG_PROBE_BYTES).read_to_end(&mut bytes).is_err() {
        return false;
    }
    let first = bytes.split(|b| *b == b'\n').next().unwrap_or_default();
    let Ok(line) = std::str::from_utf8(first) else { return false };
    let Some(rest) = line.strip_prefix("#!") else { return false };
    let mut words = rest.split_whitespace();
    let interp = words.next().unwrap_or_default();
    let interp = if interp.ends_with("/env") { words.next().unwrap_or_default() } else { interp };
    matches!(interp.rsplit('/').next(), Some("sh" | "bash"))
}

/// `git ls-files --cached --others --exclude-standard` under `root`, or `None`
/// when `root` is not a git work tree (or git is unavailable).
fn git_files(root: &Path) -> Option<Vec<String>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        out.stdout
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect(),
    )
}

/// Repo-relative paths of regular files under `root`, skipping [`SKIP_DIRS`]
/// and symlinks, capped at [`WALK_LIMIT`].
fn walk_files(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            if out.len() >= WALK_LIMIT {
                return out;
            }
            let Ok(ft) = entry.file_type() else { continue };
            let path = entry.path();
            if ft.is_dir() {
                let name = entry.file_name();
                if !SKIP_DIRS.iter().any(|s| name == *s) {
                    stack.push(path);
                }
            } else if ft.is_file()
                && let Ok(rel) = path.strip_prefix(root)
            {
                let parts: Vec<String> = rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect();
                out.push(parts.join("/"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn classifies_by_extension_and_pyproject() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(classify(tmp.path(), &files(&["scripts/a.sh"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["x.bash"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["pkg/mod.py"])), set(&["python"]));
        assert_eq!(classify(tmp.path(), &files(&["pyproject.toml"])), set(&["python"]));
        assert_eq!(classify(tmp.path(), &files(&["README.md", "src/main.rs"])), set(&[]));
    }

    #[test]
    fn extensionless_bin_script_needs_shell_shebang() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("bin")).unwrap();
        std::fs::write(tmp.path().join("bin/tool"), "#!/usr/bin/env bash\necho hi\n").unwrap();
        std::fs::write(tmp.path().join("bin/plain"), "#!/bin/sh\n").unwrap();
        std::fs::write(tmp.path().join("bin/py"), "#!/usr/bin/env python3\n").unwrap();
        std::fs::write(tmp.path().join("bin/data"), "not a script\n").unwrap();

        assert_eq!(classify(tmp.path(), &files(&["bin/tool"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["bin/plain"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["bin/py", "bin/data"])), set(&[]));
    }

    #[cfg(unix)]
    #[test]
    fn shebang_probe_ignores_symlinks_and_reads_a_bounded_prefix() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("bin")).unwrap();
        // A link to a real shell script must not count: the probe never
        // follows links (the same link could point at /dev/zero).
        std::fs::write(tmp.path().join("real.sh"), "#!/bin/bash\n").unwrap();
        std::os::unix::fs::symlink(tmp.path().join("real.sh"), tmp.path().join("bin/link"))
            .unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/link"])), set(&[]));

        // A shebang followed by far more than the probe window still matches.
        let big = format!("#!/bin/sh\n{}", "x".repeat(1 << 20));
        std::fs::write(tmp.path().join("bin/big"), big).unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/big"])), set(&["shell"]));

        // The cap is observable: an interpreter that only starts past the
        // window is never seen. An unbounded read would find `/bin/sh` after
        // the padding and match; the bounded one sees `#!` plus blanks.
        let pad = " ".repeat(usize::try_from(SHEBANG_PROBE_BYTES).unwrap());
        let late = format!("#!{pad}/bin/sh\n");
        std::fs::write(tmp.path().join("bin/late"), late).unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/late"])), set(&[]));
    }

    #[test]
    fn detect_filters_to_known_and_walks_without_git() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("a.sh"), "").unwrap();
        std::fs::write(tmp.path().join("b.py"), "").unwrap();
        // A skipped directory must not vote.
        std::fs::create_dir(tmp.path().join("node_modules")).unwrap();
        std::fs::write(tmp.path().join("node_modules/c.py"), "").unwrap();

        assert_eq!(
            detect_slices(tmp.path(), &set(&["shell", "python"])),
            set(&["python", "shell"])
        );
        assert_eq!(detect_slices(tmp.path(), &set(&["shell"])), set(&["shell"]));
    }

    #[test]
    fn walk_skips_heavy_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("target/debug")).unwrap();
        std::fs::write(tmp.path().join("target/debug/x.py"), "").unwrap();
        std::fs::create_dir(tmp.path().join("src")).unwrap();
        std::fs::write(tmp.path().join("src/y.sh"), "").unwrap();
        assert_eq!(walk_files(tmp.path()), ["src/y.sh"]);
    }
}
