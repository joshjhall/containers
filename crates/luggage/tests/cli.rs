//! End-to-end CLI tests for `luggage`.
//!
//! Each test spawns the freshly-built binary against the self-contained
//! catalog under `testdata/fixtures-catalog/`. We deliberately avoid depending
//! on a `/workspace/containers-db` checkout so the suite stays hermetic.
//!
//! Note the catalog these tests read is NOT `testdata/catalog/`, which is the
//! *production* snapshot the image ships (`Dockerfile`'s
//! `COPY crates/luggage/testdata/catalog /opt/containers-db`) and which
//! `just db-validate-vendored` holds in sync with the upstream
//! containers-db entries (issue #815). This suite needs edge cases upstream
//! has no reason to carry — an `unsupported` platform cell to exercise the
//! exit-2 path, a distinctly-named musl install method to prove per-platform
//! method selection, and `1.84.x` versions for partial-version resolution.
//! Keeping those in a separate fixture catalog lets the production copy be a
//! strict mirror without making these assertions weaker.

use std::path::PathBuf;
use std::process::{Command, Output};

use tempfile::tempdir;

const fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_luggage")
}

fn catalog_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/fixtures-catalog")
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

/// A one-thread HTTP stub standing in for the published containers-db.
/// `routes` maps a request path to `(status, body)`; any other path is a 404.
/// Serves until the test process exits. Returns the base URL.
fn evidence_server(routes: Vec<(&'static str, u16, String)>) -> String {
    use std::io::{BufRead, BufReader, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stub");
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut line = String::new();
            if BufReader::new(&stream).read_line(&mut line).is_err() {
                continue;
            }
            let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
            let (status, body) = routes
                .iter()
                .find(|(p, _, _)| *p == path)
                .map_or((404, String::new()), |(_, st, b)| (*st, b.clone()));
            let _ = write!(
                stream,
                "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    base
}

/// A base URL nothing listens on: bind an ephemeral port, then release it.
fn unreachable_base() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().unwrap();
    drop(listener);
    format!("http://{addr}")
}

/// `luggage reconcile <args> --catalog <catalog> --published-base <base>`.
fn run_reconcile(catalog: &std::path::Path, base: &str, args: &[&str]) -> Output {
    Command::new(binary())
        .arg("reconcile")
        .args(args)
        .arg("--catalog")
        .arg(catalog)
        .args(["--published-base", base])
        .output()
        .expect("spawn luggage")
}

/// A single-cell rust@2.0.0 version file (debian/13/amd64 claimed supported)
/// carrying `tested`.
fn rust_2_0_0(tested: &serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "schemaVersion": 1,
        "tool": "rust",
        "version": "2.0.0",
        "support_matrix": [
            { "os": "debian", "os_version": "13", "arch": "amd64", "status": "supported" }
        ],
        "tested": tested,
        "install_methods": [
            {
                "name": "rustup-init",
                "source_url_template": "https://example.test/{rustup_target}/rustup-init",
                "verification": { "tier": 3 }
            }
        ],
        "metadata": { "added_at": "2026-06-01T00:00:00Z", "schema_version": 1 }
    })
}

/// A passing debian/13/amd64 evidence row at `tested_at`.
fn pass_row(tested_at: &str) -> serde_json::Value {
    serde_json::json!([{
        "os": "debian", "os_version": "13", "arch": "amd64",
        "tested_at": tested_at, "result": "pass"
    }])
}

/// A temp copy of the fixtures catalog with rust@2.0.0 carrying `tested`.
fn catalog_with_rust_2_0_0(tested: &serde_json::Value) -> (tempfile::TempDir, PathBuf) {
    let workdir = tempdir().expect("tempdir");
    let catalog = workdir.path().join("catalog");
    copy_tree(&catalog_dir(), &catalog);
    std::fs::write(
        catalog.join("tools/rust/versions/2.0.0.json"),
        serde_json::to_string_pretty(&rust_2_0_0(tested)).unwrap(),
    )
    .expect("write version file");
    (workdir, catalog)
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

/// `luggage install` reads `LUGGAGE_VERSION_PROBE_TIMEOUT` (#1358): a
/// malformed value aborts before any work and names the variable, while a
/// valid one runs the same dry-run to success. The valid run is the control —
/// without it the failure could come from anything but the variable.
#[test]
fn install_reads_the_version_probe_timeout_env() {
    let workdir = tempdir().expect("tempdir");
    let dir = workdir.path().to_str().unwrap();
    let install = |value: &str| {
        Command::new(binary())
            .args(["install", "rust@1.95.0", "--os", "debian", "--os-version", "13"])
            .args(["--arch", "amd64", "--dry-run", "--log-dir", dir, "--bin-root", dir])
            .args(["--cache-root", dir, "--tmp-root", dir])
            .arg("--catalog")
            .arg(catalog_dir())
            .env("LUGGAGE_VERSION_PROBE_TIMEOUT", value)
            .output()
            .expect("spawn luggage")
    };

    assert_exit(&install("30"), 0);

    let out = install("ten");
    assert_ne!(out.status.code(), Some(0), "a malformed timeout must abort the install");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("LUGGAGE_VERSION_PROBE_TIMEOUT"), "stderr: {stderr}");
    assert!(
        out.stdout.is_empty(),
        "no plan may be printed: {}",
        String::from_utf8_lossy(&out.stdout)
    );
}

