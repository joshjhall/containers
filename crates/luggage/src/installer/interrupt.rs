//! Kill live version-probe process groups when luggage is interrupted (#1370).
//!
//! Each probe leads its own process group so the timeout can `killpg` it
//! (#1352). The cost is that a terminal Ctrl-C, sent to the foreground group,
//! reaches luggage but not the probe. Without this module luggage would die
//! on the default action and leave the probe and everything it forked
//! running with no deadline.
//!
//! [`run_version_check_within`](super::idempotency::run_version_check_within)
//! spawns through [`spawn_tracked`], which records the child's pgid in a
//! process-wide registry until the returned [`Tracked`] guard drops. Once
//! [`install_handler`] has run, a watcher thread catches the first SIGINT or
//! SIGTERM, kills every recorded group, and then lets the default action
//! terminate luggage. The shell still sees "killed by SIGINT" (130) or
//! "killed by SIGTERM" (143), not a normal exit.
//!
//! The library never installs the handler by itself: taking over process-wide
//! signals is the embedding binary's decision. The `luggage` CLI opts in from
//! `main`. A library caller that skips it keeps the gap described on
//! `run_version_check_within`.

use std::cell::Cell;
use std::io;
use std::process::{Child, Command};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::thread;

use rustix::process::{Pid, Signal, kill_process_group};
use signal_hook::consts::{SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

/// Process groups of in-flight probes, and whether an interrupt has already
/// emptied them.
#[derive(Debug, Default)]
pub struct Registry {
    pgids: Vec<Pid>,
    interrupted: bool,
}

impl Registry {
    pub const fn new() -> Self {
        Self { pgids: Vec::new(), interrupted: false }
    }
}

/// The registry every production probe spawns through.
static LIVE: Mutex<Registry> = Mutex::new(Registry::new());

/// Lock `registry`, ignoring poison. A thread that panicked while holding the
/// lock leaves only a pid list behind, which is still correct to read, and the
/// interrupt path must never give up because of an unrelated panic.
fn lock(registry: &Mutex<Registry>) -> MutexGuard<'_, Registry> {
    registry.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Keeps a probe's process group registered until the child is reaped through
/// [`Self::reap_locked`], or until the guard drops (an early-return path).
#[derive(Debug)]
#[must_use = "dropping the guard deregisters the probe group immediately"]
pub struct Tracked {
    registry: &'static Mutex<Registry>,
    pgid: Pid,
    // Set once `reap_locked` has deregistered the group. The pid is free for
    // reuse from then on, so a later drop must not deregister by value: a
    // concurrent probe given the recycled pid would lose its live entry.
    reaped: Cell<bool>,
}

impl Tracked {
    /// Run `reap` under the registry lock, and deregister the group in the
    /// same critical section when it reports the child reaped (`Ok(Some)`).
    ///
    /// Reaping frees the leader's pid for reuse. Done under the lock, no
    /// interrupt can observe a reaped probe's pgid still registered and
    /// `killpg` whatever process took that pid next. Dropping the guard after
    /// a separate reap would leave exactly that window.
    pub fn reap_locked<T>(
        &self,
        reap: impl FnOnce() -> io::Result<Option<T>>,
    ) -> io::Result<Option<T>> {
        let mut live = lock(self.registry);
        let reaped = reap();
        if matches!(reaped, Ok(Some(_))) {
            deregister(&mut live, self.pgid);
            self.reaped.set(true);
        }
        reaped
    }
}

fn deregister(live: &mut Registry, pgid: Pid) {
    if let Some(i) = live.pgids.iter().position(|p| *p == pgid) {
        live.pgids.swap_remove(i);
    }
}

impl Drop for Tracked {
    fn drop(&mut self) {
        if !self.reaped.get() {
            deregister(&mut lock(self.registry), self.pgid);
        }
    }
}

/// Spawn `command`, which must lead its own process group, and record that
/// group in the production registry. See [`spawn_tracked_in`].
pub fn spawn_tracked(command: &mut Command) -> io::Result<(Child, Tracked)> {
    spawn_tracked_in(&LIVE, command)
}

/// Spawn `command` and record its pgid in `registry`. The pgid equals the
/// child's pid, because the caller set `process_group(0)`.
///
/// The lock is held from before the spawn until after the registration, so an
/// interrupt that arrives between them waits for the lock and then still sees
/// the group. Once an interrupt has been handled this refuses to spawn, with
/// [`io::ErrorKind::Interrupted`], rather than start a probe nothing would
/// kill.
pub fn spawn_tracked_in(
    registry: &'static Mutex<Registry>,
    command: &mut Command,
) -> io::Result<(Child, Tracked)> {
    let mut live = lock(registry);
    if live.interrupted {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "luggage is shutting down on an interrupt; not starting the version probe",
        ));
    }
    let child = command.spawn()?;
    let pgid = Pid::from_child(&child);
    live.pgids.push(pgid);
    drop(live);
    Ok((child, Tracked { registry, pgid, reaped: Cell::new(false) }))
}

