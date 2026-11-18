//! `setup standards` create-only targets (`once` stubs and the `AGENTS.md`
//! link) and the containers-db snapshot recorded in `.stibbons-standards.yml`
//! (#1649).

mod standards_common;

use std::fs;

use standards_common::{
    accepted_keys, assert_ok, baseline_templates, copy_dir, shell_python_repo, standards, stdout_of,
};

/// The containers-db commit the `repo-baseline` dependency is pinned to, read
/// from the workspace Cargo.toml independently of `build.rs`.
fn pinned_rev() -> String {
    let toml =
        fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml")).unwrap();
    let line = toml.lines().find(|l| l.starts_with("repo-baseline =")).expect("pin line");
    let rev = line.split("rev = \"").nth(1).and_then(|r| r.split('"').next()).expect("rev");
    assert_eq!(rev.len(), 40, "rev is not a full SHA: {rev}");
    rev.to_string()
}

fn state_text(root: &std::path::Path) -> String {
    fs::read_to_string(root.join(".stibbons-standards.yml")).unwrap()
}

#[test]
fn init_records_the_pinned_snapshot() {
    let tmp = shell_python_repo();
    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "init");
    let sha = pinned_rev();
    let state = state_text(tmp.path());
    assert!(state.contains(&format!("snapshot: {sha}")), "{state}");
    assert!(state.contains(&format!("source: containers-db {sha}")), "{state}");
    assert!(stdout_of(&out).contains(&format!("Repo baseline (containers-db {sha})")));
}

#[test]
fn templates_dir_init_records_no_snapshot() {
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&baseline_templates(), tpl.path());
    let tpl_arg = tpl.path().to_str().unwrap();
    assert_ok(&standards(tmp.path(), &["init", "--templates-dir", tpl_arg]), "init");
    let state = state_text(tmp.path());
    assert!(!state.contains("snapshot:"), "a directory has no pinned commit:\n{state}");
}

#[test]
fn check_reports_a_moved_snapshot_apart_from_file_edits() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let sha = pinned_rev();
    let old = "0123456789abcdef0123456789abcdef01234567";
    let path = tmp.path().join(".stibbons-standards.yml");
    let state =
        state_text(tmp.path()).replace(&format!("snapshot: {sha}"), &format!("snapshot: {old}"));
    fs::write(&path, state).unwrap();

    let out = standards(tmp.path(), &["check"]);
    let s = stdout_of(&out);
    let want = format!(
        "note: templates moved on since init: containers-db 0123456789ab -> {}",
        &sha[..12]
    );
    assert!(s.contains(&want), "{s}");
    // No file was touched: the snapshot note alone is not drift.
    assert_ok(&out, "check");
    assert!(s.contains("Repo baseline is up to date."), "{s}");
}

#[test]
fn check_without_recorded_snapshot_prints_no_moved_note() {
    // A state file from before #1649 has no snapshot: no moved-on claim.
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let path = tmp.path().join(".stibbons-standards.yml");
    let mut state = String::new();
    for line in state_text(tmp.path()).lines().filter(|l| !l.starts_with("snapshot:")) {
        state.push_str(line);
        state.push('\n');
    }
    fs::write(&path, state).unwrap();
    let out = standards(tmp.path(), &["check"]);
    assert_ok(&out, "check");
    assert!(!stdout_of(&out).contains("moved on"), "{}", stdout_of(&out));
}

#[test]
fn once_stubs_are_created_then_never_overwritten() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let root = tmp.path();
    for f in ["README.md", "CLAUDE.md", "docs/.gitkeep", "CODEOWNERS"] {
        assert!(root.join(f).is_file(), "expected create-only {f}");
    }
    let state = state_text(root);
    assert!(!state.contains("README.md:"), "create-only targets carry no hash:\n{state}");

    // A user edit is never drift, never accepted, never overwritten — even
    // with --force.
    fs::write(root.join("README.md"), "mine\n").unwrap();
    let out = standards(root, &["check"]);
    assert_ok(&out, "check");
    assert!(
        stdout_of(&out).contains("✓ README.md (create-only; yours to edit)"),
        "{}",
        stdout_of(&out)
    );

    let out = standards(root, &["init", "--force"]);
    assert_ok(&out, "init --force");
    assert!(stdout_of(&out).contains("keep       README.md"), "{}", stdout_of(&out));
    assert_eq!(fs::read_to_string(root.join("README.md")).unwrap(), "mine\n");

    let out = standards(root, &["accept", "README.md"]);
    assert_ok(&out, "accept");
    assert!(stdout_of(&out).contains("skipped README.md (create-only"), "{}", stdout_of(&out));
    assert!(accepted_keys(root).is_empty());
}

