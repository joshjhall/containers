//! Bounded subprocess execution.
//!
//! The label sync shells out to `gh`/`glab`/`git`. Those CLIs can block
//! indefinitely — an expired token triggers an interactive re-auth or browser
//! flow, and a stalled network call never returns — which would hang
//! `labels sync` / `setup` forever with no feedback. That is especially bad in
//! CI, where there is no human to notice and Ctrl-C the process.
//!
//! [`run_with_timeout`] wraps [`std::process::Command`] with a deadline: it
//! spawns the child, drains stdout/stderr on reader threads (so a chatty child
//! can't deadlock on a full pipe), polls for exit against the deadline, and
//! kills the child if the timeout expires. Standard library only — no extra
//! dependency, so the workspace `Cargo.lock` is untouched.

use std::io::{self, Read};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Default wall-clock limit for a single tracker/`git` CLI invocation.
///
/// Generous enough for a slow-but-live network round-trip, short enough that a
/// wedged interactive prompt fails the run in a bounded time rather than
/// hanging until the operator intervenes.
pub const DEFAULT_CLI_TIMEOUT: Duration = Duration::from_mins(2);

/// How often [`run_with_timeout`] polls the child for completion.
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Why a bounded subprocess run failed.
#[derive(Debug)]
pub enum ExecError {
    /// The child could not be spawned (e.g. the binary is not on `PATH`).
    Spawn(io::Error),
    /// The child was still running when the deadline elapsed and was killed.
    Timeout(Duration),
}

impl std::fmt::Display for ExecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Spawn(e) => write!(f, "{e}"),
            Self::Timeout(d) => write!(f, "timed out after {}s", d.as_secs()),
        }
    }
}

impl std::error::Error for ExecError {}

/// Run `cmd`, returning its [`Output`] or an [`ExecError`] if it cannot be
/// spawned or does not finish within `timeout`.
///
/// stdin is set to null so a child that tries to prompt reads EOF and gives up
/// instead of blocking on the terminal. stdout and stderr are captured on
/// separate threads to avoid a pipe-buffer deadlock with a verbose child.
///
/// # Errors
///
/// Returns [`ExecError::Spawn`] if the process cannot start, or
/// [`ExecError::Timeout`] if it is still running when `timeout` elapses (the
/// child is killed and reaped before returning).
pub fn run_with_timeout(mut cmd: Command, timeout: Duration) -> Result<Output, ExecError> {
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(ExecError::Spawn)?;

    // Take the pipes and drain each on its own thread. Holding onto the pipes
    // and reading only after the child exits would deadlock if the child fills
    // a pipe buffer and blocks waiting for us to read.
    let stdout_reader = child.stdout.take().map(spawn_drain);
    let stderr_reader = child.stderr.take().map(spawn_drain);

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if Instant::now() >= deadline {
                    // Best-effort kill + reap so we don't leak a zombie.
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ExecError::Timeout(timeout));
                }
                std::thread::sleep(POLL_INTERVAL);
            }
            Err(e) => return Err(ExecError::Spawn(e)),
        }
    };

    let stdout = stdout_reader.map(join_drain).unwrap_or_default();
    let stderr = stderr_reader.map(join_drain).unwrap_or_default();
    Ok(Output { status, stdout, stderr })
}

/// Spawn a thread that reads a child pipe to EOF.
fn spawn_drain<R: Read + Send + 'static>(mut reader: R) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf);
        buf
    })
}

/// Join a drain thread, treating a panicked reader as empty output.
fn join_drain(handle: std::thread::JoinHandle<Vec<u8>>) -> Vec<u8> {
    handle.join().unwrap_or_default()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn quick_command_succeeds() {
        let mut cmd = Command::new("echo");
        cmd.arg("hello");
        let out = run_with_timeout(cmd, Duration::from_secs(5)).unwrap();
        assert!(out.status.success());
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "hello");
    }

    #[test]
    fn slow_command_times_out() {
        let mut cmd = Command::new("sleep");
        cmd.arg("5");
        let start = Instant::now();
        let err = run_with_timeout(cmd, Duration::from_millis(100)).unwrap_err();
        assert!(matches!(err, ExecError::Timeout(_)), "expected timeout, got {err:?}");
        // The kill must be prompt — nowhere near the full 5s sleep.
        assert!(start.elapsed() < Duration::from_secs(2), "kill was not prompt");
    }

    #[test]
    fn spawn_failure_is_reported() {
        let cmd = Command::new("stibbons-no-such-binary-xyz");
        let err = run_with_timeout(cmd, Duration::from_secs(5)).unwrap_err();
        assert!(matches!(err, ExecError::Spawn(_)), "expected spawn error, got {err:?}");
    }

    #[test]
    fn large_output_does_not_deadlock() {
        // ~256 KiB of stdout — far more than a pipe buffer holds, so a
        // read-after-exit implementation would deadlock here.
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "head -c 262144 /dev/zero | tr '\\0' 'a'"]);
        let out = run_with_timeout(cmd, Duration::from_secs(10)).unwrap();
        assert!(out.status.success());
        assert_eq!(out.stdout.len(), 262_144);
    }
}
