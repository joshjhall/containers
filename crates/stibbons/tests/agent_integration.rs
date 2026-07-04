//! End-to-end integration tests for `stibbons agent`, driving the real binary.
//!
//! The `build --dry-run` path needs no Docker daemon (it prints the command and
//! makes zero docker calls), so it runs everywhere. The `status` smoke test
//! shells out to `docker inspect`, so it is gated behind [`docker_available`].

mod common;

use common::{docker_available, run_agent, seed_project};

/// `agent build --dry-run` in a seeded project prints the docker build command
/// with the expected feature/name args and never touches Docker.
#[test]
fn agent_build_dry_run() {
    let tmp = tempfile::tempdir().unwrap();
    // `agents.igor.yml` carries an `agents:` block and python/node features.
    seed_project(tmp.path(), "agents.igor.yml");

    let out = run_agent(tmp.path(), &["build", "--dry-run"]);
    assert!(
        out.status.success(),
        "agent build --dry-run failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("docker build"), "expected a docker build line, got: {stdout}");
    assert!(stdout.contains("PROJECT_NAME=myapp"), "got: {stdout}");
    // The agents block sets username `worker`.
    assert!(stdout.contains("USERNAME=worker"), "got: {stdout}");
}

/// `agent` with no `.igor.yml` errors with the init hint.
#[test]
fn agent_without_config_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_agent(tmp.path(), &["status"]);
    assert!(!out.status.success(), "agent status should fail without .igor.yml");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no .igor.yml found"), "got: {stderr}");
}

/// `agent status` runs end-to-end against a real Docker daemon (containers
/// absent → all agents `not created`).
#[test]
fn agent_status_smoke() {
    if !docker_available() {
        eprintln!("skipping agent_status_smoke: docker not available");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "agents.igor.yml");

    let out = run_agent(tmp.path(), &["status"]);
    assert!(
        out.status.success(),
        "agent status failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("Image:"), "got: {stdout}");
    assert!(stdout.contains("AGENT"), "got: {stdout}");
}