/// Mark `registry` interrupted and SIGKILL every recorded group. A group whose
/// members have all exited makes `killpg` fail with ESRCH, which is ignored.
/// The pids are not removed here, because each one still belongs to a
/// [`Tracked`] guard that will deregister it.
///
/// Returns the still-held lock. The watcher keeps it until the process dies,
/// so a probe caller cannot act on the status of a probe killed here:
/// `Tracked::reap_locked` blocks on the lock instead of returning.
pub fn interrupt_all(registry: &Mutex<Registry>) -> MutexGuard<'_, Registry> {
    let mut live = lock(registry);
    live.interrupted = true;
    for pgid in &live.pgids {
        let _ = kill_process_group(*pgid, Signal::KILL);
    }
    live
}

/// Install the SIGINT/SIGTERM watcher. Idempotent.
///
/// A signal luggage inherited as ignored (`nohup`, a background job in a
/// non-interactive shell) stays ignored: registering a handler would replace
/// that disposition and make the signal fatal where it was not before. The
/// inherited set is read from `/proc/self/status` on Linux, since querying
/// `sigaction` needs `unsafe`. Elsewhere it cannot be read, and both signals
/// are handled.
///
/// # Errors
///
/// Returns the OS error if the signal handlers cannot be registered or the
/// watcher thread cannot be spawned.
pub fn install_handler() -> io::Result<()> {
    static INSTALLED: Mutex<bool> = Mutex::new(false);

    let mut installed = INSTALLED.lock().unwrap_or_else(PoisonError::into_inner);
    if *installed {
        return Ok(());
    }
    let ignored = inherited_ignored_signals();
    let handled = handled_signals(ignored);
    if handled.is_empty() {
        *installed = true;
        return Ok(());
    }
    let mut signals = Signals::new(&handled)?;
    let spawned = thread::Builder::new().name("luggage-interrupt".into()).spawn(move || {
        if let Some(sig) = signals.forever().next() {
            // Held, not dropped: see `interrupt_all`.
            let _held = interrupt_all(&LIVE);
            // Restores the default action and re-raises, so luggage dies by
            // the signal itself. The exit is a fallback for a signal missing
            // from signal-hook's table, which SIGINT and SIGTERM are not.
            let _ = signal_hook::low_level::emulate_default_handler(sig);
            std::process::exit(128 + sig);
        }
    });
    if let Err(e) = spawned {
        restore_termination(&handled);
        return Err(e);
    }
    *installed = true;
    drop(installed);
    Ok(())
}

/// Make each of `signals` terminate the process again, after a failed watcher
/// spawn has dropped its `Signals`. Unregistering signal-hook's last action
/// does not restore the OS default, so without this luggage would silently
/// ignore Ctrl-C and SIGTERM for the rest of its run. An always-true
/// conditional default runs the default action from signal-hook's own
/// handler. Best-effort: a failure here leaves the signal as it already was.
fn restore_termination(signals: &[i32]) {
    let always = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    for &sig in signals {
        let _ =
            signal_hook::flag::register_conditional_default(sig, std::sync::Arc::clone(&always));
    }
}

/// SIGINT and SIGTERM, minus any whose bit is set in `ignored` (a `SigIgn`
/// mask, where bit `n - 1` stands for signal `n`).
fn handled_signals(ignored: u64) -> Vec<i32> {
    [SIGINT, SIGTERM]
        .into_iter()
        .filter(|sig| u32::try_from(*sig - 1).map_or(true, |bit| ignored & (1 << bit) == 0))
        .collect()
}

/// This process's ignored-signal mask, from the `SigIgn:` line of
/// `/proc/self/status`. An unreadable or malformed file reads as "nothing
/// ignored", so luggage falls back to handling both signals rather than
/// silently handling neither.
fn inherited_ignored_signals() -> u64 {
    std::fs::read_to_string("/proc/self/status").map_or(0, |status| parse_sig_ign(&status))
}

/// Parse the hex mask on the `SigIgn:` line of a `/proc/<pid>/status` body;
/// 0 if absent or malformed.
fn parse_sig_ign(status: &str) -> u64 {
    status
        .lines()
        .find_map(|line| line.strip_prefix("SigIgn:"))
        .and_then(|mask| u64::from_str_radix(mask.trim(), 16).ok())
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "interrupt_tests.rs"]
mod tests;
