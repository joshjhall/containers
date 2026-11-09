//! Host directory holding the agent scripts that are bind-mounted into a
//! container.
//!
//! `stibbons agent start` mounts this directory at `/opt/agent-scripts:ro` into
//! a container that also carries `/var/run/docker.sock` and whose command is
//! `/opt/agent-scripts/agent-entrypoint.sh`. Anyone who can write into the
//! directory therefore gets code execution next to the host Docker socket, so
//! its *location and ownership* are a security boundary, not a detail.
//!
//! The historical implementation (issue #924, CWE-377) used
//! `std::env::temp_dir()/stibbons-agent-scripts-{pid}` with `create_dir_all`.
//! Three properties made that exploitable on a multi-user host:
//!
//! - `create_dir_all` succeeds on a pre-existing directory whatever its owner
//!   or mode, so an attacker-created path was silently adopted.
//! - `/tmp`'s sticky bit protects `/tmp` itself, not an attacker-owned
//!   subdirectory inside it — files written there could be renamed away and
//!   replaced.
//! - `:ro` is enforced container-side only; a host-side edit is visible in the
//!   container immediately, and `agent-entrypoint.sh` runs `agent-init.sh`
//!   (minutes of `cargo fetch` / `npm ci`) before it opens `agent-start.sh`,
//!   giving a wide, non-racy swap window.
//!
//! This module replaces that with a user-private `0700` directory under the
//! XDG state home, and refuses to adopt a path it does not already own.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Failure preparing the host scripts directory.
#[derive(Debug, thiserror::Error)]
pub enum ScriptsDirError {
    /// Neither `XDG_STATE_HOME` nor `HOME` is set, so there is no user-private
    /// root to use. Deliberately fatal: falling back to a world-writable
    /// location is the vulnerability this module exists to close.
    #[error("cannot locate a user-private state directory: neither XDG_STATE_HOME nor HOME is set")]
    NoStateRoot,

    /// The target path exists but is not a directory this user privately owns.
    /// Carries the specific reason so the operator can inspect the path rather
    /// than guess.
    #[error("refusing to use agent scripts directory {path}: {reason}")]
    UnsafePath {
        /// The rejected path.
        path: String,
        /// Why it was rejected (not a directory, foreign owner, or open mode).
        reason: String,
    },

