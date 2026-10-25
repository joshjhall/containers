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

// Spawn attempts made by `run_version_check_within` on this thread, so a test
// can pin the retry count exactly instead of inferring it from wall-clock
// backoff (#1408). Thread-local because the loop runs on the caller's thread,
// so concurrently running tests can't skew each other's count.
#[cfg(test)]
thread_local! {
    static SPAWN_ATTEMPTS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

/// Default deadline for one version-probe exec (#1344).
///
/// A `--version` answers in milliseconds; the headroom is for JVM-style tools
/// cold-starting under qemu emulation. Since #811 the argv is a catalog input, so a misdeclared
/// `version_args` that starts a long-running subcommand (`serve`, a daemon
/// verb, a tool blocking on a lock) would otherwise hang the install forever.
/// Hitting it means either that argv is wrong or the probe is genuinely slow
/// on this host (qemu emulation, a cold cache) — the latter is what
/// [`VERSION_PROBE_TIMEOUT_ENV`] is for (#1358).
pub const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Environment variable overriding [`VERSION_PROBE_TIMEOUT`], in whole seconds.
pub const VERSION_PROBE_TIMEOUT_ENV: &str = "LUGGAGE_VERSION_PROBE_TIMEOUT";

/// Largest accepted [`VERSION_PROBE_TIMEOUT_ENV`]: one day.
///
/// Far beyond any real probe, but bounded, so an operator typo (an extra
/// digit, a value in the wrong unit) is a clean error instead of a probe that
/// can effectively never time out. This is input validation only — panic
/// safety for an unrepresentable deadline lives in `wait_within`'s
/// `checked_add`, which stays as defense in depth: the library path checks
/// [`crate::InstallerOptions::version_probe_timeout`] against the same bound
/// in [`crate::InstallerOptions::validate`], but `wait_within` cannot assume
/// every caller came through it.
const MAX_VERSION_PROBE_TIMEOUT_SECS: u64 = 24 * 60 * 60;

/// Largest accepted version-probe deadline (one day): the bound both the
/// [`VERSION_PROBE_TIMEOUT_ENV`] parser and
/// [`crate::InstallerOptions::validate`] enforce.
pub const MAX_VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(MAX_VERSION_PROBE_TIMEOUT_SECS);

/// Smallest accepted version-probe deadline: one second, the smallest value
/// [`VERSION_PROBE_TIMEOUT_ENV`] can express. Anything shorter kills every
/// probe on its first poll (#1399).
pub const MIN_VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

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

/// Resolve the version-probe deadline from the environment.
///
/// Returns [`VERSION_PROBE_TIMEOUT`] when `LUGGAGE_VERSION_PROBE_TIMEOUT` is
/// unset or empty, and a hard error when it is malformed — the same contract,
/// and the same reasons, as
/// [`crate::installer::methods::archive_limit::max_extract_bytes_from_env`]:
/// an operator who raised the deadline for a slow emulated build must not
/// silently keep the default.
///
/// # Errors
///
/// [`crate::LuggageError::Catalog`] when the value is set but is not a whole
/// number of seconds between 1 and one day.
pub fn version_probe_timeout_from_env() -> crate::error::Result<Duration> {
    parse_version_probe_timeout(
        crate::installer::tuning_env_var(VERSION_PROBE_TIMEOUT_ENV)?.as_deref(),
    )
}

/// The value half of [`version_probe_timeout_from_env`], split out because
/// `unsafe_code = "forbid"` rules out `std::env::set_var` in tests.
///
/// # Errors
///
/// [`crate::LuggageError::Catalog`] when the value is set but is not a whole
/// number of seconds between 1 and one day.
pub fn parse_version_probe_timeout(raw: Option<&str>) -> crate::error::Result<Duration> {
    let Some(raw) = raw else { return Ok(VERSION_PROBE_TIMEOUT) };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(VERSION_PROBE_TIMEOUT);
    }
    match trimmed.parse::<u64>() {
        Ok(0) => Err(crate::error::LuggageError::Catalog(format!(
            "{VERSION_PROBE_TIMEOUT_ENV} is `0`, which would time out every version probe; \
             unset it to use the default of {}s",
            VERSION_PROBE_TIMEOUT.as_secs(),
        ))),
        Ok(n) if n > MAX_VERSION_PROBE_TIMEOUT_SECS => {
            Err(crate::error::LuggageError::Catalog(format!(
                "{VERSION_PROBE_TIMEOUT_ENV} is `{trimmed}`, above the {MAX_VERSION_PROBE_TIMEOUT_SECS}s \
                 (one day) maximum",
            )))
        }
        Ok(n) => Ok(Duration::from_secs(n)),
        Err(e) => Err(crate::error::LuggageError::Catalog(format!(
            "{VERSION_PROBE_TIMEOUT_ENV} must be a positive whole number of seconds, \
             got `{raw}`: {e}",
        ))),
    }
}

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
/// killed. Because the group is not luggage's, a terminal Ctrl-C reaches
/// luggage but not the probe. The group is therefore registered with
/// [`super::interrupt`] until the probe is reaped, and a binary that called
/// [`crate::install_interrupt_handler`] (the `luggage` CLI does) kills it on
/// SIGINT/SIGTERM before exiting (#1370). A library caller that skips that
/// call keeps the gap. A probe that exits on its own has its group killed
/// too, before the leader is reaped, so a descendant it backgrounded (a JVM
/// launcher's daemon, a script's `cmd &`) does not outlive it (#1371); on
/// OpenBSD and Cygwin, which lack the `waitid` this needs, it still does. One
/// gap remains regardless: a descendant that moved itself to another group or
/// session escapes, as with any `killpg`.
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
    // On unix the guard keeps the probe's group registered for the interrupt
    // handler until the probe is reaped, and no longer: once reaped, its pid
    // may be recycled by an unrelated process. `TrackedChild` reaps and
    // deregisters in one critical section.
    let (mut child, tracked) = loop {
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
        #[cfg(test)]
        SPAWN_ATTEMPTS.set(SPAWN_ATTEMPTS.get() + 1);
        #[cfg(unix)]
        let spawned = super::interrupt::spawn_tracked(&mut command);
        #[cfg(not(unix))]
        let spawned = command.spawn().map(|child| (child, ()));
        match spawned {
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && attempt < ETXTBSY_RETRIES => {
                attempt += 1;
                thread::sleep(ETXTBSY_BACKOFF);
            }
            other => break other?,
        }
    };

    #[cfg(unix)]
    let status = wait_within(&mut TrackedChild { child: &mut child, tracked: &tracked }, timeout)?;
    #[cfg(not(unix))]
    let status = {
        let () = tracked;
        wait_within(&mut child, timeout)?
    };

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

