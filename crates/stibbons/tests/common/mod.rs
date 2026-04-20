//! Shared test helpers for stibbons integration tests.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// Path to the fixture directory (`crates/containers-common/testdata/`).
pub fn testdata_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../containers-common/testdata")
}

/// Path to the stibbons binary under test.
const fn stibbons_bin() -> &'static str {
    env!("CARGO_BIN_EXE_stibbons")
}

/// Run `stibbons init --non-interactive --config <fixture>` in `cwd`.
pub fn run_init_noninteractive(cwd: &Path, fixture: &str) -> Output {
    let config_path = testdata_dir().join(fixture);
    Command::new(stibbons_bin())
        .current_dir(cwd)
        .args(["init", "--non-interactive", "--config"])
        .arg(config_path)
        .output()
        .expect("failed to spawn stibbons")
}

/// Run `stibbons init` with custom args in `cwd`.
pub fn run_init_with_args(cwd: &Path, extra_args: &[&str]) -> Output {
    Command::new(stibbons_bin())
        .current_dir(cwd)
        .arg("init")
        .args(extra_args)
        .output()
        .expect("failed to spawn stibbons")
}

/// Assert the command exited with code 0, otherwise panic showing stderr.
pub fn assert_success(out: &Output) {
    assert!(
        out.status.success(),
        "stibbons init failed with status {:?}\nstdout: {}\nstderr: {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

/// True if `docker` is available on PATH and responds to `--version`.
pub fn docker_available() -> bool {
    Command::new("docker").arg("--version").output().is_ok_and(|o| o.status.success())
}

/// Strip leading `// ...` comment lines so the remainder parses as JSON.
pub fn strip_json_comments(content: &str) -> String {
    content
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n")
}
