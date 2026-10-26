//! Unit tests for the streaming command runner.
//!
//! Real `sh` children for the [`ProcessRunner`] plumbing (cwd, env, line
//! caps, the drain grace), plus direct [`pump`] and [`resolve_exit`] calls
//! with fake readers for the failure paths a real pipe will not produce on
//! demand.

use super::*;

use std::fs;

use tempfile::tempdir;

use crate::installer::methods::{CommandRunner, ProcessRunner, RecordingRunner};

/// Every line a step writes reaches the log callback, stdout then stderr,
/// as `RecordingRunner` replays them — the hook the per-feature log uses.
#[test]
fn recording_runner_streams_lines_through_the_callback() {
    let runner = RecordingRunner::new();
    runner.set_outcome(
        "make",
        CommandOutcome {
            status: Some(0),
            stdout: b"compiling a.c\ncompiling b.c\n".to_vec(),
            stderr: b"warning: x\n".to_vec(),
        },
    );
    let env = BTreeMap::new();
    let cmd = StreamingCommand { program: "make", args: &[], cwd: Path::new("/src"), env: &env };
    let mut seen = Vec::new();
    let outcome = runner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();

    assert_eq!(seen, ["compiling a.c", "compiling b.c", "warning: x"]);
    assert!(outcome.success());
    assert_eq!(outcome.stderr, b"warning: x");
}

/// The production runner, against a real `sh`: it runs in the requested
/// cwd with the requested env, forwards both pipes, and keeps a bounded
/// stderr tail. No compiler involved — this is the plumbing python's
/// `make` will go through.
#[test]
fn process_runner_streams_with_cwd_env_and_bounded_tail() {
    let dir = tempdir().unwrap();
    let env = BTreeMap::from([("LUGGAGE_TEST_VAR".to_owned(), "hello".to_owned())]);
    let script = "pwd; echo \"$LUGGAGE_TEST_VAR\"; \
                  i=0; while [ $i -lt 100 ]; do echo err$i >&2; i=$((i+1)); done; exit 3";
    let args = vec!["-c".to_owned(), script.to_owned()];
    let cmd = StreamingCommand { program: "sh", args: &args, cwd: dir.path(), env: &env };

    let mut seen = Vec::new();
    let outcome = ProcessRunner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();

    assert_eq!(outcome.status, Some(3));
    let cwd = fs::canonicalize(dir.path()).unwrap();
    assert!(seen.iter().any(|l| Path::new(l) == cwd), "pwd should be the cwd: {seen:?}");
    assert!(seen.iter().any(|l| l == "hello"), "env should reach the child: {seen:?}");
    assert_eq!(seen.iter().filter(|l| l.starts_with("err")).count(), 100, "every line streams");

    let tail = String::from_utf8(outcome.stderr).unwrap();
    let tail: Vec<_> = tail.lines().collect();
    assert_eq!(tail.len(), STDERR_TAIL_LINES);
    assert_eq!(*tail.last().unwrap(), "err99");
}

/// A program that cannot be spawned is a spawn failure naming the program,
/// not a `BuildStepFailed` with a made-up exit code.
#[test]
fn process_runner_spawn_failure_is_install_stage_failed() {
    let dir = tempdir().unwrap();
    let env = BTreeMap::new();
    let cmd = StreamingCommand {
        program: "/nonexistent/luggage-no-such-binary",
        args: &[],
        cwd: dir.path(),
        env: &env,
    };
    let err = ProcessRunner.run_streaming(&cmd, &mut |_| {}).unwrap_err();
    match err {
        LuggageError::InstallStageFailed { stage, message } => {
            assert_eq!(stage, "spawn");
            assert!(message.contains("luggage-no-such-binary"), "{message}");
        }
        other => panic!("expected InstallStageFailed, got {other:?}"),
    }
}

