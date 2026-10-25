//! Tests for the interrupt registry and the SIGINT/SIGTERM watcher (#1370).

use super::*;
use std::os::unix::process::{CommandExt as _, ExitStatusExt as _};
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use crate::installer::idempotency::tests::{
    KillOnDrop, TEST_TIMEOUT, pid_is_running, write_forking_shim, write_sleeping_shim,
};
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

/// While the watcher holds the lock `interrupt_all` returned, a probe caller
/// cannot reap: it must not see the killed probe's status and carry on with
/// the install before the re-raised signal ends the process. Releasing the
/// lock lets the reap through, and that reap deregisters the group.
#[test]
fn reap_blocks_while_the_interrupt_lock_is_held() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    let pid = Pid::from_child(&child);
    let held = interrupt_all(&REG);

    let (tx, rx) = std::sync::mpsc::channel();
    let reaper = std::thread::spawn(move || {
        let status = tracked.reap_locked(|| child.wait().map(Some));
        tx.send(()).unwrap();
        (status, tracked)
    });
    assert!(
        rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "the reap must block while the interrupt lock is held",
    );
    // Killed but not reaped: a zombie still answers `kill(pid, 0)`, while a
    // reaped pid is ESRCH and free for reuse while still registered.
    assert!(
        rustix::process::test_kill_process(pid).is_ok(),
        "the probe must not be reaped while the interrupt lock is held",
    );

    drop(held);
    rx.recv_timeout(Duration::from_secs(2)).expect("releasing the lock must let the reap finish");
    let (status, tracked) = reaper.join().unwrap();
    assert_eq!(status.unwrap().unwrap().signal(), Some(Signal::KILL.as_raw()));
    assert!(lock(&REG).pgids.is_empty(), "a completed reap must deregister the group");
    drop(tracked);
}

/// A poll that finds the child still running leaves it registered; only a
/// reap deregisters.
#[test]
fn a_running_poll_keeps_the_group_registered() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    assert!(tracked.reap_locked(|| child.try_wait()).unwrap().is_none());
    assert_eq!(lock(&REG).pgids.len(), 1, "a still-running probe must stay registered");

    let _ = child.kill();
    tracked.reap_locked(|| child.wait().map(Some)).unwrap();
    assert_eq!(lock(&REG).pgids, Vec::new(), "a reap must deregister the group");
}

/// A failed reap leaves the child unreaped, so its group must stay
/// registered for the interrupt handler; the error is passed through.
#[test]
fn a_failed_reap_keeps_the_group_registered() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    let err = tracked.reap_locked::<()>(|| Err(io::Error::other("poll failed"))).unwrap_err();
    assert_eq!(err.to_string(), "poll failed");
    assert_eq!(lock(&REG).pgids.len(), 1, "an unreaped probe must stay registered");

    let _ = child.kill();
    let _ = child.wait();
    drop(tracked);
}

/// Once a reap has deregistered a group, the guard's drop must not
/// deregister again by value: the pid is free for reuse, and a concurrent
/// probe that got it must keep its live entry.
#[test]
fn a_dropped_guard_spares_a_recycled_pgid_after_its_reap() {
    static REG: Mutex<Registry> = Mutex::new(Registry::new());

    let (mut child, tracked) = spawn_tracked_in(&REG, &mut grouped_sleep()).unwrap();
    let pgid = Pid::from_child(&child);
    let _ = child.kill();
    tracked.reap_locked(|| child.wait().map(Some)).unwrap();

    // Another probe is handed the recycled pid and registers it.
    lock(&REG).pgids.push(pgid);
    drop(tracked);
    assert_eq!(lock(&REG).pgids, vec![pgid], "the stale guard removed another probe's entry");
}

/// The production path: a probe that times out is killed and reaped through
/// `TrackedChild`, and leaves no entry behind in the live registry.
#[test]
#[serial_test::serial]
fn a_timed_out_probe_leaves_no_live_registration() {
    let dir = tempfile::tempdir().unwrap();
    write_sleeping_shim(dir.path(), "tool");
    let err = run_version_check_within(
        &dir.path().join("tool"),
        &["--version"],
        &std::collections::BTreeMap::new(),
        TEST_TIMEOUT,
    )
    .expect_err("a sleeping probe must time out");
    assert_eq!(err.kind(), io::ErrorKind::TimedOut);

    let raw = std::fs::read_to_string(dir.path().join("tool.pid")).unwrap();
    let pid = Pid::from_raw(raw.trim().parse().unwrap()).unwrap();
    assert!(!lock(&LIVE).pgids.contains(&pid), "a reaped probe's group must be deregistered");
}