/// `--dry-run` must report the verification-guard refusal a real install
/// would (#1042): a non-zero exit, no plan on stdout, and a `--json-report`
/// that records the failure rather than a dry-run success.
#[test]
fn install_dry_run_reports_the_guard_refusal() {
    let workdir = tempdir().expect("tempdir");
    let catalog = workdir.path().join("catalog");
    copy_tree(&catalog_dir(), &catalog);
    // Tier 1 is unimplemented, so the guard refuses it in every mode.
    let path = catalog.join("tools/rust/versions/1.95.0.json");
    let body = std::fs::read_to_string(&path).expect("read version file");
    let refused = body.replace("\"tier\": 3", "\"tier\": 1");
    assert_ne!(refused, body, "fixture must carry a tier-3 entry to rewrite");
    std::fs::write(&path, refused).expect("write version file");

    let report_path = workdir.path().join("report.json");
    let scratch = workdir.path().to_str().unwrap();
    let out = Command::new(binary())
        .args(["install", "rust@1.95.0", "--os", "debian", "--os-version", "13"])
        .args(["--arch", "amd64", "--dry-run", "--log-dir", scratch, "--bin-root", scratch])
        .args(["--cache-root", scratch, "--tmp-root", scratch, "--json-report"])
        .arg(&report_path)
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");

    assert_ne!(out.status.code(), Some(0), "a refused dry-run must not succeed");
    assert!(out.stdout.is_empty(), "no plan for a refused entry, got: {:?}", out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("tier 1"), "stderr should name the refused tier: {stderr}");

    let report: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&report_path).expect("read report file"))
            .expect("parse report JSON");
    assert_eq!(report["tool"], "rust");
    assert!(!report["error_class"].is_null(), "a refusal is a failure: {report}");
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
    let out = run(&["reconcile", "rust", "--offline"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("rust@1.96.0"), "report should include rust@1.96.0: {stdout}");
    assert!(stdout.contains("MISS"), "uncovered cells should be marked MISS: {stdout}");
    assert!(
        stdout.contains("debian/13/amd64"),
        "report should name the uncovered coordinate: {stdout}",
    );
    assert!(stdout.contains("gate failure"), "summary should count gate failures: {stdout}");
    assert!(stdout.contains("possibly stale"), "--offline evidence is labelled stale: {stdout}");
}