/// Run `script` under the real runner, returning (outcome, streamed lines).
fn sh_stream(script: &str) -> (CommandOutcome, Vec<String>) {
    let dir = tempdir().unwrap();
    let env = BTreeMap::new();
    let args = vec!["-c".to_owned(), script.to_owned()];
    let cmd = StreamingCommand { program: "sh", args: &args, cwd: dir.path(), env: &env };
    let mut seen = Vec::new();
    let outcome = ProcessRunner.run_streaming(&cmd, &mut |l| seen.push(l.to_owned())).unwrap();
    (outcome, seen)
}

/// A step killed by a signal has no exit code; that reaches the error as
/// `status: None` (rendered "exit signal"), never a made-up number.
#[test]
fn process_runner_reports_signal_death_as_no_status() {
    let (outcome, _) = sh_stream("kill -9 $$");
    assert_eq!(outcome.status, None);
    assert!(!outcome.success());
}

/// The last line of output often has no trailing newline (a `printf`, a
/// crashed compiler); it must still be forwarded, and CRLF is trimmed.
#[test]
fn process_runner_forwards_unterminated_and_crlf_lines() {
    let (_, seen) = sh_stream("printf 'dos\\r\\nlast'");
    assert_eq!(seen, ["dos", "last"]);
}

/// Non-UTF-8 output is replaced, not dropped and not fatal.
#[test]
fn process_runner_survives_non_utf8_output() {
    let (outcome, seen) = sh_stream("printf 'a\\377b\\nnext\\n'");
    assert!(outcome.success());
    assert_eq!(seen, ["a\u{FFFD}b", "next"]);
}

/// A newline-free stream larger than the line cap is cut to the cap and
/// marked, and the line after it still arrives intact — memory stays
/// bounded by `MAX_LINE_BYTES`, not by the child's output.
#[test]
fn process_runner_truncates_oversized_lines() {
    use super::{MAX_LINE_BYTES, TRUNCATED_MARKER};
    // 200 KiB of 'x' with no newline, then a normal line.
    let (outcome, seen) = sh_stream("head -c 204800 /dev/zero | tr '\\0' x; printf '\\nafter\\n'");
    assert!(outcome.success());
    assert_eq!(seen.len(), 2, "one truncated line then `after`: {:?}", seen.len());
    assert!(seen[0].ends_with(TRUNCATED_MARKER));
    assert_eq!(seen[0].len(), MAX_LINE_BYTES + TRUNCATED_MARKER.len());
    assert_eq!(seen[1], "after");
}

/// A pipe that fails mid-stream must not end the log silently: the bytes
/// read so far are forwarded, then a marker naming the error (the repo's
/// "degradation must be loud" rule).
#[test]
fn pump_reports_a_read_error_instead_of_ending_silently() {
    use super::{Pipe, READ_ERROR_MARKER, pump};

    /// Yields `data` once, then fails every read.
    struct FailsAfter(Option<&'static [u8]>);
    impl std::io::Read for FailsAfter {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let Some(data) = self.0.take() else {
                return Err(std::io::Error::other("pipe went away"));
            };
            out[..data.len()].copy_from_slice(data);
            Ok(data.len())
        }
    }

    let (tx, rx) = std::sync::mpsc::channel();
    pump(FailsAfter(Some(b"configure: ok\npartial")), Pipe::Stderr, &tx);
    drop(tx);
    let lines: Vec<String> = rx.into_iter().map(|(_, l)| l).collect();

    assert_eq!(lines.len(), 3, "{lines:?}");
    assert_eq!(lines[0], "configure: ok");
    assert_eq!(lines[1], "partial", "bytes read before the error are kept");
    assert!(lines[2].starts_with(READ_ERROR_MARKER), "{lines:?}");
    assert!(lines[2].contains("pipe went away"), "{lines:?}");
}

/// A line of exactly the cap is not truncated — the cut is strictly for
/// lines that exceed it.
#[test]
fn process_runner_keeps_a_line_of_exactly_the_cap() {
    use super::{MAX_LINE_BYTES, TRUNCATED_MARKER};
    let (_, seen) =
        sh_stream(&format!("head -c {MAX_LINE_BYTES} /dev/zero | tr '\\0' y; printf '\\n'"));
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].len(), MAX_LINE_BYTES);
    assert!(!seen[0].ends_with(TRUNCATED_MARKER));
}

