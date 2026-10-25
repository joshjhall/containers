//! Tests for the interrupt registry and the SIGINT/SIGTERM watcher (#1370).

use super::*;
use std::os::unix::process::{CommandExt as _, ExitStatusExt as _};
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use crate::installer::idempotency::tests::{KillOnDrop, pid_is_running, write_forking_shim};
use crate::installer::idempotency::{VERSION_PROBE_TIMEOUT, run_version_check_within};

/// A `sleep 30` leading its own process group, the way probes are spawned.
fn grouped_sleep() -> Command {
    let mut command = Command::new("sleep");
    command.arg("30").process_group(0);
    command
}

/// The guard keeps the group registered while the child runs and removes it
/// on drop, so a later interrupt never signals a pgid that may have been
/// recycled.
#[test]
fn tracked_group_is_registered_until_the_guard_drops() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    let pgid = Pid::from_child(&child);
    assert_eq!(lock(&REG).pgids, vec![pgid]);

    drop(tracked);
    assert!(lock(&REG).pgids.is_empty(), "dropping the guard must deregister the group");
    let _ = child.kill();
    let _ = child.wait();
}

/// An interrupt kills a registered group, and afterwards no new probe may
/// start: a probe spawned once the handler has run would have nothing left
/// to kill it.
#[test]
fn interrupt_kills_registered_groups_and_refuses_new_spawns() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, _tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    drop(interrupt_all(&REG));

    let deadline = Instant::now() + Duration::from_secs(2);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("interrupt_all must kill the registered group");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status.signal(), Some(Signal::KILL.as_raw()));

    let err = spawn_tracked_in(&REG, &mut grouped_sleep())
        .expect_err("no probe may start once an interrupt has been handled");
    assert_eq!(err.kind(), io::ErrorKind::Interrupted);
}

/// Interrupting luggage mid-probe leaves no probe or descendant running, for
/// each signal the watcher handles.
#[test]
#[serial_test::serial]
fn sigint_mid_probe_kills_the_probe_group() {
    assert_signal_kills_probe_group("sigint_mid_probe_kills_the_probe_group", Signal::INT);
}

/// See [`sigint_mid_probe_kills_the_probe_group`]; SIGTERM must end luggage
/// the same way.
#[test]
#[serial_test::serial]
fn sigterm_mid_probe_kills_the_probe_group() {
    assert_signal_kills_probe_group("sigterm_mid_probe_kills_the_probe_group", Signal::TERM);
}

/// The signal has to land on a whole process, so the named test re-execs its
/// own binary for just itself (the same pattern as
/// `run_version_check_within_gives_the_probe_a_null_stdin`). The child
/// installs the handler (twice, which must be a no-op) and probes a forking
/// shim with a long deadline. The parent waits for the shim to record both
/// pids, sends the child `signal`, and requires three things: the child died
/// by that signal, the probe is gone, and its forked `sleep` is gone. Without
/// the handler the child still dies by the signal but both shim processes
/// survive, so the pid checks are what discriminate.
fn assert_signal_kills_probe_group(test: &str, signal: Signal) {
    const CHILD_DIR: &str = "LUGGAGE_INTERRUPT_PROBE_CHILD_DIR";

    if let Some(dir) = std::env::var_os(CHILD_DIR) {
        let dir = Path::new(&dir);
        install_handler().unwrap();
        install_handler().expect("a second install must be a no-op, not an error");
        write_forking_shim(dir, "tool");
        let _ = run_version_check_within(
            &dir.join("tool"),
            &["--version"],
            &std::collections::BTreeMap::new(),
            VERSION_PROBE_TIMEOUT * 6,
        );
        panic!("the probe returned; the parent's signal should have ended this process first");
    }

    let dir = tempfile::tempdir().unwrap();
    let module = module_path!();
    let module = module.split_once("::").map_or(module, |(_, rest)| rest);
    let name = format!("{module}::{test}");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", &name, "--test-threads=1", "--nocapture"])
        .env(CHILD_DIR, dir.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    // Both pids are recorded before the shim prints and `wait`s.
    let read_pid = |file: &str| {
        let raw = std::fs::read_to_string(dir.path().join(file)).ok()?;
        let raw = raw.trim();
        (!raw.is_empty()).then(|| raw.to_owned())
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let (pid, bgpid) = loop {
        if let (Some(pid), Some(bgpid)) = (read_pid("tool.pid"), read_pid("tool.bgpid")) {
            break (pid, bgpid);
        }
        if Instant::now() >= deadline || child.try_wait().unwrap().is_some() {
            let _ = child.kill();
            let out = child.wait_with_output().unwrap();
            panic!(
                "the re-exec'd child never started the probe ({}):\n{}\n{}",
                out.status,
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr),
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let guard = |pid: &str| KillOnDrop(Pid::from_raw(pid.parse().unwrap()).unwrap());
    let (_probe_guard, _bg_guard) = (guard(&pid), guard(&bgpid));

    rustix::process::kill_process(Pid::from_child(&child), signal).unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.signal(),
        Some(signal.as_raw()),
        "luggage must still die by {signal:?} after cleaning up ({}):\n{}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );

    let deadline = Instant::now() + Duration::from_secs(2);
    while pid_is_running(&pid) || pid_is_running(&bgpid) {
        assert!(
            Instant::now() < deadline,
            "{signal:?} must kill the probe group: probe {pid} running={}, forked sleep {bgpid} \
             running={}",
            pid_is_running(&pid),
            pid_is_running(&bgpid),
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}