/// A failed watcher spawn drops its `Signals`, and signal-hook does not put
/// the OS default back when the last action is unregistered: SIGTERM would
/// then be silently swallowed. `restore_termination` must make it fatal
/// again. The control run skips the restore and must survive, which proves
/// the swallowing is real and keeps the main assertion from passing vacuously.
#[test]
#[serial_test::serial]
fn restore_termination_undoes_a_dropped_watcher_registration() {
    const CHILD_MODE: &str = "LUGGAGE_RESTORE_TERMINATION_CHILD";

    if let Some(mode) = std::env::var_os(CHILD_MODE) {
        drop(Signals::new([SIGTERM]).unwrap());
        if mode == "restore" {
            restore_termination(&[SIGTERM]);
        }
        signal_hook::low_level::raise(SIGTERM).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        println!("survived SIGTERM");
        return;
    }

    let module = module_path!();
    let module = module.split_once("::").map_or(module, |(_, rest)| rest);
    let name = format!("{module}::restore_termination_undoes_a_dropped_watcher_registration");
    let run = |mode: &str| {
        Command::new(std::env::current_exe().unwrap())
            .args(["--exact", &name, "--test-threads=1", "--nocapture"])
            .env(CHILD_MODE, mode)
            .stdin(Stdio::null())
            .output()
            .unwrap()
    };

    let control = run("no-restore");
    assert!(
        control.status.success() && String::from_utf8_lossy(&control.stdout).contains("survived"),
        "without the restore, a dropped registration must swallow SIGTERM ({})",
        control.status,
    );
    let restored = run("restore");
    assert_eq!(
        restored.status.signal(),
        Some(Signal::TERM.as_raw()),
        "after restore_termination, SIGTERM must be fatal again ({}):\n{}",
        restored.status,
        String::from_utf8_lossy(&restored.stderr),
    );
}

/// `SigIgn` is a hex mask with bit `n - 1` for signal `n`: SIGINT (2) is
/// 0x2, SIGTERM (15) is 0x4000.
#[test]
fn sig_ign_mask_is_parsed_and_filters_the_handled_signals() {
    let status = "Name:\tluggage\nSigBlk:\t0000000000000000\nSigIgn:\t0000000000004002\n";
    assert_eq!(parse_sig_ign(status), 0x4002);
    assert_eq!(parse_sig_ign("Name:\tluggage\n"), 0, "a missing line reads as nothing ignored");
    assert_eq!(parse_sig_ign("SigIgn:\tnot-hex\n"), 0, "a malformed mask reads as nothing ignored");

    assert_eq!(handled_signals(0), vec![SIGINT, SIGTERM]);
    assert_eq!(handled_signals(0x2), vec![SIGTERM], "an ignored SIGINT stays ignored");
    assert_eq!(handled_signals(0x4000), vec![SIGINT], "an ignored SIGTERM stays ignored");
    assert_eq!(handled_signals(0x4002), Vec::<i32>::new());
    assert_eq!(handled_signals(0x1000), vec![SIGINT, SIGTERM], "other bits do not matter");
}

/// luggage started with SIGINT ignored (`nohup`, a background job) keeps
/// ignoring it: the handler must not turn an inherited ignore into a fatal
/// signal.
#[cfg(target_os = "linux")]
#[test]
#[serial_test::serial]
fn an_inherited_sigint_ignore_survives_the_handler() {
    assert_inherited_ignore_survives(
        "an_inherited_sigint_ignore_survives_the_handler",
        "INT",
        Signal::INT,
    );
}

/// With both signals inherited as ignored, `install_handler` registers
/// nothing and spawns no watcher, yet still reports success; SIGTERM must
/// stay as harmless as before.
#[cfg(target_os = "linux")]
#[test]
#[serial_test::serial]
fn inherited_ignores_of_both_signals_survive_the_handler() {
    assert_inherited_ignore_survives(
        "inherited_ignores_of_both_signals_survive_the_handler",
        "INT TERM",
        Signal::TERM,
    );
}

/// The ignore is set the way a real parent sets it, by a shell `trap ''
/// {traps}` that `exec`s the named re-exec'd test. `signal`, which the trap
/// covers, must then leave both the child and its probe running.
#[cfg(target_os = "linux")]
fn assert_inherited_ignore_survives(test: &str, traps: &str, signal: Signal) {
    const CHILD_DIR: &str = "LUGGAGE_INTERRUPT_IGNORED_CHILD_DIR";

    if let Some(dir) = std::env::var_os(CHILD_DIR) {
        let dir = Path::new(&dir);
        let bit = 1u64 << (signal.as_raw() - 1);
        assert_ne!(
            inherited_ignored_signals() & bit,
            0,
            "the re-exec'd child must start with {signal:?} ignored, or this test is vacuous",
        );
        install_handler().expect("installing over inherited ignores must still succeed");
        write_sleeping_shim(dir, "tool");
        let _ = run_version_check_within(
            &dir.join("tool"),
            &["--version"],
            &std::collections::BTreeMap::new(),
            VERSION_PROBE_TIMEOUT * 6,
        );
        return;
    }

    let dir = tempfile::tempdir().unwrap();
    let module = module_path!();
    let module = module.split_once("::").map_or(module, |(_, rest)| rest);
    let name = format!("{module}::{test}");
    let mut child = Command::new("/bin/sh")
        .args(["-c", &format!("trap '' {traps}; exec \"$0\" \"$@\"")])
        .arg(std::env::current_exe().unwrap())
        .args(["--exact", &name, "--test-threads=1", "--nocapture"])
        .env(CHILD_DIR, dir.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let pid = loop {
        if let Ok(raw) = std::fs::read_to_string(dir.path().join("tool.pid"))
            && !raw.trim().is_empty()
        {
            break raw.trim().to_owned();
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
    let _probe_guard = KillOnDrop(Pid::from_raw(pid.parse().unwrap()).unwrap());

    rustix::process::kill_process(Pid::from_child(&child), signal).unwrap();
    std::thread::sleep(Duration::from_millis(500));
    let still_running = child.try_wait().unwrap().is_none();
    let probe_alive = pid_is_running(&pid);
    let _ = child.kill();
    let out = child.wait_with_output().unwrap();
    assert!(
        still_running && probe_alive,
        "an inherited {signal:?} ignore must survive the handler (child running={still_running}, \
         probe running={probe_alive}, child {}):\n{}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
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
