//! Binary-tarball method — unpack a prebuilt archive into a prefix.
//!
//! Generalises the extraction the go and node feature scripts perform:
//!
//! - `lib/features/golang.sh` — `tar -xzf go.tar.gz -C /usr/local`, so the
//!   archive's own `go/` top level becomes `/usr/local/go` (strip 0).
//! - `lib/features/node.sh` — `tar -xJf node.tar.xz --strip-components=1 -C
//!   /usr/local`, flattening the versioned root into the prefix (strip 1).
//!
//! Both compressions and the strip depth come from the catalog, so a new
//! tarball-shaped tool needs no code here. The cache-dir and `bin_root`
//! handling is the shared [`super::layout`] code, identical to
//! `script-installer` (issue #806). This method builds no env map: unlike
//! `script-installer` it spawns no child to export one to, and the
//! post-install and validation stages receive their own map assembled by
//! `run_stages` from the same catalog `cache_dirs`.
//!
//! # Why this extracts in-process instead of shelling out to `tar`
//!
//! The sibling `script-installer` dispatches through [`super::CommandRunner`],
//! and the obvious symmetry would be to run `tar -xzf ... -C <prefix>` the
//! same way. This module deliberately does not, and that choice is load-
//! bearing rather than stylistic: `RecordingRunner` records an argv and
//! returns canned success without extracting anything. Under a shell-out
//! design the security requirement of issue #808 — that an archive whose
//! entries escape the prefix is *rejected* — could only be tested by
//! asserting we passed `-C` to `tar`, which demonstrates nothing about what
//! `tar` would then do. Extracting in-process is what makes the crafted-
//! fixture tests at the bottom of this file real. Please do not "restore the
//! symmetry" by converting this to a `runner.run("tar", ...)`.
//!
//! # Extraction safety
//!
//! Extraction runs as **root** during the image build, so an archive entry
//! that escapes the prefix could write anywhere on the filesystem. Every
//! entry is validated by [`safe_relative_path`] before anything is written,
//! and link entries additionally have their targets checked — a `..` in a
//! symlink target is just as dangerous as one in an entry name, since a
//! later entry can be written *through* the link. Nothing is trusted to the
//! `tar` crate's own defaults (issue #808 requires this be proven by test,
//! not assumed).
//!
//! That includes entry *types* and permission bits (issue #862). Only
//! regular files, directories and symlinks are written; any other type —
//! hard links, device nodes, fifos, sparse or contiguous files, unknown
//! typeflags — rejects the whole archive. Hard links are refused rather
//! than validated because tar-rs resolves a hard link's source against the
//! *process* working directory when unpacking an entry on its own, so a
//! target that looks prefix-relative to [`validate_link_target`] could
//! link a file from outside the prefix. tar-rs would today write such an
//! entry as a plain file and strip setuid/setgid unless
//! `preserve_permissions` is set, but both are its defaults, not ours: the
//! allowlist and an explicit special-bit mask make the guarantee hold
//! regardless of what a future tar release or a later change to the
//! unpack options does.
//!
//! # Partial-install behaviour
//!
//! The archive unpacks into a staging directory first and is merged into the
//! prefix only once every entry has been validated and written. So a bad
//! compression, a traversal entry, or a truncated archive leaves the prefix
//! **untouched**. A failure during the merge itself can still leave a
//! partially-populated prefix; making that atomic would need filesystem
//! transactions we don't have. Such a failure is reported as
//! [`LuggageError::ArchiveMergeFailed`], naming the prefix and how many of
//! the archive's entries had landed, and the landed paths are logged at
//! `warn` level (issue #863). It is deliberately *not* rolled back: undoing a
//! merge into a shared prefix risks deleting files another tool owns. The
//! merge cannot rename-into-place because node strips into an
//! already-populated `/usr/local` — the prefix is shared with other tools
//! rather than owned by this one.

use std::fs::{self, File};
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};

use flate2::read::GzDecoder;
use tar::{Archive, EntryType};

