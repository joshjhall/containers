//! Streaming command runner behind [`super::ProcessRunner`]'s `run_streaming`.
//!
//! Spawns a child with its own cwd and env, drains stdout and stderr
//! concurrently, bounds each forwarded line at [`MAX_LINE_BYTES`], keeps a
//! [`STDERR_TAIL_LINES`] stderr tail for the error report, and stops reading
//! [`PIPE_DRAIN_GRACE`] after the child exits. Split out of `mod.rs` (#1434)
//! so the module root stays dispatch plus the runner trait.

use std::collections::{BTreeMap, VecDeque};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;

use super::CommandOutcome;
use crate::error::{LuggageError, Result};

/// Stderr lines a streamed command keeps for its error report.
///
/// Everything is forwarded to the log as it arrives; only this tail is held
/// in memory, because a PGO python build writes far more stderr than is
/// worth buffering and the cause of a failure is almost always at the end.
pub const STDERR_TAIL_LINES: usize = 40;

/// A command run through [`super::CommandRunner::run_streaming`].
#[derive(Debug, Clone, Copy)]
pub struct StreamingCommand<'a> {
    /// Program to execute — an absolute path or a bare name looked up on
    /// `PATH`.
    pub program: &'a str,
    /// Argument vector.
    pub args: &'a [String],
    /// Working directory for the child.
    pub cwd: &'a Path,
    /// Variables added to the inherited environment.
    pub env: &'a BTreeMap<String, String>,
}

/// One [`super::CommandRunner::run_streaming`] call as [`super::RecordingRunner`] saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamingCall {
    /// Program executed.
    pub program: String,
    /// Argument vector.
    pub args: Vec<String>,
    /// Working directory the child was given.
    pub cwd: PathBuf,
    /// Environment additions the child was given.
    pub env: BTreeMap<String, String>,
}

/// Keeps the last [`STDERR_TAIL_LINES`] lines of a stream.
#[derive(Debug, Default)]
pub(super) struct Tail(VecDeque<String>);

impl Tail {
    pub(super) fn push(&mut self, line: &str) {
        if self.0.len() == STDERR_TAIL_LINES {
            self.0.pop_front();
        }
        self.0.push_back(line.to_owned());
    }

    pub(super) fn into_bytes(self) -> Vec<u8> {
        Vec::from(self.0).join("\n").into_bytes()
    }
}

/// Which pipe a streamed line came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Pipe {
    Stdout,
    Stderr,
}

/// Longest line [`pump`] forwards; anything past it is dropped up to the
/// next newline and the line is marked truncated.
///
/// A step that writes a huge newline-free stream would otherwise grow one
/// line buffer without limit — the stderr tail bounds how many lines are
/// kept, not how long each is.
pub const MAX_LINE_BYTES: usize = 64 * 1024;

/// Suffix appended to a line [`pump`] cut at [`MAX_LINE_BYTES`].
pub const TRUNCATED_MARKER: &str = " [line truncated]";

/// Prefix of the line [`pump`] forwards when reading a pipe fails.
pub const READ_ERROR_MARKER: &str = "[luggage: failed reading build output:";

/// Forward every line of `pipe` to `tx`, tagged with `which`.
///
/// Lossy UTF-8: a compiler printing a non-UTF-8 byte must not stall the
/// stream or abort the build's log. A final line with no trailing newline
/// is still forwarded.
///
/// A read error ends the stream, but never silently: whatever was already
/// read is forwarded, then a [`READ_ERROR_MARKER`] line naming the error, so
/// a log that stops short says why rather than looking like a quiet build.
pub(super) fn pump(pipe: impl Read, which: Pipe, tx: &mpsc::Sender<(Pipe, String)>) {
    let mut reader = BufReader::new(pipe);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        // `take` caps how much one read can buffer; one byte over the cap
        // is what tells a cut line from one that fits exactly.
        let limit = u64::try_from(MAX_LINE_BYTES).unwrap_or(u64::MAX) + 1;
        let mut failure = match (&mut reader).take(limit).read_until(b'\n', &mut buf) {
            Ok(0) => return,
            Ok(_) => None,
            Err(e) => Some(e),
        };
        let truncated =
            failure.is_none() && buf.len() > MAX_LINE_BYTES && buf.last() != Some(&b'\n');
        if truncated {
            buf.truncate(MAX_LINE_BYTES);
            // Discard the rest of the oversized line, a bounded chunk at a
            // time, so the next forwarded line starts on a real boundary.
            failure = discard_through_newline(&mut reader).err();
        }
        if !buf.is_empty() {
            let text = String::from_utf8_lossy(&buf);
            let mut line = text.trim_end_matches(['\n', '\r']).to_owned();
            if truncated {
                line.push_str(TRUNCATED_MARKER);
            }
            if tx.send((which, line)).is_err() {
                return;
            }
        }
        if let Some(e) = failure {
            tracing::warn!("failed reading build step {which:?}: {e}");
            let _ = tx.send((which, format!("{READ_ERROR_MARKER} {e}]")));
            return;
        }
    }
}

