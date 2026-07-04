//! Integration tests for `stibbons status` — ports of Go's `status_test.go`.
//!
//! Each test seeds a temp project with `init --non-interactive` (using the
//! shared `minimal.igor.yml` fixture), then spawns the built binary so both the
//! exit code (0 = clean, 1 = drift) and stdout are exercised end-to-end.

mod common;

use std::fs;

use crate::common::{run_status, seed_project};

/// stdout of a status run as a String.
fn stdout_of(out: &std::process::Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

// Test 1: No .igor.yml → error exit.
#[test]
fn no_igor_yml_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_status(tmp.path());
    assert!(!out.status.success(), "expected failure when no .igor.yml exists");
}

// Test 2: Clean project → exit 0, no modified/missing.
#[test]
fn clean_project_is_clean() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let out = run_status(tmp.path());
    assert!(out.status.success(), "status should succeed on a clean project");

    let s = stdout_of(&out);
    assert!(!s.contains("modified"), "clean project should not show modified files:\n{s}");
    assert!(!s.contains("missing"), "clean project should not show missing files:\n{s}");
}

// Test 3: Modified generated file → exit 1 + "modified".
#[test]
fn modified_file_detected() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    fs::write(tmp.path().join(".devcontainer/.env"), b"# user edit\n").unwrap();

    let out = run_status(tmp.path());
    assert!(!out.status.success(), "expected drift exit when a file is modified");
    assert!(stdout_of(&out).contains("modified"), "output should show 'modified'");
}

// Test 4: Deleted generated file → exit 1 + "missing".
#[test]
fn missing_file_detected() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    fs::remove_file(tmp.path().join(".devcontainer/.env")).unwrap();

    let out = run_status(tmp.path());
    assert!(!out.status.success(), "expected drift exit when a file is missing");
    assert!(stdout_of(&out).contains("missing"), "output should show 'missing'");
}

// Test 5: Shows explicit features and their versions.
#[test]
fn shows_features_with_version() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let s = stdout_of(&run_status(tmp.path()));
    assert!(s.contains("python"), "output should contain 'python'");
    assert!(s.contains("python_dev"), "output should contain 'python_dev'");
    assert!(s.contains("3.14"), "output should show the python version");
}

// Test 6: Shows the features summary line with counts.
#[test]
fn shows_features_summary() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let s = stdout_of(&run_status(tmp.path()));
    assert!(s.contains("Features ("), "output should contain the features summary line");
    assert!(s.contains("explicit"), "summary should mention 'explicit'");
}

// Test 7: Project header shows name, user, and base image.
#[test]
fn shows_project_header() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let s = stdout_of(&run_status(tmp.path()));
    assert!(s.contains("myapp"), "header should contain project name 'myapp'");
    assert!(s.contains("developer"), "header should contain username 'developer'");
    assert!(s.contains("debian:trixie-slim"), "header should contain the base image");
}
