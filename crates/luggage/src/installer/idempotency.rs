//! Idempotency pre-check: skip install when the tool is already at the
//! target version.
//!
//! The convention is "`<bin_root>/<binary> <version_args…>` contains
//! `<version>`" — exactly what bash's `lib/features/rust.sh` does with
//! `command -v rustc && rustc --version | grep -q "$RUST_VERSION"`. Both the
//! binary and its argv come from the catalog
//! ([`crate::ResolvedInstall::primary_binary`] and
//! [`crate::ResolvedInstall::version_args`]), so a tool that only answers a
//! subcommand (`go version`) is probed the way it understands.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, Read as _, Seek as _, SeekFrom};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// `errno` for `ETXTBSY` ("text file busy"), returned by `exec` when another
/// thread in this process briefly holds a writable fd to the binary across a
/// concurrent `fork`/`exec`. Transient, not "binary absent". See issue #518.
const ETXTBSY: i32 = 26;

/// Bounded retry budget for the version-probe exec when it hits `ETXTBSY`, and
/// the backoff between attempts.
const ETXTBSY_RETRIES: u32 = 3;
const ETXTBSY_BACKOFF: Duration = Duration::from_millis(50);

/// Deadline for one version-probe exec (#1344). A `--version` answers in
/// milliseconds; the headroom is for JVM-style tools cold-starting under
/// qemu emulation. Since #811 the argv is a catalog input, so a misdeclared
/// `version_args` that starts a long-running subcommand (`serve`, a daemon
/// verb, a tool blocking on a lock) would otherwise hang the install forever.
/// Hitting it means the argv is wrong, not that the machine is slow.
pub(crate) const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Interval between `try_wait` polls while the probe runs.
const VERSION_PROBE_POLL: Duration = Duration::from_millis(10);

/// Most bytes of each probe stream (stdout, stderr) read back into memory
/// (#1353). A real `--version` prints a few hundred bytes; a misdeclared argv
/// that floods output would otherwise be loaded whole. Only the *first* bytes
/// are kept, so a version line printed before a flood still matches, and a
/// truncation is logged. The on-disk capture file itself is not capped — its
/// size is bounded only by how much the probe writes before
/// [`VERSION_PROBE_TIMEOUT`].
pub(crate) const VERSION_PROBE_OUTPUT_CAP: u64 = 1024 * 1024;

/// [`run_version_check_within`] at the production [`VERSION_PROBE_TIMEOUT`];
/// the ETXTBSY tests exercise the retry loop through it.
#[cfg(test)]
pub(crate) fn run_version_check<S: AsRef<OsStr>>(
    binary: &Path,
    args: &[S],
    env: &BTreeMap<String, String>,
) -> io::Result<Output> {
    run_version_check_within(binary, args, env, VERSION_PROBE_TIMEOUT)
}