use super::MethodContext;
use super::archive_limit::{LimitedReader, LimitedWriter};
use super::archive_path::{safe_relative_path, strip_prefix_components, validate_link_target};
use super::layout::{install_binaries, prepare_cache_dirs};
use crate::error::{LuggageError, Result};

/// Compression wrapping the tar stream, inferred from the artifact filename.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Compression {
    /// `.tar.gz` / `.tgz` — go's shape.
    Gzip,
    /// `.tar.xz` / `.txz` — node's shape.
    Xz,
}

/// Extraction prefix used when the catalog names none.
///
/// Matches what both bash scripts pass to `tar -C`.
const DEFAULT_PREFIX: &str = "/usr/local";

/// Run the binary-tarball flow.
///
/// # Errors
///
/// - [`LuggageError::UnsupportedArchiveFormat`] when the artifact filename
///   carries no compression this build recognises.
/// - [`LuggageError::UnsafeArchiveEntry`] when any entry path or link target
///   would escape the extraction prefix, or an entry's type is not a regular
///   file, directory, or symlink.
/// - [`LuggageError::ArchiveExtractionFailed`] when the archive is corrupt or
///   truncated, or an entry cannot be written.
/// - [`LuggageError::Io`] when the staging area, prefix, or bin directories
///   cannot be created.
/// - [`LuggageError::ArchiveMergeFailed`] when moving the extracted files
///   into the prefix fails partway; it reports how many entries landed.
/// - [`LuggageError::InstallStageFailed`] when a cache-dir `chown` fails.
/// - [`LuggageError::Catalog`] when the method lists `binaries` but no
///   `bin_source_dir` to link them from.
pub fn run(ctx: &MethodContext<'_>) -> Result<()> {
    // 1. Cache dirs first — same contract as script-installer (#462 / #492).
    prepare_cache_dirs(ctx)?;

    let artifact_name = artifact_name(ctx.artifact);
    let compression = detect_compression(&artifact_name)?;
    let prefix = resolve_prefix(ctx.prefix)?;

    // 2. Unpack into a staging dir beside the artifact, so a rejected or
    //    corrupt archive never touches the prefix. `TempDir` cleans itself up
    //    on both the success and error paths.
    let staging = tempfile::Builder::new()
        .prefix("luggage-extract-")
        .tempdir_in(ctx.artifact.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| LuggageError::Io { path: ctx.artifact.to_owned(), source: e })?;

    extract(
        ctx.artifact,
        &artifact_name,
        compression,
        staging.path(),
        ctx.strip_components,
        ctx.max_extract_bytes,
    )?;

    // 3. Merge staging into the prefix.
    fs::create_dir_all(&prefix)
        .map_err(|e| LuggageError::Io { path: prefix.clone(), source: e })?;
    merge_into_prefix(staging.path(), &prefix, &artifact_name)?;

    // 4. Symlink the catalog's binaries. Unlike script-installer, a tarball's
    //    binaries land under the extraction prefix (go: `go/bin`), not the
    //    cache root, so the prefix is what `bin_source_dir` resolves against.
    install_binaries(ctx, &prefix)
}

/// Resolve the catalog's `prefix`, defaulting and validating it.
///
/// The catalog documents `prefix` as absolute, but nothing upstream enforces
/// that. A relative value — `usr/local` missing its leading slash — would
/// otherwise extract relative to whatever working directory the build happens
/// to run from, scattering a tool's files somewhere unintended instead of
/// failing. Reported as a catalog defect, mirroring how `install_binaries`
/// treats a missing `bin_source_dir`.
pub(super) fn resolve_prefix(prefix: Option<&str>) -> Result<PathBuf> {
    let Some(raw) = prefix else { return Ok(PathBuf::from(DEFAULT_PREFIX)) };
    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Err(LuggageError::Catalog(format!(
            "install method `prefix` must be an absolute path, got `{raw}`",
        )));
    }
    Ok(path)
}

