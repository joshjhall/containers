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
/// An empty value counts as unset, per the XDG spec ("If `$XDG_STATE_HOME` is
/// either not set or empty…") — treating `""` as a path would resolve the
/// directory relative to the current working directory.
///
/// There is intentionally **no** `temp_dir()` fallback. A shared-`/tmp`
/// fallback is exactly the CWE-377 exposure #924 fixed, and it would reappear
/// silently on any host where these variables are unset (cron, some CI
/// runners). Erroring makes that configuration visible instead.
fn state_root_from(
    xdg_state_home: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Result<PathBuf, ScriptsDirError> {
    if let Some(dir) = xdg_state_home.filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    if let Some(home) = home.filter(|v| !v.is_empty()) {
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
        use std::os::unix::fs::PermissionsExt;

        let uid = rustix::process::getuid().as_raw();
        if meta.uid() != uid {
            return Err(unsafe_path(
                path,
                format!("owned by uid {}, not the current uid {uid}", meta.uid()),
            ));
        }

        let mode = meta.permissions().mode() & 0o777;
        if mode != DIR_MODE {
            return Err(unsafe_path(path, format!("has mode {mode:04o}, expected {DIR_MODE:04o}")));
        }
    }

    Ok(())
}

/// Creates `path` as a `0700` directory, failing if anything already occupies
/// it.
///
/// `create_dir`, never `create_dir_all`: adopting a pre-existing path is the
/// bug (#924). The caller has already removed any directory of its own, so an
/// occupant here means something raced in between that removal and this call.
///
/// The mode is set in a second step rather than through the create call. That
/// leaves a brief window where the directory carries the process umask's mode —
/// harmless, because the parent `agent-scripts` directory is itself `0700`, so
/// nobody else can traverse into this one to observe or use the window.
fn create_private_dir(path: &Path) -> Result<(), ScriptsDirError> {
    std::fs::create_dir(path).map_err(|e| io_err(path, e))?;
    set_mode(path, DIR_MODE)
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
/// start, so it is removed and recreated (rather than written over) so no stale
/// file from a previous version survives into the mount.
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
    let parent = state_root.join("stibbons").join("agent-scripts");
    std::fs::create_dir_all(&parent).map_err(|e| io_err(&parent, e))?;
    // Lock down the shared parent too: it is what makes the umask window in
    // `create_private_dir` unobservable, and it hides which agents exist.
    set_mode(&parent, DIR_MODE)?;

    let dir = parent.join(container_name);
    if std::fs::symlink_metadata(&dir).is_ok() {
        // Ours from a previous start? Then start clean. Anything else is
        // rejected by `ensure_private_dir` rather than adopted.
        ensure_private_dir(&dir)?;
        std::fs::remove_dir_all(&dir).map_err(|e| io_err(&dir, e))?;
    }
    create_private_dir(&dir)?;

    for (name, body) in scripts {
        let path = dir.join(name);
        std::fs::write(&path, body).map_err(|e| io_err(&path, e))?;
        set_mode(&path, SCRIPT_MODE)?;
    }

    Ok(dir)
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

    /// `XDG_STATE_HOME` wins when it is set to a real path.
    #[test]
    fn xdg_state_home_is_used_verbatim() {
        let root = state_root_from(Some(OsStr::new("/xdg")), Some(OsStr::new("/home/u"))).unwrap();
        assert_eq!(root, PathBuf::from("/xdg"));
    }

    /// Unset `XDG_STATE_HOME` falls back to the XDG default under `$HOME`.
    #[test]
    fn home_supplies_the_xdg_default() {
        let root = state_root_from(None, Some(OsStr::new("/home/u"))).unwrap();
        assert_eq!(root, PathBuf::from("/home/u/.local/state"));
    }

    /// An EMPTY `XDG_STATE_HOME` counts as unset, per the XDG spec. Treating
    /// `""` as a path would resolve the scripts directory relative to the cwd.
    #[test]
    fn empty_xdg_state_home_counts_as_unset() {
        let root = state_root_from(Some(OsStr::new("")), Some(OsStr::new("/home/u"))).unwrap();
        assert_eq!(root, PathBuf::from("/home/u/.local/state"));
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

        assert_eq!(dir, tmp.path().join("stibbons/agent-scripts/myproject-agent-1"));
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
}
