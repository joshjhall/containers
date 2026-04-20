//! Integration tests for `stibbons init` — ports of Go's `init_test.go`.

mod common;

use std::fs;
use std::path::Path;

use containers_common::config::IgorConfig;

use crate::common::{
    assert_success, docker_available, run_init_noninteractive, run_init_with_args,
    strip_json_comments,
};

/// The five files `init` generates, relative to the project root.
const GENERATED_FILES: &[&str] = &[
    ".devcontainer/docker-compose.yml",
    ".devcontainer/devcontainer.json",
    ".devcontainer/.env",
    ".env.example",
    ".igor.yml",
];

// Test 1: All 5 files are created and non-empty.
#[test]
fn non_interactive_minimal() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    for path in GENERATED_FILES {
        let full = tmp.path().join(path);
        assert!(full.exists(), "expected {path} to exist");
        let meta = fs::metadata(&full).unwrap();
        assert!(meta.len() > 0, "expected {path} to be non-empty");
    }
}

// Test 2: Generated docker-compose.yml parses as valid YAML with a services key.
#[test]
fn non_interactive_valid_yaml() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let content = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    let parsed: serde_yaml::Value = serde_yaml::from_str(&content).expect("valid YAML");
    assert!(parsed.get("services").is_some(), "docker-compose.yml must have services key");
}

// Test 3: Generated devcontainer.json parses as valid JSON (after stripping `// ===` markers).
#[test]
fn non_interactive_valid_json() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let raw = fs::read_to_string(tmp.path().join(".devcontainer/devcontainer.json")).unwrap();
    let stripped = strip_json_comments(&raw);
    let parsed: serde_json::Value = serde_json::from_str(&stripped).expect("valid JSON");
    assert!(parsed.get("name").is_some(), "devcontainer.json must have name key");
}

// Test 4: Saved .igor.yml round-trips through IgorConfig::load with correct fields.
#[test]
fn non_interactive_igor_yml_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let loaded = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
    assert_eq!(loaded.schema_version, 1);
    assert_eq!(loaded.containers_dir, "containers");
    assert_eq!(loaded.project.name, "myapp");
    assert_eq!(loaded.project.username, "developer");
    assert_eq!(loaded.project.base_image, "debian:trixie-slim");
    assert!(loaded.features.contains(&"python".to_string()));
    assert!(loaded.features.contains(&"python_dev".to_string()));
}

// Test 5: generated hash map has an entry for each of the 5 files, each a 64-char hex digest.
#[test]
fn non_interactive_generated_hashes() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let loaded = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
    assert_eq!(
        loaded.generated.len(),
        GENERATED_FILES.len(),
        "expected {} hash entries, got {:?}",
        GENERATED_FILES.len(),
        loaded.generated.keys().collect::<Vec<_>>(),
    );
    for path in GENERATED_FILES {
        let hash =
            loaded.generated.get(*path).unwrap_or_else(|| panic!("missing hash entry for {path}"));
        assert_eq!(hash.len(), 64, "SHA-256 hex must be 64 chars, got {hash}");
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()), "non-hex chars in hash: {hash}");
    }
}

// Test 6: Fullstack config renders expected content (docker.sock, SYS_ADMIN, cache volumes).
#[test]
fn non_interactive_fullstack() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "fullstack.igor.yml");
    assert_success(&out);

    let compose = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(compose.contains("docker.sock"), "fullstack must mount docker.sock");
    assert!(compose.contains("SYS_ADMIN"), "fullstack must request SYS_ADMIN capability");
    assert!(compose.contains("cache:/cache/"), "fullstack must include cache volumes");
}

// Test 7: --non-interactive without --config must fail.
#[test]
fn non_interactive_missing_config() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_with_args(tmp.path(), &["--non-interactive"]);
    assert!(!out.status.success(), "expected non-zero exit when --config is missing");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("--config") && stderr.contains("--non-interactive"),
        "stderr should mention both flags, got: {stderr}",
    );
}

// Test 8: --config pointing at a nonexistent path must fail.
#[test]
fn non_interactive_invalid_config_path() {
    let tmp = tempfile::tempdir().unwrap();
    let bogus = tmp.path().join("does-not-exist.yml");
    let out =
        run_init_with_args(tmp.path(), &["--non-interactive", "--config", bogus.to_str().unwrap()]);
    assert!(!out.status.success(), "expected non-zero exit when config file is missing");
}

// Test 9: `docker compose config` accepts the generated minimal compose file.
// Gated: silently returns if docker is not on PATH.
#[test]
fn non_interactive_compose_valid() {
    if !docker_available() {
        eprintln!("skipping non_interactive_compose_valid: docker not available");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let status = std::process::Command::new("docker")
        .args(["compose", "-f", ".devcontainer/docker-compose.yml", "config", "--quiet"])
        .current_dir(tmp.path())
        .status()
        .expect("failed to spawn docker compose");
    assert!(status.success(), "docker compose config failed for minimal fixture");
}

// Test 10: Same as #9 but for the fullstack fixture.
#[test]
fn non_interactive_fullstack_compose_valid() {
    if !docker_available() {
        eprintln!("skipping non_interactive_fullstack_compose_valid: docker not available");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "fullstack.igor.yml");
    assert_success(&out);

    let status = std::process::Command::new("docker")
        .args(["compose", "-f", ".devcontainer/docker-compose.yml", "config", "--quiet"])
        .current_dir(tmp.path())
        .status()
        .expect("failed to spawn docker compose");
    assert!(status.success(), "docker compose config failed for fullstack fixture");
}

// Test 11: A config without an explicit versions block has defaults filled in after init.
#[test]
fn non_interactive_default_versions_filled() {
    let tmp = tempfile::tempdir().unwrap();
    let out = run_init_noninteractive(tmp.path(), "minimal.igor.yml");
    assert_success(&out);

    let loaded = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();
    let py = loaded
        .versions
        .get("PYTHON_VERSION")
        .expect("PYTHON_VERSION should be filled from registry default");
    assert!(!py.is_empty(), "PYTHON_VERSION should not be empty");
}

// Test 12: Two successive init runs produce byte-identical output for the 4 templated files,
// and .igor.yml round-trips to an equal IgorConfig.
#[test]
fn non_interactive_feature_order_stable() {
    let tmp = tempfile::tempdir().unwrap();

    let out1 = run_init_noninteractive(tmp.path(), "fullstack.igor.yml");
    assert_success(&out1);
    let snapshot1 = snapshot_generated(tmp.path());
    let cfg1 = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();

    let out2 = run_init_noninteractive(tmp.path(), "fullstack.igor.yml");
    assert_success(&out2);
    let snapshot2 = snapshot_generated(tmp.path());
    let cfg2 = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap();

    for path in &["docker-compose.yml", "devcontainer.json", ".env"] {
        let key = format!(".devcontainer/{path}");
        assert_eq!(snapshot1.get(&key), snapshot2.get(&key), "{key} differs between runs");
    }
    assert_eq!(snapshot1.get(".env.example"), snapshot2.get(".env.example"));

    assert_eq!(cfg1.features, cfg2.features, "feature order must be stable across runs");
    assert_eq!(cfg1.versions, cfg2.versions);
    assert_eq!(cfg1.generated, cfg2.generated, "hashes must match across runs");
}

fn snapshot_generated(root: &Path) -> std::collections::BTreeMap<String, String> {
    GENERATED_FILES
        .iter()
        .map(|p| ((*p).to_string(), fs::read_to_string(root.join(p)).unwrap()))
        .collect()
}
