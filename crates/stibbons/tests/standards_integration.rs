//! Integration tests for `stibbons setup standards {init,check,accept}`.
//!
//! Each test spawns the built binary in a temp directory (no git repo, so
//! language detection takes the directory-walk path and CI detection falls back
//! to `--ci` or GitHub), and asserts on exit codes, files on disk, and stdout.
//! The `git ls-files` detection path is unit-tested in `standards/detect.rs`;
//! `--templates-dir` and render.sh parity live in `standards_templates.rs`.

mod standards_common;

use std::fs;
use std::process::Command;

use standards_common::{
    assert_ok, copy_dir, shell_python_repo, standards, stdout_of, stibbons_bin, vendored_templates,
};

#[test]
fn init_writes_baseline_for_detected_slices() {
    let tmp = shell_python_repo();
    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "init");
    let s = stdout_of(&out);
    assert!(s.contains("slices [python, shell], ci [github]"), "{s}");

    let root = tmp.path();
    for f in [
        "lefthook.yml",
        "justfile",
        "tests/run.sh",
        "bin/install-tools.sh",
        ".github/workflows/ci.yml",
        ".shellcheckrc",
        "ruff.toml",
        ".stibbons-standards.yml",
    ] {
        assert!(root.join(f).is_file(), "expected {f} to be written");
    }
    assert!(!root.join(".gitlab-ci.yml").exists(), "github-only init wrote GitLab CI");

    // Slice fragments are concatenated in: both slices' lint hooks present.
    let lefthook = fs::read_to_string(root.join("lefthook.yml")).unwrap();
    assert!(lefthook.contains("shellcheck"), "shell fragment missing:\n{lefthook}");
    assert!(lefthook.contains("ruff"), "python fragment missing:\n{lefthook}");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for f in ["tests/run.sh", "bin/install-tools.sh", "bin/ruff-version.sh"] {
            let mode = fs::metadata(root.join(f)).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "{f} should be executable (mode {mode:o})");
        }
        let mode = fs::metadata(root.join("lefthook.yml")).unwrap().permissions().mode();
        assert_eq!(mode & 0o111, 0, "lefthook.yml must not be executable");
    }
}

#[test]
fn shell_only_repo_omits_python_files() {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("run.sh"), "#!/bin/sh\n").unwrap();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    assert!(tmp.path().join(".shellcheckrc").is_file());
    assert!(!tmp.path().join("ruff.toml").exists(), "python slice applied to a shell-only repo");
}

#[test]
fn ci_flag_selects_platforms() {
    let gitlab = shell_python_repo();
    assert_ok(&standards(gitlab.path(), &["init", "--ci", "gitlab"]), "init --ci gitlab");
    assert!(gitlab.path().join(".gitlab-ci.yml").is_file());
    assert!(!gitlab.path().join(".github/workflows/ci.yml").exists());
    let lefthook = fs::read_to_string(gitlab.path().join("lefthook.yml")).unwrap();
    assert!(!lefthook.contains("actionlint"), "GitHub-only hook in a GitLab render");

    let both = shell_python_repo();
    assert_ok(&standards(both.path(), &["init", "--ci", "github,gitlab"]), "init --ci both");
    assert!(both.path().join(".gitlab-ci.yml").is_file());
    assert!(both.path().join(".github/workflows/ci.yml").is_file());
}

#[test]
fn rerun_preserves_user_edits_unless_forced() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");

    let path = tmp.path().join("ruff.toml");
    let original = fs::read_to_string(&path).unwrap();
    let edited = format!("{original}# local tweak\n");
    fs::write(&path, &edited).unwrap();

    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "re-init");
    assert!(stdout_of(&out).contains("skip       ruff.toml"), "{}", stdout_of(&out));
    assert_eq!(fs::read_to_string(&path).unwrap(), edited, "re-init clobbered a user edit");

    // A second re-init still recognizes the edit as the user's (provenance
    // hash preserved across the skip), rather than adopting it as "ours".
    assert_ok(&standards(tmp.path(), &["init"]), "re-re-init");
    assert_eq!(fs::read_to_string(&path).unwrap(), edited);

    assert_ok(&standards(tmp.path(), &["init", "--force"]), "init --force");
    assert_eq!(fs::read_to_string(&path).unwrap(), original, "--force did not restore");
}

#[test]
fn preexisting_unrecorded_file_is_not_clobbered() {
    let tmp = shell_python_repo();
    fs::write(tmp.path().join("justfile"), "default:\n    echo mine\n").unwrap();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    assert_eq!(
        fs::read_to_string(tmp.path().join("justfile")).unwrap(),
        "default:\n    echo mine\n"
    );
}