/// Run `<binary> <args…>` with `env` layered on the inherited environment,
/// bounded by `timeout` and retrying on a transient `ETXTBSY`.
///
/// A child still running at `timeout` is killed and reaped, and the call
/// returns an [`io::ErrorKind::TimedOut`] error. On unix the child leads its
/// own process group, and on that timeout path the whole group is killed, so
/// a non-exec wrapper (shell script, JVM launcher) that hangs cannot leave
/// forked descendants running (#1352); elsewhere only the direct child is
/// killed. Two gaps remain. A probe that exits on its own is not group-killed,
/// so a descendant it backgrounded outlives it. And because the group is not
/// luggage's, a terminal Ctrl-C reaches luggage but not the probe: luggage
/// installs no signal handler, so an interactive interrupt mid-probe leaves the
/// probe running unbounded. Under `docker build` (no TTY; cancelling tears down
/// the whole container) neither applies. A descendant that moved itself to
/// another group or session escapes, as with any `killpg`.
/// Its stdout/stderr go to anonymous tempfiles rather than pipes, so
/// polling never deadlocks on a full pipe buffer, and a grandchild that
/// inherited the write end cannot block us after the kill. stdin is null,
/// as with [`Command::output`].
///
/// Writing an executable and immediately `exec`ing it races with any
/// concurrent `fork` in the same process: the child momentarily inherits a
/// writable fd to the file, so the `exec` fails with `ETXTBSY` until that fd
/// closes. Collapsing that transient into "not installed"/failure is the root
/// cause of the flaky `install_rust` tests (issue #518) and could equally
/// misfire in real igor flows that write a binary then version-check it. We
/// retry a bounded number of times with a short backoff; every other I/O
/// error (and every success) is returned to the caller on the first
/// occurrence. `ETXTBSY` is an exec-time error, so the retry wraps `spawn`.
pub(crate) fn run_version_check_within<S: AsRef<OsStr>>(
    binary: &Path,
    args: &[S],
    env: &BTreeMap<String, String>,
    timeout: Duration,
) -> io::Result<Output> {
    let mut stdout = capture_file()?;
    let mut stderr = capture_file()?;
    let mut attempt = 0;
    let mut child = loop {
        let mut command = Command::new(binary);
        command
            .args(args)
            .envs(env)
            .stdin(Stdio::null())
            .stdout(stdout.try_clone()?)
            .stderr(stderr.try_clone()?);
        // pgid 0 = a new group led by the child, so the timeout can kill it
        // and everything it forked in one signal.
        #[cfg(unix)]
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
        let spawned = command.spawn();
        match spawned {
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && attempt < ETXTBSY_RETRIES => {
                attempt += 1;
                thread::sleep(ETXTBSY_BACKOFF);
            }
            other => break other?,
        }
    };

    let status = wait_within(&mut child, timeout)?;

    Ok(Output {
        status,
        stdout: read_back(&mut stdout, "stdout")?,
        stderr: read_back(&mut stderr, "stderr")?,
    })
}

/// The child-process operations [`wait_within`] needs, behind a seam so a
/// test can inject a `try_wait` error a real [`Child`] almost never returns
/// (#1354). Named apart from `Child`'s inherent methods so a call on a real
/// child cannot silently resolve to the wrong one.
trait ProbeChild {
    /// Non-blocking exit check ([`Child::try_wait`]).
    fn poll(&mut self) -> io::Result<Option<ExitStatus>>;
    /// Best-effort kill of the child and, on unix, its process group.
    fn kill_all(&mut self);
    /// Best-effort blocking reap ([`Child::wait`]).
    fn reap(&mut self);
}

impl ProbeChild for Child {
    fn poll(&mut self) -> io::Result<Option<ExitStatus>> {
        self.try_wait()
    }

    // The group kill fails only if every member already exited; `kill`
    // likewise for the child.
    fn kill_all(&mut self) {
        #[cfg(unix)]
        let _ = rustix::process::kill_process_group(
            rustix::process::Pid::from_child(self),
            rustix::process::Signal::KILL,
        );
        let _ = self.kill();
    }

    fn reap(&mut self) {
        let _ = self.wait();
    }
}

/// Poll `child` until it exits or `timeout` elapses. On timeout, or if a poll
/// itself errors, the child is killed and reaped before returning, so an
/// early return never leaves it running or a zombie.
fn wait_within(child: &mut impl ProbeChild, timeout: Duration) -> io::Result<ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        let polled = child.poll();
        let timed_out = matches!(polled, Ok(None)) && Instant::now() >= deadline;
        if timed_out || polled.is_err() {
            child.kill_all();
            child.reap();
        }
        match polled? {
            Some(status) => return Ok(status),
            None if timed_out => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("timed out after {timeout:?}"),
                ));
            }
            None => thread::sleep(VERSION_PROBE_POLL),
        }
    }
}

/// Create an anonymous capture tempfile (in `TMPDIR`), with context on
/// failure so a full or unwritable temp dir is not mistaken for the probe
/// binary failing to launch.
fn capture_file() -> io::Result<File> {
    tempfile::tempfile()
        .map_err(|e| io::Error::new(e.kind(), format!("creating probe capture file: {e}")))
}

