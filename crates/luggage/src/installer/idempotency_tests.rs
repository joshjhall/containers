//! Unit tests for the idempotency pre-check and the version-probe runner,
//! plus the shim and process-liveness helpers the sibling installer tests
//! (`mod.rs`, `stages.rs`, `validate.rs`) import from here.
//!
//! Split out of `idempotency.rs` so the production file carries only
//! production code (#1398). Same `#[path]` idiom as `download_tests.rs`.

use super::*;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt as _;

use tempfile::tempdir;

/// Write an executable shim at `dir/name` that behaves like `go`: the
/// `version` subcommand prints `version_line`, anything else (including
/// `--version`) is a usage error with exit 2. Shared by the idempotency and
/// validate tests that pin the catalog-declared `version_args` (#811).
#[cfg(unix)]
pub fn write_subcommand_shim(dir: &Path, name: &str, version_line: &str) {
    use std::os::unix::fs::PermissionsExt as _;

    let path = dir.join(name);
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\nif [ \"$1\" = version ]; then echo '{version_line}'; exit 0; fi\n\
             echo \"flag provided but not defined: $1\" >&2\nexit 2\n"
        ),
    )
    .unwrap();
    let mut perms = std::fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).unwrap();
}

/// Write an executable shim at `dir/name` that records its pid in
/// `dir/name.pid`, prints a version line, then `exec`s `sleep 30` — standing
/// in for a misdeclared `version_args` that starts a long-running subcommand
/// (#1344). The `exec` keeps the pid, so the recorded pid IS the direct child
/// the timeout must kill; [`assert_probe_child_gone`] checks it.
#[cfg(unix)]
pub fn write_sleeping_shim(dir: &Path, name: &str) {
    use std::os::unix::fs::PermissionsExt as _;

    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\necho $$ > \"$0.pid\"\necho 'tool 1.0.0'\nexec sleep 30\n")
        .unwrap();
    let mut perms = std::fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).unwrap();
}

/// Write an executable shim at `dir/name` that records its own pid in
/// `dir/name.pid`, forks a background `sleep 30`, records the sleep's pid in
/// `dir/name.bgpid`, prints a version line, then `wait`s — a non-exec wrapper
/// whose descendant outlives a direct-child-only kill (#1352).
/// [`assert_probe_child_gone`] checks the direct child and
/// [`assert_forked_descendant_gone`] the descendant.
#[cfg(unix)]
pub fn write_forking_shim(dir: &Path, name: &str) {
    write_forking_shim_ending(dir, name, "wait");
}

/// Like [`write_forking_shim`], but the shim exits with `code` right after
/// printing instead of `wait`ing, so the background `sleep` outlives a probe
/// that finished on its own (#1371).
#[cfg(unix)]
fn write_backgrounding_shim(dir: &Path, name: &str, code: i32) {
    write_forking_shim_ending(dir, name, &format!("exit {code}"));
}

#[cfg(unix)]
fn write_forking_shim_ending(dir: &Path, name: &str, last: &str) {
    use std::os::unix::fs::PermissionsExt as _;

    let path = dir.join(name);
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\necho $$ > \"$0.pid\"\nsleep 30 &\necho $! > \"$0.bgpid\"\necho 'tool 1.0.0'\n{last}\n",
        ),
    )
    .unwrap();
    let mut perms = std::fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).unwrap();
}

/// Deadline for the [`write_sleeping_shim`] timeout tests; the shim runs 30s.
/// Long enough that a loaded runner has started `sh` and recorded the pid
/// before the kill, short enough to keep the suite fast.
#[cfg(unix)]
pub const TEST_TIMEOUT: Duration = Duration::from_secs(1);

/// Assert the probe child recorded by [`write_sleeping_shim`] no longer
/// exists — killed **and** reaped. A merely-dropped `Child` keeps running,
/// and a killed-but-unwaited one lingers as a zombie; [`pid_exists`] reports
/// both, so either leak fails here, where an elapsed-time bound alone would
/// pass (the timeout returns early whether or not the child is ended). A pid
/// recycled to another user's process also fails rather than passing (#1357).
#[cfg(unix)]
pub fn assert_probe_child_gone(dir: &Path, name: &str) {
    let pid_file = dir.join(format!("{name}.pid"));
    let pid = std::fs::read_to_string(&pid_file).unwrap_or_else(|e| {
        panic!(
            "the shim never recorded its pid at {} ({e}) — it was killed before `sh` \
             started, so the test deadline is too short for this runner",
            pid_file.display(),
        )
    });
    let pid = pid.trim();
    assert!(!pid.is_empty(), "the shim must have recorded its pid");
    assert!(!pid_exists(pid), "the timed-out probe child (pid {pid}) must be killed and reaped");
}

/// Whether `pid` exists per `kill(pid, 0)`. Only ESRCH means gone: EPERM
/// means a process exists that we may not signal (a pid recycled to another
/// user), and any other errno panics, so an unobservable pid can never pass
/// as a dead one. Unlike `kill(1)`, whose exit status is 1 for both, this
/// reads the errno directly (#1357).
#[cfg(unix)]
fn pid_exists(pid: &str) -> bool {
    use rustix::process::{Pid, test_kill_process};

    let raw: i32 = pid.parse().unwrap_or_else(|e| panic!("unparsable pid {pid:?} ({e})"));
    let target = Pid::from_raw(raw).unwrap_or_else(|| panic!("pid {raw} is not positive"));
    kill_probe_says_exists(raw, test_kill_process(target))
}

/// The ESRCH-only classification behind [`pid_exists`], split out so each
/// errno is testable without arranging a process the kernel answers it for.
#[cfg(unix)]
fn kill_probe_says_exists(pid: i32, probe: rustix::io::Result<()>) -> bool {
    use rustix::io::Errno;

    match probe {
        Ok(()) | Err(Errno::PERM) => true,
        Err(Errno::SRCH) => false,
        Err(e) => panic!("cannot probe pid {pid} ({e})"),
    }
}

