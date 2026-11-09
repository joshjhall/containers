//! Detect which repo-baseline language slices apply to a repository.
//!
//! The file list comes from `git ls-files` (tracked + untracked-but-not-ignored)
//! so vendored and build output the repo already ignores never votes; outside a
//! git repo it falls back to a bounded directory walk that skips the usual
//! heavy directories. Classification is pure and unit-tested separately.

use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

/// Directories the fallback walk never descends into.
const SKIP_DIRS: &[&str] = &[".git", "target", "node_modules", ".venv", "venv", ".worktrees"];

/// Upper bound on files the fallback walk visits, so a huge non-git tree
/// cannot stall `init`.
const WALK_LIMIT: usize = 50_000;

/// Detect the language slices present under `root`, restricted to `known`
/// (the slices the manifest defines).
#[must_use]
pub fn detect_slices(root: &Path, known: &BTreeSet<String>) -> BTreeSet<String> {
    let files = git_files(root).unwrap_or_else(|| walk_files(root));
    classify(root, &files).into_iter().filter(|s| known.contains(s)).collect()
}

/// Map repo-relative file paths to language slices.
///
/// - `shell`: a `*.sh`/`*.bash` file, or an extensionless file under `bin/`
///   whose first line is a `sh`/`bash` shebang.
/// - `python`: a `*.py` file, or `pyproject.toml`.
#[must_use]
pub fn classify(root: &Path, files: &[String]) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for f in files {
        let name = f.rsplit('/').next().unwrap_or(f);
        let ext = Path::new(name).extension().and_then(|e| e.to_str());
        match ext {
            Some("sh" | "bash") => {
                found.insert("shell".to_string());
            }
            Some("py") => {
                found.insert("python".to_string());
            }
            Some("toml") if name == "pyproject.toml" => {
                found.insert("python".to_string());
            }
            None if f.starts_with("bin/") && has_shell_shebang(&root.join(f)) => {
                found.insert("shell".to_string());
            }
            _ => {}
        }
    }
    found
}

/// Bytes read when probing a shebang: a `#!` line is far shorter, and a cap
/// keeps a hostile repo (huge file, `/dev/zero` behind a link) from stalling us.
const SHEBANG_PROBE_BYTES: u64 = 256;

/// Whether `path`'s first line is a `sh`/`bash` shebang. Only a regular file
/// (not a symlink, FIFO, or device) is opened, and only its first
/// [`SHEBANG_PROBE_BYTES`] are read.
fn has_shell_shebang(path: &Path) -> bool {
    use std::io::Read as _;
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_file() => {}
        _ => return false,
    }
    let Ok(file) = std::fs::File::open(path) else { return false };
    let mut bytes = Vec::new();
    if file.take(SHEBANG_PROBE_BYTES).read_to_end(&mut bytes).is_err() {
        return false;
    }
    let first = bytes.split(|b| *b == b'\n').next().unwrap_or_default();
    let Ok(line) = std::str::from_utf8(first) else { return false };
    let Some(rest) = line.strip_prefix("#!") else { return false };
    let mut words = rest.split_whitespace();
    let interp = words.next().unwrap_or_default();
    let interp = if interp.ends_with("/env") { words.next().unwrap_or_default() } else { interp };
    matches!(interp.rsplit('/').next(), Some("sh" | "bash"))
}

/// `git ls-files --cached --others --exclude-standard` under `root`, or `None`
/// when `root` is not a git work tree (or git is unavailable).
///
/// `root` is often a freshly cloned, untrusted repo, and `ls-files` honors
/// its `.git/config`: a `core.fsmonitor` command there runs on every call.
/// Command-line `-c` overrides beat repo-local config, so fsmonitor is pinned
/// off; `core.hooksPath` is pinned too as defense in depth (ls-files runs no
/// hooks today). Inherited repo-selecting and config-injecting env
/// ([`GIT_REPO_ENV`]) is dropped so `-C root` alone picks the repository.
fn git_files(root: &Path) -> Option<Vec<String>> {
    run_ls_files(ls_files_command(root))
}

/// Run a `git ls-files -z` command and split its NUL-separated output, or
/// `None` when git cannot run or exits non-zero.
fn run_ls_files(mut cmd: Command) -> Option<Vec<String>> {
    let out = cmd.output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        out.stdout
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect(),
    )
}