/// A write failure partway through `init` must still record the files it
/// already wrote, so a later run updates them rather than reporting them as
/// user edits (#1542).
#[cfg(unix)]
#[test]
fn partial_init_failure_records_written_files() {
    use std::os::unix::fs::PermissionsExt;

    let tmp = shell_python_repo();
    let root = tmp.path();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&vendored_templates(), tpl.path());
    let tpl_arg = tpl.path().to_str().unwrap();

    // `tests/run.sh` follows lefthook.yml and justfile in manifest order; a
    // read-only `tests/` makes its write fail after those two are written.
    let tests_dir = root.join("tests");
    fs::create_dir(&tests_dir).unwrap();
    fs::set_permissions(&tests_dir, fs::Permissions::from_mode(0o555)).unwrap();
    if fs::write(tests_dir.join("probe"), b"").is_ok() {
        eprintln!("skipping: running with permission to write a 0555 dir (root?)");
        return;
    }

    let out = standards(root, &["init", "--templates-dir", tpl_arg]);
    assert!(!out.status.success(), "init into a read-only dir must fail");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("failed to write") && err.contains("tests/run.sh"), "{err}");
    assert!(root.join("lefthook.yml").is_file(), "lefthook.yml should precede the failure");
    assert!(root.join(".stibbons-standards.yml").is_file(), "no state saved after failure");

    let out = standards(root, &["check", "--templates-dir", tpl_arg]);
    let s = stdout_of(&out);
    assert!(s.contains("✓ lefthook.yml\n"), "{s}");
    assert!(s.contains("tests/run.sh (missing)"), "{s}");

    // Fix the cause and change a lefthook fragment: lefthook.yml is now an
    // unedited stibbons file the templates would change, so it updates.
    fs::set_permissions(&tests_dir, fs::Permissions::from_mode(0o755)).unwrap();
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

#[test]
fn rerun_restores_deleted_file() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    fs::remove_file(tmp.path().join("dprint.json")).unwrap();
    assert_ok(&standards(tmp.path(), &["init"]), "re-init");
    assert!(tmp.path().join("dprint.json").is_file());
}

#[test]
fn check_is_clean_after_init() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let out = standards(tmp.path(), &["check"]);
    assert_ok(&out, "check");
    assert!(stdout_of(&out).contains("up to date"), "{}", stdout_of(&out));
}

#[test]
fn check_fails_on_missing_file() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    fs::remove_file(tmp.path().join("tests/run.sh")).unwrap();

    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1), "missing file must exit 1");
    assert!(stdout_of(&out).contains("tests/run.sh (missing)"), "{}", stdout_of(&out));
}

#[test]
fn check_fails_on_modified_file_until_accepted() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let path = tmp.path().join("_typos.toml");
    let edited = format!("{}# per-repo edit\n", fs::read_to_string(&path).unwrap());
    fs::write(&path, &edited).unwrap();

    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1), "modified file must exit 1");
    assert!(stdout_of(&out).contains("_typos.toml (modified)"), "{}", stdout_of(&out));

    let out = standards(tmp.path(), &["accept", "_typos.toml"]);
    assert_ok(&out, "accept");

    let out = standards(tmp.path(), &["check"]);
    assert_ok(&out, "check after accept");
    assert!(stdout_of(&out).contains("_typos.toml (accepted local edit)"), "{}", stdout_of(&out));

    // An accepted edit survives a plain re-init…
    assert_ok(&standards(tmp.path(), &["init"]), "re-init");
    assert_eq!(fs::read_to_string(&path).unwrap(), edited, "re-init clobbered an accepted edit");
    assert_ok(&standards(tmp.path(), &["check"]), "check after re-init");

    // …and editing it again re-flags drift.
    fs::write(&path, format!("{edited}# another\n")).unwrap();
    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stdout_of(&out).contains("_typos.toml (modified)"), "{}", stdout_of(&out));
}

#[test]
fn accept_without_paths_takes_every_modified_file() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    for f in ["_typos.toml", ".gitleaks.toml"] {
        let p = tmp.path().join(f);
        fs::write(&p, format!("{}# edit\n", fs::read_to_string(&p).unwrap())).unwrap();
    }
    let out = standards(tmp.path(), &["accept"]);
    assert_ok(&out, "accept");
    let s = stdout_of(&out);
    assert!(s.contains("accepted _typos.toml") && s.contains("accepted .gitleaks.toml"), "{s}");
    assert_ok(&standards(tmp.path(), &["check"]), "check");
}