/// A read error while discarding the tail of an oversized line still
/// forwards the truncated line, then the error marker.
#[test]
fn pump_reports_a_read_error_after_a_truncated_line() {
    use super::{MAX_LINE_BYTES, Pipe, READ_ERROR_MARKER, TRUNCATED_MARKER, pump};

    /// Yields `MAX_LINE_BYTES + 10` bytes with no newline, then fails.
    struct LongThenFails(usize);
    impl std::io::Read for LongThenFails {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            if self.0 == 0 {
                return Err(std::io::Error::other("pipe went away"));
            }
            let n = self.0.min(out.len());
            out[..n].fill(b'z');
            self.0 -= n;
            Ok(n)
        }
    }

    let (tx, rx) = std::sync::mpsc::channel();
    pump(LongThenFails(MAX_LINE_BYTES + 10), Pipe::Stdout, &tx);
    drop(tx);
    let lines: Vec<String> = rx.into_iter().map(|(_, l)| l).collect();

    assert_eq!(lines.len(), 2, "{:?}", lines.iter().map(String::len).collect::<Vec<_>>());
    assert!(lines[0].ends_with(TRUNCATED_MARKER));
    assert!(lines[1].starts_with(READ_ERROR_MARKER), "{}", lines[1]);
}

/// A step that backgrounds a process inheriting its output (a ccache
/// server, a build daemon) must not hang the build: the step's own exit is
/// collected, and the still-held pipes are reported, not waited on forever.
#[test]
fn process_runner_returns_when_a_background_child_holds_the_pipes() {
    use super::{PIPE_DRAIN_GRACE, PIPES_HELD_MARKER};

    let started = std::time::Instant::now();
    let (outcome, seen) = sh_stream("sleep 30 & echo done");
    let elapsed = started.elapsed();

    assert!(outcome.success(), "{outcome:?}");
    assert!(seen.iter().any(|l| l == "done"), "{seen:?}");
    assert!(seen.iter().any(|l| l.starts_with(PIPES_HELD_MARKER)), "{seen:?}");
    assert!(
        elapsed < PIPE_DRAIN_GRACE + std::time::Duration::from_secs(10),
        "must return after the drain grace, not when `sleep 30` exits: {elapsed:?}"
    );
}

/// The child was launched and ran, so a failure collecting its status is
/// stage `"wait"`, never `"spawn"` — for both ways it can fail.
#[test]
fn wait_failures_are_reported_as_the_wait_stage() {
    use super::resolve_exit;

    let failed_wait = resolve_exit("make", Ok(Err(std::io::Error::other("ECHILD"))));
    let lost_waiter = resolve_exit("make", Err(std::sync::mpsc::RecvError));
    for (err, needle) in [(failed_wait, "ECHILD"), (lost_waiter, "waiter thread")] {
        match err {
            Err(LuggageError::InstallStageFailed { stage, message }) => {
                assert_eq!(stage, "wait");
                assert!(message.contains("`make`") && message.contains(needle), "{message}");
            }
            other => panic!("expected wait-stage failure, got {other:?}"),
        }
    }
}

/// A normal step whose pipes close with it does not wait out the grace
/// period and does not emit the held-pipes marker.
#[test]
fn process_runner_does_not_wait_out_the_grace_on_a_normal_exit() {
    use super::{PIPE_DRAIN_GRACE, PIPES_HELD_MARKER};

    let started = std::time::Instant::now();
    let (outcome, seen) = sh_stream("echo quick");
    assert!(outcome.success());
    assert_eq!(seen, ["quick"]);
    assert!(!seen.iter().any(|l| l.starts_with(PIPES_HELD_MARKER)));
    assert!(started.elapsed() < PIPE_DRAIN_GRACE, "{:?}", started.elapsed());
}