/// A probe [`Child`] whose every reap also deregisters its process group from
/// the interrupt registry, atomically with respect to the interrupt handler
/// (see [`super::interrupt::Tracked::reap_locked`]).
#[cfg(unix)]
struct TrackedChild<'a> {
    child: &'a mut Child,
    tracked: &'a super::interrupt::Tracked,
}

#[cfg(unix)]
impl ProbeChild for TrackedChild<'_> {
    fn poll(&mut self) -> io::Result<Option<ExitStatus>> {
        self.tracked.reap_locked(|| {
            #[cfg(not(any(target_os = "openbsd", target_os = "cygwin")))]
            kill_group_if_exited(self.child)?;
            self.child.try_wait()
        })
    }

    fn kill_all(&mut self) {
        self.child.kill_all();
    }

    fn reap(&mut self) {
        let _ = self.tracked.reap_locked(|| {
            self.child.reap();
            Ok(Some(()))
        });
    }
}

/// If the probe leader has exited, SIGKILL its process group so a descendant
/// it backgrounded does not outlive the probe (#1371). Must run before the
/// reap: `WNOWAIT` leaves the leader a zombie, which keeps its pid — and so
/// the pgid — reserved through the `killpg`. Killing after the reap could
/// signal an unrelated group that was handed the recycled pid. With nothing
/// left running, the kill reaches only the zombie leader, a no-op; its result
/// is ignored either way. ECHILD (the child already reaped, which the poll
/// loop never does before this point) is left for `try_wait` to report.
#[cfg(all(unix, not(any(target_os = "openbsd", target_os = "cygwin"))))]
fn kill_group_if_exited(child: &Child) -> io::Result<()> {
    use rustix::process::{WaitId, WaitIdOptions};

    let pid = rustix::process::Pid::from_child(child);
    let peek = WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT;
    match rustix::process::waitid(WaitId::Pid(pid), peek) {
        Ok(Some(_)) => {
            let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
            Ok(())
        }
        Ok(None) | Err(rustix::io::Errno::CHILD) => Ok(()),
        Err(e) => Err(e.into()),
    }
}

/// Poll `child` until it exits or `timeout` elapses. On timeout, or if a poll
/// itself errors, the child is killed and reaped before returning, so an
/// early return never leaves it running or a zombie.
///
/// A `timeout` too large to add to `Instant::now()` means no deadline rather
/// than a panic (#1358). Both the env reader and
/// [`crate::InstallerOptions::validate`] cap the value (#1399), but this
/// function takes any `Duration` and must not rely on that.
fn wait_within(child: &mut impl ProbeChild, timeout: Duration) -> io::Result<ExitStatus> {
    let deadline = Instant::now().checked_add(timeout);
    loop {
        let polled = child.poll();
        let timed_out = matches!(polled, Ok(None)) && deadline.is_some_and(|d| Instant::now() >= d);
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
    capture_file_in(&std::env::temp_dir())
}

/// [`capture_file`] against an explicit directory — the seam that makes the
/// failure path testable without pointing `TMPDIR` elsewhere, which needs
/// `std::env::set_var` (ruled out by `unsafe_code = "forbid"`).
fn capture_file_in(dir: &Path) -> io::Result<File> {
    tempfile::tempfile_in(dir)
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
/// still running past the default [`VERSION_PROBE_TIMEOUT`]. The caller must
/// treat `false` as "go install"; only `true` should skip.
#[must_use]
pub fn already_installed<S: AsRef<OsStr>>(
    binary: &str,
    args: &[S],
    version: &str,
    bin_root: &Path,
) -> bool {
    already_installed_within(binary, args, version, bin_root, VERSION_PROBE_TIMEOUT)
}

/// [`already_installed`] with an explicit probe deadline — the installer's
/// path, which passes [`crate::InstallerOptions::version_probe_timeout`].
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

#[cfg(test)]
#[path = "idempotency_tests.rs"]
pub(crate) mod tests;
