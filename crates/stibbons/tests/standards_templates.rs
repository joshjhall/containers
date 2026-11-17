//! `setup standards` against a `--templates-dir` on disk, and byte parity of
//! the embedded templates with containers-db's reference `render.sh` at the
//! commit they were vendored from.

mod standards_common;

use std::fs;
use std::path::{Path, PathBuf};
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

/// Git variables that would redirect `git -C <repo>` away from `<repo>` when
/// leaked from a hook or worktree context (#1745).
const GIT_ENV_LEAKS: [&str; 5] =
    ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];

fn git(dir: &Path) -> Command {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(dir);
    for var in GIT_ENV_LEAKS {
        cmd.env_remove(var);
    }
    cmd
}

fn is_git_checkout(dir: &Path) -> bool {
    git(dir).args(["rev-parse", "--git-dir"]).output().is_ok_and(|o| o.status.success())
}

/// The containers-db checkout to read `render.sh` from, resolved like
/// `bin/sync-repo-baseline.sh`: `CONTAINERS_DB_REPO`, else `$CONTAINERS_DB`
/// when it is a git checkout (in the image it names the catalog snapshot),
/// else the `containers-db` sibling of the main checkout.
fn containers_db_repo() -> PathBuf {
    if let Some(repo) = std::env::var_os("CONTAINERS_DB_REPO").filter(|v| !v.is_empty()) {
        return PathBuf::from(repo);
    }
    if let Some(db) =
        std::env::var_os("CONTAINERS_DB").map(PathBuf::from).filter(|d| is_git_checkout(d))
    {
        return db;
    }
    // Through the common git dir, so a run from .worktrees/<name> still finds
    // the sibling of the main checkout.
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let common = git(&here)
        .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()));
    let main = common
        .as_deref()
        .and_then(Path::parent)
        .map_or_else(|| here.join("../.."), Path::to_path_buf);
    main.join("../containers-db")
}

/// The containers-db commit the vendored templates come from: `SOURCE` must be
/// exactly `containers-db <40-hex sha>` (the shape bin/sync-repo-baseline.sh
/// writes), so the renderer is never read from a branch.
fn pinned_sha() -> String {
    let source = fs::read_to_string(vendored_templates().join("SOURCE")).unwrap();
    let sha = source
        .strip_suffix('\n')
        .and_then(|l| l.strip_prefix("containers-db "))
        .filter(|s| s.len() == 40 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
        .unwrap_or_else(|| panic!("SOURCE is not 'containers-db <full sha>': {source:?}"));
    sha.to_owned()
}

/// `render.sh` as committed at `sha`, or `None` when that commit (or the
/// checkout) is not available.
fn render_sh_at(repo: &Path, sha: &str) -> Option<Vec<u8>> {
    let out =
        git(repo).args(["show", &format!("{sha}:baseline/templates/render.sh")]).output().ok()?;
    out.status.success().then_some(out.stdout)
}

/// Byte parity with containers-db's reference renderer, at the SHA recorded in
/// the vendored `SOURCE` — the same commit the embedded templates come from.
///
/// The renderer is read from that commit (`git show`), never a working tree
/// or branch. `CONTAINERS_DB_REPO` overrides the checkout. When the checkout
/// or the pinned commit is absent the test skips, unless
/// `REQUIRE_BASELINE_PARITY=1` (set in CI), which turns the skip into a
/// failure so parity cannot go green unrun.
#[test]
fn matches_baseline_render_sh() {
    let sha = pinned_sha();
    let repo = containers_db_repo();
    let Some(script) = render_sh_at(&repo, &sha) else {
        assert!(
            std::env::var("REQUIRE_BASELINE_PARITY").as_deref() != Ok("1"),
            "REQUIRE_BASELINE_PARITY=1 but baseline/templates/render.sh at {sha} is not in {}",
            repo.display()
        );
        eprintln!("skipping: baseline/templates/render.sh at {sha} not in {}", repo.display());
        return;
    };
    let bin = tempfile::tempdir().unwrap();
    let render = bin.path().join("render.sh");
    fs::write(&render, script).unwrap();

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
