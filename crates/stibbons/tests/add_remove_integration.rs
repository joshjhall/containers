//! Integration tests for `stibbons add` / `stibbons remove` — ports of Go's
//! `add_test.go` (12) and `remove_test.go` (14), plus a regression test for
//! the agents/services preservation fix.
//!
//! Each test seeds a real project with `init --non-interactive` in a tempdir,
//! then exercises `add`/`remove` against it — so the cross-command hash
//! contract (`.igor.yml`'s `generated` map) is exercised end to end.

mod common;

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use containers_common::config::IgorConfig;

use crate::common::{run_add, run_remove, seed_project};

/// Load the project's `.igor.yml` from a tempdir root.
fn load_cfg(root: &Path) -> IgorConfig {
    IgorConfig::load(root.join(".igor.yml")).unwrap()
}

/// Assert a command succeeded, dumping output otherwise.
fn ok(out: &std::process::Output) {
    assert!(
        out.status.success(),
        "command failed: {:?}\nstdout: {}\nstderr: {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

/// Assert a command failed and its stderr contains `needle`.
fn err_contains(out: &std::process::Output, needle: &str) {
    assert!(!out.status.success(), "expected failure, got success: {out:?}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains(needle), "stderr {stderr:?} does not contain {needle:?}");
}

/// Snapshot every generated file's bytes for before/after comparison.
fn snapshot(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut map = BTreeMap::new();
    for path in [
        ".devcontainer/docker-compose.yml",
        ".devcontainer/devcontainer.json",
        ".devcontainer/.env",
        ".env.example",
        ".igor.yml",
    ] {
        let full = root.join(path);
        if let Ok(bytes) = fs::read(&full) {
            map.insert(path.to_string(), bytes);
        }
    }
    map
}

// ===========================================================================
// add
// ===========================================================================

// add 1: features list in `.igor.yml` gains the added feature.
#[test]
fn add_updates_features() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_add(tmp.path(), &["docker"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.contains(&"docker".to_string()));
    assert!(cfg.features.contains(&"python".to_string()));
    assert!(cfg.features.contains(&"python_dev".to_string()));
    // features are stored sorted.
    let mut sorted = cfg.features.clone();
    sorted.sort();
    assert_eq!(cfg.features, sorted);
}

// add 2: generated files are re-rendered — the new build arg appears.
#[test]
fn add_rerenders_generated_files() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");
    let before = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(!before.contains("INCLUDE_DOCKER"));

    ok(&run_add(tmp.path(), &["docker"]));

    let after = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(after.contains("INCLUDE_DOCKER"), "compose must reference INCLUDE_DOCKER after add");
}

// add 3 [AC]: `add <feature> --dev` adds the feature + its `_dev` companion.
#[test]
fn add_with_dev_adds_companion() {
    let tmp = tempfile::tempdir().unwrap();
    // minimal already has python+python_dev, so use rust to exercise --dev on a
    // feature not yet present.
    seed_project(tmp.path(), "minimal.igor.yml");
    ok(&run_add(tmp.path(), &["rust", "--dev"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.contains(&"rust".to_string()));
    assert!(cfg.features.contains(&"rust_dev".to_string()), "rust_dev companion must be added");
}

// add 4: `--dev` on a feature with no `_dev` companion errors.
#[test]
fn add_dev_no_companion_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let out = run_add(tmp.path(), &["kubernetes", "--dev"]);
    err_contains(&out, "kubernetes");
}

// add 5: unknown feature errors.
#[test]
fn add_unknown_feature_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let out = run_add(tmp.path(), &["not_a_feature"]);
    err_contains(&out, "unknown feature");
}

// add 6: adding an already-enabled feature is a no-op success.
#[test]
fn add_already_enabled_is_noop() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");
    let before = load_cfg(tmp.path()).features;

    let out = run_add(tmp.path(), &["python"]);
    ok(&out);

    let after = load_cfg(tmp.path()).features;
    assert_eq!(before, after, "feature set unchanged when adding an enabled feature");
}

// add 7: transitive dependency is auto-resolved (kotlin -> java).
#[test]
fn add_resolves_transitive_dep() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_add(tmp.path(), &["kotlin"]));

    let compose = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    // java is auto-resolved by kotlin's `requires` and should be rendered.
    assert!(compose.contains("INCLUDE_JAVA"), "java must be auto-resolved and rendered");
    // java is auto-resolved, not explicit, so it is NOT written to features.
    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.contains(&"kotlin".to_string()));
    assert!(!cfg.features.contains(&"java".to_string()), "auto-resolved java stays implicit");
}

