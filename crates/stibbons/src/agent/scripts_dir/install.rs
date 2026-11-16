//! The atomic-install layer of [`super::prepare_with_hook`]: builds the
//! script set in a private staging sibling and renames it into place, so the
//! target directory is only ever absent or complete (#927).

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use super::{DIR_MODE, SCRIPT_MODE, ScriptsDirError, io_err, private_dir_state, set_mode};

/// Points in [`super::prepare_with_hook`] a test can pause at to drive a concurrent
/// interleaving deterministically, instead of relying on timing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
    /// An owned ancestor (`stibbons` or `agent-scripts`) was just found
    /// absent; it has not been created yet.
    AncestorAbsent,
    /// The ancestors are in place; the target has not been inspected yet.
    BeforeTargetCheck,
    /// The full script set is written to the staging directory, not yet
    /// installed.
    Built,
    /// The install rename just failed because the target was occupied; the
    /// target has not been re-inspected yet.
    RenameFailed,
    /// An occupant of the target path was just moved aside; the install
    /// rename has not been retried yet.
    MovedAside,
}

/// How many times [`install`] retries after losing a race to a concurrent
/// invocation. Each retry needs another process to finish an install in the
/// gap, so a handful is ample; the bound only stops a pathological livelock.
pub(super) const MAX_INSTALL_ATTEMPTS: usize = 8;

/// Distinguishes sibling names created within one process (threads, or
/// repeated retries), on top of the PID that distinguishes processes and the
/// timestamp that distinguishes a reused PID from a crashed predecessor whose
/// hidden entry was never cleaned up.
static SIBLING_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// A fresh sibling path `.{container}.{kind}-{pid}-{nanos}-{seq}` in `parent`.
///
/// Same parent as the target, so it is on the same filesystem (`rename` is
/// atomic only within one) and already behind the `0700` `agent-scripts`
/// directory. The leading `.` keeps it from ever equalling a container name —
/// Docker names cannot start with one.
///
/// Known limit: a process killed outright (SIGKILL, OOM) between creating one
/// of these and removing it leaves it behind, since no drop guard runs. It is
/// harmless — hidden, inside the `0700` parent, never mounted, never reused —
/// and is deliberately not swept: another invocation may be mid-prepare with a
/// live sibling, and telling a live one from a dead one needs a lock this
/// design exists to avoid.
pub(super) fn sibling(parent: &Path, container_name: &str, kind: &str) -> PathBuf {
    let seq = SIBLING_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    parent.join(format!(".{container_name}.{kind}-{}-{nanos}-{seq}", std::process::id()))
}

/// A directory removed on drop unless [`disarm`](Self::disarm)ed, so a staging
/// directory never outlives an error path (#927).
pub(super) struct RemoveOnDrop(Option<PathBuf>);

impl RemoveOnDrop {
    fn path(&self) -> &Path {
        self.0.as_deref().expect("path is only taken by disarm, which consumes self")
    }

    /// Keeps the directory: it has been renamed into place.
    fn disarm(mut self) {
        self.0 = None;
    }
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            // Best effort: a drop cannot report, and the path is hidden inside
            // the private parent, so a failure here leaks nothing to others.
            let _ = std::fs::remove_dir_all(path);
        }
    }
}

/// Writes the full script set into a fresh private staging directory beside
/// the target. Nothing reads the staging path, so no reader can observe it
/// half-written; it only becomes visible through the atomic rename in
/// [`install`].
///
/// `create_dir`, never `create_dir_all`: adopting a pre-existing path is the
/// bug (#924). The mode is set in a second step rather than through the create
/// call, leaving a brief window at the process umask's mode — harmless, because
/// the parent `agent-scripts` directory is itself `0700`, so nobody else can
/// traverse in to observe or use it. The drop guard is armed before that
/// second step, so even a failing chmod leaves nothing behind.
pub(super) fn build_staged(
    parent: &Path,
    container_name: &str,
    scripts: &[(&str, &str)],
) -> Result<RemoveOnDrop, ScriptsDirError> {
    let path = sibling(parent, container_name, "tmp");
    std::fs::create_dir(&path).map_err(|e| io_err(&path, e))?;
    let staged = RemoveOnDrop(Some(path));
    set_mode(staged.path(), DIR_MODE)?;
    for (name, body) in scripts {
        let file = staged.path().join(name);
        std::fs::write(&file, body).map_err(|e| io_err(&file, e))?;
        set_mode(&file, SCRIPT_MODE)?;
    }
    Ok(staged)
}

/// Whether `dir` holds exactly `scripts` — the same names, bytes, and (on
/// Unix) [`SCRIPT_MODE`] — and nothing else.
///
/// Any read failure counts as "no": the caller then replaces the directory,
/// which is the safe direction.
pub(super) fn matches(dir: &Path, scripts: &[(&str, &str)]) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    let mut seen = 0usize;
    for entry in entries {
        let Ok(entry) = entry else {
            return false;
        };
        let name = entry.file_name();
        let Some((_, body)) = scripts.iter().find(|(n, _)| OsStr::new(n) == name) else {
            return false;
        };
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            return false;
        };
        if !meta.is_file() {
            return false;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if meta.permissions().mode() & 0o777 != SCRIPT_MODE {
                return false;
            }
        }
        if std::fs::read(&path).ok().as_deref() != Some(body.as_bytes()) {
            return false;
        }
        seen += 1;
    }
    seen == scripts.len()
}

