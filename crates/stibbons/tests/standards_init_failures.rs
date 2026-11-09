//! Integration tests for a `stibbons setup standards init` that fails partway:
//! a target write, the state save, or both. Split out of
//! `standards_integration.rs` (#1578). Each test makes a directory read-only
//! and skips itself when that does not refuse writes (running as root).
#![cfg(unix)]

mod standards_common;

use std::fs;

use standards_common::{
    ModeGuard, assert_ok, copy_dir, refuses_writes, shell_python_repo, standards, stdout_of,
    vendored_templates,
};

/// A write failure partway through `init` must still record the files it
/// already wrote, so a later run updates them rather than reporting them as
/// user edits (#1542).
#[cfg(unix)]
#[test]
fn partial_init_failure_records_written_files() {
    let tmp = shell_python_repo();
    let root = tmp.path();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&vendored_templates(), tpl.path());
    let tpl_arg = tpl.path().to_str().unwrap();

    // `tests/run.sh` follows lefthook.yml and justfile in manifest order; a
    // read-only `tests/` makes its write fail after those two are written.
    let tests_dir = root.join("tests");
    fs::create_dir(&tests_dir).unwrap();
    let read_only = ModeGuard::set(&tests_dir, 0o555);
    if !refuses_writes(&tests_dir) {
        return;
    }

    let out = standards(root, &["init", "--templates-dir", tpl_arg]);
    assert!(!out.status.success(), "init into a read-only dir must fail");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("failed to write") && err.contains("tests/run.sh"), "{err}");
    assert!(err.contains("recorded the files written so far"), "{err}");
    // Stdout reports what happened, not the plan: nothing from the failed
    // write on is claimed created.
    let s = stdout_of(&out);
    assert!(s.contains("create     lefthook.yml\n"), "{s}");
    assert!(s.contains("failed     tests/run.sh\n"), "{s}");
    assert!(s.contains("not run    dprint.json\n"), "{s}");
    assert!(!s.contains("create     tests/run.sh") && !s.contains("create     dprint.json"), "{s}");
    assert!(root.join("lefthook.yml").is_file(), "lefthook.yml should precede the failure");
    assert!(root.join(".stibbons-standards.yml").is_file(), "no state saved after failure");

    let out = standards(root, &["check", "--templates-dir", tpl_arg]);
    let s = stdout_of(&out);
    assert!(s.contains("✓ lefthook.yml\n"), "{s}");
    assert!(s.contains("tests/run.sh (missing)"), "{s}");

    // Fix the cause and change a lefthook fragment: lefthook.yml is now an
    // unedited stibbons file the templates would change, so it updates.
    drop(read_only);
    let frag = tpl.path().join("core/lefthook/10-pre-commit.yml.tmpl");
    fs::write(&frag, format!("{}\n", fs::read_to_string(&frag).unwrap())).unwrap();

    let out = standards(root, &["init", "--templates-dir", tpl_arg]);
    assert_ok(&out, "re-init after fixing the failure");
    let s = stdout_of(&out);
    assert!(s.contains("update     lefthook.yml"), "{s}");
    assert!(s.contains("create     tests/run.sh"), "{s}");
    assert!(!s.contains("skip "), "re-init treated a stibbons-written file as a user edit:\n{s}");
    assert_ok(&standards(root, &["check", "--templates-dir", tpl_arg]), "check");
}

#[cfg(unix)]
#[test]
fn failed_state_save_still_reports_targets() {
    let tmp = shell_python_repo();
    let root = tmp.path();
    assert_ok(&standards(root, &["init"]), "init");
    // Every target is now unchanged; only the state save can touch the root.
    fs::remove_file(root.join(".stibbons-standards.yml")).unwrap();
    let read_only = ModeGuard::set(root, 0o555);
    if !refuses_writes(root) {
        return;
    }

    let out = standards(root, &["init"]);
    drop(read_only);
    assert!(!out.status.success(), "init must fail when the state file cannot be saved");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains(
            "wrote every baseline file but could not record them in .stibbons-standards.yml"
        ),
        "{err}"
    );
    // The chained cause is printed once: the path, then the OS reason.
    assert!(
        err.contains(": failed to write ") && err.contains(".stibbons-standards.yml: "),
        "{err}"
    );
    let s = stdout_of(&out);
    assert!(s.contains("ok         lefthook.yml\n"), "report lost on a failed save:\n{s}");
    assert!(!s.contains("Wrote .stibbons-standards.yml"), "{s}");
}

/// A failed write whose best-effort state save fails too reports both, and does
/// not claim the written files were recorded.
#[cfg(unix)]
#[test]
fn init_write_and_save_failure_reports_both() {
    let tmp = shell_python_repo();
    let root = tmp.path();
    // A read-only root fails the first write and the state save after it.
    let read_only = ModeGuard::set(root, 0o555);
    if !refuses_writes(root) {
        return;
    }

    let out = standards(root, &["init"]);
    drop(read_only);
    assert!(!out.status.success(), "init into a read-only root must fail");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("failed to write") && err.contains("lefthook.yml"), "{err}");
    assert!(err.contains("(and saving .stibbons-standards.yml failed too: "), "{err}");
    // Both failures carry the OS reason, each exactly once: the save's inside
    // the parentheses, the write's chained after them (#1578).
    let reason = std::io::Error::from(std::io::ErrorKind::PermissionDenied).to_string();
    let reason = reason.split(" (os error").next().unwrap_or(&reason).to_lowercase();
    assert_eq!(err.to_lowercase().matches(&reason).count(), 2, "{err}");
    assert!(err.trim_end().to_lowercase().contains(&format!("): {reason}")), "{err}");
    assert!(
        !err.contains("recorded the files written so far"),
        "claimed a save that failed:\n{err}"
    );
    assert!(!root.join(".stibbons-standards.yml").exists(), "state file appeared");
    let s = stdout_of(&out);
    assert!(s.contains("failed     lefthook.yml\n"), "{s}");
}