// add 8: default version for the added feature is filled in.
#[test]
fn add_fills_default_version() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_add(tmp.path(), &["kotlin"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.versions.contains_key("KOTLIN_VERSION"), "KOTLIN_VERSION must be filled");
    // Pre-existing version preserved.
    assert!(cfg.versions.contains_key("PYTHON_VERSION"));
}

// add 9 [AC]: `--dry-run` writes nothing.
#[test]
fn add_dry_run_writes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");
    let before = snapshot(tmp.path());

    let out = run_add(tmp.path(), &["docker", "--dry-run"]);
    ok(&out);
    assert!(String::from_utf8_lossy(&out.stdout).contains("Dry run"));

    let after = snapshot(tmp.path());
    assert_eq!(before, after, "dry-run must not modify any file");
}

// add 10 [AC]: a user-modified generated file is skipped (not overwritten).
#[test]
fn add_skips_user_modified_file() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    // Simulate a local edit to a generated file.
    let env_path = tmp.path().join(".devcontainer/.env");
    fs::write(&env_path, "# hand edited\n").unwrap();

    let out = run_add(tmp.path(), &["docker"]);
    ok(&out);

    let after = fs::read_to_string(&env_path).unwrap();
    assert_eq!(after, "# hand edited\n", "user-modified file must be preserved");
    assert!(String::from_utf8_lossy(&out.stdout).contains("skip"));
}

// add 11 [AC]: `--force` overwrites a user-modified file.
#[test]
fn add_force_overwrites_user_modified_file() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let env_path = tmp.path().join(".devcontainer/.env");
    fs::write(&env_path, "# hand edited\n").unwrap();

    ok(&run_add(tmp.path(), &["docker", "--force"]));

    let after = fs::read_to_string(&env_path).unwrap();
    assert_ne!(after, "# hand edited\n", "--force must overwrite the local edit");
}

// add 12: multiple features added at once.
#[test]
fn add_multiple_features() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_add(tmp.path(), &["docker", "kubernetes"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.contains(&"docker".to_string()));
    assert!(cfg.features.contains(&"kubernetes".to_string()));
}

// ===========================================================================
// remove
// ===========================================================================

// remove 1: features list loses the removed feature.
#[test]
fn remove_updates_features() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");

    ok(&run_remove(tmp.path(), &["kubernetes"]));

    let cfg = load_cfg(tmp.path());
    assert!(!cfg.features.contains(&"kubernetes".to_string()));
    assert!(cfg.features.contains(&"python".to_string()), "unrelated features remain");
    assert!(cfg.features.contains(&"docker".to_string()));
}

// remove 2: generated files re-rendered — the build arg disappears.
#[test]
fn remove_rerenders_generated_files() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");
    let before = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(before.contains("INCLUDE_KUBERNETES"));

    ok(&run_remove(tmp.path(), &["kubernetes"]));

    let after = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    assert!(!after.contains("INCLUDE_KUBERNETES"), "compose must drop INCLUDE_KUBERNETES");
}

// remove 3 [AC]: removing a feature still required by a dependent errors.
#[test]
fn remove_blocked_by_dependent_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    // python_dev requires python; removing python without --cascade must fail.
    let out = run_remove(tmp.path(), &["python"]);
    err_contains(&out, "python_dev");
}

// remove 4 [AC]: `--cascade` removes the feature and its dependents.
#[test]
fn remove_cascade_removes_dependents() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_remove(tmp.path(), &["python", "--cascade"]));

    let cfg = load_cfg(tmp.path());
    assert!(!cfg.features.contains(&"python".to_string()));
    assert!(!cfg.features.contains(&"python_dev".to_string()), "cascade drops python_dev too");
}

// remove 5: `--dev-only` removes just the companion, keeps the runtime feature.
#[test]
fn remove_dev_only_keeps_runtime() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_remove(tmp.path(), &["python", "--dev-only"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.contains(&"python".to_string()), "runtime python kept");
    assert!(!cfg.features.contains(&"python_dev".to_string()), "python_dev removed");
}

// remove 6: `--dev-only` with no companion errors.
#[test]
fn remove_dev_only_no_companion_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");

    let out = run_remove(tmp.path(), &["kubernetes", "--dev-only"]);
    err_contains(&out, "kubernetes");
}

// remove 7: removing an auto-resolved (non-explicit) feature errors.
#[test]
fn remove_auto_resolved_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");
    // Add kotlin so java is auto-resolved (implicit), then try to remove java.
    ok(&run_add(tmp.path(), &["kotlin"]));

    let out = run_remove(tmp.path(), &["java"]);
    err_contains(&out, "java");
}

