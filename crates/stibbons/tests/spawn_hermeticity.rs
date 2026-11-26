//! Hermeticity of the stibbons spawns made by the shared test helpers (#1694,
//! #1746).
//!
//! Three layers:
//! - `stibbons_cmd_is_hermetic`: the builder's env config (scrubbed git vars,
//!   pinned identity).
//! - `sync_replay_uses_injected_identity`: behavioural. A real
//!   commit-replaying `worktree sync` runs under a git env with **no** identity
//!   source except the one `stibbons_cmd` injects. A negative control proves
//!   that env really is identity-less.
//! - `run_helpers_route_through_stibbons_cmd`: structural. Every `run_*`
//!   helper in `common/mod.rs` must spawn through `stibbons_cmd`, so a helper
//!   that bypasses it fails here.

mod common;

use std::path::Path;
use std::process::{Command, Output};

use common::{commit_file, init_repo, rev_parse_head, run_worktree, write_igor_yml};

/// #1694: every stibbons spawn must strip the enclosing git env and carry a
/// fixed identity, so stibbons' own git children (`worktree add`, `rebase`)
/// can neither retarget the outer repo nor fail on a host with no gitconfig.
#[test]
fn stibbons_cmd_is_hermetic() {
    let dir = tempfile::tempdir().expect("tempdir");
    let cmd = common::stibbons_cmd("worktree", dir.path());
    let envs: std::collections::HashMap<_, _> = cmd
        .get_envs()
        .map(|(k, v)| {
            (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))
        })
        .collect();

    // Pin the list itself too, so trimming it is a visible test failure.
    for must in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
        assert!(common::LEAKY_GIT_VARS.contains(&must), "{must} missing from LEAKY_GIT_VARS");
    }
    for &removed in common::LEAKY_GIT_VARS {
        assert_eq!(envs.get(removed), Some(&None), "{removed} must be explicitly removed");
    }
    for (key, want) in [
        ("GIT_AUTHOR_NAME", common::TEST_GIT_NAME),
        ("GIT_AUTHOR_EMAIL", common::TEST_GIT_EMAIL),
        ("GIT_COMMITTER_NAME", common::TEST_GIT_NAME),
        ("GIT_COMMITTER_EMAIL", common::TEST_GIT_EMAIL),
    ] {
        assert_eq!(envs.get(key), Some(&Some(want.to_owned())), "{key} must be pinned");
    }
}

/// The identity env vars `stibbons_cmd` injects.
const IDENTITY_VARS: &[&str] =
    &["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"];

/// Builds a project whose agent01 branch carries its own commit while `main`
/// advanced on a different file, so `sync 1` must **replay** a commit (and so
/// needs a committer identity). A fast-forward needs no identity at all and
/// would make the test pass vacuously. Returns `(project, agent worktree)`.
fn replay_fixture(base: &Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let project = base.join("myapp");
    init_repo(&project);
    write_igor_yml(&project, &[], None);
    let out = run_worktree(&project, &["create", "1"]);
    assert!(out.status.success(), "create failed: {}", String::from_utf8_lossy(&out.stderr));

    let worktree = base.join("myapp-agent01");
    commit_file(&worktree, "agent.txt", "agent work\n", "agent change");
    commit_file(&project, "CHANGELOG.md", "v1\n", "advance main");
    (project, worktree)
}

/// `stibbons worktree sync 1` via `stibbons_cmd`, with every ambient identity
/// source cut off so only what the builder injects can reach git:
/// - `HOME`/`XDG_CONFIG_HOME` point at an empty dir, so there's no global gitconfig.
/// - `GIT_CONFIG_NOSYSTEM`, so there's no system gitconfig.
/// - `GIT_CONFIG_COUNT=1` replaces any inherited `GIT_CONFIG_KEY_n` entries.
///   A devcontainer injects `user.name`/`user.email`/`commit.gpgsign` this way.
///   The replacement sets `user.useConfigOnly`, so git can't guess an identity
///   from the hostname.
/// - `EMAIL`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_PARAMETERS` are removed.
fn identityless_sync(project: &Path, home: &Path) -> Command {
    let mut cmd = common::stibbons_cmd("worktree", project);
    cmd.args(["sync", "1"])
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "user.useConfigOnly")
        .env("GIT_CONFIG_VALUE_0", "true")
        .env_remove("EMAIL")
        .env_remove("GIT_CONFIG_GLOBAL")
        .env_remove("GIT_CONFIG_PARAMETERS");
    cmd
}

