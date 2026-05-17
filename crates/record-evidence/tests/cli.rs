//! End-to-end CLI tests for `record-evidence`.

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

use tempfile::tempdir;

const fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_record-evidence")
}

fn write_report(dir: &std::path::Path, report: &str) -> PathBuf {
    let path = dir.join("report.json");
    fs::write(&path, report).unwrap();
    path
}

fn run(args: &[&str]) -> Output {
    Command::new(binary()).args(args).output().expect("spawn record-evidence")
}

fn assert_exit(out: &Output, expected: i32) {
    let actual = out.status.code().unwrap_or(-1);
    assert_eq!(
        actual,
        expected,
        "expected exit {expected}, got {actual}\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

const SUCCESS_REPORT: &str = r#"{
    "tool": "rust",
    "version": "1.95.0",
    "already_installed": false,
    "duration_seconds": 12.5,
    "version_output": "rustc 1.95.0 (abcdef0)"
}"#;

const FAILURE_REPORT: &str = r#"{
    "tool": "rust",
    "version": "1.95.0",
    "already_installed": false,
    "duration_seconds": 4.2,
    "error_class": "verify"
}"#;

const SKIP_REPORT: &str = r#"{
    "tool": "rust",
    "version": "1.95.0",
    "already_installed": true,
    "duration_seconds": 0.1
}"#;

#[test]
fn success_report_emits_pass_row_with_evidence_fields() {
    let dir = tempdir().unwrap();
    let report = write_report(dir.path(), SUCCESS_REPORT);
    let out = run(&[
        "--luggage-report",
        report.to_str().unwrap(),
        "--image-ref",
        "ghcr.io/x/base-debian-12-amd64:v1.0.0",
        "--image-digest",
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        "--ci-run",
        "https://github.com/x/runs/1",
        "--os",
        "debian",
        "--os-version",
        "12",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let row: serde_json::Value = serde_json::from_str(&stdout).expect("parse stdout JSON");
    assert_eq!(row["result"], "pass");
    assert_eq!(row["os"], "debian");
    assert_eq!(row["arch"], "amd64");
    assert_eq!(
        row["image_digest"],
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    );
    assert_eq!(row["duration_seconds"], 12.5);
    assert_eq!(row["version_output"], "rustc 1.95.0 (abcdef0)");
    assert!(row["error_class"].is_null());
    assert!(row["tested_at"].as_str().unwrap().contains('T'));
}

#[test]
fn failure_report_emits_fail_row_with_error_class() {
    let dir = tempdir().unwrap();
    let report = write_report(dir.path(), FAILURE_REPORT);
    let out = run(&[
        "--luggage-report",
        report.to_str().unwrap(),
        "--image-ref",
        "ghcr.io/x/base-debian-12-amd64:v1.0.0",
        "--image-digest",
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "--os",
        "debian",
        "--os-version",
        "12",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 0);

    let row: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(row["result"], "fail");
    assert_eq!(row["error_class"], "verify");
    assert!(row["ci_run"].is_null(), "ci_run is optional");
}

#[test]
fn skip_report_emits_skip_row() {
    let dir = tempdir().unwrap();
    let report = write_report(dir.path(), SKIP_REPORT);
    let out = run(&[
        "--luggage-report",
        report.to_str().unwrap(),
        "--image-ref",
        "ghcr.io/x/base-debian-12-amd64:v1.0.0",
        "--image-digest",
        "sha256:2222222222222222222222222222222222222222222222222222222222222222",
        "--os",
        "debian",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 0);

    let row: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(row["result"], "skip");
    assert!(row["os_version"].is_null(), "os_version is optional");
}

#[test]
fn rejects_bad_image_digest_with_exit_two() {
    let dir = tempdir().unwrap();
    let report = write_report(dir.path(), SUCCESS_REPORT);
    let out = run(&[
        "--luggage-report",
        report.to_str().unwrap(),
        "--image-ref",
        "ghcr.io/x/base-debian-12-amd64:v1.0.0",
        "--image-digest",
        "not-a-real-digest",
        "--os",
        "debian",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 2);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("invalid image_digest"), "stderr: {stderr}");
}

#[test]
fn missing_luggage_report_exits_one() {
    let out = run(&[
        "--luggage-report",
        "/does/not/exist.json",
        "--image-ref",
        "ghcr.io/x/base-debian-12-amd64:v1.0.0",
        "--image-digest",
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        "--os",
        "debian",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 1);
}
