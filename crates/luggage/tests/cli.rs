//! End-to-end CLI tests for `luggage`.
//!
//! Each test spawns the freshly-built binary against the self-contained
//! catalog under `testdata/catalog/`. We deliberately avoid depending on a
//! `/workspace/containers-db` checkout so the suite stays hermetic.

use std::path::PathBuf;
use std::process::{Command, Output};

use tempfile::tempdir;

const fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_luggage")
}

fn catalog_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/catalog")
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .args(args)
        .arg("--catalog")
        .arg(catalog_dir())
        .output()
        .expect("spawn luggage")
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

#[test]
fn resolve_default_version_emits_rustup_recipe_as_json() {
    let out = run(&[
        "resolve",
        "rust",
        "--os",
        "debian",
        "--os-version",
        "13",
        "--arch",
        "amd64",
        "--json",
    ]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let value: serde_json::Value = serde_json::from_str(&stdout).expect("parse JSON");

    assert_eq!(value["tool"], "rust");
    assert_eq!(value["version"], "1.95.0");
    assert_eq!(value["method_name"], "rustup-init");
    assert_eq!(value["verification_tier"], 3);
    assert_eq!(value["verification"]["algorithm"], "sha256");
    assert_eq!(value["platform"]["os"], "debian");
    assert!(value["dependencies"].is_array());
}

#[test]
fn resolve_partial_version_picks_highest_patch() {
    let out = run(&[
        "resolve",
        "rust",
        "--version",
        "1.84",
        "--os",
        "debian",
        "--os-version",
        "13",
        "--arch",
        "amd64",
        "--json",
    ]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let value: serde_json::Value = serde_json::from_str(&stdout).expect("parse JSON");
    assert_eq!(value["version"], "1.84.1", "expected highest 1.84.x patch");
}

#[test]
fn resolve_unsupported_platform_exits_two() {
    let out = run(&["resolve", "rust", "--os", "windows", "--arch", "amd64"]);
    assert_exit(&out, 2);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unsupported"), "stderr should mention unsupported: {stderr}");
    assert!(
        stderr.contains("no upstream rustup target"),
        "stderr should include the support_matrix reason: {stderr}",
    );
}

#[test]
fn resolve_missing_tool_exits_one() {
    let out =
        run(&["resolve", "ghosttool", "--os", "debian", "--os-version", "13", "--arch", "amd64"]);
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("not found"), "stderr should mention 'not found': {stderr}");
}

#[test]
fn resolve_missing_version_exits_one() {
    let out = run(&[
        "resolve",
        "rust",
        "--version",
        "9.9.9",
        "--os",
        "debian",
        "--os-version",
        "13",
        "--arch",
        "amd64",
    ]);
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no version"), "stderr should mention 'no version': {stderr}");
}

#[test]
fn resolve_alpine_picks_musl_method() {
    let out = run(&[
        "resolve",
        "rust",
        "--os",
        "alpine",
        "--os-version",
        "3.21",
        "--arch",
        "amd64",
        "--json",
    ]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let value: serde_json::Value = serde_json::from_str(&stdout).expect("parse JSON");
    assert_eq!(value["method_name"], "rustup-init-musl");
}

#[test]
fn resolve_human_output_starts_with_tool_at_version() {
    let out = run(&["resolve", "rust", "--os", "debian", "--os-version", "13", "--arch", "amd64"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.starts_with("rust@1.95.0"),
        "human output should lead with `rust@1.95.0`: {stdout}",
    );
    assert!(stdout.contains("method=rustup-init"), "human output should include method name");
    assert!(stdout.contains("tier=3"), "human output should include verification tier");
}

#[test]
fn resolve_missing_catalog_exits_one() {
    let out = Command::new(binary())
        .args(["resolve", "rust", "--os", "debian", "--os-version", "13", "--arch", "amd64"])
        .arg("--catalog")
        .arg("/does/not/exist")
        .output()
        .expect("spawn luggage");
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("not a directory"),
        "stderr should explain the missing catalog: {stderr}",
    );
}

/// Dry-run with `--json-report` writes the report file alongside the
/// existing plan-on-stdout behavior. The report has every field the
/// evidence-run wrapper depends on, even though the install was never
/// executed.
#[test]
fn install_dry_run_writes_json_report() {
    let workdir = tempdir().expect("tempdir");
    let report_path = workdir.path().join("report.json");
    let out = run(&[
        "install",
        "rust@1.95.0",
        "--os",
        "debian",
        "--os-version",
        "13",
        "--arch",
        "amd64",
        "--dry-run",
        "--log-dir",
        workdir.path().to_str().unwrap(),
        "--bin-root",
        workdir.path().to_str().unwrap(),
        "--cache-root",
        workdir.path().to_str().unwrap(),
        "--tmp-root",
        workdir.path().to_str().unwrap(),
        "--json-report",
        report_path.to_str().unwrap(),
    ]);
    assert_exit(&out, 0);

    let body = std::fs::read_to_string(&report_path).expect("read report file");
    let report: serde_json::Value = serde_json::from_str(&body).expect("parse report JSON");

    assert_eq!(report["tool"], "rust");
    assert_eq!(report["version"], "1.95.0");
    assert_eq!(report["already_installed"], false);
    assert!(report["duration_seconds"].is_number(), "duration_seconds must be present");
    assert!(report["version_output"].is_null(), "dry-run has no validate output");
    assert!(report["error_class"].is_null(), "dry-run is not a failure");

    // Stdout still carries the plan JSON for human inspection.
    let stdout = String::from_utf8_lossy(&out.stdout);
    let plan: serde_json::Value = serde_json::from_str(&stdout).expect("parse plan from stdout");
    assert_eq!(plan["tool"], "rust");
    assert_eq!(plan["method_name"], "rustup-init");
}

/// Resolve-time errors (`ToolNotFound`, `UnsupportedPlatform`) return
/// before `run_with_report` is reached, so no report file is written.
/// Evidence rows only make sense for tuples that resolve cleanly;
/// misconfigured inputs are stderr-only.
#[test]
fn install_resolve_time_errors_do_not_write_json_report() {
    let workdir = tempdir().expect("tempdir");
    let report_path = workdir.path().join("report.json");
    let out = run(&[
        "install",
        "ghosttool",
        "--os",
        "debian",
        "--os-version",
        "13",
        "--arch",
        "amd64",
        "--log-dir",
        workdir.path().to_str().unwrap(),
        "--bin-root",
        workdir.path().to_str().unwrap(),
        "--cache-root",
        workdir.path().to_str().unwrap(),
        "--tmp-root",
        workdir.path().to_str().unwrap(),
        "--json-report",
        report_path.to_str().unwrap(),
    ]);
    assert_exit(&out, 1);
    assert!(!report_path.exists(), "resolve-time errors run before run_with_report");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("not found"), "stderr should mention 'not found': {stderr}");
}