#[test]
fn a_deleted_once_stub_is_not_drift_but_init_recreates_it() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    fs::remove_file(tmp.path().join("CLAUDE.md")).unwrap();

    let out = standards(tmp.path(), &["check"]);
    assert_ok(&out, "check");
    assert!(stdout_of(&out).contains("- CLAUDE.md (create-only; absent"), "{}", stdout_of(&out));

    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "re-init");
    assert!(stdout_of(&out).contains("create     CLAUDE.md"), "{}", stdout_of(&out));
    assert!(tmp.path().join("CLAUDE.md").is_file());
}

#[cfg(unix)]
#[test]
fn agents_md_is_a_relative_symlink_to_claude_md() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let link = tmp.path().join("AGENTS.md");
    assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    assert_eq!(fs::read_link(&link).unwrap(), std::path::Path::new("CLAUDE.md"));
    let out = standards(tmp.path(), &["check"]);
    assert!(stdout_of(&out).contains("✓ AGENTS.md (create-only"), "{}", stdout_of(&out));
}

#[cfg(unix)]
#[test]
fn an_existing_agents_md_is_kept_even_a_dangling_link() {
    // A regular file the user wrote.
    let tmp = shell_python_repo();
    fs::write(tmp.path().join("AGENTS.md"), "my agents\n").unwrap();
    assert_ok(&standards(tmp.path(), &["init", "--force"]), "init");
    assert_eq!(fs::read_to_string(tmp.path().join("AGENTS.md")).unwrap(), "my agents\n");

    // A dangling link: present, so left alone (render.sh's `-e || -L`), and
    // nothing is created at its target.
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    let dest = outside.path().join("nowhere");
    std::os::unix::fs::symlink(&dest, tmp.path().join("AGENTS.md")).unwrap();
    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "init");
    assert!(stdout_of(&out).contains("keep       AGENTS.md"), "{}", stdout_of(&out));
    assert_eq!(fs::read_link(tmp.path().join("AGENTS.md")).unwrap(), dest);
    assert!(!dest.exists(), "followed a dangling create-only link");
}

#[cfg(unix)]
#[test]
fn absent_create_only_target_under_a_symlinked_dir_is_refused() {
    // `.github` is a link out of the repo: the absent once-only issue templates
    // under it must not be created through it, even with --force.
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), tmp.path().join(".github")).unwrap();
    let out = standards(tmp.path(), &["init", "--force"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains(".github is a symlink"));
    assert!(!outside.path().join("ISSUE_TEMPLATE").exists(), "wrote through the symlink");
}

/// Without symlinks (Windows), a missing link is reported and skipped, and
/// `init` still writes every other target — it must not abort mid-render.
#[cfg(not(unix))]
#[test]
fn link_is_skipped_without_aborting_where_symlinks_are_unsupported() {
    let tmp = shell_python_repo();
    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "init");
    let s = stdout_of(&out);
    assert!(s.contains("skip       AGENTS.md"), "{s}");
    assert!(s.contains("symlinks are not supported here; create this link yourself"), "{s}");
    assert!(!tmp.path().join("AGENTS.md").exists());
    for f in ["CLAUDE.md", "docs/.gitkeep", "CODEOWNERS", ".stibbons-standards.yml"] {
        assert!(tmp.path().join(f).is_file(), "expected {f} after the skipped link");
    }
    assert_ok(&standards(tmp.path(), &["check"]), "check");
}