/// Consume `reader` up to and including the next newline (or EOF) without
/// buffering more than one internal chunk.
fn discard_through_newline(reader: &mut impl BufRead) -> std::io::Result<()> {
    loop {
        let chunk = reader.fill_buf()?;
        if chunk.is_empty() {
            return Ok(());
        }
        if let Some(pos) = chunk.iter().position(|&b| b == b'\n') {
            reader.consume(pos + 1);
            return Ok(());
        }
        let len = chunk.len();
        reader.consume(len);
    }
}

/// Body of [`super::ProcessRunner`]'s `run_streaming`: spawn `cmd` and hand
/// each output line to `on_line` as it is produced.
pub(super) fn run(
    cmd: &StreamingCommand<'_>,
    on_line: &mut dyn FnMut(&str),
) -> Result<CommandOutcome> {
    let program = cmd.program;
    let mut child = Command::new(program)
        .args(cmd.args)
        .current_dir(cmd.cwd)
        .envs(cmd.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| LuggageError::InstallStageFailed {
            stage: "spawn",
            message: format!("failed to launch `{program}` in {}: {e}", cmd.cwd.display()),
        })?;

    // Both pipes are drained concurrently: reading one to EOF before the
    // other deadlocks once the unread pipe's buffer fills and the child
    // blocks writing to it. Lines from both arrive on one channel, so the
    // log interleaves them in roughly the order they were written.
    //
    // The child is waited on by its own thread rather than after the
    // pipes reach EOF. EOF only arrives once *every* holder of the write
    // ends closes them, and a step that backgrounds a daemon (a ccache
    // server, a build-tool daemon) leaves a grandchild holding them after
    // the step itself has exited — waiting for EOF first would hang the
    // build forever. Pump threads are detached for the same reason: one
    // stuck on a held pipe must not keep this call from returning.
    let (tx, rx) = mpsc::channel();
    if let Some(pipe) = child.stdout.take() {
        let tx = tx.clone();
        std::thread::spawn(move || pump(pipe, Pipe::Stdout, &tx));
    }
    if let Some(pipe) = child.stderr.take() {
        let tx = tx.clone();
        std::thread::spawn(move || pump(pipe, Pipe::Stderr, &tx));
    }
    let (exit_tx, exit_rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = exit_tx.send(child.wait());
    });
    drop(tx);

    let mut tail = Tail::default();
    let mut forward = |which: Pipe, line: String| {
        if which == Pipe::Stderr {
            tail.push(&line);
        }
        on_line(&line);
    };
    let status = loop {
        // Poll the exit at a short interval while forwarding output, so
        // a child that exits with its pipes still held is noticed.
        match rx.recv_timeout(EXIT_POLL_INTERVAL) {
            Ok((which, line)) => forward(which, line),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            // Both pumps hit EOF: the exit is all that remains.
            Err(mpsc::RecvTimeoutError::Disconnected) => break exit_rx.recv(),
        }
        if let Ok(status) = exit_rx.try_recv() {
            break Ok(status);
        }
    };
    let status = resolve_exit(program, status)?;

    // The step has exited. Drain what is left, but only for a bounded
    // grace period: past it, whatever still holds the pipes is not the
    // step, and its output is not the step's to report.
    let deadline = std::time::Instant::now() + PIPE_DRAIN_GRACE;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        match rx.recv_timeout(remaining) {
            Ok((which, line)) => forward(which, line),
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let marker = format!(
                    "{PIPES_HELD_MARKER} stopped reading {}s after `{program}` exited \
                     (a background process it started still holds its output)]",
                    PIPE_DRAIN_GRACE.as_secs(),
                );
                tracing::warn!("{marker}");
                forward(Pipe::Stderr, marker);
                break;
            }
        }
    }

    Ok(CommandOutcome { status: status.code(), stdout: Vec::new(), stderr: tail.into_bytes() })
}

/// Turn what the waiter thread delivered into the step's exit status.
///
/// Both failure shapes — `wait()` itself erroring, and the waiter thread
/// dying before it could report — are stage `"wait"`: the child was
/// launched and ran, so `"spawn"` would point at the wrong problem.
pub(super) fn resolve_exit(
    program: &str,
    delivered: std::result::Result<std::io::Result<std::process::ExitStatus>, mpsc::RecvError>,
) -> Result<std::process::ExitStatus> {
    delivered
        .unwrap_or_else(|_| Err(std::io::Error::other("waiter thread exited without a status")))
        .map_err(|e| LuggageError::InstallStageFailed {
            stage: "wait",
            message: format!("failed to wait for `{program}`: {e}"),
        })
}

/// How often [`super::ProcessRunner`]'s `run_streaming` checks whether the
/// child has exited while forwarding its output.
const EXIT_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

/// How long [`super::ProcessRunner`]'s `run_streaming` keeps reading after the
/// child exits, before concluding a background process is holding its pipes.
pub const PIPE_DRAIN_GRACE: std::time::Duration = std::time::Duration::from_secs(5);

/// Prefix of the line forwarded when output pipes outlive the step.
pub const PIPES_HELD_MARKER: &str = "[luggage: output pipes still open:";