/// The state field of a `/proc/<pid>/stat` line, or `None` if it does not
/// parse. `comm` (field 2) is parenthesised and may itself contain spaces or
/// `)`, so the state is the first field after the **last** `)`.
#[cfg(target_os = "linux")]
fn proc_stat_state(stat: &str) -> Option<&str> {
    stat.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().next())
}

/// Whether `pid` is still running. A zombie counts as gone: it was killed,
/// and whether it is reaped depends on the reparenting ancestor (no init in
/// a bare `docker run` reaps nothing), which is not what the test pins. Linux
/// reads the state field of `/proc/<pid>/stat`; other unixes fall back to
/// [`pid_exists`], which cannot tell a zombie apart. A missing stat file means
/// gone, and so does ESRCH: a process that exits between the `/proc` lookup
/// and the read fails the read with ESRCH, not ENOENT, so a poll racing a
/// kill sees it (#1370). Any other read error (no `/proc`, `hidepid`) or an
/// unparsable stat line panics, so an unobservable pid can never pass as a
/// dead one.
#[cfg(unix)]
pub fn pid_is_running(pid: &str) -> bool {
    #[cfg(target_os = "linux")]
    {
        let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => stat,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return false,
            Err(e) if e.raw_os_error() == Some(rustix::io::Errno::SRCH.raw_os_error()) => {
                return false;
            }
            Err(e) => panic!("cannot observe pid {pid} via /proc ({e})"),
        };
        let state = proc_stat_state(&stat)
            .unwrap_or_else(|| panic!("unparsable /proc/{pid}/stat: {stat:?}"));
        state != "Z" && state != "X"
    }
    #[cfg(not(target_os = "linux"))]
    {
        pid_exists(pid)
    }
}

/// Assert the background `sleep` forked by [`write_forking_shim`] is gone.
/// Once its parent dies it is reparented to an ancestor we do not control,
/// so poll briefly rather than check once: a killed orphan clears within
/// milliseconds, while a survivor is still running at the bound.
#[cfg(unix)]
pub fn assert_forked_descendant_gone(dir: &Path, name: &str) {
    let pid_file = dir.join(format!("{name}.bgpid"));
    let pid = std::fs::read_to_string(&pid_file).unwrap_or_else(|e| {
        panic!(
            "the shim never recorded its background pid at {} ({e}) — it was killed \
             before `sh` forked, so the test deadline is too short for this runner",
            pid_file.display(),
        )
    });
    let pid = pid.trim();
    assert!(!pid.is_empty(), "the shim must have recorded its background pid");
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if !pid_is_running(pid) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the probe's forked descendant (pid {pid}) must die with its process group",
        );
        thread::sleep(Duration::from_millis(20));
    }
}

/// The catalog default argv (`version_args` absent).
const VERSION_ARGS: &[&str] = &["--version"];

#[cfg(unix)]
fn write_shim(dir: &Path, name: &str, version_line: &str) {
    write_shim_to(dir, name, version_line, false);
}

/// Write an executable shim printing `version_line` to stdout (or stderr
/// when `to_stderr`). The line is single-quote-escaped so version strings
/// containing an apostrophe can't break the surrounding shell quoting.
#[cfg(unix)]
fn write_shim_to(dir: &Path, name: &str, version_line: &str, to_stderr: bool) {
    let path = dir.join(name);
    let escaped = version_line.replace('\'', "'\\''");
    let redirect = if to_stderr { " >&2" } else { "" };
    fs::write(&path, format!("#!/bin/sh\necho '{escaped}'{redirect}\n")).unwrap();
    let mut perms = fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&path, perms).unwrap();
}

#[test]
fn missing_binary_returns_false() {
    let dir = tempdir().unwrap();
    assert!(!already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()));
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn matching_version_returns_true() {
    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
    assert!(already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()));
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn stderr_version_returns_true() {
    // Some tools print `--version` to stderr; `already_installed` must
    // match the version there too, not only on stdout.
    let dir = tempdir().unwrap();
    write_shim_to(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)", true);
    assert!(already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()));
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn version_with_apostrophe_does_not_break_shim() {
    // Guards the shim helper's quote-escaping: a version literal with an
    // apostrophe must still be emitted verbatim and matched.
    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.95.0 o'brien");
    assert!(already_installed("rustc", VERSION_ARGS, "o'brien", dir.path()));
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn nonzero_exit_returns_false() {
    // A binary that runs and even prints the matching version but exits
    // non-zero can't confirm an install — the contract says return false.
    let dir = tempdir().unwrap();
    let path = dir.path().join("rustc");
    fs::write(&path, "#!/bin/sh\necho 'rustc 1.95.0'\nexit 1\n").unwrap();
    let mut perms = fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&path, perms).unwrap();
    assert!(
        !already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()),
        "non-zero exit must return false even if the version appears in output",
    );
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn exec_error_returns_false() {
    // The binary exists (passes the `.exists()` guard) but can't be
    // exec'd — a launch error must resolve to "can't confirm → false".
    let dir = tempdir().unwrap();
    let path = dir.path().join("rustc");
    fs::write(&path, b"not executable").unwrap();
    // Mode 000: present on disk but not executable.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
    assert!(!already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()));
}

#[cfg(unix)]
#[test]
#[serial_test::serial]
fn nonmatching_version_returns_false() {
    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.84.0 (abcdef0)");
    assert!(!already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()));
}

/// The check runs whatever binary name it is handed, with no per-tool
/// translation of its own — the catalog already resolved
/// `rust` → `rustc` before this point (issue #806).
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn checks_the_binary_name_it_is_given() {
    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
    assert!(
        already_installed("rustc", VERSION_ARGS, "1.95.0", dir.path()),
        "the resolved binary name is what gets version-checked",
    );
}