/// Rewind a capture tempfile and read back at most
/// [`VERSION_PROBE_OUTPUT_CAP`] bytes of what the child wrote to it, warning
/// (with the `stream` name) when the rest is dropped.
fn read_back(file: &mut File, stream: &str) -> io::Result<Vec<u8>> {
    let written = file.metadata()?.len();
    if written > VERSION_PROBE_OUTPUT_CAP {
        tracing::warn!(
            stream,
            written,
            cap = VERSION_PROBE_OUTPUT_CAP,
            "version probe output truncated to the cap",
        );
    }
    let mut buf = Vec::new();
    file.seek(SeekFrom::Start(0))?;
    file.by_ref().take(VERSION_PROBE_OUTPUT_CAP).read_to_end(&mut buf)?;
    Ok(buf)
}

/// Check whether `<bin_root>/<binary> <args…>` reports `version`.
///
/// `binary` is the catalog-resolved
/// [`crate::ResolvedInstall::primary_binary`] — the tool's `primary_binary`
/// index field, or its id when that field is absent. It used to be derived
/// here from a `match tool` table that only knew `"rust" => "rustc"`, which
/// silently returned the wrong name for every tool whose binary differs from
/// its id (python installs `python3`). `args` is the resolved
/// [`crate::ResolvedInstall::version_args`].
///
/// Returns `false` for any reason it can't confirm — missing binary,
/// non-zero exit, output without the version literal, I/O error, or a probe
/// still running past the 10s probe deadline. The caller must treat `false`
/// as "go install"; only `true` should skip.
#[must_use]
pub fn already_installed<S: AsRef<OsStr>>(
    binary: &str,
    args: &[S],
    version: &str,
    bin_root: &Path,
) -> bool {
    already_installed_within(binary, args, version, bin_root, VERSION_PROBE_TIMEOUT)
}

/// [`already_installed`] with an explicit probe deadline.
pub(crate) fn already_installed_within<S: AsRef<OsStr>>(
    binary: &str,
    args: &[S],
    version: &str,
    bin_root: &Path,
    timeout: Duration,
) -> bool {
    let binary = bin_root.join(binary);
    if !binary.exists() {
        return false;
    }
    // Retries a transient ETXTBSY; any other launch error, and a timeout,
    // still means "can't confirm → go install" per the contract above.
    let Ok(output) = run_version_check_within(&binary, args, &BTreeMap::new(), timeout) else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    stdout.contains(version) || stderr.contains(version)
}

/// Write an executable shim at `dir/name` that behaves like `go`: the
/// `version` subcommand prints `version_line`, anything else (including
/// `--version`) is a usage error with exit 2. Shared by the idempotency and
/// validate tests that pin the catalog-declared `version_args` (#811).
#[cfg(all(test, unix))]
pub(crate) fn write_subcommand_shim(dir: &Path, name: &str, version_line: &str) {
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
#[cfg(all(test, unix))]
pub(crate) fn write_sleeping_shim(dir: &Path, name: &str) {
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
#[cfg(all(test, unix))]
pub(crate) fn write_forking_shim(dir: &Path, name: &str) {
    use std::os::unix::fs::PermissionsExt as _;

    let path = dir.join(name);
    std::fs::write(
        &path,
        "#!/bin/sh\necho $$ > \"$0.pid\"\nsleep 30 &\necho $! > \"$0.bgpid\"\necho 'tool 1.0.0'\nwait\n",
    )
    .unwrap();
    let mut perms = std::fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&path, perms).unwrap();
}

/// Deadline for the [`write_sleeping_shim`] timeout tests; the shim runs 30s.
/// Long enough that a loaded runner has started `sh` and recorded the pid
/// before the kill, short enough to keep the suite fast.
#[cfg(all(test, unix))]
pub(crate) const TEST_TIMEOUT: Duration = Duration::from_secs(1);

/// Assert the probe child recorded by [`write_sleeping_shim`] no longer
/// exists — killed **and** reaped. A merely-dropped `Child` keeps running,
/// and a killed-but-unwaited one lingers as a zombie; `kill -0` succeeds on
/// both, so either leak fails here, where an elapsed-time bound alone would
/// pass (the timeout returns early whether or not the child is ended).
#[cfg(all(test, unix))]
pub(crate) fn assert_probe_child_gone(dir: &Path, name: &str) {
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
    let alive = Command::new("/bin/kill")
        .args(["-0", pid])
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(!alive, "the timed-out probe child (pid {pid}) must be killed and reaped");
}

/// The state field of a `/proc/<pid>/stat` line, or `None` if it does not
/// parse. `comm` (field 2) is parenthesised and may itself contain spaces or
/// `)`, so the state is the first field after the **last** `)`.
#[cfg(all(test, target_os = "linux"))]
fn proc_stat_state(stat: &str) -> Option<&str> {
    stat.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().next())
}