/// The artifact's filename, for error messages and format detection.
pub(super) fn artifact_name(artifact: &Path) -> String {
    artifact
        .file_name()
        .map_or_else(|| artifact.display().to_string(), |n| n.to_string_lossy().into_owned())
}

/// Infer the compression from the artifact filename.
///
/// Filename-based because that is what the catalog's `source_url_template`
/// controls and what the publisher names the artifact; sniffing magic bytes
/// would accept an archive whose name and contents disagree, which is a
/// signal worth failing on rather than papering over.
pub(super) fn detect_compression(name: &str) -> Result<Compression> {
    /// Recognised suffixes, longest-first so `.tar.gz` is never shadowed by
    /// a shorter match. Compared against an already-lowercased filename.
    const SUFFIXES: [(&str, Compression); 4] = [
        (".tar.gz", Compression::Gzip),
        (".tar.xz", Compression::Xz),
        (".tgz", Compression::Gzip),
        (".txz", Compression::Xz),
    ];

    let lower = name.to_ascii_lowercase();
    SUFFIXES
        .iter()
        .find_map(|(suffix, compression)| lower.ends_with(suffix).then_some(*compression))
        .ok_or_else(|| LuggageError::UnsupportedArchiveFormat {
            artifact: name.to_owned(),
            message: "expected one of `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`".to_owned(),
        })
}

/// Decompress and unpack `artifact` into `dest`, stripping `strip` leading
/// path components from every entry.
pub(super) fn extract(
    artifact: &Path,
    artifact_name: &str,
    compression: Compression,
    dest: &Path,
    strip: u32,
    max_bytes: u64,
) -> Result<()> {
    let file = File::open(artifact)
        .map_err(|e| LuggageError::Io { path: artifact.to_owned(), source: e })?;
    let reader = BufReader::new(file);

    match compression {
        Compression::Gzip => {
            // gzip streams straight into the tar reader — no intermediate.
            // The limiter sits on the *decompressed* side, so it measures
            // expansion rather than artifact size.
            let limited = LimitedReader::new(GzDecoder::new(reader), max_bytes);
            unpack_limited(limited, artifact_name, dest, strip, max_bytes)
        }
        Compression::Xz => {
            // `lzma_rs::xz_decompress` writes into a sink rather than
            // exposing a `Read`, so xz lands as a plain `.tar` beside the
            // archive first. The temp file is dropped as soon as the unpack
            // finishes.
            //
            // The ceiling therefore has to sit on the WRITER: this path
            // materialises the whole decompressed stream before a single
            // entry is read, so a reader-side cap would fire only after the
            // bomb was already on disk — exactly the outcome it exists to
            // prevent.
            let plain = tempfile::Builder::new()
                .prefix("luggage-xz-")
                .suffix(".tar")
                .tempfile_in(dest.parent().unwrap_or_else(|| Path::new(".")))
                .map_err(|e| LuggageError::Io { path: artifact.to_owned(), source: e })?;
            {
                let mut reader = reader;
                let mut writer = LimitedWriter::new(BufWriter::new(plain.as_file()), max_bytes);
                let outcome = lzma_rs::xz_decompress(&mut reader, &mut writer);
                // Check the limiter first: the write error surfaces through
                // `xz_decompress` as an opaque decompression failure, and
                // reporting a bomb as "corrupt archive" would send whoever
                // reads it looking for the wrong problem.
                if writer.tripped() {
                    return Err(LuggageError::ArchiveTooLarge {
                        artifact: artifact_name.to_owned(),
                        limit: max_bytes,
                    });
                }
                outcome.map_err(|e| LuggageError::ArchiveExtractionFailed {
                    artifact: artifact_name.to_owned(),
                    message: format!("xz decompression failed: {e}"),
                })?;
            }
            let tar_file = plain
                .reopen()
                .map_err(|e| LuggageError::Io { path: plain.path().to_owned(), source: e })?;
            // The temp file is already bounded by the writer above, so the
            // tar read needs no second limiter.
            unpack(Archive::new(BufReader::new(tar_file)), artifact_name, dest, strip)
        }
    }
}