#[test]
fn accept_ok_file_is_noop_with_note() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let state = tmp.path().join(".stibbons-standards.yml");
    let before = fs::read(&state).unwrap();

    let out = standards(tmp.path(), &["accept", "_typos.toml"]);
    assert_ok(&out, "accept ok file");
    let s = stdout_of(&out);
    assert!(s.contains("skipped _typos.toml (already matches the baseline"), "{s}");
    assert!(!s.contains("accepted _typos.toml"), "{s}");
    assert_eq!(fs::read(&state).unwrap(), before, "accepting an Ok file changed the state");
}

#[test]
fn accept_stale_file_warns() {
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&vendored_templates(), tpl.path());
    let tpl_arg = tpl.path().to_str().unwrap();
    assert_ok(&standards(tmp.path(), &["init", "--templates-dir", tpl_arg]), "init");
    let frag = tpl.path().join("core/dprint.json.tmpl");
    fs::write(&frag, format!("{}\n", fs::read_to_string(&frag).unwrap())).unwrap();

    let out = standards(tmp.path(), &["accept", "dprint.json", "--templates-dir", tpl_arg]);
    assert_ok(&out, "accept stale file");
    let s = stdout_of(&out);
    assert!(s.contains("warning: dprint.json is stale"), "{s}");
    assert!(s.contains("pins it against template updates"), "{s}");
    assert!(s.contains("accepted dprint.json"), "{s}");

    let out = standards(tmp.path(), &["check", "--templates-dir", tpl_arg]);
    assert_ok(&out, "check after accepting stale file");
    assert!(stdout_of(&out).contains("dprint.json (accepted local edit)"), "{}", stdout_of(&out));
}

#[test]
fn accept_rejects_non_baseline_path() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let out = standards(tmp.path(), &["accept", "app.py"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("not a repo-baseline file"));
}

#[test]
fn check_without_state_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("run `stibbons setup standards init`"));
}

#[test]
fn dry_run_writes_nothing() {
    let tmp = shell_python_repo();
    let out = standards(tmp.path(), &["init", "--dry-run"]);
    assert_ok(&out, "init --dry-run");
    assert!(stdout_of(&out).contains("create     lefthook.yml"));
    assert!(!tmp.path().join("lefthook.yml").exists());
    assert!(!tmp.path().join(".stibbons-standards.yml").exists());
}