/// Regression guard for the deleted `match tool { "rust" => "rustc" }`
/// table: the tool *id* must NOT be silently translated here any more.
/// A catalog whose `primary_binary` says `rustc` is the only reason
/// `rustc` ever gets probed, so passing the bare id must not find it.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn does_not_translate_a_tool_id_to_a_binary_name() {
    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
    assert!(
        !already_installed("rust", VERSION_ARGS, "1.95.0", dir.path()),
        "no built-in id→binary mapping survives; only `rustc` is on disk",
    );
}

/// The probe runs the argv it is given (#811): a subcommand-only binary
/// is seen as installed under `["version"]`, and NOT under the default
/// `--version`, which it rejects with exit 2. Both halves matter — the
/// negative one proves the positive is the argv's doing, not a shim that
/// answers anything.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn probes_with_the_given_version_args() {
    let dir = tempdir().unwrap();
    write_subcommand_shim(dir.path(), "go", "go version go1.27.2 linux/arm64");
    assert!(already_installed("go", &["version"], "1.27.2", dir.path()));
    assert!(
        !already_installed("go", VERSION_ARGS, "1.27.2", dir.path()),
        "`go --version` exits 2, so the default argv must not confirm the install",
    );
}

/// A multi-element argv reaches the binary as separate arguments, not as
/// one space-joined string. The shim answers only when `$1` and `$2` are
/// `version` and `-short` individually; the joined form arrives as a
/// single `$1` and is rejected.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn multi_element_version_args_are_passed_as_separate_argv() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("tool");
    fs::write(
        &path,
        "#!/bin/sh\n[ \"$1\" = version ] && [ \"$2\" = -short ] && echo 'tool 2.0.0' && exit 0\nexit 2\n",
    )
    .unwrap();
    let mut perms = fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&path, perms).unwrap();

    assert!(already_installed("tool", &["version", "-short"], "2.0.0", dir.path()));
    assert!(
        !already_installed("tool", &["version -short"], "2.0.0", dir.path()),
        "a joined argv must not satisfy a shim that checks $1 and $2 separately",
    );
}

/// A probe still running at the deadline is killed and surfaces as
/// `TimedOut` (#1344). The elapsed bound proves the call did not wait the
/// shim's 30s out; the pid check proves the child was actually ended.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_times_out_and_kills_a_hung_probe() {
    let dir = tempdir().unwrap();
    write_sleeping_shim(dir.path(), "tool");

    let start = Instant::now();
    let result = run_version_check_within(
        &dir.path().join("tool"),
        VERSION_ARGS,
        &BTreeMap::new(),
        TEST_TIMEOUT,
    );
    let elapsed = start.elapsed();

    let err = result.expect_err("a probe past its deadline must fail");
    assert_eq!(err.kind(), io::ErrorKind::TimedOut, "got: {err}");
    assert!(elapsed >= TEST_TIMEOUT, "must wait out the deadline first ({elapsed:?})");
    assert!(elapsed < Duration::from_secs(5), "the hung child must be killed ({elapsed:?})");
    assert_probe_child_gone(dir.path(), "tool");
}

/// The timeout kills the probe's whole process group, not just the direct
/// child (#1352). The shim forks a `sleep` and `wait`s on it, so killing
/// only `sh` would orphan the sleep for its full 30s.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_timeout_kills_forked_descendants() {
    let dir = tempdir().unwrap();
    write_forking_shim(dir.path(), "tool");

    let result = run_version_check_within(
        &dir.path().join("tool"),
        VERSION_ARGS,
        &BTreeMap::new(),
        TEST_TIMEOUT,
    );

    let err = result.expect_err("a probe past its deadline must fail");
    assert_eq!(err.kind(), io::ErrorKind::TimedOut, "got: {err}");
    assert_probe_child_gone(dir.path(), "tool");
    assert_forked_descendant_gone(dir.path(), "tool");
}

/// A probe that prints its version and exits on its own while a backgrounded
/// child keeps running still has its group killed (#1371): the probe returns
/// its output and status unchanged, and nothing it forked survives the
/// return. A failing exit takes the same path, so both codes are pinned.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_kills_descendants_left_by_a_normal_exit() {
    for code in [0, 3] {
        let dir = tempdir().unwrap();
        write_backgrounding_shim(dir.path(), "tool", code);

        let out = run_version_check_within(
            &dir.path().join("tool"),
            VERSION_ARGS,
            &BTreeMap::new(),
            VERSION_PROBE_TIMEOUT,
        )
        .expect("a probe that exits on its own must return its output");

        assert_eq!(out.status.code(), Some(code), "status must be the probe's own");
        assert_eq!(String::from_utf8_lossy(&out.stdout), "tool 1.0.0\n");
        assert_eq!(String::from_utf8_lossy(&out.stderr), "");
        assert_probe_child_gone(dir.path(), "tool");
        assert_forked_descendant_gone(dir.path(), "tool");
    }
}

/// ECHILD from the `WNOWAIT` peek (a child already reaped) is tolerated, so
/// `try_wait` reports the reaped state rather than the poll failing (#1371).
/// Unreachable through the poll loop, so it is driven on the helper directly.
#[cfg(all(unix, not(any(target_os = "openbsd", target_os = "cygwin"))))]
#[test]
fn kill_group_if_exited_tolerates_an_already_reaped_child() {
    let mut child = Command::new("true").spawn().unwrap();
    child.wait().unwrap();

    kill_group_if_exited(&child).expect("ECHILD must not fail the poll");
}

