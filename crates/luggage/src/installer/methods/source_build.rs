//! Source-build method — extract a source archive and run the catalog's
//! ordered build steps inside it.
//!
//! Generalises what `lib/features/python.sh` does today:
//!
//! ```text
//! tar -xzf Python-X.Y.Z.tgz && cd Python-X.Y.Z
//! ./configure --prefix=/usr/local --enable-optimizations ...
//! make -j"$(nproc)"
//! make install
//! ```
//!
//! The steps, their flags, and the parallelism (`{nproc}`) all come from the
//! catalog's `build_steps[]`, so a new source-built tool needs no code here.
//! Build-dependency packages (compilers, `-dev` headers) are not this
//! method's concern: they are the method's `dependencies`, installed by the
//! system-package stage before any method runs.
//!
//! # Extraction
//!
//! Reuses the `binary-tarball` method's traversal-safe extraction
//! ([`super::tarball`]) rather than a second copy of it — the archive is just
//! as untrusted here, and the build then *executes* what it unpacked.
//! `strip_components` applies as it does there: python's tarball carries a
//! `Python-X.Y.Z/` root, which a strip of `1` flattens so the extracted
//! directory itself is the source root.
//!
//! # Who runs the steps
//!
//! Steps run as the luggage process (root during an image build), not
//! through `su` to the install user like `script-installer`. `make install`
//! writes into the prefix (`/usr/local`), which only root can do — the same
//! reason `python.sh` runs the whole build as root.
//!
//! # Progress and failure
//!
//! A PGO python build runs for many minutes, so each step's output is
//! streamed line-by-line into the per-feature log as it is produced
//! ([`super::CommandRunner::run_streaming`]) instead of buffered. A failing
//! step aborts the build with [`LuggageError::BuildStepFailed`], which names
//! the step's position and argv and carries only the tail of its stderr —
//! the full output is already in the log.
//!
//! # Cleanup
//!
//! The source tree is a [`tempfile::TempDir`] beside the artifact, removed by
//! its `Drop` on every exit path: success, a failed step, or a rejected
//! archive.

use std::path::{Path, PathBuf};

use containers_common::tooldb::BuildStep;

use super::layout::{build_env, install_binaries, prepare_cache_dirs};
use super::tarball::{artifact_name, detect_compression, extract, resolve_prefix};
use super::{MethodContext, StreamingCommand};
use crate::error::{LuggageError, Result};
use crate::installer::template::{Substitutions, host_nproc, substitute_url};

/// Prefix of the scratch directory the source tree is extracted into.
pub const BUILD_DIR_PREFIX: &str = "luggage-build-";