fn spawn(cmd: &mut Command) -> Output {
    cmd.output().expect("failed to spawn stibbons")
}

/// `git log -1 --format=<fmt>` in `dir`, trimmed.
fn log_format(dir: &Path, fmt: &str) -> String {
    let out = common::scrub_git_env(&mut Command::new("git"))
        .current_dir(dir)
        .args(["log", "-1", &format!("--format={fmt}")])
        .output()
        .expect("failed to spawn git");
    assert!(out.status.success(), "git log failed: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// #1746 AC1: a real stibbons git child depends on the identity `stibbons_cmd`
/// injects. Under an otherwise identity-less env, the replaying sync succeeds
/// and stamps the injected committer. With the injected vars removed, the same
/// sync fails, which shows nothing else supplied the identity.
#[test]
fn sync_replay_uses_injected_identity() {
    let home = tempfile::tempdir().expect("tempdir");

    // Negative control first: same env minus the injected identity must fail.
    let tmp = tempfile::tempdir().expect("tempdir");
    let (project, _) = replay_fixture(tmp.path());
    let mut cmd = identityless_sync(&project, home.path());
    for var in IDENTITY_VARS {
        cmd.env_remove(var);
    }
    let out = spawn(&mut cmd);
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "control: sync must fail with no identity source:\n{err}");
    assert!(
        err.contains("auto-detection is disabled") || err.contains("tell me who you are"),
        "control must fail for lack of an identity, not something else:\n{err}"
    );

    // Positive: identical env, injected identity left in place.
    let tmp = tempfile::tempdir().expect("tempdir");
    let (project, worktree) = replay_fixture(tmp.path());
    let tip_before_ok = rev_parse_head(&worktree);
    let out = spawn(&mut identityless_sync(&project, home.path()));
    assert!(
        out.status.success(),
        "identity-less sync failed — stibbons_cmd's identity did not reach git:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    assert_ne!(rev_parse_head(&worktree), tip_before_ok, "sync must have replayed the commit");
    let main_tip = rev_parse_head(&project);
    assert_eq!(log_format(&worktree, "%P"), main_tip, "agent commit must now sit on main's tip");
    assert_eq!(
        log_format(&worktree, "%cn <%ce>"),
        format!("{} <{}>", common::TEST_GIT_NAME, common::TEST_GIT_EMAIL),
        "the replayed commit's committer must be the injected identity"
    );
    // The empty HOME stayed empty: stibbons wrote no gitconfig behind our back.
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0, "HOME must stay empty");
}

/// Source of the shared helpers, checked structurally below.
const COMMON_SRC: &str = include_str!("common/mod.rs");

/// `line` with any `//` comment removed. A `//` only counts as a comment
/// when it sits outside a string literal (an even number of `"` before it).
/// Escaped quotes are not handled; `common/mod.rs` contains none.
fn strip_line_comment(line: &str) -> &str {
    let mut quotes = 0;
    let bytes = line.as_bytes();
    for i in 0..bytes.len() {
        match bytes[i] {
            b'"' => quotes += 1,
            b'/' if quotes % 2 == 0 && bytes.get(i + 1) == Some(&b'/') => {
                return line[..i].trim_end();
            }
            _ => {}
        }
    }
    line
}

/// Top-level `fn` items in `src` as `(name, body)` pairs. `//` comments, both
/// whole-line and trailing, are stripped so prose can't satisfy or trip a
/// check. Relies on rustfmt layout: an item starts with
/// `fn`/`pub fn`/`const fn`/`pub const fn` at column 0 and ends at the first
/// column-0 `}`. This is a text scan, not a parser. A `stibbons_cmd(` inside
/// a string literal would still satisfy it.
fn top_level_fns(src: &str) -> Vec<(String, String)> {
    let mut fns = Vec::new();
    let mut current: Option<(String, String)> = None;
    for line in src.lines() {
        let line = strip_line_comment(line);
        if line.trim().is_empty() {
            continue;
        }
        if current.is_none() {
            let sig = ["pub const fn ", "const fn ", "pub fn ", "fn "]
                .iter()
                .find_map(|p| line.strip_prefix(p));
            if let Some(rest) = sig {
                let name = rest.split(['(', '<']).next().unwrap_or_default().to_string();
                current = Some((name, String::new()));
            }
        }
        if let Some((_, body)) = current.as_mut() {
            body.push_str(line);
            body.push('\n');
            if line == "}" || (line.ends_with('}') && !line.starts_with(' ')) {
                fns.push(current.take().unwrap());
            }
        }
    }
    fns
}

/// Every stibbons spawn in `src` must go through `stibbons_cmd`:
/// - The binary path (`CARGO_BIN_EXE_stibbons`) appears only in `stibbons_bin`.
/// - `stibbons_bin()` is called only from `stibbons_cmd`.
/// - Every `run_*` helper calls `stibbons_cmd(`.
fn check_routing(src: &str) -> Result<(), String> {
    let fns = top_level_fns(src);
    let names: Vec<&str> = fns.iter().map(|(n, _)| n.as_str()).collect();
    if !names.contains(&"stibbons_cmd") || !names.contains(&"stibbons_bin") {
        return Err(format!("stibbons_cmd/stibbons_bin not found; parsed fns: {names:?}"));
    }
    let mut run_helpers = 0;
    for (name, body) in &fns {
        if body.contains("CARGO_BIN_EXE_stibbons") && name != "stibbons_bin" {
            return Err(format!("`{name}` names the stibbons binary directly"));
        }
        if body.contains("stibbons_bin()")
            && !matches!(name.as_str(), "stibbons_cmd" | "stibbons_bin")
        {
            return Err(format!("`{name}` spawns stibbons_bin() outside stibbons_cmd"));
        }
        if name.starts_with("run_") {
            run_helpers += 1;
            if !body.contains("stibbons_cmd(") {
                return Err(format!("`{name}` does not route through stibbons_cmd"));
            }
        }
    }
    if run_helpers == 0 {
        return Err("no run_* helpers found — the parser or the layout drifted".into());
    }
    Ok(())
}

/// #1746 AC2: a `run_*` helper that bypasses `stibbons_cmd` fails this test.
#[test]
fn run_helpers_route_through_stibbons_cmd() {
    if let Err(e) = check_routing(COMMON_SRC) {
        panic!("tests/common/mod.rs: {e}");
    }
    // Sanity floor: the parser must see the helpers we know exist.
    let names: Vec<String> = top_level_fns(COMMON_SRC).into_iter().map(|(n, _)| n).collect();
    for known in ["run_worktree", "run_status", "run_init_noninteractive", "stibbons_cmd"] {
        assert!(names.iter().any(|n| n == known), "parser missed `{known}`; got {names:?}");
    }
}

/// The guard rejects each bypass shape, on synthetic copies of the real source
/// (never by editing the tracked file).
#[test]
fn routing_guard_rejects_bypasses() {
    let bypass_run = format!(
        "{COMMON_SRC}\npub fn run_foo(cwd: &Path) -> Output {{\n    \
         Command::new(stibbons_bin()).current_dir(cwd).output().unwrap()\n}}\n"
    );
    let bare_spawn = format!(
        "{COMMON_SRC}\npub fn sneaky(cwd: &Path) -> Output {{\n    \
         Command::new(env!(\"CARGO_BIN_EXE_stibbons\")).current_dir(cwd).output().unwrap()\n}}\n"
    );
    let unrouted_run = format!(
        "{COMMON_SRC}\npub fn run_bar(cwd: &Path) -> Output {{\n    \
         // stibbons_cmd( mentioned only in a comment\n    \
         sneaky(cwd)\n}}\n"
    );
    let trailing_comment_run = format!(
        "{COMMON_SRC}\npub fn run_baz(cwd: &Path) -> Output {{\n    \
         sneaky(cwd) // was stibbons_cmd(\"baz\", cwd)\n}}\n"
    );
    for (label, src, want) in [
        ("run_* spawning stibbons_bin()", bypass_run, "run_foo"),
        ("bare CARGO_BIN_EXE spawn", bare_spawn, "sneaky"),
        ("run_* not calling stibbons_cmd", unrouted_run, "run_bar"),
        ("stibbons_cmd( only in a trailing comment", trailing_comment_run, "run_baz"),
    ] {
        match check_routing(&src) {
            Ok(()) => panic!("guard accepted a bypass: {label}"),
            Err(e) => assert!(e.contains(want), "{label}: wrong rejection: {e}"),
        }
    }
}