/// Env vars that would let an inherited setting pick a repo other than
/// `root` or inject config (`GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_COUNT` can
/// re-enable fsmonitor). This is git's own `git rev-parse --local-env-vars`
/// list, the set git clears when it switches into a submodule.
const GIT_REPO_ENV: &[&str] = &[
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
];

/// The hardened `git ls-files` invocation [`git_files`] runs (see there).
fn ls_files_command(root: &Path) -> Command {
    let mut cmd = Command::new("git");
    cmd.args(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"])
        .arg("-C")
        .arg(root)
        .args(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
    for var in GIT_REPO_ENV {
        cmd.env_remove(var);
    }
    cmd
}

/// Repo-relative paths of regular files under `root`, skipping [`SKIP_DIRS`]
/// and symlinks, capped at [`WALK_LIMIT`].
fn walk_files(root: &Path) -> Vec<String> {
    walk_files_capped(root, WALK_LIMIT)
}

/// [`walk_files`] with an explicit cap, so the limit is testable.
fn walk_files_capped(root: &Path, limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            if out.len() >= limit {
                return out;
            }
            let Ok(ft) = entry.file_type() else { continue };
            let path = entry.path();
            if ft.is_dir() {
                let name = entry.file_name();
                if !SKIP_DIRS.iter().any(|s| name == *s) {
                    stack.push(path);
                }
            } else if ft.is_file()
                && let Ok(rel) = path.strip_prefix(root)
            {
                let parts: Vec<String> = rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect();
                out.push(parts.join("/"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn classifies_by_extension_and_pyproject() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(classify(tmp.path(), &files(&["scripts/a.sh"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["x.bash"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["pkg/mod.py"])), set(&["python"]));
        assert_eq!(classify(tmp.path(), &files(&["pyproject.toml"])), set(&["python"]));
        assert_eq!(classify(tmp.path(), &files(&["README.md", "src/main.rs"])), set(&[]));
    }

    #[test]
    fn extensionless_bin_script_needs_shell_shebang() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("bin")).unwrap();
        std::fs::write(tmp.path().join("bin/tool"), "#!/usr/bin/env bash\necho hi\n").unwrap();
        std::fs::write(tmp.path().join("bin/plain"), "#!/bin/sh\n").unwrap();
        std::fs::write(tmp.path().join("bin/py"), "#!/usr/bin/env python3\n").unwrap();
        std::fs::write(tmp.path().join("bin/data"), "not a script\n").unwrap();

        assert_eq!(classify(tmp.path(), &files(&["bin/tool"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["bin/plain"])), set(&["shell"]));
        assert_eq!(classify(tmp.path(), &files(&["bin/py", "bin/data"])), set(&[]));
    }

    #[cfg(unix)]
    #[test]
    fn shebang_probe_ignores_symlinks_and_reads_a_bounded_prefix() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("bin")).unwrap();
        // A link to a real shell script must not count: the probe never
        // follows links (the same link could point at /dev/zero).
        std::fs::write(tmp.path().join("real.sh"), "#!/bin/bash\n").unwrap();
        std::os::unix::fs::symlink(tmp.path().join("real.sh"), tmp.path().join("bin/link"))
            .unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/link"])), set(&[]));

        // A shebang followed by far more than the probe window still matches.
        let big = format!("#!/bin/sh\n{}", "x".repeat(1 << 20));
        std::fs::write(tmp.path().join("bin/big"), big).unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/big"])), set(&["shell"]));

        // The cap is observable: an interpreter that only starts past the
        // window is never seen. An unbounded read would find `/bin/sh` after
        // the padding and match; the bounded one sees `#!` plus blanks.
        let pad = " ".repeat(usize::try_from(SHEBANG_PROBE_BYTES).unwrap());
        let late = format!("#!{pad}/bin/sh\n");
        std::fs::write(tmp.path().join("bin/late"), late).unwrap();
        assert_eq!(classify(tmp.path(), &files(&["bin/late"])), set(&[]));
    }

    #[test]
    fn detect_filters_to_known_and_walks_without_git() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("a.sh"), "").unwrap();
        std::fs::write(tmp.path().join("b.py"), "").unwrap();
        // A skipped directory must not vote.
        std::fs::create_dir(tmp.path().join("node_modules")).unwrap();
        std::fs::write(tmp.path().join("node_modules/c.py"), "").unwrap();

        assert_eq!(
            detect_slices(tmp.path(), &set(&["shell", "python"])),
            set(&["python", "shell"])
        );
        assert_eq!(detect_slices(tmp.path(), &set(&["shell"])), set(&["shell"]));
    }

    /// Runs `git` in `dir` with any inherited repo-selecting env stripped.
    #[cfg(unix)]
    fn git(dir: &Path, args: &[&str]) -> bool {
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(dir).args(args);
        for var in GIT_REPO_ENV {
            cmd.env_remove(var);
        }
        hermetic(&mut cmd);
        cmd.output().is_ok_and(|o| o.status.success())
    }

    /// Ignore the developer's global and system git config and global
    /// excludes, so nothing outside the fixture changes what
    /// `--exclude-standard` drops. With `core.excludesFile` unset, git still
    /// reads its default `$XDG_CONFIG_HOME/git/ignore`, so the key is pinned
    /// to `/dev/null` too. This must run after `ls_files_command`, whose
    /// `GIT_CONFIG_COUNT` removal it overrides. Repo-local config (which the
    /// fsmonitor test relies on) still applies.
    #[cfg(unix)]
    fn hermetic(cmd: &mut Command) -> &mut Command {
        cmd.env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "core.excludesFile")
            .env("GIT_CONFIG_VALUE_0", "/dev/null")
    }

    #[cfg(unix)]
    #[test]
    fn git_files_never_runs_repo_fsmonitor() {
        let repo = tempfile::tempdir().unwrap();
        // The marker lives outside the repo so it can never alter the list.
        let elsewhere = tempfile::tempdir().unwrap();
        let marker = elsewhere.path().join("MARKER");
        // No skip-if-missing: a silent pass would hide a regression.
        assert!(git(repo.path(), &["init", "-q"]), "git init failed");
        std::fs::write(repo.path().join("a.sh"), "").unwrap();
        assert!(git(repo.path(), &["add", "a.sh"]));
        // A hostile clone's config: fsmonitor names a command git would run.
        let hook = format!("touch '{}'; false #", marker.display());
        assert!(git(repo.path(), &["config", "core.fsmonitor", &hook]));

        // Positive control: without the override this git does run the
        // hook, so the negative assertion below cannot pass vacuously on a
        // git version that never consults fsmonitor for ls-files.
        assert!(git(repo.path(), &["ls-files", "--others"]));
        assert!(
            marker.exists(),
            "control: this git version never runs core.fsmonitor for ls-files, \
             so this test cannot observe the guard (environment limit, not a bug)"
        );
        std::fs::remove_file(&marker).unwrap();

        // Some(..) proves the git path ran, not the walk fallback.
        assert_eq!(git_files(repo.path()), Some(files(&["a.sh"])));
        assert!(!marker.exists(), "repo-local core.fsmonitor was executed");
    }

    /// Env var that turns [`hostile_env_probe`] from a no-op into a probe.
    #[cfg(unix)]
    const PROBE_ROOT_VAR: &str = "STIBBONS_DETECT_PROBE_ROOT";

    /// Prefix of the one line [`hostile_env_probe`] prints.
    #[cfg(unix)]
    const PROBE_TAG: &str = "PROBE_RESULT:";

    /// Child half of the hostile-env tests: [`run_probe`] re-runs this test
    /// binary filtered to this test, with the hostile env set on the child
    /// only, so this process's own environment is never mutated. Without
    /// [`PROBE_ROOT_VAR`] (e.g. a plain `cargo test -- --ignored`) it is a
    /// no-op.
    #[cfg(unix)]
    #[test]
    #[ignore = "child process for run_probe; does nothing when run directly"]
    fn hostile_env_probe() {
        if let Some(root) = std::env::var_os(PROBE_ROOT_VAR) {
            // libtest's `test <name> ... ` precedes this on the same line.
            println!("\n{PROBE_TAG}{:?}", git_files(Path::new(&root)));
        }
    }

    /// Hermetic git config for a child: no global/system config and no
    /// default `$XDG_CONFIG_HOME/git/ignore`. Unlike [`hermetic`] this uses
    /// no `GIT_CONFIG_COUNT`, which the hostile env below needs for itself.
    #[cfg(unix)]
    fn hermetic_child<'a>(cmd: &'a mut Command, xdg: &Path) -> &'a mut Command {
        for var in GIT_REPO_ENV {
            cmd.env_remove(var);
        }
        cmd.env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("XDG_CONFIG_HOME", xdg)
    }

    /// Run `git_files(root)` in a re-executed copy of this test binary whose
    /// environment carries `hostile`, and return the `{:?}` of its result.
    /// Panics unless the child succeeded and printed exactly one probe line,
    /// so a test filter that matches nothing can never pass vacuously.
    #[cfg(unix)]
    fn run_probe(root: &Path, hostile: &[(&str, &str)]) -> String {
        // libtest names tests by module path without the crate name.
        let module = module_path!().split_once("::").unwrap().1;
        let xdg = tempfile::tempdir().unwrap();
        let mut cmd = Command::new(std::env::current_exe().unwrap());
        cmd.arg(format!("{module}::hostile_env_probe")).args([
            "--exact",
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ]);
        hermetic_child(&mut cmd, xdg.path()).env(PROBE_ROOT_VAR, root);
        cmd.envs(hostile.iter().copied());
        let out = cmd.output().unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "probe child failed: {stdout}");
        let lines: Vec<&str> = stdout.lines().filter_map(|l| l.strip_prefix(PROBE_TAG)).collect();
        assert_eq!(lines.len(), 1, "probe did not run exactly once: {stdout}");
        lines[0].to_string()
    }

    /// Control: the same `ls-files` with `hostile` but none of the hardening
    /// (no `-c` pins, no env stripping), showing what git does unguarded.
    #[cfg(unix)]
    fn plain_ls_files(root: &Path, hostile: &[(&str, &str)]) -> Option<Vec<String>> {
        let xdg = tempfile::tempdir().unwrap();
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(root).args(["ls-files", "-z", "--cached", "--others"]);
        hermetic_child(&mut cmd, xdg.path()).envs(hostile.iter().copied());
        run_ls_files(cmd)
    }

    /// A tempdir repo holding one committed-to-index file `name`.
    #[cfg(unix)]
    fn repo_with(name: &str) -> tempfile::TempDir {
        let repo = tempfile::tempdir().unwrap();
        assert!(git(repo.path(), &["init", "-q"]), "git init failed");
        std::fs::write(repo.path().join(name), "").unwrap();
        assert!(git(repo.path(), &["add", name]));
        repo
    }

    #[cfg(unix)]
    #[test]
    fn git_files_ignores_inherited_git_dir() {
        let root = repo_with("a.sh");
        let decoy = repo_with("decoy.py");
        let git_dir = decoy.path().join(".git");
        let hostile = [("GIT_DIR", git_dir.to_str().unwrap())];

        // Positive control: unguarded git reads the decoy's index, listing a
        // file that exists only in the decoy.
        let plain = plain_ls_files(root.path(), &hostile).expect("control ls-files failed");
        assert!(
            plain.iter().any(|f| f == "decoy.py"),
            "control: inherited GIT_DIR was not honored: {plain:?}"
        );

        assert_eq!(run_probe(root.path(), &hostile), format!("{:?}", Some(files(&["a.sh"]))));
    }

    /// Either guard alone (the `GIT_CONFIG_COUNT` strip or the
    /// `-c core.fsmonitor=false` pin) defeats this; it proves the outcome,
    /// while `ls_files_command_pins_config_and_strips_repo_env` pins both.
    #[cfg(unix)]
    #[test]
    fn git_files_ignores_env_injected_fsmonitor() {
        let root = repo_with("a.sh");
        // The marker lives outside the repo so it can never alter the list.
        let elsewhere = tempfile::tempdir().unwrap();
        let marker = elsewhere.path().join("MARKER");
        let hook = format!("touch '{}'; false #", marker.display());
        let hostile = [
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "core.fsmonitor"),
            ("GIT_CONFIG_VALUE_0", hook.as_str()),
        ];

        // Positive control: unguarded git runs the env-injected hook.
        assert!(plain_ls_files(root.path(), &hostile).is_some());
        assert!(
            marker.exists(),
            "control: this git never ran an env-injected core.fsmonitor for \
             ls-files, so this test cannot observe the guard (environment limit)"
        );
        std::fs::remove_file(&marker).unwrap();

        assert_eq!(run_probe(root.path(), &hostile), format!("{:?}", Some(files(&["a.sh"]))));
        assert!(!marker.exists(), "env-injected core.fsmonitor was executed");
    }

    /// Pins the guards the fsmonitor test cannot observe: the hooksPath
    /// override (ls-files runs no hooks) and the repo-selecting env removal.
    /// Asserting on the builder avoids mutating this process's environment;
    /// the runtime effect of the removal is proven by
    /// `git_files_ignores_inherited_git_dir` and
    /// `git_files_ignores_env_injected_fsmonitor`.
    #[test]
    fn ls_files_command_pins_config_and_strips_repo_env() {
        let cmd = ls_files_command(Path::new("/r"));
        let args: Vec<_> = cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect();
        let pos = |s: &str| args.iter().position(|a| a == s).unwrap();
        // `-c` only binds as a global option, i.e. before the subcommand.
        assert!(pos("core.fsmonitor=false") < pos("ls-files"));
        assert!(pos("core.hooksPath=/dev/null") < pos("ls-files"));
        assert_eq!(args[pos("core.fsmonitor=false") - 1], "-c");
        assert_eq!(args[pos("core.hooksPath=/dev/null") - 1], "-c");

        let removed: BTreeSet<String> = cmd
            .get_envs()
            .filter(|(_, v)| v.is_none())
            .map(|(k, _)| k.to_string_lossy().into_owned())
            .collect();
        let must = [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
        ];
        for var in must {
            assert!(removed.contains(var), "{var} is not stripped");
        }
        assert_eq!(removed.len(), GIT_REPO_ENV.len());
    }

    #[test]
    fn walk_skips_heavy_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("target/debug")).unwrap();
        std::fs::write(tmp.path().join("target/debug/x.py"), "").unwrap();
        std::fs::create_dir(tmp.path().join("src")).unwrap();
        std::fs::write(tmp.path().join("src/y.sh"), "").unwrap();
        assert_eq!(walk_files(tmp.path()), ["src/y.sh"]);
    }

    /// The path real repos take: ignored files never vote, untracked ones
    /// do, and the NUL split keeps odd names whole. The fixture is chosen so
    /// the walk fallback would answer differently (`{python, shell}`), which
    /// separates the two paths.
    #[cfg(unix)]
    #[test]
    fn git_files_honors_exclude_standard_and_others() {
        let repo = tempfile::tempdir().unwrap();
        let root = repo.path();
        // No skip-if-missing: a silent pass would hide a regression.
        assert!(git(root, &["init", "-q"]), "git init failed");
        std::fs::write(root.join(".gitignore"), "vendor/\n").unwrap();
        assert!(git(root, &["add", ".gitignore"]));
        std::fs::create_dir(root.join("vendor")).unwrap();
        // Ignored: only `--exclude-standard` keeps it from voting python.
        std::fs::write(root.join("vendor/x.py"), "").unwrap();
        // Untracked, not ignored: only `--others` lists it.
        std::fs::write(root.join("run.sh"), "").unwrap();
        // Without `-z`, git C-quotes this name and the split mangles it.
        let odd = "a b\nc.txt";
        std::fs::write(root.join(odd), "").unwrap();

        // The production command and parser, isolated from global excludes.
        let mut cmd = ls_files_command(root);
        hermetic(&mut cmd);
        let mut listed = run_ls_files(cmd).expect("git path did not run");
        listed.sort();
        assert_eq!(listed, files(&[".gitignore", odd, "run.sh"]));

        assert_eq!(classify(root, &listed), set(&["shell"]));

        // `detect_slices` must take the git path. This holds whatever the
        // developer's global excludes are: the repo's own `.gitignore` drops
        // `vendor/x.py`, so git never votes python while the walk always does.
        let real = classify(root, &git_files(root).expect("git path did not run"));
        assert!(!real.contains("python"), "{real:?}");
        assert_eq!(detect_slices(root, &set(&["shell", "python"])), real);
        // Control: the walk over the same tree does see the ignored file.
        assert_eq!(classify(root, &walk_files(root)), set(&["python", "shell"]));
    }

    #[cfg(unix)]
    #[test]
    fn git_files_is_none_outside_a_work_tree() {
        let tmp = tempfile::tempdir().unwrap();
        // Controls: `None` must come from "not a work tree", not from git
        // being absent, and not from a TMPDIR that sits inside some repo
        // (git searches parent directories).
        assert!(git(tmp.path(), &["--version"]), "git is not runnable");
        // rev-parse exits 0 and prints `false` inside a `.git` dir, so read
        // its answer rather than its exit code.
        let mut probe = Command::new("git");
        probe.arg("-C").arg(tmp.path()).args(["rev-parse", "--is-inside-work-tree"]);
        for var in GIT_REPO_ENV {
            probe.env_remove(var);
        }
        let inside =
            probe.output().is_ok_and(|o| o.status.success() && o.stdout.trim_ascii() == b"true");
        assert!(
            !inside,
            "control: TMPDIR is inside a git work tree (environment limit, not a bug)"
        );
        // `-C` to a non-repo makes git fail, which selects the walk fallback.
        assert_eq!(git_files(tmp.path()), None);
    }

    #[cfg(unix)]
    #[test]
    fn walk_skips_symlinked_dirs_and_files() {
        use std::os::unix::fs::symlink;
        let tmp = tempfile::tempdir().unwrap();
        let elsewhere = tempfile::tempdir().unwrap();
        std::fs::write(elsewhere.path().join("z.py"), "").unwrap();
        std::fs::write(elsewhere.path().join("real.sh"), "").unwrap();
        std::fs::write(tmp.path().join("a.txt"), "").unwrap();
        symlink(elsewhere.path(), tmp.path().join("linked_dir")).unwrap();
        symlink(elsewhere.path().join("real.sh"), tmp.path().join("link.sh")).unwrap();
        // A link-following walk would also return linked_dir/z.py,
        // linked_dir/real.sh, and link.sh.
        assert_eq!(walk_files(tmp.path()), ["a.txt"]);
    }

    #[test]
    fn walk_stops_at_limit() {
        let tmp = tempfile::tempdir().unwrap();
        for i in 0..5 {
            std::fs::write(tmp.path().join(format!("f{i}.txt")), "").unwrap();
        }
        assert_eq!(walk_files_capped(tmp.path(), 3).len(), 3);
        assert_eq!(walk_files_capped(tmp.path(), 10).len(), 5);
    }

    /// The cap must hold across directories, not just within one: a cap
    /// counted per directory passes [`walk_stops_at_limit`]'s flat tree but
    /// returns all 6 files here for a limit of 4. `target/` (a [`SKIP_DIRS`]
    /// entry) and the symlink must never count toward the cap.
    ///
    /// Swapping the inner `return out` for `break` is an equivalent mutant
    /// (each later directory stops on its first entry, so the output is
    /// identical); no output-based test can tell them apart.
    #[cfg(unix)]
    #[test]
    fn walk_cap_holds_across_nested_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        for (dir, range) in [("a", 0..3), ("b", 3..6)] {
            std::fs::create_dir(root.join(dir)).unwrap();
            for i in range {
                std::fs::write(root.join(dir).join(format!("f{i}.txt")), "").unwrap();
            }
        }
        std::fs::create_dir(root.join("target")).unwrap();
        std::fs::write(root.join("target/t.txt"), "").unwrap();
        std::os::unix::fs::symlink(root.join("a/f0.txt"), root.join("link.txt")).unwrap();

        let real = set(&["a/f0.txt", "a/f1.txt", "a/f2.txt", "b/f3.txt", "b/f4.txt", "b/f5.txt"]);
        // Control: uncapped, the walk sees exactly the six regular files.
        let all: BTreeSet<String> = walk_files_capped(root, 100).into_iter().collect();
        assert_eq!(all, real);

        let capped = walk_files_capped(root, 4);
        assert_eq!(capped.len(), 4, "cap overshot: {capped:?}");
        let unique: BTreeSet<String> = capped.iter().cloned().collect();
        assert_eq!(unique.len(), 4, "duplicate paths: {capped:?}");
        assert!(unique.is_subset(&real), "non-regular or skipped path: {capped:?}");
    }
}
