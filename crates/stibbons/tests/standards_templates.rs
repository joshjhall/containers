//! `setup standards` against a `--templates-dir` on disk, and byte parity of
//! the embedded templates with containers-db's reference `render.sh` at the
//! pinned snapshot they were compiled from.

mod standards_common;

use std::fs;

use standards_common::{
    assert_ok, baseline_templates, copy_dir, shell_python_repo, standards, stdout_of,
};

#[test]
fn check_flags_stale_file_when_templates_change() {
    // Init from a copy of the templates, then change a fragment: the unedited
    // file is now stale, and re-init updates it in place.
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&baseline_templates(), tpl.path());
    let tpl_arg = tpl.path().to_str().unwrap();

    assert_ok(&standards(tmp.path(), &["init", "--templates-dir", tpl_arg]), "init");
    let frag = tpl.path().join("core/dprint.json.tmpl");
    fs::write(&frag, format!("{}\n", fs::read_to_string(&frag).unwrap())).unwrap();

    let out = standards(tmp.path(), &["check", "--templates-dir", tpl_arg]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stdout_of(&out).contains("dprint.json (stale"), "{}", stdout_of(&out));

    let out = standards(tmp.path(), &["init", "--templates-dir", tpl_arg]);
    assert_ok(&out, "re-init");
    assert!(stdout_of(&out).contains("update     dprint.json"), "{}", stdout_of(&out));
    assert_ok(&standards(tmp.path(), &["check", "--templates-dir", tpl_arg]), "check");
}

#[test]
fn templates_dir_without_manifest_errors() {
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    let out = standards(tmp.path(), &["init", "--templates-dir", tpl.path().to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    let want = format!("manifest.tsv not found in {}", tpl.path().display());
    assert!(err.contains(&want), "{err}");
    assert!(!tmp.path().join(".stibbons-standards.yml").exists());
}

#[test]
fn templates_dir_manifest_with_missing_source_errors() {
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&baseline_templates(), tpl.path());
    fs::remove_file(tpl.path().join("core/dprint.json.tmpl")).unwrap();
    let out = standards(tmp.path(), &["init", "--templates-dir", tpl.path().to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("source not found: core/dprint.json.tmpl"), "{err}");
    assert!(!tmp.path().join("dprint.json").exists());
}

/// Byte parity with containers-db's reference renderer at the pinned snapshot.
///
/// `render.sh` and `manifest.tsv` come from `repo_baseline::TEMPLATES_DIR`: the
/// cargo git checkout of the exact rev the embedded templates were compiled
/// from, so there is no checkout to resolve and nothing to skip. Covers every
/// mode — tracked files, `once` stubs, and the `AGENTS.md` symlink.
// Unix only: `render.sh` makes `AGENTS.md` with `ln -s`, which Windows shells
// emulate (often as a copy) while stibbons leaves the link to the user there.
#[cfg(unix)]
#[test]
fn matches_baseline_render_sh() {
    use standards_common::tree;
    use std::path::Path;
    use std::process::Command;

    let render = Path::new(repo_baseline::TEMPLATES_DIR).join("render.sh");
    for (slices, ci) in
        [("shell,python", "github"), ("shell", "gitlab"), ("python", "github,gitlab")]
    {
        let ours = tempfile::tempdir().unwrap();
        let out = standards(ours.path(), &["init", "--lang", slices, "--ci", ci]);
        assert_ok(&out, "init");
        fs::remove_file(ours.path().join(".stibbons-standards.yml")).unwrap();

        let theirs = tempfile::tempdir().unwrap();
        let status = Command::new("bash")
            .arg(&render)
            .args(["--slices", slices, "--ci", ci, "--out"])
            .arg(theirs.path())
            .output()
            .unwrap();
        assert_ok(&status, "render.sh");

        let want = tree(theirs.path());
        assert!(
            want.iter().any(|(p, _, _)| p == "AGENTS.md"),
            "render.sh wrote no AGENTS.md link; parity would not cover link mode"
        );
        assert_eq!(
            tree(ours.path()),
            want,
            "stibbons and render.sh disagree for --lang {slices} --ci {ci}"
        );
    }
}