/// `proc_stat_state` takes the field after the LAST `)`, so a `comm` with
/// spaces or its own `)` cannot shift the state, and a line it cannot
/// parse is `None` — which `pid_is_running` turns into a panic, never into
/// "not running" (a pass the descendant check would not have earned).
#[cfg(target_os = "linux")]
#[test]
fn proc_stat_state_reads_the_field_after_the_last_paren() {
    assert_eq!(proc_stat_state("4242 (sleep) S 1 4242 4242"), Some("S"));
    assert_eq!(proc_stat_state("4242 (sleep) Z 1 4242 4242"), Some("Z"));
    assert_eq!(proc_stat_state("4242 (my tool) R 1 4242"), Some("R"));
    assert_eq!(proc_stat_state("4242 (a) b) X 1 4242"), Some("X"));
    assert_eq!(proc_stat_state("4242 sleep S 1"), None, "no `)` at all");
    assert_eq!(proc_stat_state("4242 (sleep)"), None, "nothing after `)`");
    assert_eq!(proc_stat_state(""), None);
}

/// `pid_exists` sees a live child, then — once it is killed and reaped,
/// so the kernel answers ESRCH — reports it gone. The reaped pid is
/// checked immediately, before the kernel could plausibly recycle it.
#[cfg(unix)]
#[test]
fn pid_exists_tracks_a_child_through_kill_and_reap() {
    let mut child = Command::new("sleep").arg("30").spawn().unwrap();
    let pid = child.id().to_string();
    assert!(pid_exists(&pid), "a running child must exist");
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(!pid_exists(&pid), "a killed and reaped child must be gone (ESRCH)");
}

/// EPERM is a process we may not signal, not an absent one — a pid
/// recycled to another user's process must not pass as gone (#1357).
/// Driven through the pure classifier so it runs under any euid; a live
/// EPERM depends on who owns pid 1, and a skip there would read as a pass.
#[cfg(unix)]
#[test]
fn kill_probe_classifies_only_esrch_as_gone() {
    use rustix::io::Errno;

    assert!(kill_probe_says_exists(4242, Ok(())), "signalable means present");
    assert!(kill_probe_says_exists(4242, Err(Errno::PERM)), "EPERM must count as present");
    assert!(!kill_probe_says_exists(4242, Err(Errno::SRCH)), "ESRCH is the only gone");
}

/// Any errno besides EPERM/ESRCH is unobservable, never gone.
#[cfg(unix)]
#[test]
#[should_panic(expected = "cannot probe pid 4242")]
fn kill_probe_panics_on_an_unexpected_errno() {
    kill_probe_says_exists(4242, Err(rustix::io::Errno::INVAL));
}

#[cfg(unix)]
#[test]
#[should_panic(expected = "unparsable pid")]
fn pid_exists_panics_on_an_unparsable_pid() {
    pid_exists("abc");
}

/// `kill(0, 0)` would probe our own process group and always succeed, so
/// a zero pid must panic rather than reach the syscall.
#[cfg(unix)]
#[test]
#[should_panic(expected = "is not positive")]
fn pid_exists_panics_on_a_non_positive_pid() {
    pid_exists("0");
}

/// Counterpart to the timeout test: a probe that exits promptly is
/// captured in full, so the timeout path is not simply firing for every
/// probe. It runs at the production deadline — a short one would flake
/// on a loaded runner where `sh` alone can take longer to start.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_within_deadline_captures_output() {
    let dir = tempdir().unwrap();
    write_shim_to(dir.path(), "out", "tool 2.0.0 stdout", false);
    write_shim_to(dir.path(), "err", "tool 2.0.0 stderr", true);

    let out = run_version_check_within(
        &dir.path().join("out"),
        VERSION_ARGS,
        &BTreeMap::new(),
        VERSION_PROBE_TIMEOUT,
    )
    .expect("a prompt probe must succeed");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout), "tool 2.0.0 stdout\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "");

    let err = run_version_check_within(
        &dir.path().join("err"),
        VERSION_ARGS,
        &BTreeMap::new(),
        VERSION_PROBE_TIMEOUT,
    )
    .expect("a prompt probe must succeed");
    assert!(err.status.success());
    assert_eq!(String::from_utf8_lossy(&err.stdout), "");
    assert_eq!(String::from_utf8_lossy(&err.stderr), "tool 2.0.0 stderr\n");
}

/// The probe's stdin is `/dev/null`. Unlike [`Command::output`], `spawn()`
/// defaults stdin to *inherit*, so dropping the explicit `Stdio::null()`
/// would hand a REPL-ish `version_args` the caller's terminal to block on.
/// The shim succeeds only if its stdin is the null device and a `read` hits
/// EOF at once; an inherited stdin that is not `/dev/null` fails the `-ef`
/// check (or blocks in `read` into the deadline).
///
/// A runner whose own stdin is already `/dev/null` (most CI) cannot tell
/// inherit from null, so the probe never runs in this process: the test
/// re-execs its own binary for just itself, with a pipe as stdin (#1409).
/// The child refuses to probe unless its stdin really is not `/dev/null`,
/// and the parent requires `1 passed` rather than a bare exit 0 — a filter
/// that matched nothing also exits 0, which would pass on no assertion.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_within_gives_the_probe_a_null_stdin() {
    use std::io::Write as _;
    use std::os::unix::fs::MetadataExt as _;

    const CHILD_MARKER: &str = "LUGGAGE_NULL_STDIN_PROBE_CHILD";

    if std::env::var_os(CHILD_MARKER).is_some() {
        let id = |p: &str| {
            let m = fs::metadata(p).unwrap();
            (m.dev(), m.ino())
        };
        assert_ne!(
            id("/dev/stdin"),
            id("/dev/null"),
            "re-exec'd child must run with a non-null stdin, or the probe check is vacuous",
        );
        assert_probe_stdin_is_null();
        return;
    }

    let module = module_path!();
    let module = module.split_once("::").map_or(module, |(_, rest)| rest);
    let name = format!("{module}::run_version_check_within_gives_the_probe_a_null_stdin");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", &name, "--test-threads=1", "--nocapture"])
        .env(CHILD_MARKER, "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // Data on the pipe makes an inherited stdin visible to the shim's
    // `read` too, not just to its `-ef` check. The write result is ignored:
    // a child that already died fails it with EPIPE, and the assertion below
    // reports that child's output, which an `unwrap` here would swallow.
    let _ = child.stdin.take().unwrap().write_all(b"from-parent\n");
    let out = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && stdout.contains("1 passed"),
        "re-exec'd probe test failed ({}):\n--- stdout ---\n{stdout}\n--- stderr ---\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr),
    );
}

