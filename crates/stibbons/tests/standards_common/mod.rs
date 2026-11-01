//! Shared helpers for the `stibbons setup standards` integration tests.
//!
//! Compiled into each standards test binary, each of which uses a subset.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

pub const fn stibbons_bin() -> &'static str {
    env!("CARGO_BIN_EXE_stibbons")
}

/// Run `stibbons setup standards <args...>` in `cwd`.
pub fn standards(cwd: &Path, args: &[&str]) -> Output {
    Command::new(stibbons_bin())
        .current_dir(cwd)
        .args(["setup", "standards"])
        .args(args)
        .output()
        .expect("failed to spawn stibbons")
}

pub fn stdout_of(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

pub fn assert_ok(out: &Output, what: &str) {
    assert!(
        out.status.success(),
        "{what} failed ({:?})\nstdout:\n{}\nstderr:\n{}",
        out.status.code(),
        stdout_of(out),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A temp repo holding one shell and one Python file.
pub fn shell_python_repo() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("hello.sh"), "#!/bin/bash\necho hi\n").unwrap();
    fs::write(tmp.path().join("app.py"), "print(1)\n").unwrap();
    tmp
}

/// The vendored templates directory in this checkout.
pub fn vendored_templates() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/repo-baseline")
}

/// `(relative path, bytes, executable)` for every file under `root`, sorted.
pub fn tree(root: &Path) -> Vec<(String, Vec<u8>, bool)> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                let rel = p.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                out.push((rel, fs::read(&p).unwrap(), is_executable(&p)));
            }
        }
    }
    out.sort();
    out
}

#[cfg(unix)]
pub fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(p).unwrap().permissions().mode() & 0o100 != 0
}

#[cfg(not(unix))]
pub fn is_executable(_p: &Path) -> bool {
    false
}

pub fn copy_dir(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).unwrap();
    for e in fs::read_dir(src).unwrap() {
        let p = e.unwrap().path();
        let target = dst.join(p.file_name().unwrap());
        if p.is_dir() {
            copy_dir(&p, &target);
        } else {
            fs::copy(&p, &target).unwrap();
        }
    }
}