// remove 8: unknown feature errors.
#[test]
fn remove_unknown_feature_errors() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let out = run_remove(tmp.path(), &["not_a_feature"]);
    err_contains(&out, "unknown feature");
}

// remove 9: removing a feature prunes its version entry.
#[test]
fn remove_prunes_version_entry() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");
    assert!(load_cfg(tmp.path()).versions.contains_key("RUST_VERSION"));

    // rust_dev requires rust; cascade to remove both and prune RUST_VERSION.
    ok(&run_remove(tmp.path(), &["rust", "--cascade"]));

    let cfg = load_cfg(tmp.path());
    assert!(!cfg.versions.contains_key("RUST_VERSION"), "RUST_VERSION pruned");
}

// remove 10: unrelated version entries are kept.
#[test]
fn remove_keeps_other_versions() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");

    ok(&run_remove(tmp.path(), &["rust", "--cascade"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.versions.contains_key("PYTHON_VERSION"), "unrelated PYTHON_VERSION kept");
}

// remove 11 [AC]: `--dry-run` writes nothing.
#[test]
fn remove_dry_run_writes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");
    let before = snapshot(tmp.path());

    let out = run_remove(tmp.path(), &["kubernetes", "--dry-run"]);
    ok(&out);
    assert!(String::from_utf8_lossy(&out.stdout).contains("Dry run"));

    let after = snapshot(tmp.path());
    assert_eq!(before, after, "dry-run must not modify any file");
}

// remove 12 [AC]: a user-modified generated file is skipped.
#[test]
fn remove_skips_user_modified_file() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");

    let env_path = tmp.path().join(".devcontainer/.env");
    fs::write(&env_path, "# hand edited\n").unwrap();

    ok(&run_remove(tmp.path(), &["kubernetes"]));

    let after = fs::read_to_string(&env_path).unwrap();
    assert_eq!(after, "# hand edited\n", "user-modified file preserved");
}

// remove 13 [AC]: `--force` overwrites a user-modified file.
#[test]
fn remove_force_overwrites_user_modified_file() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "fullstack.igor.yml");

    let env_path = tmp.path().join(".devcontainer/.env");
    fs::write(&env_path, "# hand edited\n").unwrap();

    ok(&run_remove(tmp.path(), &["kubernetes", "--force"]));

    let after = fs::read_to_string(&env_path).unwrap();
    assert_ne!(after, "# hand edited\n", "--force overwrites the local edit");
}

// remove 14: removing down to an empty selection still yields valid YAML.
#[test]
fn remove_to_empty_yields_valid_yaml() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    // Remove both features (python_dev first, then python).
    ok(&run_remove(tmp.path(), &["python", "--cascade"]));

    let cfg = load_cfg(tmp.path());
    assert!(cfg.features.is_empty(), "all features removed");
    // Reloading proves the saved `.igor.yml` is still valid YAML.
    let compose = fs::read_to_string(tmp.path().join(".devcontainer/docker-compose.yml")).unwrap();
    let _: serde_yaml::Value = serde_yaml::from_str(&compose).expect("compose still valid YAML");
}

// ===========================================================================
// regression: agents/services preserved on save (fixes the Go data-loss bug)
// ===========================================================================

#[test]
fn add_preserves_agents_and_services() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "services.igor.yml");
    let before = load_cfg(tmp.path());
    assert!(!before.services.is_empty(), "fixture must carry services");
    assert_eq!(before.agents.max, 3);

    ok(&run_add(tmp.path(), &["docker"]));

    let after = load_cfg(tmp.path());
    // ServiceConfig has no PartialEq; compare the serialized YAML, which is what
    // round-trip preservation actually protects.
    assert_eq!(
        serde_yaml::to_string(&after.services).unwrap(),
        serde_yaml::to_string(&before.services).unwrap(),
        "services must survive an add",
    );
    assert_eq!(after.agents.max, before.agents.max, "agents must survive an add");
    assert_eq!(after.agents.network, before.agents.network);
}

#[test]
fn remove_preserves_agents_and_services() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "services.igor.yml");
    let before = load_cfg(tmp.path());

    // postgres_client is explicit in the fixture; removing it must not drop
    // the agents/services blocks.
    ok(&run_remove(tmp.path(), &["postgres_client"]));

    let after = load_cfg(tmp.path());
    assert_eq!(
        serde_yaml::to_string(&after.services).unwrap(),
        serde_yaml::to_string(&before.services).unwrap(),
        "services must survive a remove",
    );
    assert_eq!(after.agents.max, before.agents.max, "agents must survive a remove");
}