/// The shim half of [`run_version_check_within_gives_the_probe_a_null_stdin`],
/// run only inside its re-exec'd child.
#[cfg(unix)]
fn assert_probe_stdin_is_null() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("tool");
    fs::write(
        &path,
        "#!/bin/sh\n[ /dev/stdin -ef /dev/null ] || { echo 'stdin is not /dev/null' >&2; exit 3; }\n\
         if read -r line; then echo \"stdin had data: $line\" >&2; exit 4; fi\n\
         echo 'tool 1.0.0'\n",
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

    let out =
        run_version_check_within(&path, VERSION_ARGS, &BTreeMap::new(), VERSION_PROBE_TIMEOUT)
            .expect("a probe reading stdin must hit EOF, not wait out the deadline");
    assert!(
        out.status.success(),
        "probe stdin must be /dev/null: {}",
        String::from_utf8_lossy(&out.stderr),
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "tool 1.0.0\n");
}

/// Output past a pipe buffer (~64KiB) is captured whole. With piped
/// stdio and a `try_wait` poll the child would block on a full pipe and
/// this would time out instead — the deadlock the tempfile capture
/// exists to avoid.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_captures_output_larger_than_a_pipe_buffer() {
    const BYTES: usize = 256 * 1024;

    let dir = tempdir().unwrap();
    let path = dir.path().join("chatty");
    fs::write(
        &path,
        format!("#!/bin/sh\nhead -c {BYTES} /dev/zero\nhead -c {BYTES} /dev/zero >&2\n"),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

    let out =
        run_version_check_within(&path, VERSION_ARGS, &BTreeMap::new(), Duration::from_secs(5))
            .expect("a large-output probe must not deadlock");
    assert!(out.status.success());
    assert_eq!(out.stdout.len(), BYTES);
    assert_eq!(out.stderr.len(), BYTES);
}

/// SIGKILLs the recorded grandchild on drop, so a failed assertion cannot
/// leak the shim's `sleep 30`. Never asserts: a panic in `drop` while
/// already unwinding would abort the test binary.
#[cfg(unix)]
pub struct KillOnDrop(pub rustix::process::Pid);

#[cfg(unix)]
impl Drop for KillOnDrop {
    fn drop(&mut self) {
        let _ = rustix::process::kill_process(self.0, rustix::process::Signal::KILL);
    }
}

/// A probe that exits while a backgrounded grandchild still holds the
/// inherited stdout/stderr returns promptly (#1359). With piped stdio and
/// read-to-EOF the read would block until the grandchild's `sleep 30`
/// ended — the hang the tempfile capture exists to avoid. The
/// still-running check proves the fds really were held at return, so the
/// elapsed bound cannot pass because the grandchild died early.
///
/// The grandchild moves itself to its own process group first. A descendant
/// left in the probe's group is killed when the probe exits (#1371), so
/// an in-group one raced that kill and the still-running check flaked
/// (#1497). An escaped descendant is the gap the group kill leaves, and the
/// one where the tempfile capture still matters. The shim exits only once
/// the pid file exists, which perl writes (renamed into place, never seen
/// half-written) after `setpgrp`, so the group kill cannot reach it. If the
/// shim gives up first, the test re-polls for the late pid and kills it
/// while failing, so a slow perl cannot leak its `sleep` (#1501).
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_returns_while_a_grandchild_holds_the_capture_fds() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("tool");
    fs::write(
        &path,
        r#"#!/bin/sh
echo 'tool 1.0.0'
command -v perl >/dev/null || { echo 'perl not found' >&2; exit 1; }
perl -e 'setpgrp(0, 0) or die "setpgrp: $!";
open my $f, ">", "$ARGV[0].tmp" or die "open: $!"; print $f "$$\n"; close $f or die "close: $!";
rename "$ARGV[0].tmp", $ARGV[0] or die "rename: $!";
exec "sleep", "30" or die "exec: $!"' "$0.gpid" &
i=0
while [ ! -s "$0.gpid" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
exit 0
"#,
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

    let start = Instant::now();
    let result =
        run_version_check_within(&path, VERSION_ARGS, &BTreeMap::new(), VERSION_PROBE_TIMEOUT);
    let elapsed = start.elapsed();

    // perl's `die` text lands in the probe's captured stderr, so show it.
    let gpid_file = dir.path().join("tool.gpid");
    let gpid = fs::read_to_string(&gpid_file).unwrap_or_else(|e| {
        // A perl slow enough to outlast the shim's wait has already left the
        // probe's group, so nothing else will kill it. Wait briefly for its
        // late pid and arm the guard before panicking: the unwind then kills
        // it, before or after its exec into `sleep 30` (#1501). A perl later
        // than that still leaks; the shell's `$!` is no safer to kill here, as
        // it may already name a dead, reused pid.
        let deadline = Instant::now() + Duration::from_secs(2);
        let late = loop {
            if let Ok(pid) = fs::read_to_string(&gpid_file) {
                break pid.trim().parse().ok().and_then(rustix::process::Pid::from_raw);
            }
            if Instant::now() >= deadline {
                break None;
            }
            thread::sleep(Duration::from_millis(20));
        };
        let late_note = late.map_or_else(
            || "no late pid appeared within 2s".to_owned(),
            |pid| format!("killed late pid {}", pid.as_raw_nonzero()),
        );
        let _late = late.map(KillOnDrop);
        let stderr = result.as_ref().map(|out| String::from_utf8_lossy(&out.stderr).into_owned());
        panic!(
            "the shim must record its background pid before exiting ({e}); {late_note}; \
             probe stderr: {stderr:?}"
        )
    });
    let gpid = gpid.trim().to_owned();
    let raw: i32 = gpid.parse().unwrap_or_else(|e| panic!("unparsable pid {gpid:?} ({e})"));
    let guard = KillOnDrop(
        rustix::process::Pid::from_raw(raw).unwrap_or_else(|| panic!("pid {raw} is not positive")),
    );

    let out = result.expect("a probe that exits 0 must succeed despite a live grandchild");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout), "tool 1.0.0\n");
    assert!(
        elapsed < Duration::from_secs(5),
        "must not wait on the grandchild holding the capture fds ({elapsed:?})",
    );
    assert!(pid_is_running(&gpid), "the grandchild must still be alive when the probe returns");

    drop(guard);
    let deadline = Instant::now() + Duration::from_secs(2);
    while pid_is_running(&gpid) {
        assert!(Instant::now() < deadline, "cleanup must kill the grandchild (pid {gpid})");
        thread::sleep(Duration::from_millis(20));
    }
}