#[test]
fn unknown_lang_and_ci_are_rejected_before_writing() {
    let tmp = shell_python_repo();
    let out = standards(tmp.path(), &["init", "--lang", "cobol"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown language 'cobol'"));

    let out = standards(tmp.path(), &["init", "--ci", "jenkins"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown CI platform 'jenkins'"));
    assert!(!tmp.path().join("lefthook.yml").exists(), "a rejected run wrote files");
}

#[test]
fn rerun_reuses_stored_selection() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init", "--lang", "shell", "--ci", "gitlab"]), "init");
    let out = standards(tmp.path(), &["init"]);
    assert_ok(&out, "re-init");
    assert!(stdout_of(&out).contains("slices [shell], ci [gitlab]"), "{}", stdout_of(&out));
    assert!(!tmp.path().join("ruff.toml").exists());
}

#[cfg(unix)]
#[test]
fn refuses_to_write_through_symlinked_dir() {
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), tmp.path().join(".github")).unwrap();

    let out = standards(tmp.path(), &["init"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("is a symlink"));
    assert!(!outside.path().join("workflows/ci.yml").exists(), "wrote through the symlink");
    assert!(!tmp.path().join("lefthook.yml").exists(), "partial write before refusing");
}

#[cfg(unix)]
#[test]
fn refuses_symlinked_leaf_and_dangling_link() {
    // A symlinked target file: writing would clobber the link's target.
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    let victim = outside.path().join("victim");
    fs::write(&victim, "precious\n").unwrap();
    std::os::unix::fs::symlink(&victim, tmp.path().join("justfile")).unwrap();
    let out = standards(tmp.path(), &["init", "--force"]);
    assert!(!out.status.success(), "init wrote through a symlinked file");
    assert!(String::from_utf8_lossy(&out.stderr).contains("justfile is a symlink"));
    assert_eq!(fs::read_to_string(&victim).unwrap(), "precious\n");

    // A dangling link reads as "missing" (Created) — the guard must still fire.
    let tmp = shell_python_repo();
    let target = outside.path().join("would-be-created");
    std::os::unix::fs::symlink(&target, tmp.path().join("dprint.json")).unwrap();
    let out = standards(tmp.path(), &["init"]);
    assert!(!out.status.success(), "init followed a dangling symlink");
    assert!(String::from_utf8_lossy(&out.stderr).contains("dprint.json is a symlink"));
    assert!(!target.exists(), "dangling symlink target was created");
}

#[cfg(unix)]
#[test]
fn refuses_to_chmod_unchanged_script_through_symlink() {
    use std::os::unix::fs::PermissionsExt;

    // The link's target already holds the exact rendered bytes, so the target
    // classifies Unchanged — it is never written, but it WOULD be chmodded.
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let outside = tempfile::tempdir().unwrap();
    let ext = outside.path().join("run.sh");
    fs::copy(tmp.path().join("tests/run.sh"), &ext).unwrap();
    fs::set_permissions(&ext, fs::Permissions::from_mode(0o600)).unwrap();
    fs::remove_file(tmp.path().join("tests/run.sh")).unwrap();
    std::os::unix::fs::symlink(&ext, tmp.path().join("tests/run.sh")).unwrap();

    let out = standards(tmp.path(), &["init"]);
    assert!(!out.status.success(), "init chmodded through a symlink");
    assert!(String::from_utf8_lossy(&out.stderr).contains("tests/run.sh is a symlink"));
    assert_eq!(fs::metadata(&ext).unwrap().permissions().mode() & 0o777, 0o600);
}

#[cfg(unix)]
#[test]
fn refuses_to_save_state_through_symlink() {
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    let ext = outside.path().join("state.yml");
    std::os::unix::fs::symlink(&ext, tmp.path().join(".stibbons-standards.yml")).unwrap();
    let out = standards(tmp.path(), &["init"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains(".stibbons-standards.yml is a symlink"));
    assert!(!ext.exists(), "state written through a symlink");
    assert!(!tmp.path().join("lefthook.yml").exists(), "partial write before refusing");
}

#[cfg(unix)]
#[test]
fn accept_refuses_to_save_state_through_symlink() {
    // A checkout that ships the state file as a link: `accept` must not write
    // through it, exactly like `init`.
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    let state = tmp.path().join(".stibbons-standards.yml");
    let outside = tempfile::tempdir().unwrap();
    let ext = outside.path().join("state.yml");
    fs::rename(&state, &ext).unwrap();
    let before = fs::read_to_string(&ext).unwrap();
    std::os::unix::fs::symlink(&ext, &state).unwrap();
    let p = tmp.path().join("_typos.toml");
    fs::write(&p, format!("{}# edit\n", fs::read_to_string(&p).unwrap())).unwrap();

    let out = standards(tmp.path(), &["accept", "_typos.toml"]);
    assert!(!out.status.success(), "accept wrote through a symlinked state file");
    assert!(String::from_utf8_lossy(&out.stderr).contains(".stibbons-standards.yml is a symlink"));
    assert_eq!(fs::read_to_string(&ext).unwrap(), before, "link target was modified");
}

#[cfg(unix)]
#[test]
fn dry_run_ignores_symlinked_state_file() {
    // --dry-run saves nothing, so a linked state file is not a write target:
    // the run succeeds and leaves both the link and its target untouched.
    let tmp = shell_python_repo();
    let outside = tempfile::tempdir().unwrap();
    let ext = outside.path().join("state.yml");
    std::os::unix::fs::symlink(&ext, tmp.path().join(".stibbons-standards.yml")).unwrap();
    assert_ok(&standards(tmp.path(), &["init", "--dry-run"]), "init --dry-run");
    assert!(!ext.exists(), "dry run wrote the state file");
    assert!(!tmp.path().join("lefthook.yml").exists(), "dry run wrote a file");
}

#[test]
fn corrupt_state_file_fails_check_loudly() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init"]), "init");
    fs::write(tmp.path().join(".stibbons-standards.yml"), "files: [not, a, map\n").unwrap();
    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("failed to parse"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn gitlab_check_detects_missing_gitlab_ci() {
    let tmp = shell_python_repo();
    assert_ok(&standards(tmp.path(), &["init", "--ci", "gitlab"]), "init");
    assert_ok(&standards(tmp.path(), &["check"]), "check clean");
    fs::remove_file(tmp.path().join(".gitlab-ci.yml")).unwrap();
    let out = standards(tmp.path(), &["check"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stdout_of(&out).contains(".gitlab-ci.yml (missing)"), "{}", stdout_of(&out));
}

#[test]
fn bare_setup_still_parses_label_sync_flags() {
    // Backward compat: `stibbons setup --help` lists both the subcommand and
    // the original label-sync flags.
    let out = Command::new(stibbons_bin()).args(["setup", "--help"]).output().unwrap();
    let help = stdout_of(&out);
    assert!(help.contains("standards"), "{help}");
    assert!(help.contains("--dry-run") && help.contains("--platform"), "{help}");
}
