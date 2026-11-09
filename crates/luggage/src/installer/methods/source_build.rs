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

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use containers_common::tooldb::BuildStep;

use super::layout::{build_env, install_binaries, prepare_cache_dirs};
use super::tarball::{artifact_name, detect_compression, extract, resolve_prefix};
use super::{MethodContext, StreamingCommand};
use crate::error::{LuggageError, Result};
use crate::installer::template::{Substitutions, host_nproc, substitute_url};

/// Prefix of the scratch directory the source tree is extracted into.
pub const BUILD_DIR_PREFIX: &str = "luggage-build-";

/// Env var that opts a source build into a compiler launcher (`ccache`).
///
/// Unset — the default, and every production install — changes nothing.
/// Evidence runs set it so node's alpine compile is cached across runs
/// (#1594). Kept luggage-side rather than in the catalog so the catalog stays
/// tool-agnostic and a production image never grows a ccache dependency.
pub const COMPILER_LAUNCHER_ENV: &str = "LUGGAGE_COMPILER_LAUNCHER";

/// Read [`COMPILER_LAUNCHER_ENV`].
///
/// # Errors
///
/// [`LuggageError::Catalog`] when the value is set but not valid UTF-8, empty,
/// or not a plain program name or path — see [`parse_compiler_launcher`].
pub fn compiler_launcher_from_env() -> Result<Option<String>> {
    parse_compiler_launcher(crate::installer::tuning_env_var(COMPILER_LAUNCHER_ENV)?.as_deref())
}

/// The value half of [`compiler_launcher_from_env`], split out so it is
/// testable without `std::env::set_var` (forbidden here).
///
/// Unlike the numeric tuning vars, an exported-but-empty value is an error,
/// not "unset": the only reason to export this is to turn caching on, so an
/// empty value is a mis-set opt-in that would otherwise silently cost a
/// two-hour cold compile. Anything outside `[A-Za-z0-9._/+-]` is refused:
/// `make` word-splits `$(CC)`, so `ccache --foo` would become a launcher plus
/// a stray flag, and shell metacharacters would run as code in the build.
/// A value whose last `/`-segment is empty, `.` or `..` (`/`, `.`, `..`,
/// `bin/`, `/usr/..`) names a directory, not a program, and is refused too.
///
/// # Errors
///
/// [`LuggageError::Catalog`] naming the variable for an empty value, one with
/// a character outside `[A-Za-z0-9._/+-]`, or one that names a directory.
pub fn parse_compiler_launcher(raw: Option<&str>) -> Result<Option<String>> {
    let Some(raw) = raw else { return Ok(None) };
    // A conservative charset: a bare program name or a path. `configure`
    // and make recipes expand `$CC` through `/bin/sh` (sometimes via
    // `eval`), and these steps run as root, so a `;`, `$(...)` or backtick
    // here would execute as shell code rather than name a launcher.
    let launcher_char = |c: char| c.is_ascii_alphanumeric() || "._/+-".contains(c);
    // The program's own name: what is left after the last `/`.
    let program = raw.rsplit('/').next().unwrap_or(raw);
    // A leading `-` would read as a flag, not a program (`--foo cc`).
    if raw.is_empty()
        || raw.starts_with('-')
        || !raw.chars().all(launcher_char)
        || matches!(program, "" | "." | "..")
    {
        return Err(LuggageError::Catalog(format!(
            "{COMPILER_LAUNCHER_ENV} must name a single launcher program (e.g. `ccache`), \
             got `{raw}`; unset it to build without one",
        )));
    }
    Ok(Some(raw.to_owned()))
}