/// A probe that floods both streams far past the cap and then exits 0
/// comes back with exactly [`VERSION_PROBE_OUTPUT_CAP`] bytes of each —
/// the cap bounds what is read into memory, without turning the
/// successful exit into a failure (#1353).
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn run_version_check_caps_captured_output() {
    let flood = VERSION_PROBE_OUTPUT_CAP * 4;

    let dir = tempdir().unwrap();
    let path = dir.path().join("flood");
    fs::write(
        &path,
        format!("#!/bin/sh\nhead -c {flood} /dev/zero\nhead -c {flood} /dev/zero >&2\n"),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

    let out =
        run_version_check_within(&path, VERSION_ARGS, &BTreeMap::new(), Duration::from_secs(5))
            .expect("a flooding probe that exits must not error");
    assert!(out.status.success());
    let cap = usize::try_from(VERSION_PROBE_OUTPUT_CAP).unwrap();
    assert_eq!(out.stdout.len(), cap);
    assert_eq!(out.stderr.len(), cap);
}

/// A [`ProbeChild`] that answers every poll with a fixed result and
/// records each call, so the `try_wait`-error branch can be driven
/// without a real process (#1354).
struct FakeChild {
    poll_result: fn() -> io::Result<Option<ExitStatus>>,
    calls: Vec<&'static str>,
}

impl ProbeChild for FakeChild {
    fn poll(&mut self) -> io::Result<Option<ExitStatus>> {
        self.calls.push("poll");
        (self.poll_result)()
    }

    fn kill_all(&mut self) {
        self.calls.push("kill");
    }

    fn reap(&mut self) {
        self.calls.push("reap");
    }
}

/// A `try_wait` error must kill and reap the child before propagating —
/// a bare `child.try_wait()?` would return with it still running and
/// unreaped. The error surfaces unchanged, after a single poll.
#[test]
fn wait_within_kills_and_reaps_when_try_wait_errors() {
    let mut child = FakeChild {
        poll_result: || Err(io::Error::other("injected try_wait failure")),
        calls: Vec::new(),
    };

    let err =
        wait_within(&mut child, Duration::from_secs(1)).expect_err("poll error must propagate");

    assert_eq!(err.kind(), io::ErrorKind::Other, "must not be remapped to TimedOut");
    assert_eq!(err.to_string(), "injected try_wait failure");
    assert_eq!(child.calls, ["poll", "kill", "reap"]);
}

/// A capture tempfile that cannot be created must say so, with its kind
/// intact (#1360) — otherwise `validate::check` reports a full or
/// unwritable temp dir as nothing more than the probe failing to launch.
/// The `Ok` control proves the failure is the missing dir, not the host.
#[test]
fn capture_file_in_a_missing_dir_keeps_kind_and_adds_context() {
    const CONTEXT: &str = "creating probe capture file: ";
    let dir = tempdir().unwrap();
    capture_file_in(dir.path()).expect("a capture file in an existing dir must succeed");

    let err = capture_file_in(&dir.path().join("missing"))
        .expect_err("a capture file in a missing dir must fail");

    assert_eq!(err.kind(), io::ErrorKind::NotFound, "kind must survive the wrap: {err}");
    let message = err.to_string();
    assert!(message.starts_with(CONTEXT), "missing capture-file context: {message:?}");
    assert!(message.len() > CONTEXT.len(), "the underlying error was dropped: {message:?}");
}

/// `Duration::MAX` — reachable through the public
/// `InstallerOptions::version_probe_timeout`, which the env cap does not
/// guard — must wait for the child, not panic computing the deadline
/// (#1358). Before `checked_add` this panicked on `Instant + Duration`.
#[cfg(unix)]
#[test]
fn wait_within_does_not_panic_on_an_unrepresentable_timeout() {
    use std::os::unix::process::ExitStatusExt as _;

    let mut child =
        FakeChild { poll_result: || Ok(Some(ExitStatus::from_raw(0))), calls: Vec::new() };

    let status = wait_within(&mut child, Duration::MAX).unwrap();

    assert!(status.success());
    assert_eq!(child.calls, ["poll"]);
}

/// The test above only proves the deadline computes: its child exits on
/// the first poll, so the deadline is never consulted. This one keeps the
/// child running for two polls, which pins what an unrepresentable
/// deadline MEANS — wait, not "already expired". Reading it as expired
/// would kill every still-running probe on its first poll, turning a
/// slow-but-valid probe into a spurious timeout (#1358).
#[cfg(unix)]
#[test]
fn wait_within_waits_on_a_running_child_under_an_unrepresentable_timeout() {
    use std::os::unix::process::ExitStatusExt as _;

    /// Running for the first two polls, then exited.
    struct ExitsOnThirdPoll {
        calls: Vec<&'static str>,
    }
    impl ProbeChild for ExitsOnThirdPoll {
        fn poll(&mut self) -> io::Result<Option<ExitStatus>> {
            self.calls.push("poll");
            Ok((self.calls.len() >= 3).then(|| ExitStatus::from_raw(0)))
        }
        fn kill_all(&mut self) {
            self.calls.push("kill");
        }
        fn reap(&mut self) {
            self.calls.push("reap");
        }
    }

    let mut child = ExitsOnThirdPoll { calls: Vec::new() };

    let status = wait_within(&mut child, Duration::MAX).unwrap();

    assert!(status.success());
    assert_eq!(child.calls, ["poll", "poll", "poll"], "must wait, never kill");
}

/// The counterpart: a child that exits on its own is neither killed nor
/// reaped again, so the test above is not satisfied by an unconditional
/// kill.
#[cfg(unix)]
#[test]
fn wait_within_leaves_an_exited_child_alone() {
    use std::os::unix::process::ExitStatusExt as _;

    let mut child =
        FakeChild { poll_result: || Ok(Some(ExitStatus::from_raw(0))), calls: Vec::new() };

    let status = wait_within(&mut child, TEST_TIMEOUT).unwrap();

    assert!(status.success());
    assert_eq!(child.calls, ["poll"]);
}

/// The cap boundary is exact: a stream of exactly the cap is read whole
/// with no warning, one byte more is cut back to the cap and `read_back`
/// itself logs the truncation, naming the stream. The warning is captured
/// from a thread-local subscriber, so parallel tests cannot leak into it.
#[test]
fn read_back_cap_boundary() {
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);
    impl io::Write for Captured {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let cap = usize::try_from(VERSION_PROBE_OUTPUT_CAP).unwrap();
    for (len, truncated) in [(cap - 1, false), (cap, false), (cap + 1, true)] {
        let mut file = tempfile::tempfile().unwrap();
        io::Write::write_all(&mut file, &vec![b'x'; len]).unwrap();

        let log = Captured::default();
        let writer = log.clone();
        let subscriber =
            tracing_subscriber::fmt().with_writer(move || writer.clone()).with_ansi(false).finish();
        let buf = tracing::subscriber::with_default(subscriber, || {
            read_back(&mut file, "stderr").unwrap()
        });

        assert_eq!(buf.len(), len.min(cap), "read-back length for a {len}-byte stream");
        let logged = String::from_utf8(log.0.lock().unwrap().clone()).unwrap();
        assert_eq!(
            logged.contains("version probe output truncated"),
            truncated,
            "truncation warning for a {len}-byte stream, got: {logged:?}",
        );
        if truncated {
            assert!(logged.contains("stream=\"stderr\""), "names the stream: {logged:?}");
        }
    }
}

/// The cap keeps the head of the stream, so a version line printed before
/// a flood still matches.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn already_installed_matches_a_version_printed_before_a_flood() {
    let flood = VERSION_PROBE_OUTPUT_CAP * 2;

    let dir = tempdir().unwrap();
    let path = dir.path().join("tool");
    fs::write(&path, format!("#!/bin/sh\necho 'tool 1.2.3'\nhead -c {flood} /dev/zero\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(already_installed("tool", VERSION_ARGS, "1.2.3", dir.path()));
}

/// Unset or empty means the default; a positive integer is seconds and is
/// trimmed; anything else — including `0` — is a hard error naming the
/// variable, never a silent fallback (#1358).
#[test]
fn parse_version_probe_timeout_cases() {
    assert_eq!(parse_version_probe_timeout(None).unwrap(), VERSION_PROBE_TIMEOUT);
    assert_eq!(parse_version_probe_timeout(Some("")).unwrap(), VERSION_PROBE_TIMEOUT);
    assert_eq!(parse_version_probe_timeout(Some("  ")).unwrap(), VERSION_PROBE_TIMEOUT);
    assert_eq!(parse_version_probe_timeout(Some("30")).unwrap(), Duration::from_secs(30));
    assert_eq!(parse_version_probe_timeout(Some(" 45 ")).unwrap(), Duration::from_secs(45));
    assert_eq!(
        parse_version_probe_timeout(Some("86400")).unwrap(),
        Duration::from_secs(MAX_VERSION_PROBE_TIMEOUT_SECS),
        "the cap itself is accepted"
    );
    // Values that parse as u64 but exceed the one-day cap — up to u64-max —
    // are operator errors and must be refused here, naming the variable.
    for bad in ["0", "abc", "-1", "1.5", "10s", "86401", "18446744073709551615"] {
        let err = parse_version_probe_timeout(Some(bad)).unwrap_err();
        let msg = err.to_string();
        assert!(
            matches!(err, crate::error::LuggageError::Catalog(_)),
            "`{bad}` must be a Catalog error, got {msg}"
        );
        assert!(msg.contains(VERSION_PROBE_TIMEOUT_ENV), "`{bad}`: {msg}");
    }
}

/// `already_installed` folds a timeout into "can't confirm → false", even
/// though the hung shim already printed the matching version before it
/// stalled — a probe that never exits has no success status to trust.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn already_installed_returns_false_when_the_probe_times_out() {
    let dir = tempdir().unwrap();
    write_sleeping_shim(dir.path(), "tool");

    let start = Instant::now();
    let installed =
        already_installed_within("tool", VERSION_ARGS, "1.0.0", dir.path(), TEST_TIMEOUT);
    assert!(!installed, "a timed-out probe must not confirm the install");
    assert!(start.elapsed() < Duration::from_secs(5), "the hung child must be killed");
    assert_probe_child_gone(dir.path(), "tool");
}

/// A non-`ETXTBSY` launch error must be returned on the *first* attempt,
/// never retried. Pointing at a path with no file on disk makes `exec`
/// fail with `ENOENT`, which the `other => break other?` arm must surface
/// immediately. The check counts spawn attempts rather than timing the
/// backoff: a wall-clock bound under the full retry budget could not tell a
/// correct run from one that retried once or twice (#1408), while exactly one
/// attempt fails any retry of this error at all, with no load sensitivity.
#[cfg(unix)]
#[test]
fn run_version_check_returns_non_etxtbsy_error_without_retrying() {
    let dir = tempdir().unwrap();
    let missing = dir.path().join("does-not-exist");

    SPAWN_ATTEMPTS.set(0);
    let result = run_version_check(&missing, VERSION_ARGS, &BTreeMap::new());
    let attempts = SPAWN_ATTEMPTS.get();

    let err = result.expect_err("a missing binary must surface its launch error");
    assert_eq!(
        err.kind(),
        io::ErrorKind::NotFound,
        "the induced error must be the missing binary's ENOENT, got: {err}",
    );
    assert_eq!(
        attempts, 1,
        "a non-ETXTBSY error must be returned on the first spawn, never retried"
    );
}

/// A *transient* `ETXTBSY` that clears mid-flight must be absorbed by the
/// retry loop and resolve to the eventual success — the "retry up to
/// `ETXTBSY_RETRIES`, then succeed" path that the exhaustion test above
/// never reaches. A background thread holds a write fd open just long
/// enough to force `ETXTBSY` on the first attempt(s), then drops it so a
/// later retry within budget execs cleanly and returns the version output.
///
/// Linux-only for the same reason as the exhaustion tests: only Linux
/// returns `ETXTBSY` while a writable fd is held.
#[cfg(target_os = "linux")]
#[test]
#[serial_test::serial]
fn run_version_check_retries_then_succeeds_when_etxtbsy_clears() {
    use std::fs::OpenOptions;

    let dir = tempdir().unwrap();
    let binary = dir.path().join("rustc");
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (after retry)");

    // Hold a writable fd, then release it from a background thread after
    // ~one backoff. The first exec attempt hits ETXTBSY; by the time the
    // loop backs off and retries, the fd is gone and the exec succeeds —
    // comfortably inside the 3-retry / 150ms budget.
    let writer = OpenOptions::new().write(true).open(&binary).unwrap();
    let releaser = thread::spawn(move || {
        thread::sleep(ETXTBSY_BACKOFF / 2);
        drop(writer);
    });

    let result = run_version_check(&binary, VERSION_ARGS, &BTreeMap::new());
    releaser.join().expect("releaser thread panicked");

    let output = result.expect("a transient ETXTBSY that clears must resolve to success");
    assert!(output.status.success(), "the shim exits 0 once exec succeeds");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("1.95.0"),
        "the retried exec must capture the shim's version output, got: {stdout}",
    );
}