/// Renames `staged` onto `dir`, so the target is only ever absent or complete —
/// never partially written (#927).
///
/// `rename` cannot replace a non-empty directory, so an occupant is first moved
/// aside, then the rename is retried. A concurrent invocation can slip its own
/// install into that gap; the loop then sees the new occupant and goes round
/// again — unless it already holds these exact scripts, in which case the
/// other process did our work and the staging copy is discarded.
///
/// Only an "occupied" rename failure is retried (see [`target_occupied`]).
/// Any other failure — `EACCES`, `ENOSPC`, `EIO` — is returned as-is: retrying
/// it would only move a working installed tree aside (and then delete it) and
/// finally report a misleading "lost the race".
///
/// Every moved-aside tree is removed on every exit, success or error. If a
/// removal fails, the error names that aside path, which is left on disk:
///
/// - **Install succeeded:** the call still returns [`ScriptsDirError::Io`] for
///   the aside path, even though the target is complete. This is deliberate.
///   A leaked aside is an old copy of the scripts sitting in the state
///   directory, and failing the start loudly is better than leaking it
///   silently on every restart.
/// - **Install failed:** the install error is returned and the cleanup error
///   is dropped (the first error wins). The cleanup is still attempted.
pub(super) fn install(
    parent: &Path,
    dir: &Path,
    container_name: &str,
    staged: RemoveOnDrop,
    scripts: &[(&str, &str)],
    hook: &mut dyn FnMut(Stage),
) -> Result<(), ScriptsDirError> {
    let mut aside = Vec::new();
    let result = install_loop(parent, dir, container_name, staged, scripts, hook, &mut aside);

    // Moved-aside trees are ours (they passed `ensure_private_dir`) and nothing
    // can reach them under the hidden name, so they are always removed, on the
    // error path too. A removal failure is reported rather than leaked.
    let mut cleanup = Ok(());
    for old in aside {
        if let Err(e) = std::fs::remove_dir_all(&old)
            && cleanup.is_ok()
        {
            cleanup = Err(io_err(&old, e));
        }
    }
    result.and(cleanup)
}

/// The retry loop of [`install`], split out so every exit — success or
/// error — funnels through `install`'s moved-aside cleanup.
fn install_loop(
    parent: &Path,
    dir: &Path,
    container_name: &str,
    staged: RemoveOnDrop,
    scripts: &[(&str, &str)],
    hook: &mut dyn FnMut(Stage),
    aside: &mut Vec<PathBuf>,
) -> Result<(), ScriptsDirError> {
    let mut last_err = None;
    for _ in 0..MAX_INSTALL_ATTEMPTS {
        let err = match std::fs::rename(staged.path(), dir) {
            Ok(()) => {
                staged.disarm();
                return Ok(());
            }
            Err(e) => e,
        };
        hook(Stage::RenameFailed);
        if !target_occupied(&err, dir) {
            return Err(io_err(dir, err));
        }
        last_err = Some(err);

        // The target is (still, or again) occupied — or it vanished between
        // the rename and here because another invocation moved it aside, in
        // which case just retry.
        if !private_dir_state(dir)? {
            continue;
        }
        if matches(dir, scripts) {
            return Ok(());
        }

        let old = sibling(parent, container_name, "old");
        match std::fs::rename(dir, &old) {
            Ok(()) => {
                aside.push(old);
                hook(Stage::MovedAside);
            }
            // Someone else moved it aside first; retry the install.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(io_err(dir, e)),
        }
    }

    let last = last_err.map_or_else(|| "none".to_owned(), |e| e.to_string());
    Err(io_err(
        dir,
        std::io::Error::other(format!(
            "could not install after {MAX_INSTALL_ATTEMPTS} attempts \
             (concurrent agent starts kept replacing it; last error: {last})"
        )),
    ))
}

/// Whether a failed `rename(staged, dir)` means "the target is occupied" — the
/// only failure [`install_loop`] retries.
///
/// On Unix that is `ENOTEMPTY`/`EEXIST`, by kind. Windows reports an occupied
/// directory target as access-denied, indistinguishable by kind from a real
/// permission error, so there it also requires the target to exist.
pub(super) fn target_occupied(err: &std::io::Error, dir: &Path) -> bool {
    use std::io::ErrorKind;
    matches!(err.kind(), ErrorKind::AlreadyExists | ErrorKind::DirectoryNotEmpty)
        || (cfg!(windows)
            && err.kind() == ErrorKind::PermissionDenied
            && std::fs::symlink_metadata(dir).is_ok())
}
