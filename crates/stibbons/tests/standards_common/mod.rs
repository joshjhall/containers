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

/// The targets recorded under `accepted` in `root`'s state file, parsed rather
/// than sliced out of the YAML so field order cannot change the answer.
pub fn accepted_keys(root: &Path) -> std::collections::BTreeSet<String> {
    #[derive(serde::Deserialize)]
    struct State {
        #[serde(default)]
        accepted: std::collections::BTreeMap<String, String>,
    }
    let text = fs::read_to_string(root.join(".stibbons-standards.yml")).unwrap();
    let state: State = serde_saphyr::from_str(&text).unwrap();
    state.accepted.into_keys().collect()
}

/// Sets a directory's mode and restores 0755 on drop, so a panicking assertion
/// cannot leave a read-only dir behind that the tempdir then fails to remove.
#[cfg(unix)]
pub struct ModeGuard(PathBuf);

#[cfg(unix)]
impl ModeGuard {
    pub fn set(dir: &Path, mode: u32) -> Self {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(mode)).unwrap();
        Self(dir.to_path_buf())
    }
}

#[cfg(unix)]
impl Drop for ModeGuard {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        // Not `unwrap`: a panic while already unwinding would abort the run.
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
    }
}

/// Whether `dir` refuses writes, so a permission-based failure can be injected
/// there. Root writes through mode 0555; CI runs unprivileged and sets
/// `REQUIRE_UNPRIVILEGED_TESTS=1`, so there a writable dir fails the test rather
/// than skipping it.
pub fn refuses_writes(dir: &Path) -> bool {
    let probe = dir.join(".probe");
    if fs::write(&probe, b"").is_err() {
        return true;
    }
    let _ = fs::remove_file(&probe);
    assert!(
        std::env::var("REQUIRE_UNPRIVILEGED_TESTS").as_deref() != Ok("1"),
        "REQUIRE_UNPRIVILEGED_TESTS=1 but a 0555 dir is writable (running as root?)"
    );
    eprintln!("skipping: a 0555 dir is writable here (running as root?)");
    false
}