/// Prefix `launcher` onto the build's `CC` and `CXX`.
///
/// The compiler each wraps is the one the unwrapped build would have used,
/// so caching never changes the toolchain:
///
/// 1. the catalog's own non-empty `CC`/`CXX` when it exports one (it wins in
///    the step env, so it wins here too);
/// 2. else a non-empty `CC`/`CXX` inherited from luggage's environment — the
///    streaming runner passes the process env through to every step, so an
///    image-level `CC=clang` would otherwise reach `configure` unwrapped but
///    be silently replaced by `cc` once the launcher is on;
/// 3. else the first of `gcc`, `cc` (for `CXX`: `g++`, `c++`) found on
///    `PATH` — the order autoconf's `AC_PROG_CC`/`AC_PROG_CXX` probe in, so
///    an image whose `cc` is not its `gcc` still gets the compiler
///    `configure` would have picked;
/// 4. else nothing: the variable is left as it was. A C-only image has no
///    C++ compiler, and a `CXX` naming one that does not exist would turn
///    an unwrapped build's "no C++" into a hard failure.
///
/// A blank value at either level counts as unset, as autoconf's
/// `test -z "$CC"` treats it — wrapping it would hand ccache no compiler.
/// A base that already starts with the launcher (an inherited
/// `CC="ccache gcc"`) is kept as-is rather than wrapped a second time.
///
/// `inherited` looks a variable up in the process environment and `on_path`
/// reports whether a program is executable on `PATH`; both are parameters
/// so tests can supply them without `std::env::set_var`.
fn apply_compiler_launcher(
    env: &mut BTreeMap<String, String>,
    launcher: &str,
    inherited: impl Fn(&str) -> Option<String>,
    on_path: impl Fn(&str) -> bool,
) {
    for (var, probe) in [("CC", ["gcc", "cc"]), ("CXX", ["g++", "c++"])] {
        let set = |v: &String| !v.trim().is_empty();
        let Some(base) = env
            .get(var)
            .filter(|v| set(v))
            .cloned()
            .or_else(|| inherited(var).filter(set))
            .or_else(|| probe.into_iter().find(|p| on_path(p)).map(str::to_owned))
        else {
            continue;
        };
        let wrapped =
            if already_launched(&base, launcher) { base } else { format!("{launcher} {base}") };
        env.insert(var.to_owned(), wrapped);
    }
}

/// `true` when `base`'s first word is `launcher` — compared by file name, so
/// `ccache gcc` counts as launched for both `ccache` and `/opt/x/ccache`.
fn already_launched(base: &str, launcher: &str) -> bool {
    let name = |s: &str| s.rsplit('/').next().unwrap_or(s).to_owned();
    base.split_whitespace().next().is_some_and(|first| name(first) == name(launcher))
}

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
    // Also a pure catalog property, so it is checked here rather than left
    // to `install_binaries`: by then a PGO build and a root `make install`
    // into the prefix would already have run.
    if !ctx.binaries.is_empty() && ctx.bin_source_dir.is_none() {
        return Err(LuggageError::Catalog(format!(
            "install method lists {} binaries but no `bin_source_dir` to link them from",
            ctx.binaries.len(),
        )));
    }

    // 1. Cache dirs first — same contract as the other methods (#806).
    prepare_cache_dirs(ctx)?;

    let name = artifact_name(ctx.artifact);
    let compression = detect_compression(&name)?;
    let prefix = resolve_prefix(ctx.prefix)?;

    // 2. Extract into a scratch dir. Bound for the rest of the function, so
    //    its Drop removes the source tree on success and on every `?` below.
    //
    //    The root must be absolute because it is used twice per step: as the
    //    child's cwd AND as the anchor for `./configure`. A relative root
    //    (`luggage install --tmp-root ./scratch`) would be applied once by the
    //    join and again by the chdir. `tempfile` already absolutises its base
    //    dir today; this makes the requirement explicit here rather than
    //    leaving it to that crate's internals. A bare-filename artifact has
    //    parent `Some("")`, which means ".".
    let parent = match ctx.artifact.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    let parent = std::path::absolute(parent)
        .map_err(|e| LuggageError::Io { path: parent.to_owned(), source: e })?;
    let scratch = tempfile::Builder::new()
        .prefix(BUILD_DIR_PREFIX)
        .tempdir_in(&parent)
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
    let mut env = build_env(ctx);
    if let Some(launcher) = ctx.compiler_launcher {
        apply_compiler_launcher(
            &mut env,
            launcher,
            |var| std::env::var(var).ok(),
            crate::installer::syspackages::on_path,
        );
        let shown = |var: &str| env.get(var).map_or("unset", String::as_str);
        let note =
            format!("compiler launcher: {launcher} (CC=`{}`, CXX=`{}`)", shown("CC"), shown("CXX"));
        if let Some(l) = ctx.log {
            l.message(&note);
        } else {
            tracing::info!("{note}");
        }
    }
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