    /// An underlying filesystem operation failed. Carries the path, because a
    /// bare `io::Error` ("permission denied") names nothing.
    #[error("agent scripts directory {path}: {source}")]
    Io {
        /// The path being operated on when the error occurred.
        path: String,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
}

/// Wraps an [`std::io::Error`] with the path it happened on.
fn io_err(path: &Path, source: std::io::Error) -> ScriptsDirError {
    ScriptsDirError::Io { path: path.display().to_string(), source }
}

/// Builds an [`ScriptsDirError::UnsafePath`] for `path`.
fn unsafe_path(path: &Path, reason: impl Into<String>) -> ScriptsDirError {
    ScriptsDirError::UnsafePath { path: path.display().to_string(), reason: reason.into() }
}

/// Mode the scripts directory (and its `agent-scripts` parent) must have:
/// owner-only, so no other local user can read, write, or traverse it.
const DIR_MODE: u32 = 0o700;

/// Mode for the scripts themselves — executable, since the container's
/// entrypoint runs them directly.
const SCRIPT_MODE: u32 = 0o755;

/// Derives the user-private state root from the two environment values.
///
/// Takes them as arguments rather than reading the process environment so it is
/// testable: `std::env::set_var` is `unsafe` in edition 2024 and this workspace
/// sets `unsafe_code = "forbid"`, which cannot be lifted locally. Passing the
/// values in also keeps the precedence rule itself pure.
///
/// An empty **or relative** value counts as unset, per the XDG spec: it says a
/// value that "is not an absolute path… should be considered invalid and
/// ignored", and empty is the degenerate case of that one rule. Both fail the
/// same way if honored — `""` and `state` each resolve against the current
/// working directory, littering the cwd and then handing `docker run -v` a
/// non-absolute source it rejects with a confusing error.
///
/// There is intentionally **no** `temp_dir()` fallback. A shared-`/tmp`
/// fallback is exactly the CWE-377 exposure #924 fixed, and it would reappear
/// silently on any host where these variables are unset (cron, some CI
/// runners). Erroring makes that configuration visible instead.
fn state_root_from(
    xdg_state_home: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Result<PathBuf, ScriptsDirError> {
    let usable = |v: &&OsStr| !v.is_empty() && Path::new(v).is_absolute();
    if let Some(dir) = xdg_state_home.filter(usable) {
        return Ok(PathBuf::from(dir));
    }
    if let Some(home) = home.filter(usable) {
        return Ok(PathBuf::from(home).join(".local").join("state"));
    }
    Err(ScriptsDirError::NoStateRoot)
}

/// Reads the state root from the process environment. See [`state_root_from`].
///
/// # Errors
///
/// [`ScriptsDirError::NoStateRoot`] when neither variable yields a usable path.
pub fn state_root() -> Result<PathBuf, ScriptsDirError> {
    state_root_from(
        std::env::var_os("XDG_STATE_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}

/// Rejects `path` unless it is a real directory owned by the current user with
/// mode exactly [`DIR_MODE`].
///
/// The three checks are separate because they fail for different reasons and an
/// operator needs to know which: a *file* at the path is usually local
/// confusion, whereas a foreign owner or an open mode is the attack this module
/// defends against.
///
/// `symlink_metadata` (not `metadata`) is deliberate: a symlink planted at the
/// leaf would otherwise be followed and the *target's* ownership checked, so an
/// attacker could point it at a directory of ours and still control the
/// contents through their own link.
///
/// Off Unix there is no uid or mode to inspect; the directory is accepted as-is
/// (see the module note on why that is safe there).
fn ensure_private_dir(path: &Path) -> Result<(), ScriptsDirError> {
    ensure_owned_dir(path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mode =
            std::fs::symlink_metadata(path).map_err(|e| io_err(path, e))?.permissions().mode()
                & 0o777;
        if mode != DIR_MODE {
            return Err(unsafe_path(
                path,
                format!(
                    "has mode {mode:04o}, expected {DIR_MODE:04o} \
                     (remove it and re-run if it is a leftover)"
                ),
            ));
        }
    }

    Ok(())
}

/// The ownership half of [`ensure_private_dir`]: a real directory, not a
/// symlink, owned by the current user — with no assertion about its mode.
///
/// Split out for the ancestors (`<root>/stibbons`, `<root>/stibbons/
/// agent-scripts`), which are created by `create_dir_all` and so may
/// legitimately pre-exist at whatever mode the umask gave them. They still must
/// not be a symlink or someone else's directory: `create_dir_all` adopts a
/// pre-existing path whatever its owner — the exact behavior this module exists
/// to stop — and a symlink planted at an ancestor would otherwise be followed,
/// letting an attacker relocate the whole tree even though the leaf check
/// passes.
fn ensure_owned_dir(path: &Path) -> Result<(), ScriptsDirError> {
    let meta = std::fs::symlink_metadata(path).map_err(|e| io_err(path, e))?;

    if meta.file_type().is_symlink() {
        return Err(unsafe_path(path, "is a symlink"));
    }
    if !meta.is_dir() {
        return Err(unsafe_path(path, "is not a directory"));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let uid = rustix::process::getuid().as_raw();
        if meta.uid() != uid {
            return Err(unsafe_path(
                path,
                format!("owned by uid {}, not the current uid {uid}", meta.uid()),
            ));
        }
    }

    Ok(())
}

/// Sets `mode` on `path` on Unix. A no-op elsewhere.
///
/// The scripts only ever execute inside the Linux agent container they are
/// mounted into, so the host's mode bits are irrelevant off-Unix — this keeps
/// the Windows build green (cf. #362).
//
// `allow`, not `expect`: on non-Unix the body reduces to `Ok(())` and clippy's
// `missing_const_for_fn` / `unnecessary_wraps` fire, but on Unix they do not —
// an `#[expect]` would then be unfulfilled (itself a `-D warnings` error there).
#[allow(clippy::missing_const_for_fn, clippy::unnecessary_wraps)]
fn set_mode(path: &Path, mode: u32) -> Result<(), ScriptsDirError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
            .map_err(|e| io_err(path, e))?;
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
    Ok(())
}

/// Writes the agent scripts to a user-private host directory and returns its
/// path, ready to bind-mount at `/opt/agent-scripts`.
///
/// The directory is `<state root>/stibbons/agent-scripts/<container_name>`,
/// mode `0700`. It is keyed by container name rather than randomly, for two
/// reasons: `stibbons agent restart` re-enters `run_start` against the same
/// container and must land on the same path, and a per-invocation name would
/// leak a directory on every start — which the retired PID-keyed
/// implementation did, permanently, by design.
///
/// A pre-existing path is **rejected** unless it is a directory this user owns
/// with mode `0700`; in that case it is our own directory from an earlier
/// start. If it already holds exactly `scripts` it is returned untouched;
/// otherwise it is replaced wholesale (never written over), so no stale file
/// from a previous version survives into the mount.
///
/// The directory is intentionally not cleaned up on exit: it is mounted into a
/// container that outlives this process.
///
/// `state_root` is [`AgentContext::state_root`](super::context::AgentContext),
/// resolved from the environment once at config load. Passing it in rather than
/// reading `$XDG_STATE_HOME` here is what makes this testable: `set_var` is
/// `unsafe` in edition 2024 and the workspace sets `unsafe_code = "forbid"`, so
/// a test could not otherwise redirect the root away from the real `$HOME`.
///
/// # Errors
///
/// [`ScriptsDirError::NoStateRoot`] when `state_root` is `None` (no
/// user-private root could be resolved), [`ScriptsDirError::UnsafePath`] when
/// the target exists but is not privately ours, or [`ScriptsDirError::Io`] on a
/// filesystem failure.
pub fn prepare_scripts_dir(
    state_root: Option<&Path>,
    container_name: &str,
    scripts: &[(&str, &str)],
) -> Result<PathBuf, ScriptsDirError> {
    prepare_with_hook(state_root, container_name, scripts, &mut |_| {})
}

/// [`prepare_scripts_dir`] with a `hook` called at each [`Stage`], so a test
/// can pause one invocation mid-flight while another runs (#927).
///
/// Concurrency: two invocations for the same container (parallel golem
/// dispatch, or a re-run after a hung `docker run`) share the path. The scripts
/// are therefore built in a private sibling and renamed into place, so the
/// target is only ever absent or complete; an existing directory that already
/// holds these exact scripts is returned untouched, so a tree another
/// invocation has already bind-mounted is not pulled out from under it.
fn prepare_with_hook(
    state_root: Option<&Path>,
    container_name: &str,
    scripts: &[(&str, &str)],
    hook: &mut dyn FnMut(Stage),
) -> Result<PathBuf, ScriptsDirError> {
    let state_root = state_root.ok_or(ScriptsDirError::NoStateRoot)?;
    // Defend at the sink, not only upstream (#924). `AgentContext::load`
    // allow-lists the project name this is derived from, but this function does
    // the `Path::join` — where `/` and `..` are real components — and cannot see
    // whether its caller validated. A future caller, or a reordering of that
    // validation, would silently turn this back into a path escape.
    // `Normal` is the only component kind that names a new directory: it
    // excludes `.` and `..` (which are `CurDir`/`ParentDir`, each a single
    // component, so a bare count would let `..` through) as well as any root or
    // prefix. Requiring exactly one Normal component also rejects separators.
    let sole_component = {
        let mut components = Path::new(container_name).components();
        match (components.next(), components.next()) {
            (Some(std::path::Component::Normal(c)), None) => Some(c),
            _ => None,
        }
    };
    if sole_component.is_none_or(|c| c != std::ffi::OsStr::new(container_name)) {
        return Err(unsafe_path(
            &state_root.join(container_name),
            format!("container name {container_name:?} is not a single path component"),
        ));
    }
    // Create the ancestors one level at a time, checking ownership at each.
    // A single `create_dir_all` over the whole chain would adopt a pre-existing
    // `<root>/stibbons` whatever its owner — the behavior that caused #924 —
    // and `set_mode` follows symlinks, so a link planted at an ancestor would
    // be chmod'd and written through even though the leaf check passes. That
    // matters whenever the state root is shared (a CI runner pointing
    // XDG_STATE_HOME somewhere common), which is exactly where the original
    // vulnerability lived.
    // The state root itself may not exist yet (a fresh `$HOME/.local/state`),
    // and it is not ours to police — it is a standard shared location whose
    // intermediate dirs belong to the user's environment, not to this tool.
    // Only the two directories this module owns get the ownership check.
    std::fs::create_dir_all(state_root).map_err(|e| io_err(state_root, e))?;
    let mut parent = state_root.to_path_buf();
    for segment in ["stibbons", "agent-scripts"] {
        parent.push(segment);
        if std::fs::symlink_metadata(&parent).is_ok() {
            ensure_owned_dir(&parent)?;
        } else {
            std::fs::create_dir(&parent).map_err(|e| io_err(&parent, e))?;
        }
    }
    // Lock down the shared parent: it is what makes the umask window in
    // `build_staged` unobservable, and it hides which agents exist.
    set_mode(&parent, DIR_MODE)?;

    let dir = parent.join(container_name);
    if std::fs::symlink_metadata(&dir).is_ok() {
        // Ours from a previous start? Anything else is rejected by
        // `ensure_private_dir` rather than adopted. If it already holds exactly
        // these scripts, leave it alone: a concurrent start of the same agent
        // may have bind-mounted it already (#927).
        ensure_private_dir(&dir)?;
        if matches(&dir, scripts) {
            return Ok(dir);
        }
    }

    let staged = build_staged(&parent, container_name, scripts)?;
    hook(Stage::Built);
    install(&parent, &dir, container_name, staged, scripts, hook)?;
    Ok(dir)
}

/// Points in [`prepare_with_hook`] a test can pause at to drive a concurrent
/// interleaving deterministically, instead of relying on timing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
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
const MAX_INSTALL_ATTEMPTS: usize = 8;

/// Distinguishes sibling names created within one process (threads, or
/// repeated retries), on top of the PID that distinguishes processes.
static SIBLING_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// A fresh sibling path `.{container}.{kind}-{pid}-{seq}` in `parent`.
///
/// Same parent as the target, so it is on the same filesystem (`rename` is
/// atomic only within one) and already behind the `0700` `agent-scripts`
/// directory. The leading `.` keeps it from ever equalling a container name —
/// Docker names cannot start with one.
fn sibling(parent: &Path, container_name: &str, kind: &str) -> PathBuf {
    let seq = SIBLING_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    parent.join(format!(".{container_name}.{kind}-{}-{seq}", std::process::id()))
}

/// A directory removed on drop unless [`disarm`](Self::disarm)ed, so a staging
/// directory never outlives an error path (#927).
struct RemoveOnDrop(Option<PathBuf>);

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
fn build_staged(
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
fn matches(dir: &Path, scripts: &[(&str, &str)]) -> bool {
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
/// Error detection is by re-inspecting the target rather than by `errno`: the
/// "target occupied" error is `ENOTEMPTY` or `EEXIST` on Linux and different
/// again on Windows, while "is the target there?" is portable.
fn install(
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
    for _ in 0..MAX_INSTALL_ATTEMPTS {
        if std::fs::rename(staged.path(), dir).is_ok() {
            staged.disarm();
            return Ok(());
        }
        hook(Stage::RenameFailed);

        // The target is (still, or again) occupied — or it vanished between
        // the rename and here because another invocation moved it aside, in
        // which case just retry.
        if std::fs::symlink_metadata(dir).is_err() {
            continue;
        }
        ensure_private_dir(dir)?;
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

    Err(io_err(
        dir,
        std::io::Error::other(format!(
            "could not install after {MAX_INSTALL_ATTEMPTS} attempts \
             (concurrent agent starts kept replacing it)"
        )),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The scripts a test writes. Content is arbitrary — only the file names,
    /// modes, and bytes round-tripping matter here.
    fn scripts() -> Vec<(&'static str, &'static str)> {
        vec![
            ("agent-entrypoint.sh", "#!/bin/bash\nentrypoint\n"),
            ("agent-init.sh", "#!/bin/bash\ninit\n"),
            ("agent-start.sh", "#!/bin/bash\nstart\n"),
        ]
    }

    #[cfg(unix)]
    fn mode_of(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    // --- state root derivation ---

    /// Absolute paths for these tests, spelled per-platform.
    ///
    /// `state_root_from` requires an absolute path, and what counts as one is
    /// platform-specific: on Windows `/xdg` is NOT absolute (it needs a drive
    /// prefix, `C:\xdg`), so Unix literals made every one of these tests fail
    /// on the windows-latest CI leg while the production logic was correct.
    #[cfg(windows)]
    const ABS_XDG: &str = r"C:\xdg";
    #[cfg(windows)]
    const ABS_HOME: &str = r"C:\home\u";
    #[cfg(not(windows))]
    const ABS_XDG: &str = "/xdg";
    #[cfg(not(windows))]
    const ABS_HOME: &str = "/home/u";

    /// `XDG_STATE_HOME` wins when it is set to a real path.
    #[test]
    fn xdg_state_home_is_used_verbatim() {
        let root = state_root_from(Some(OsStr::new(ABS_XDG)), Some(OsStr::new(ABS_HOME))).unwrap();
        assert_eq!(root, PathBuf::from(ABS_XDG));
    }

    /// Unset `XDG_STATE_HOME` falls back to the XDG default under `$HOME`.
    #[test]
    fn home_supplies_the_xdg_default() {
        let root = state_root_from(None, Some(OsStr::new(ABS_HOME))).unwrap();
        // Built with `join`, not a literal, so the separator matches the
        // platform the assertion runs on.
        assert_eq!(root, PathBuf::from(ABS_HOME).join(".local").join("state"));
    }

    /// An EMPTY `XDG_STATE_HOME` counts as unset, per the XDG spec. Treating
    /// `""` as a path would resolve the scripts directory relative to the cwd.
    #[test]
    fn empty_xdg_state_home_counts_as_unset() {
        let root = state_root_from(Some(OsStr::new("")), Some(OsStr::new(ABS_HOME))).unwrap();
        assert_eq!(root, PathBuf::from(ABS_HOME).join(".local").join("state"));
    }

    /// A RELATIVE value is ignored too — the spec's actual rule, of which empty
    /// is just the degenerate case. Honoring `state` would resolve against the
    /// cwd and then hand `docker run -v` a non-absolute source.
    #[test]
    fn relative_xdg_state_home_counts_as_unset() {
        let root = state_root_from(Some(OsStr::new(".state")), Some(OsStr::new(ABS_HOME))).unwrap();
        assert_eq!(root, PathBuf::from(ABS_HOME).join(".local").join("state"));
    }

    /// A relative `HOME` is no better than an unset one — the fallback would
    /// otherwise build the relative path `.local/state`.
    #[test]
    fn relative_home_counts_as_unset() {
        let err = state_root_from(None, Some(OsStr::new("relative/home"))).unwrap_err();
        assert!(matches!(err, ScriptsDirError::NoStateRoot), "{err}");
    }

    /// An empty `HOME` is unset too — otherwise the fallback would build the
    /// relative path `.local/state`.
    #[test]
    fn empty_home_counts_as_unset() {
        let err = state_root_from(Some(OsStr::new("")), Some(OsStr::new(""))).unwrap_err();
        assert!(matches!(err, ScriptsDirError::NoStateRoot), "{err}");
    }

    /// AC1's negative half: with no user-private root resolvable the call
    /// fails, rather than silently falling back to the shared temp directory
    /// the way the retired `temp_dir()/stibbons-agent-scripts-{pid}` did.
    #[test]
    fn no_state_root_errors_rather_than_using_tmp() {
        let err = state_root_from(None, None).unwrap_err();
        assert!(matches!(err, ScriptsDirError::NoStateRoot), "{err}");
    }

    // --- directory preparation ---

    /// AC1: the directory sits under the user-private state root and is named
    /// for the container — nothing is derived from the PID or `temp_dir()`.
    #[test]
    fn dir_is_under_state_root_and_named_for_the_container() {
        let tmp = tempfile::tempdir().unwrap();

        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        // Chained joins, not a "/"-joined literal, so the expected path uses
        // the platform's own separator (cf. #362).
        assert_eq!(
            dir,
            tmp.path().join("stibbons").join("agent-scripts").join("myproject-agent-1")
        );
    }

    /// AC3: a freshly created directory is exactly 0700 — and so is the shared
    /// parent, which is what keeps the create/chmod window unobservable.
    #[cfg(unix)]
    #[test]
    fn fresh_dir_is_0700() {
        let tmp = tempfile::tempdir().unwrap();

        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        assert_eq!(mode_of(&dir), 0o700, "leaf directory");
        assert_eq!(mode_of(dir.parent().unwrap()), 0o700, "agent-scripts parent");
    }

    /// The scripts land with their content intact and executable.
    #[test]
    fn writes_each_script_executable() {
        let tmp = tempfile::tempdir().unwrap();

        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        for (name, body) in scripts() {
            let path = dir.join(name);
            assert_eq!(std::fs::read_to_string(&path).unwrap(), body, "{name} content");
            #[cfg(unix)]
            assert_eq!(mode_of(&path), 0o755, "{name} mode");
        }
    }

    /// AC4: a pre-existing directory with an open mode is refused, not adopted.
    /// This is the attacker-planted case — on a shared root, a 0755 directory
    /// someone else can write into must never be mounted next to docker.sock.
    #[cfg(unix)]
    #[test]
    fn preexisting_open_mode_dir_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("stibbons/agent-scripts/myproject-agent-1");
        std::fs::create_dir_all(&dir).unwrap();
        set_mode(&dir, 0o755).unwrap();

        let err =
            prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap_err();

        let msg = err.to_string();
        assert!(msg.contains(&dir.display().to_string()), "names the path: {msg}");
        assert!(msg.contains("0755"), "names the offending mode: {msg}");
        assert!(!dir.join("agent-start.sh").exists(), "must not write into a rejected dir");
    }

    /// A non-directory at the target is refused too. Distinct from the mode
    /// case: this one is reachable without an attacker (local confusion), and
    /// blindly `remove_dir_all`-ing it would fail obscurely instead.
    #[test]
    fn preexisting_file_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("stibbons/agent-scripts");
        std::fs::create_dir_all(&parent).unwrap();
        std::fs::write(parent.join("myproject-agent-1"), "not a dir").unwrap();

        let err =
            prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap_err();

        assert!(err.to_string().contains("is not a directory"), "{err}");
    }

    /// A symlink at the target is refused rather than followed. Following it
    /// would check the *target's* ownership, letting an attacker aim their own
    /// link at a directory of ours and still control what gets mounted.
    #[cfg(unix)]
    #[test]
    fn preexisting_symlink_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("stibbons/agent-scripts");
        std::fs::create_dir_all(&parent).unwrap();
        let elsewhere = tmp.path().join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, parent.join("myproject-agent-1")).unwrap();

        let err =
            prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap_err();

        assert!(err.to_string().contains("is a symlink"), "{err}");
        assert!(!elsewhere.join("agent-start.sh").exists(), "must not write through the link");
    }

    /// Our own 0700 directory from a previous start is reused — this is the
    /// `stibbons agent restart` path, which would break under a literal
    /// "reject anything pre-existing" rule. Stale files inside it do not
    /// survive into the new mount.
    #[cfg(unix)]
    #[test]
    fn preexisting_own_private_dir_is_recreated_clean() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        std::fs::write(dir.join("stale.sh"), "leftover").unwrap();

        let again = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        assert_eq!(again, dir);
        assert!(!again.join("stale.sh").exists(), "stale file must not survive");
        assert!(again.join("agent-entrypoint.sh").exists(), "scripts rewritten");
        assert_eq!(mode_of(&again), 0o700);
    }

    /// #924: a container name that is not a single path component is refused,
    /// so the `Path::join` cannot escape the 0700 tree. `AgentContext::load`
    /// also allow-lists the project name this derives from, but this function
    /// owns the join and must not depend on a caller it cannot see.
    #[test]
    fn traversing_container_name_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();

        for name in ["../../escape-agent-1", "sub/dir-agent-1", "..", ""] {
            let err = prepare_scripts_dir(Some(tmp.path()), name, &scripts())
                .expect_err("must be rejected");
            assert!(err.to_string().contains("not a single path component"), "{name:?}: {err}");
        }
        assert!(!tmp.path().join("escape-agent-1").exists(), "nothing written outside the tree");
    }

    /// An ANCESTOR symlink is refused, not followed. `create_dir_all` would
    /// have walked through it and `set_mode` would have chmod'd its target, so
    /// the scripts would be written into an attacker-controlled directory even
    /// though the leaf itself checks out. Only reachable on a shared state
    /// root, which is the setting the original CWE-377 bug lived in.
    #[cfg(unix)]
    #[test]
    fn ancestor_symlink_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let elsewhere = tmp.path().join("attacker-owned");
        std::fs::create_dir(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, tmp.path().join("stibbons")).unwrap();

        let err = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts())
            .expect_err("must not follow an ancestor symlink");

        assert!(err.to_string().contains("is a symlink"), "{err}");
        assert!(!elsewhere.join("agent-scripts").exists(), "nothing created through the link");
    }

    /// An ancestor that already exists as our own directory is reused, whatever
    /// its mode — the ordinary case, since `<root>/stibbons` is created at the
    /// umask and shared with anything else that may live under it.
    #[test]
    fn preexisting_ancestor_is_reused() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("stibbons")).unwrap();

        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        assert!(dir.join("agent-entrypoint.sh").exists());
    }

