//! Integration tests for `stibbons update` — a port of Go's `update_test.go`.
//!
//! Each test seeds a real project with `init --non-interactive` in a tempdir,
//! then runs `update` against it, so the version-detection, config-preservation,
//! and cross-command hash contract (`.igor.yml`'s `generated` map) are all
//! exercised end to end.

mod common;

use std::fs;
use std::path::Path;

use containers_common::config::IgorConfig;
use containers_common::generate::hash_content;

use crate::common::{run_update, seed_project};

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

// update 1 [AC]: running with no `.igor.yml` errors.
#[test]
fn update_no_igor_yml_errors() {
    let tmp = tempfile::tempdir().unwrap();

    let out = run_update(tmp.path(), &[]);
    assert!(!out.status.success(), "update without .igor.yml must fail");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains(".igor.yml"), "stderr should mention .igor.yml: {stderr:?}");
}

// update 2 [AC]: init then update leaves the recorded hashes identical.
#[test]
fn update_idempotent() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");
    let before = load_cfg(tmp.path()).generated;

    ok(&run_update(tmp.path(), &[]));

    let after = load_cfg(tmp.path()).generated;
    assert_eq!(before, after, "update must not change hashes when nothing changed");
}

// update 3 [AC]: feature selection and project config survive an update.
#[test]
fn update_preserves_config() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_update(tmp.path(), &[]));

    let cfg = load_cfg(tmp.path());
    assert_eq!(cfg.project.name, "myapp");
    assert_eq!(cfg.project.username, "developer");
    assert_eq!(cfg.containers_dir, "containers");
    assert!(cfg.features.contains(&"python".to_string()));
    assert!(cfg.features.contains(&"python_dev".to_string()));
}

// update 4 [AC]: a user-modified generated file is skipped (not overwritten).
#[test]
fn update_skips_modified_files() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let compose = tmp.path().join(".devcontainer/docker-compose.yml");
    let modified = fs::read_to_string(&compose).unwrap() + "\n# user edit\n";
    fs::write(&compose, &modified).unwrap();

    let out = run_update(tmp.path(), &[]);
    ok(&out);

    assert_eq!(fs::read_to_string(&compose).unwrap(), modified, "skipped file must be preserved");
    assert!(String::from_utf8_lossy(&out.stdout).contains("skip"));
}

// update 5 [AC]: `--force` overwrites a user-modified file.
#[test]
fn update_force_overwrites_modified() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let compose = tmp.path().join(".devcontainer/docker-compose.yml");
    let modified = fs::read_to_string(&compose).unwrap() + "\n# user edit\n";
    fs::write(&compose, &modified).unwrap();

    ok(&run_update(tmp.path(), &["--force"]));

    assert_ne!(
        fs::read_to_string(&compose).unwrap(),
        modified,
        "--force must overwrite the local edit",
    );
}

// update 6 [AC]: the detected containers VERSION is recorded as containers_ref.
#[test]
fn update_updates_containers_ref() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let containers = tmp.path().join("containers");
    fs::create_dir_all(&containers).unwrap();
    fs::write(containers.join("VERSION"), "v4.15.8\n").unwrap();

    ok(&run_update(tmp.path(), &[]));

    let cfg = load_cfg(tmp.path());
    assert_eq!(cfg.containers_ref.as_deref(), Some("v4.15.8"));
}

// update 7 [AC]: every recorded non-state hash matches the file on disk.
#[test]
fn update_hashes_match_disk() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    ok(&run_update(tmp.path(), &[]));

    let cfg = load_cfg(tmp.path());
    for (path, expected) in &cfg.generated {
        if path == ".igor.yml" {
            continue; // rewritten by save(), never matches its own tracked hash.
        }
        let disk = fs::read_to_string(tmp.path().join(path)).unwrap();
        assert_eq!(&hash_content(&disk), expected, "hash mismatch for {path}");
    }
}

// update 8 [AC]: a skipped (user-modified) file keeps its *original* hash.
#[test]
fn update_skipped_file_hash_preserved() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let orig_hash =
        load_cfg(tmp.path()).generated.get(".devcontainer/docker-compose.yml").cloned().unwrap();

    let compose = tmp.path().join(".devcontainer/docker-compose.yml");
    let modified = fs::read_to_string(&compose).unwrap() + "\n# user edit\n";
    fs::write(&compose, &modified).unwrap();

    ok(&run_update(tmp.path(), &[]));

    let after_hash =
        load_cfg(tmp.path()).generated.get(".devcontainer/docker-compose.yml").cloned().unwrap();
    assert_eq!(after_hash, orig_hash, "skipped file's recorded hash must be preserved");
}

// update 9 [AC]: a deleted generated file is re-created.
#[test]
fn update_creates_deleted_file() {
    let tmp = tempfile::tempdir().unwrap();
    seed_project(tmp.path(), "minimal.igor.yml");

    let env = tmp.path().join(".devcontainer/.env");
    fs::remove_file(&env).unwrap();

    ok(&run_update(tmp.path(), &[]));

    assert!(env.exists(), "deleted file must be re-created");
}
