//! Catalog-driven install layout shared by every install method.
//!
//! These are the three side-effects issue #806 made catalog-driven rather
//! than per-tool: create-and-chown the `cache_dirs`, layer those directories
//! into the installer's environment, and symlink the `binaries` into
//! `bin_root`.
//!
//! They live here rather than in one method because `script-installer` and
//! `binary-tarball` must perform them *identically* — the two methods differ
//! only in how the payload gets onto disk (run an executable vs unpack an
//! archive), not in how the result is surfaced. Keeping one copy is what
//! stops #806 parity (and the #492 root-chown carve-out) from drifting apart
//! as further method kinds land.

use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs as unix_fs;
use std::path::Path;

use super::{CommandRunner, MethodContext};
use crate::error::{LuggageError, Result};
use crate::installer::user::{ROOT_USER, chown_command};

/// Create each `cache_dirs` entry under `cache_root` and chown it to the
/// install user.
///
/// `create_dir_all` runs in the parent (root) process, so any subdirs it
/// creates would otherwise be root-owned and a subsequent unprivileged write
/// into one would hit EACCES (issue #462).
///
/// When the install user *is* root there is nothing to transfer — root
/// already owns the freshly-created dirs — and `chown root:root` is at best a
/// no-op. Skipping it also keeps the install correct on base images where the
/// resolved user doesn't exist: `resolve_install_user` falls back to `root`
/// there, and an unconditional `chown <user>:<user>` would fail outright
/// (issue #492).
///
/// # Errors
///
/// - [`LuggageError::Io`] when a directory cannot be created.
/// - [`LuggageError::InstallStageFailed`] when the `chown` exits non-zero.
pub fn prepare_cache_dirs(ctx: &MethodContext<'_>) -> Result<()> {
    let needs_chown = ctx.user != ROOT_USER;
    for rel in ctx.cache_dirs.values() {
        let dir = ctx.cache_root.join(rel);
        fs::create_dir_all(&dir).map_err(|e| LuggageError::Io { path: dir.clone(), source: e })?;
        if !needs_chown {
            continue;
        }
        let argv = chown_command(ctx.user, &dir);
        let outcome = ctx.runner.run(&argv[0], &argv[1..])?;
        if !outcome.success() {
            return Err(LuggageError::InstallStageFailed {
                stage: "chown",
                message: format!(
                    "chown {} -> {} exited with status {:?}: {}",
                    dir.display(),
                    ctx.user,
                    outcome.status,
                    String::from_utf8_lossy(&outcome.stderr).trim_end(),
                ),
            });
        }
    }
    Ok(())
}

/// Build the install environment: the caller's explicit exports layered over
/// the paths derived from `cache_dirs`.
///
/// `or_insert` keeps an explicit `invoke.env` value winning over the path
/// derived from `cache_dirs` for the same variable — the catalog documents
/// that precedence.
#[must_use]
pub fn build_env(ctx: &MethodContext<'_>) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = ctx.env.clone();
    for (var, rel) in ctx.cache_dirs {
        env.entry(var.clone()).or_insert_with(|| ctx.cache_root.join(rel).display().to_string());
    }
    env
}

/// Symlink the method's `binaries` into `bin_root`, resolving their source
/// directory against `source_root`.
///
/// `source_root` differs per method: `script-installer` links out of the
/// cache root (rust's `cargo/bin`), while `binary-tarball` links out of the
/// extraction prefix (go's `go/bin`). `bin_source_dir` stays relative in both
/// cases, so the method supplies the root it should resolve against.
///
/// A no-op when the method lists no binaries.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `binaries` is non-empty but the method
///   declares no `bin_source_dir` to link them from.
/// - [`LuggageError::Io`] when a link cannot be created or replaced.
pub fn install_binaries(ctx: &MethodContext<'_>, source_root: &Path) -> Result<()> {
    if ctx.binaries.is_empty() {
        return Ok(());
    }
    let rel = ctx.bin_source_dir.ok_or_else(|| {
        LuggageError::Catalog(format!(
            "install method lists {} binaries but no `bin_source_dir` to link them from",
            ctx.binaries.len(),
        ))
    })?;
    install_symlinks(&source_root.join(rel), ctx.binaries, ctx.bin_root, ctx.runner)
}

/// Symlink `<source_dir>/<name>` → `<bin_root>/<name>` for each name in
/// `binaries`. Existing symlinks are replaced; existing non-symlinks are
/// left alone (avoids clobbering distro-managed files).
///
/// Unix-only — the catalog marks the tools using these methods `unsupported`
/// on Windows in `support_matrix`, so this path is unreachable there. The
/// non-unix build returns `NotImplemented` so the crate still compiles for
/// any host that doesn't go through the resolver (e.g. `cargo build` on
/// Windows for a developer working on something unrelated).
#[cfg(unix)]
fn install_symlinks(
    source_dir: &Path,
    binaries: &[String],
    bin_root: &Path,
    runner: &dyn CommandRunner,
) -> Result<()> {
    fs::create_dir_all(bin_root)
        .map_err(|e| LuggageError::Io { path: bin_root.to_owned(), source: e })?;
    for name in binaries {
        let target = source_dir.join(name);
        let link = bin_root.join(name);
        if link.exists() {
            let metadata = fs::symlink_metadata(&link)
                .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
            if metadata.file_type().is_symlink() {
                fs::remove_file(&link)
                    .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
            } else {
                continue;
            }
        }
        unix_fs::symlink(&target, &link)
            .map_err(|e| LuggageError::Io { path: link.clone(), source: e })?;
    }
    // The runner is unused here today (symlink syscalls go direct), but
    // accepting it keeps the API uniform and lets future versions of this
    // function shell out for cross-distro quirks (e.g. SELinux contexts).
    let _ = runner;
    Ok(())
}

#[cfg(not(unix))]
fn install_symlinks(
    _source_dir: &Path,
    _binaries: &[String],
    _bin_root: &Path,
    _runner: &dyn CommandRunner,
) -> Result<()> {
    Err(LuggageError::NotImplemented(
        "binary symlinking is unix-only; tools using it are `unsupported` on Windows in catalog",
    ))
}
