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

/// Recursively copy a directory tree (test helper — keeps the suite hermetic
/// without shelling out to `cp`).
fn copy_tree(src: &std::path::Path, dst: &std::path::Path) {
    std::fs::create_dir_all(dst).expect("create dst dir");
    for entry in std::fs::read_dir(src).expect("read src dir") {
        let entry = entry.expect("dir entry");
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if entry.file_type().expect("file type").is_dir() {
            copy_tree(&from, &to);
        } else {
            std::fs::copy(&from, &to).expect("copy file");
        }
    }
}

/// `catalog add-version` clones the latest version entry into a new one,
/// lists it in `available[]`, leaves `default_version` alone, and resolves
/// afterward — then a second run is an idempotent no-op. Operates on a temp
/// copy so the in-tree fixture is never mutated.
#[test]
fn catalog_add_version_generates_resolvable_entry_and_is_idempotent() {
    let workdir = tempdir().expect("tempdir");
    let catalog = workdir.path().join("catalog");
    copy_tree(&catalog_dir(), &catalog);

    let add = Command::new(binary())
        .args(["catalog", "add-version", "rust@1.99.0", "--released", "2026-08-01"])
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");
    assert_exit(&add, 0);

    // The generated version file resolves and carries the rewritten toolchain.
    let resolve = Command::new(binary())
        .args([
            "resolve",
            "rust",
            "--version",
            "1.99.0",
            "--os",
            "debian",
            "--os-version",
            "13",
            "--arch",
            "amd64",
            "--json",
        ])
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");
    assert_exit(&resolve, 0);
    let value: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&resolve.stdout)).expect("parse JSON");
    assert_eq!(value["version"], "1.99.0");

    // default_version is untouched.
    let index: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(catalog.join("tools/rust/index.json")).expect("read index"),
    )
    .expect("parse index");
    assert_eq!(index["default_version"], "1.95.0");

    // Second run is a no-op.
    let again = Command::new(binary())
        .args(["catalog", "add-version", "rust@1.99.0"])
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");
    assert_exit(&again, 0);
    assert!(
        String::from_utf8_lossy(&again.stdout).contains("already present"),
        "second run should report the version is already present",
    );
}

/// Report mode exits 0 even when cells are uncovered (the vendored rust
/// catalog claims `supported` cells with `tested: []`), and names the
/// uncovered coordinates so a human can act on them.
#[test]
fn reconcile_report_mode_exits_zero_and_lists_uncovered() {
    let out = run(&["reconcile", "rust"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("rust@1.96.0"), "report should include rust@1.96.0: {stdout}");
    assert!(stdout.contains("MISS"), "uncovered cells should be marked MISS: {stdout}");
    assert!(
        stdout.contains("debian/13/amd64"),
        "report should name the uncovered coordinate: {stdout}",
    );
    assert!(stdout.contains("gate failure"), "summary should count gate failures: {stdout}");
}

/// `--gate` turns uncovered `supported` cells into a non-zero exit so a
/// catalog PR claiming unbacked support fails review.
#[test]
fn reconcile_gate_mode_exits_nonzero_when_cells_uncovered() {
    let out = run(&["reconcile", "rust", "--gate"]);
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("uncovered or contradicted"),
        "gate stderr should explain the failure: {stderr}",
    );
}

/// `--json` for a single `tool@version` emits a parseable array whose cells
/// carry the claim and the reconciliation verdict.
#[test]
fn reconcile_json_single_version_reports_uncovered_supported_cell() {
    let out = run(&["reconcile", "rust@1.96.0", "--json"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let value: serde_json::Value = serde_json::from_str(&stdout).expect("parse JSON");
    assert_eq!(value.as_array().expect("array").len(), 1, "one version requested");
    assert_eq!(value[0]["tool"], "rust");
    assert_eq!(value[0]["version"], "1.96.0");

    let cells = value[0]["cells"].as_array().expect("cells array");
    let supported_uncovered =
        cells.iter().any(|c| c["claimed"] == "supported" && c["status"]["kind"] == "uncovered");
    assert!(supported_uncovered, "a supported cell should be uncovered: {stdout}");
}

/// A passing `tested[]` row covering a `supported` cell flips that cell to
/// `covered`; once every supported cell is backed, `--gate` exits 0. Operates
/// on a temp copy so the in-tree fixture is never mutated.
#[test]
fn reconcile_gate_passes_when_every_supported_cell_has_evidence() {
    let workdir = tempdir().expect("tempdir");
    let catalog = workdir.path().join("catalog");
    copy_tree(&catalog_dir(), &catalog);

    // Build a single-cell version file: one supported cell + one matching
    // passing row. Keeps the fixture self-contained and the gate green.
    let version_path = catalog.join("tools/rust/versions/2.0.0.json");
    let doc = serde_json::json!({
        "schemaVersion": 1,
        "tool": "rust",
        "version": "2.0.0",
        "support_matrix": [
            { "os": "debian", "os_version": "13", "arch": "amd64", "status": "supported" }
        ],
        "tested": [
            {
                "os": "debian",
                "os_version": "13",
                "arch": "amd64",
                "tested_at": "2026-06-01T00:00:00Z",
                "result": "pass"
            }
        ],
        "install_methods": [
            {
                "name": "rustup-init",
                "source_url_template": "https://example.test/{rustup_target}/rustup-init",
                "verification": { "tier": 3 }
            }
        ],
        "metadata": { "added_at": "2026-06-01T00:00:00Z", "schema_version": 1 }
    });
    std::fs::write(&version_path, serde_json::to_string_pretty(&doc).unwrap())
        .expect("write version file");

    let out = Command::new(binary())
        .args(["reconcile", "rust@2.0.0", "--gate"])
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("OK"), "the backed cell should be marked OK: {stdout}");
    assert!(stdout.contains("0 gate failure"), "summary should show zero failures: {stdout}");
}