    /// Two agents get separate directories, so starting one container never
    /// clobbers another's scripts mid-run.
    #[test]
    fn each_container_gets_its_own_dir() {
        let tmp = tempfile::tempdir().unwrap();

        let one = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        let two = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-2", &scripts()).unwrap();

        assert_ne!(one, two);
        assert!(one.join("agent-start.sh").exists(), "agent-1 scripts survive agent-2's start");
    }

    /// Hidden staging/aside entries left in the `agent-scripts` parent. Every
    /// prepare — success or failure — must leave none (#927).
    fn leftovers(state_root: &Path) -> Vec<String> {
        let parent = state_root.join("stibbons").join("agent-scripts");
        std::fs::read_dir(parent)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with('.'))
            .collect()
    }

    /// Asserts `dir` holds exactly `expected`, byte for byte.
    fn assert_complete(dir: &Path, expected: &[(&str, &str)]) {
        let mut names: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        let mut want: Vec<_> = expected.iter().map(|(n, _)| (*n).to_owned()).collect();
        want.sort();
        assert_eq!(names, want, "{}", dir.display());
        for (name, body) in expected {
            assert_eq!(std::fs::read_to_string(dir.join(name)).unwrap(), *body, "{name}");
        }
    }

    /// Runs invocation A up to `pause_at`, runs B to completion in that gap,
    /// then lets A finish. Barriers, not sleeps, so the interleaving is the
    /// same every run (#927).
    fn interleave(
        root: &Path,
        a_scripts: &[(&'static str, &'static str)],
        b_scripts: &[(&'static str, &'static str)],
        pause_at: Stage,
    ) -> (PathBuf, PathBuf) {
        use std::sync::{Arc, Barrier};

        let paused = Arc::new(Barrier::new(2));
        let resume = Arc::new(Barrier::new(2));
        let a = {
            let (root, scripts) = (root.to_path_buf(), a_scripts.to_vec());
            let (paused, resume) = (Arc::clone(&paused), Arc::clone(&resume));
            std::thread::spawn(move || {
                let mut hit = false;
                let dir = prepare_with_hook(Some(&root), "myproject-agent-1", &scripts, &mut |s| {
                    if s == pause_at && !hit {
                        hit = true;
                        paused.wait();
                        resume.wait();
                    }
                });
                assert!(hit, "A never reached {pause_at:?}");
                dir
            })
        };
        paused.wait();
        let b = prepare_scripts_dir(Some(root), "myproject-agent-1", b_scripts).unwrap();
        resume.wait();
        (a.join().unwrap().unwrap(), b)
    }

    /// The scripts with one body changed — a different stibbons version.
    fn other_scripts() -> Vec<(&'static str, &'static str)> {
        let mut s = scripts();
        s[1].1 = "#!/bin/bash\ninit v2\n";
        s
    }

    /// #927 acceptance: A has built its scripts but not installed them when B
    /// runs a whole prepare for the same container. Both must come back with
    /// the full script set — under the old remove-then-write sequence, B's
    /// `remove_dir_all` deleted A's half-written tree.
    #[test]
    fn concurrent_prepare_same_scripts_both_complete() {
        let tmp = tempfile::tempdir().unwrap();

        let (a, b) = interleave(tmp.path(), &scripts(), &scripts(), Stage::Built);

        assert_eq!(a, b);
        assert_complete(&a, &scripts());
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    }

    /// The same race with differing content: A must replace B's tree whole,
    /// never merge with it, and clear its staging and moved-aside copies.
    #[test]
    fn concurrent_prepare_different_scripts_last_install_wins_whole() {
        let tmp = tempfile::tempdir().unwrap();

        let (a, _) = interleave(tmp.path(), &other_scripts(), &scripts(), Stage::Built);

        assert_complete(&a, &other_scripts());
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    }

    /// The narrower window: A has moved the old tree aside and the target is
    /// momentarily absent when B installs. A's rename then hits B's tree and
    /// must retry rather than fail or merge.
    #[test]
    fn concurrent_install_into_moved_aside_gap_retries() {
        let tmp = tempfile::tempdir().unwrap();
        prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        let (a, b) = interleave(tmp.path(), &other_scripts(), &scripts(), Stage::MovedAside);

        assert_eq!(a, b);
        assert_complete(&a, &other_scripts());
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    }

    /// The target vanishes between A's failed rename and its re-inspection —
    /// another invocation moved it aside. A must treat that as "retry", not as
    /// an error, and still install a complete tree.
    #[test]
    fn target_vanishing_after_failed_rename_is_retried() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        let elsewhere = tmp.path().join("moved-by-someone-else");

        let mut vanished = false;
        let got =
            prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
                if s == Stage::RenameFailed && !vanished {
                    vanished = true;
                    std::fs::rename(&dir, &elsewhere).unwrap();
                }
            })
            .unwrap();

        assert!(vanished, "rename never failed, so the branch was not reached");
        assert_complete(&got, &other_scripts());
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    }

    /// A tree that already holds these exact scripts is left in place — same
    /// inode — so a concurrent start that has bind-mounted it keeps its files.
    #[cfg(unix)]
    #[test]
    fn unchanged_scripts_leave_dir_in_place() {
        use std::os::unix::fs::MetadataExt;
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        let ino = std::fs::metadata(&dir).unwrap().ino();

        prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        assert_eq!(std::fs::metadata(&dir).unwrap().ino(), ino);
    }

    /// Changed content replaces the tree rather than editing it in place.
    #[cfg(unix)]
    #[test]
    fn changed_scripts_replace_the_dir() {
        use std::os::unix::fs::MetadataExt;
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        let ino = std::fs::metadata(&dir).unwrap().ino();

        prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &other_scripts()).unwrap();

        assert_ne!(std::fs::metadata(&dir).unwrap().ino(), ino);
        assert_complete(&dir, &other_scripts());
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    }

    /// A script that fails to write aborts the prepare without leaking the
    /// staging directory, and leaves an existing installed tree intact.
    #[test]
    fn failed_build_leaks_no_staging_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        let mut bad = scripts();
        bad.push(("missing/sub.sh", "x"));
        prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &bad)
            .expect_err("write into a missing subdir must fail");

        assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
        assert_complete(&dir, &scripts());
    }
}