/// Unpack through a [`LimitedReader`], converting an exhausted budget into
/// [`LuggageError::ArchiveTooLarge`].
///
/// The reader signals its cap with EOF so the tar layer unwinds cleanly; that
/// EOF is indistinguishable from a truncated archive until the limiter is
/// consulted, which is what this wrapper exists to do.
fn unpack_limited<R: std::io::Read>(
    limited: LimitedReader<R>,
    artifact_name: &str,
    dest: &Path,
    strip: u32,
    max_bytes: u64,
) -> Result<()> {
    let mut archive = Archive::new(limited);
    let result = unpack_entries(&mut archive, artifact_name, dest, strip);
    if archive.into_inner().tripped() {
        return Err(LuggageError::ArchiveTooLarge {
            artifact: artifact_name.to_owned(),
            limit: max_bytes,
        });
    }
    result
}

/// Walk every archive entry, validate its path (and link target), and write
/// it under `dest`.
///
/// Entries are written one at a time rather than via `Archive::unpack` so
/// that validation happens *before* each write, on the path we then use —
/// there is no window in which the crate's own path handling could differ
/// from what we checked.
fn unpack<R: std::io::Read>(
    mut archive: Archive<R>,
    artifact_name: &str,
    dest: &Path,
    strip: u32,
) -> Result<()> {
    unpack_entries(&mut archive, artifact_name, dest, strip)
}

/// The entry loop itself, borrowing the archive so a caller holding a limiter
/// can reclaim it afterwards to ask whether the budget was exhausted.
fn unpack_entries<R: std::io::Read>(
    archive: &mut Archive<R>,
    artifact_name: &str,
    dest: &Path,
    strip: u32,
) -> Result<()> {
    let entries = archive.entries().map_err(|e| LuggageError::ArchiveExtractionFailed {
        artifact: artifact_name.to_owned(),
        message: format!("could not read archive entries: {e}"),
    })?;

    for entry in entries {
        let mut entry = entry.map_err(|e| LuggageError::ArchiveExtractionFailed {
            artifact: artifact_name.to_owned(),
            message: format!("could not read an archive entry: {e}"),
        })?;

        let raw = entry.path().map_err(|e| LuggageError::ArchiveExtractionFailed {
            artifact: artifact_name.to_owned(),
            message: format!("entry has an unreadable path: {e}"),
        })?;
        let raw = raw.into_owned();

        // Type before path or strip: a device node is rejected even when it
        // sits shallow enough to be stripped away, so the verdict on an
        // archive never depends on the catalog's strip depth.
        if !allowed_entry_type(entry.header().entry_type(), &raw, artifact_name)? {
            continue;
        }

        // Validate the full recorded path first, so a traversal attempt is
        // rejected even when stripping would have removed the offending
        // component.
        let safe = safe_relative_path(&raw, artifact_name)?;

        // Then strip. An entry shallower than the strip depth is the
        // archive's own top-level directory being flattened away — skip it
        // rather than erroring, matching `tar --strip-components`.
        let Some(relative) = strip_prefix_components(&safe, strip) else {
            continue;
        };
        if relative.as_os_str().is_empty() {
            continue;
        }

        let target = dest.join(&relative);

        // A link's *target* escaping the prefix is the subtler half of the
        // traversal problem: the link itself sits safely inside, but a later
        // entry written through it lands outside. Hard links never get here —
        // `allowed_entry_type` refuses them.
        if entry.header().entry_type() == EntryType::Symlink {
            let link = entry
                .link_name()
                .map_err(|e| LuggageError::ArchiveExtractionFailed {
                    artifact: artifact_name.to_owned(),
                    message: format!(
                        "entry `{}` has an unreadable link target: {e}",
                        raw.display()
                    ),
                })?
                .ok_or_else(|| LuggageError::ArchiveExtractionFailed {
                    artifact: artifact_name.to_owned(),
                    message: format!("entry `{}` is a link with no target", raw.display()),
                })?;
            validate_link_target(&relative, &link, &raw, artifact_name)?;
        }

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| LuggageError::Io { path: parent.to_owned(), source: e })?;
        }

        write_entry(&mut entry, &target).map_err(|e| LuggageError::ArchiveExtractionFailed {
            artifact: artifact_name.to_owned(),
            message: format!("could not write entry `{}`: {e}", raw.display()),
        })?;
    }

    Ok(())
}