/// Exhaustion counterpart to the `install_rust` regression test, which only
/// covers success-after-retry. Holding an open write fd to the binary makes
/// every `exec` fail with `ETXTBSY`, so `run_version_check` burns the whole
/// `ETXTBSY_RETRIES` budget and then propagates the error via `other =>
/// break other?` instead of dropping it — the path that was previously
/// untested. The held fd guarantees the failure deterministically (no
/// cross-thread fork race needed), and the `>= ETXTBSY_RETRIES` sleep floor
/// proves the retry loop actually ran to exhaustion rather than returning
/// early.
///
/// Linux-only: the "open-for-write ⇒ `exec` fails with `ETXTBSY`" guarantee
/// is a Linux kernel behavior. macOS/Darwin does *not* return `ETXTBSY`
/// while a writable fd is held, so this deterministic-induction technique
/// can't run there — the production retry logic it guards is itself
/// exercised end-to-end by the parallel regression tests in `install_rust`,
/// which do run on every unix.
#[cfg(target_os = "linux")]
#[test]
#[serial_test::serial]
fn run_version_check_propagates_etxtbsy_after_exhausting_retries() {
    use std::fs::OpenOptions;
    use std::time::Instant;

    let dir = tempdir().unwrap();
    let binary = dir.path().join("rustc");
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (never runs)");

    // A writable fd open across the exec keeps the kernel returning ETXTBSY
    // for the lifetime of `_writer`; drop only happens at end of scope.
    let _writer = OpenOptions::new().write(true).open(&binary).unwrap();

    let start = Instant::now();
    let result = run_version_check(&binary, VERSION_ARGS, &BTreeMap::new());
    let elapsed = start.elapsed();

    let err = result.expect_err("held write fd must force ETXTBSY exhaustion");
    assert_eq!(
        err.raw_os_error(),
        Some(ETXTBSY),
        "exhaustion must propagate the ETXTBSY error, not remap it",
    );
    assert!(
        elapsed >= ETXTBSY_BACKOFF * ETXTBSY_RETRIES,
        "should back off once per retry before giving up (elapsed {elapsed:?})",
    );
}

/// The public `already_installed` wrapper must fold that same exhaustion
/// into its "can't confirm → false" contract rather than surfacing the
/// error, so the caller still treats the tool as "go install".
///
/// Linux-only for the same reason as the exhaustion test above: the held
/// write fd only forces `ETXTBSY` on Linux.
#[cfg(target_os = "linux")]
#[test]
#[serial_test::serial]
fn already_installed_returns_false_when_etxtbsy_never_clears() {
    use std::fs::OpenOptions;

    let dir = tempdir().unwrap();
    write_shim(dir.path(), "rustc", "rustc 1.95.0 (never runs)");
    let _writer = OpenOptions::new().write(true).open(dir.path().join("rustc")).unwrap();

    assert!(
        !already_installed("rust", VERSION_ARGS, "1.95.0", dir.path()),
        "persistent ETXTBSY must resolve to false, not a spurious true",
    );
}
