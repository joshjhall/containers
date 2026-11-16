//! Guards the `STIBBONS_VERSION` build stamp (#697).
//!
//! `build.rs` stamps the repo-root `VERSION` file into the binary via
//! `env!("STIBBONS_VERSION")`, replacing `CARGO_PKG_VERSION` for both the
//! `--version` output and the startup log line (`main.rs`). If that wiring
//! regressed to `CARGO_PKG_VERSION`, `--version` would report the crate's
//! `0.1.0` instead of the product version. These tests assert the binary
//! reports the `VERSION` file contents, not the crate version — both via
//! `--version` and via the startup log line (asserted directly, #749).

use std::fs;
use std::path::PathBuf;
use std::process::Command;

/// Absolute path to the stibbons binary under test (provided by cargo).
const fn stibbons_bin() -> &'static str {
    env!("CARGO_BIN_EXE_stibbons")
}

/// The crate's own Cargo version — what a regressed build would wrongly stamp.
const fn cargo_pkg_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Read the repo-root `VERSION` file by walking up from this crate's manifest
/// dir — the same resolution `build.rs` performs.
fn repo_version() -> String {
    let start = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for dir in start.ancestors() {
        let candidate: PathBuf = dir.join("VERSION");
        if candidate.is_file() {
            return fs::read_to_string(&candidate).expect("VERSION readable").trim().to_string();
        }
    }
    panic!("repo-root VERSION file not found walking up from {}", start.display());
}

#[test]
fn version_flag_reports_version_file_not_crate_version() {
    let out = Command::new(stibbons_bin())
        .arg("--version")
        .output()
        .expect("failed to spawn stibbons --version");
    assert!(out.status.success(), "--version should exit 0");

    let stdout = String::from_utf8(out.stdout).expect("utf8 --version output");
    let expected = repo_version();

    assert!(
        stdout.contains(&expected),
        "--version output {stdout:?} should contain the VERSION-file value {expected:?}"
    );

    // The two only coincide if someone sets the crate version equal to the
    // product version; in this repo they differ (crate 0.1.0 vs product 4.x),
    // so a stamp regression is observable. Guard the discriminator holds.
    let crate_ver = cargo_pkg_version();
    if crate_ver != expected {
        assert!(
            !stdout.contains(crate_ver),
            "--version output {stdout:?} must NOT report the crate version {crate_ver:?} \
             (that would mean the STIBBONS_VERSION stamp regressed to CARGO_PKG_VERSION)"
        );
    }
}

/// The bare-invocation startup log line (`main.rs`: `tracing::info!("stibbons
/// v{}", …)`) carries the stamped product version, not the crate version.
/// Asserted directly rather than inferred from `--version` (#749).
#[test]
fn startup_log_line_reports_version_file() {
    let cwd = tempfile::tempdir().expect("tempdir");
    let out = Command::new(stibbons_bin())
        // Default `info` filter must apply; a caller's RUST_LOG could hide it.
        .env_remove("RUST_LOG")
        .current_dir(cwd.path())
        .output()
        .expect("failed to spawn bare stibbons");
    assert!(out.status.success(), "bare `stibbons` should exit 0");

    // tracing's fmt subscriber writes to stdout by default; check both
    // streams so a writer change does not mask the line.
    let combined =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let expected = format!("stibbons v{}", repo_version());
    assert!(
        combined.contains(&expected),
        "startup output {combined:?} should contain the log line {expected:?}"
    );

    let crate_line = format!("stibbons v{}", cargo_pkg_version());
    assert!(
        !combined.contains(&crate_line),
        "startup log {combined:?} must NOT report the crate version line {crate_line:?}"
    );
}

/// Sanity: the stamp discriminator is meaningful — VERSION file and crate
/// version actually differ in this repo, so the assertion above has teeth.
#[test]
fn stamp_and_crate_version_differ() {
    assert_ne!(
        repo_version(),
        cargo_pkg_version(),
        "the VERSION-file value and CARGO_PKG_VERSION must differ for the stamp \
         test to be meaningful; update this guard if the crate is ever versioned \
         to match the product"
    );
}