/// Whether `pid` is still running. A zombie counts as gone: it was killed,
/// and whether it is reaped depends on the reparenting ancestor (no init in
/// a bare `docker run` reaps nothing), which is not what the test pins. Linux
/// reads the state field of `/proc/<pid>/stat`; other unixes fall back to
/// `kill -0`, which cannot tell a zombie apart. Only a missing stat file means
/// gone — any other read error (no `/proc`, `hidepid`) or an unparsable stat
/// line panics, so an unobservable pid can never pass as a dead one.
#[cfg(all(test, unix))]
fn pid_is_running(pid: &str) -> bool {
    #[cfg(target_os = "linux")]
    {
        let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => stat,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return false,
            Err(e) => panic!("cannot observe pid {pid} via /proc ({e})"),
        };
        let state = proc_stat_state(&stat)
            .unwrap_or_else(|| panic!("unparsable /proc/{pid}/stat: {stat:?}"));
        state != "Z" && state != "X"
    }
    #[cfg(not(target_os = "linux"))]
    {
        Command::new("/bin/kill")
            .args(["-0", pid])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    }
}

/// Assert the background `sleep` forked by [`write_forking_shim`] is gone.
/// Once its parent dies it is reparented to an ancestor we do not control,
/// so poll briefly rather than check once: a killed orphan clears within
/// milliseconds, while a survivor is still running at the bound.
#[cfg(all(test, unix))]
pub(crate) fn assert_forked_descendant_gone(dir: &Path, name: &str) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

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
            let subscriber = tracing_subscriber::fmt()
                .with_writer(move || writer.clone())
                .with_ansi(false)
                .finish();
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
        fs::write(&path, format!("#!/bin/sh\necho 'tool 1.2.3'\nhead -c {flood} /dev/zero\n"))
            .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(already_installed("tool", VERSION_ARGS, "1.2.3", dir.path()));
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
    /// immediately — a near-zero elapsed time proves the retry loop's backoff
    /// (which would add ≥`ETXTBSY_BACKOFF` per attempt) never ran. Serialized
    /// so the tight timing bound doesn't share the runner with shim-spawning
    /// tests.
    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn run_version_check_returns_non_etxtbsy_error_without_retrying() {
        use std::time::Instant;

        let dir = tempdir().unwrap();
        let missing = dir.path().join("does-not-exist");

        let start = Instant::now();
        let result = run_version_check(&missing, VERSION_ARGS, &BTreeMap::new());
        let elapsed = start.elapsed();

        let err = result.expect_err("a missing binary must surface its launch error");
        assert_ne!(
            err.raw_os_error(),
            Some(ETXTBSY),
            "the induced error must be a genuine non-ETXTBSY failure",
        );
        assert!(
            elapsed < ETXTBSY_BACKOFF,
            "a non-ETXTBSY error must return before any backoff sleep (elapsed {elapsed:?})",
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
}