/// setuid, setgid and sticky — cleared from every extracted entry's mode.
const SPECIAL_MODE_BITS: u32 = 0o7000;

/// Write one validated entry to `target` with setuid/setgid/sticky masked.
///
/// This is the only place an entry is written, so the mask cannot be
/// skipped by a code path that forgets it. tar-rs already drops these bits
/// while `preserve_permissions` is false, its default — but that is its
/// default, not ours, and the build runs as root, so a setuid binary
/// landing in the prefix is a privilege escalation waiting for a caller.
/// The mask does not depend on the preserve flag, so it holds even if a
/// later change turns preservation on: the test
/// `write_entry_masks_special_bits_even_with_preserve_permissions` drives
/// this function with preservation forced on to pin exactly that.
fn write_entry<R: std::io::Read>(
    entry: &mut tar::Entry<'_, R>,
    target: &Path,
) -> std::io::Result<()> {
    entry.set_mask(SPECIAL_MODE_BITS);
    entry.unpack(target).map(|_| ())
}

/// Decide what to do with an entry of type `kind`: `Ok(true)` to write it,
/// `Ok(false)` to skip it, or an [`LuggageError::UnsafeArchiveEntry`] when
/// the type is outside the allowlist.
///
/// The allowlist is regular files, directories, and symlinks (whose targets
/// are validated separately). Hard links are refused: see the module doc for
/// why their source cannot be validated against what tar-rs then opens. A
/// pax *global* header (`g`, emitted by `git archive`) carries only metadata
/// and writes nothing, so it is skipped rather than rejected. Everything
/// else — `Link`, `Char`, `Block`, `Fifo`, `Continuous`, `GNUSparse`, an
/// extension header tar-rs did not consume, or an unknown typeflag — is
/// refused.
fn allowed_entry_type(kind: EntryType, raw: &Path, artifact_name: &str) -> Result<bool> {
    match kind {
        EntryType::Regular | EntryType::Directory | EntryType::Symlink => Ok(true),
        EntryType::XGlobalHeader => Ok(false),
        other => Err(LuggageError::UnsafeArchiveEntry {
            artifact: artifact_name.to_owned(),
            entry: raw.display().to_string(),
            reason: format!(
                "entry type {other:?} is not allowed (only regular files, directories and symlinks)"
            ),
        }),
    }
}

/// How many moved paths the merge-failure `warn` log lists before
/// summarising the rest. node ships thousands of files; the error itself
/// carries the exact counts.
const MERGE_FAILURE_LOG_LIMIT: usize = 50;

/// A merge step that failed: the path being acted on and why.
type MergeFailure = (PathBuf, std::io::Error);

/// Merge staging into `prefix`, reporting progress if the merge fails partway.
///
/// The merge cannot be rolled back — the prefix is shared, and undoing it
/// risks deleting files another tool owns — so a failure instead says how
/// many of the archive's files and links already landed, and logs which ones
/// at `warn` level so the build log carries the recovery information.
fn merge_into_prefix(staging: &Path, prefix: &Path, artifact: &str) -> Result<()> {
    let mut moved = Vec::new();
    let Err((path, source)) = merge_dir(staging, prefix, &mut moved) else {
        return Ok(());
    };

    // The total is only walked on failure. `merge_dir` moves leaves out of
    // staging as they land, so what is still in staging plus what moved is
    // the archive's full contribution.
    let total = moved.len() + count_leaves(staging);
    tracing::warn!(
        prefix = %prefix.display(),
        merged = moved.len(),
        total,
        failed_at = %path.display(),
        "binary-tarball merge failed partway; these entries already landed in the prefix: {}",
        landed_summary(&moved, MERGE_FAILURE_LOG_LIMIT),
    );

    Err(LuggageError::ArchiveMergeFailed {
        artifact: artifact.to_owned(),
        prefix: prefix.to_owned(),
        merged: moved.len(),
        total,
        path,
        source,
    })
}

