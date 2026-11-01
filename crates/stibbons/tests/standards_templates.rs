//! `setup standards` against a `--templates-dir` on disk, and byte parity of
//! the embedded templates with librarian's reference `render.sh`.

mod standards_common;

use std::fs;
use std::path::PathBuf;
use std::process::Command;

use standards_common::{
    assert_ok, copy_dir, shell_python_repo, standards, stdout_of, tree, vendored_templates,
};

#[test]
fn check_flags_stale_file_when_templates_change() {
    // Init from a copy of the templates, then change a fragment: the unedited
    // file is now stale, and re-init updates it in place.
    let tmp = shell_python_repo();
    let tpl = tempfile::tempdir().unwrap();
    copy_dir(&vendored_templates(), tpl.path());
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
    copy_dir(&vendored_templates(), tpl.path());
    fs::remove_file(tpl.path().join("core/dprint.json.tmpl")).unwrap();
    let out = standards(tmp.path(), &["init", "--templates-dir", tpl.path().to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("source not found: core/dprint.json.tmpl"), "{err}");
    assert!(!tmp.path().join("dprint.json").exists());
}

/// Default location of librarian's reference renderer in the dev image.
const DEFAULT_RENDER_SH: &str =
    "/opt/librarian/plugins/dev-core/skills/repo-baseline/templates/render.sh";

/// Byte parity with librarian's reference renderer.
///
/// `LIBRARIAN_RENDER_SH` overrides the renderer path. When the renderer is
/// absent the test skips, unless `REQUIRE_LIBRARIAN_PARITY=1` (set in CI),
/// which turns the skip into a failure so parity cannot go green unrun.
#[test]
fn matches_librarian_render_sh() {
    let render = std::env::var_os("LIBRARIAN_RENDER_SH")
        .map_or_else(|| PathBuf::from(DEFAULT_RENDER_SH), PathBuf::from);
    if !render.is_file() {
        assert!(
            std::env::var("REQUIRE_LIBRARIAN_PARITY").as_deref() != Ok("1"),
            "REQUIRE_LIBRARIAN_PARITY=1 but {} is not present",
            render.display()
        );
        eprintln!("skipping: {} not present", render.display());
        return;
    }
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
            .env("RENDER_MANIFEST", vendored_templates().join("manifest.tsv"))
            .output()
            .unwrap();
        assert_ok(&status, "render.sh");

        assert_eq!(
            tree(ours.path()),
            tree(theirs.path()),
            "stibbons and render.sh disagree for --lang {slices} --ci {ci}"
        );
    }
}