/// Run the source-build flow.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when the method declares no `build_steps`, a
///   step has an empty command, or it lists `binaries` without a
///   `bin_source_dir`.
/// - [`LuggageError::TemplateMissingKey`] when a step arg names a
///   placeholder other than `{nproc}`.
/// - The archive errors of [`super::tarball::run`]
///   ([`LuggageError::UnsupportedArchiveFormat`],
///   [`LuggageError::UnsafeArchiveEntry`], [`LuggageError::ArchiveTooLarge`],
///   [`LuggageError::ArchiveExtractionFailed`]) — raised before any step runs.
/// - [`LuggageError::InstallStageFailed`] when a step cannot be spawned, or
///   a cache-dir `chown` fails.
/// - [`LuggageError::BuildStepFailed`] when a step exits non-zero.
/// - [`LuggageError::Io`] when the scratch dir or bin links cannot be made.
pub fn run(ctx: &MethodContext<'_>) -> Result<()> {
    // Validate the catalog shape before touching the filesystem: a source
    // build with nothing to run is a catalog defect, not an empty success.
    if ctx.build_steps.is_empty() {
        return Err(LuggageError::Catalog(
            "source-build install method declares no `build_steps`".into(),
        ));
    }
    if let Some(i) = ctx.build_steps.iter().position(|s| s.command.trim().is_empty()) {
        return Err(LuggageError::Catalog(format!(
            "source-build step {} of {} has an empty `command`",
            i + 1,
            ctx.build_steps.len(),
        )));
    }

    // 1. Cache dirs first — same contract as the other methods (#806).
    prepare_cache_dirs(ctx)?;

    let name = artifact_name(ctx.artifact);
    let compression = detect_compression(&name)?;
    let prefix = resolve_prefix(ctx.prefix)?;

    // 2. Extract into a scratch dir. Bound for the rest of the function, so
    //    its Drop removes the source tree on success and on every `?` below.
    let scratch = tempfile::Builder::new()
        .prefix(BUILD_DIR_PREFIX)
        .tempdir_in(ctx.artifact.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| LuggageError::Io { path: ctx.artifact.to_owned(), source: e })?;
    let source_root = scratch.path();
    extract(
        ctx.artifact,
        &name,
        compression,
        source_root,
        ctx.strip_components,
        ctx.max_extract_bytes,
    )?;

    // 3. Run the steps in order; the first failure aborts the rest.
    let env = build_env(ctx);
    let nproc = host_nproc();
    let subs = Substitutions { nproc: Some(&nproc), ..Substitutions::default() };
    let total = ctx.build_steps.len();
    for (i, step) in ctx.build_steps.iter().enumerate() {
        run_step(ctx, step, i + 1, total, source_root, &env, &subs)?;
    }

    // 4. Surface the catalog's binaries. Like a tarball, a source build
    //    installs under the prefix (python: `/usr/local/bin`), so that is
    //    what `bin_source_dir` resolves against.
    install_binaries(ctx, &prefix)
}

/// Substitute, log, and run one build step.
fn run_step(
    ctx: &MethodContext<'_>,
    step: &BuildStep,
    index: usize,
    total: usize,
    source_root: &Path,
    env: &std::collections::BTreeMap<String, String>,
    subs: &Substitutions<'_>,
) -> Result<()> {
    let args =
        step.args.iter().flatten().map(|a| substitute_url(a, subs)).collect::<Result<Vec<_>>>()?;
    let program = resolve_command(&step.command, source_root);
    let program = program.to_string_lossy();

    // The argv as the catalog wrote it (`./configure`, not the scratch-dir
    // absolute path), so the log and error read like the bash they replace.
    let shown = shell_words::join(
        std::iter::once(step.command.as_str()).chain(args.iter().map(String::as_str)),
    );
    let banner = format!("build step {index}/{total}: {shown}");
    if let Some(l) = ctx.log {
        l.step(&banner);
    } else {
        tracing::info!("{banner}");
    }

    // With no per-feature log the lines still go to `tracing`, so a build
    // never runs silently just because logging degraded.
    let cmd = StreamingCommand { program: &program, args: &args, cwd: source_root, env };
    let outcome = ctx.runner.run_streaming(&cmd, &mut |line| {
        if let Some(l) = ctx.log {
            l.message(line);
        } else {
            tracing::info!("{line}");
        }
    })?;
    if outcome.success() {
        return Ok(());
    }
    Err(LuggageError::BuildStepFailed {
        step: index,
        total,
        argv: shown,
        status: outcome.status,
        stderr_tail: String::from_utf8_lossy(&outcome.stderr).trim_end().to_owned(),
    })
}

/// Resolve a step's `command` to what gets spawned.
///
/// A relative path with a separator (`./configure`, `build/gen.sh`) names a
/// file in the source tree and is anchored to `source_root` explicitly:
/// whether `Command` resolves a relative program against the child's
/// `current_dir` or the parent's cwd is platform-dependent, and guessing
/// wrong would run nothing (or the wrong file). A bare name (`make`) is left
/// for `PATH` lookup; an absolute path is used as-is.
fn resolve_command(command: &str, source_root: &Path) -> PathBuf {
    let path = Path::new(command);
    if path.is_relative() && command.contains('/') {
        source_root.join(path)
    } else {
        path.to_owned()
    }
}

#[cfg(all(test, unix))]
#[path = "source_build_tests.rs"]
mod tests;