/// `--gate` turns uncovered `supported` cells into a non-zero exit so a
/// catalog PR claiming unbacked support fails review. The stub answers 404
/// for everything: containers-db reached, nothing published — authoritative,
/// so the local evidence is judged normally.
#[test]
fn reconcile_gate_mode_exits_nonzero_when_cells_uncovered() {
    let base = evidence_server(vec![]);
    let out = run_reconcile(&catalog_dir(), &base, &["rust", "--gate"]);
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
    let out = run(&["reconcile", "rust@1.96.0", "--json", "--offline"]);
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
/// on a temp copy so the in-tree fixture is never mutated. Not published
/// (404), so the local row is the evidence.
#[test]
fn reconcile_gate_passes_when_every_supported_cell_has_evidence() {
    let (_w, catalog) = catalog_with_rust_2_0_0(&pass_row("2026-06-01T00:00:00Z"));
    let base = evidence_server(vec![]);
    let out = run_reconcile(&catalog, &base, &["rust@2.0.0", "--gate"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("OK"), "the backed cell should be marked OK: {stdout}");
    assert!(stdout.contains("0 gate failure"), "summary should show zero failures: {stdout}");
    assert!(stdout.contains("not yet published"), "origin is reported: {stdout}");
}

/// Published evidence replaces the stale local copy before judging: the
/// local file has no rows, upstream has a passing one, so the gate passes.
/// This is the vendored-catalog case — tested[] is no longer mirrored, and
/// reconcile must not report a gap upstream has already closed.
#[test]
fn reconcile_judges_against_published_evidence() {
    let (_w, catalog) = catalog_with_rust_2_0_0(&serde_json::json!([]));
    let published = rust_2_0_0(&pass_row("2026-10-12T04:01:42Z")).to_string();
    let base = evidence_server(vec![("/tools/rust/versions/2.0.0.json", 200, published)]);
    let out = run_reconcile(&catalog, &base, &["rust@2.0.0", "--gate"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("evidence: published"), "origin is reported: {stdout}");
    assert!(
        stdout.contains("covered (tested 2026-10-12T04:01:42Z)"),
        "the cell is covered by the PUBLISHED row: {stdout}"
    );
}

/// Unreachable published containers-db (offline / air-gapped): the local
/// evidence is used, the uncovered cell is a warning naming the newest local
/// `tested_at`, and `--gate` does not block on it.
#[test]
fn reconcile_unreachable_published_evidence_warns_instead_of_gating() {
    let (_w, catalog) = catalog_with_rust_2_0_0(&serde_json::json!([{
        "os": "debian", "os_version": "12", "arch": "amd64",
        "tested_at": "2026-09-30T12:00:00Z", "result": "pass"
    }]));
    let out = run_reconcile(&catalog, &unreachable_base(), &["rust@2.0.0", "--gate"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stdout.contains("MISS"), "the cell is still classified uncovered: {stdout}");
    assert!(stdout.contains("0 gate failure"), "not a gate failure: {stdout}");
    assert!(stdout.contains("1 stale-evidence warning"), "counted as a warning: {stdout}");
    assert!(
        stderr.contains("possibly stale") && stderr.contains("2026-09-30T12:00:00Z"),
        "warning names the newest local evidence timestamp: {stderr}"
    );
}

/// A 5xx is not an answer: it falls back like an unreachable host rather
/// than being read as "not published" (which would gate).
#[test]
fn reconcile_server_error_is_a_fallback_not_a_gate_failure() {
    let (_w, catalog) = catalog_with_rust_2_0_0(&serde_json::json!([]));
    let base = evidence_server(vec![("/tools/rust/versions/2.0.0.json", 503, String::new())]);
    let out = run_reconcile(&catalog, &base, &["rust@2.0.0", "--gate"]);
    assert_exit(&out, 0);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("none recorded"), "no local rows to date the fallback: {stderr}");
}

/// No positional target walks the whole catalog. The vendored catalog only
/// has rust, so the report covers every rust version and exits 0.
#[test]
fn reconcile_no_target_covers_all_tools_in_catalog() {
    let out = run(&["reconcile", "--offline"]);
    assert_exit(&out, 0);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("rust@1.96.0"), "whole-catalog walk should include rust: {stdout}");
    assert!(stdout.contains("version(s)"), "summary should report a version count: {stdout}");
}

/// An unknown tool is a hard error (exit 1), mirroring `resolve`.
#[test]
fn reconcile_missing_tool_exits_one() {
    let out = run(&["reconcile", "ghosttool"]);
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("not found"), "stderr should mention 'not found': {stderr}");
}

/// An unknown exact version is a hard error (exit 1).
#[test]
fn reconcile_missing_version_exits_one() {
    let out = run(&["reconcile", "rust@9.9.9"]);
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no version"), "stderr should mention 'no version': {stderr}");
}

/// A non-directory `--catalog` is rejected before any work, mirroring `resolve`.
#[test]
fn reconcile_missing_catalog_exits_one() {
    let out = Command::new(binary())
        .args(["reconcile", "rust", "--catalog", "/does/not/exist"])
        .output()
        .expect("spawn luggage");
    assert_exit(&out, 1);

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("not a directory"),
        "stderr should explain the missing catalog: {stderr}",
    );
}

/// A passing row on an `unsupported` cell is a contradiction: the claim says
/// "won't run" but the evidence says it did. `--gate` must flag it (exit 1)
/// and the report must render the BAD/CONTRADICTION marker. Operates on a temp
/// copy so the in-tree fixture is never mutated.
#[test]
fn reconcile_gate_flags_contradiction_for_unsupported_with_evidence() {
    let workdir = tempdir().expect("tempdir");
    let catalog = workdir.path().join("catalog");
    copy_tree(&catalog_dir(), &catalog);

    let version_path = catalog.join("tools/rust/versions/3.0.0.json");
    let doc = serde_json::json!({
        "schemaVersion": 1,
        "tool": "rust",
        "version": "3.0.0",
        "support_matrix": [
            { "os": "windows", "arch": "amd64", "status": "unsupported" }
        ],
        "tested": [
            {
                "os": "windows",
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
        .args(["reconcile", "rust@3.0.0", "--gate"])
        .arg("--catalog")
        .arg(&catalog)
        .output()
        .expect("spawn luggage");
    assert_exit(&out, 1);

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("CONTRADICTION"),
        "report should render the contradiction marker: {stdout}",
    );
}

/// `tool@version` and `--channel` are mutually exclusive, and the conflict
/// must be an explicit error rather than a silent preference.
///
/// clap's `conflicts_with = "channel"` on `--version` cannot catch this: the
/// inline `@version` is split out by hand, outside clap's view. Without the
/// guard in `cmd_install`, `build_spec` prefers the channel unconditionally
/// and the pinned version is discarded with no diagnostic — the user asks for
/// an exact version and silently gets whatever the channel resolves to.
#[test]
fn install_rejects_inline_version_with_channel() {
    let out = run(&["install", "rust@1.95.0", "--channel", "nightly"]);
    assert_exit(&out, 1);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("specify the version once"),
        "stderr should name the conflict, not resolve the channel: {stderr}",
    );
}