/// Render the landed paths for the merge-failure log: the first `limit`
/// paths, then an `...and N more` tail for the rest.
fn landed_summary(moved: &[PathBuf], limit: usize) -> String {
    let shown: Vec<_> = moved.iter().take(limit).map(|p| p.display().to_string()).collect();
    let more = moved.len() - shown.len();
    let tail = if more > 0 { format!(" ...and {more} more") } else { String::new() };
    format!("[{}]{tail}", shown.join(", "))
}

/// Count the files and links under `dir` (directories themselves excluded).
///
/// Best-effort: it only feeds an error message, so an unreadable subtree
/// counts as empty rather than masking the merge failure being reported.
/// `DirEntry::file_type` does not follow links, so a link to a directory
/// counts as one leaf rather than being descended into.
fn count_leaves(dir: &Path) -> usize {
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    entries
        .flatten()
        .map(|entry| match entry.file_type() {
            Ok(t) if t.is_dir() => count_leaves(&entry.path()),
            _ => 1,
        })
        .sum()
}

/// Recursively move `src`'s contents into `dst`, merging with whatever is
/// already there, and push each file or link that lands onto `moved`.
///
/// A plain rename would be cheaper but cannot work: node strips into an
/// already-populated `/usr/local`, so existing directories must be descended
/// into rather than replaced. Files (and links) at the same path are
/// overwritten — the tool being installed owns them.
///
/// Entries are visited in file-name order so a partial merge's progress
/// report is deterministic; the order has no effect on a successful merge's
/// result.
fn merge_dir(
    src: &Path,
    dst: &Path,
    moved: &mut Vec<PathBuf>,
) -> std::result::Result<(), MergeFailure> {
    let mut entries = fs::read_dir(src)
        .and_then(Iterator::collect::<std::io::Result<Vec<_>>>)
        .map_err(|e| (src.to_owned(), e))?;
    entries.sort_by_key(fs::DirEntry::file_name);

    for entry in entries {
        let from = entry.path();
        let to = dst.join(entry.file_name());

        let file_type = entry.file_type().map_err(|e| (from.clone(), e))?;

        if file_type.is_dir() {
            // Replace a pre-existing *symlink* sitting where this directory
            // goes, rather than descending through it. `create_dir_all`
            // follows symlinks when testing existence, so without this a link
            // planted at that path — by an earlier tool install, or by this
            // archive's own earlier entries — would silently redirect the
            // whole subtree's writes to wherever it points. The leaf branch
            // below needs no explicit guard: `rename` replaces a symlink at
            // `to` rather than following it.
            if fs::symlink_metadata(&to).is_ok_and(|m| m.file_type().is_symlink()) {
                fs::remove_file(&to).map_err(|e| (to.clone(), e))?;
            }
            fs::create_dir_all(&to).map_err(|e| (to.clone(), e))?;
            merge_dir(&from, &to, moved)?;
            continue;
        }

        // No `remove_file` first: `rename` atomically replaces an existing
        // file or symlink at `to` (a symlink is replaced, never followed, so
        // its target is not clobbered). Removing first would mean a failed
        // rename leaves the prefix *missing* the file it used to have —
        // unrecorded in `moved` and invisible in the merge report.
        fs::rename(&from, &to).map_err(|e| (to.clone(), e))?;
        moved.push(to);
    }
    Ok(())
}

#[cfg(all(test, unix))]
#[path = "tarball_tests.rs"]
mod tests;
