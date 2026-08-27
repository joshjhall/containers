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
//! # Partial-install behaviour
//!
//! The archive unpacks into a staging directory first and is merged into the
//! prefix only once every entry has been validated and written. So a bad
//! compression, a traversal entry, or a truncated archive leaves the prefix
//! **untouched**. A failure during the merge itself can still leave a
//! partially-populated prefix; making that atomic would need filesystem
//! transactions we don't have. The merge cannot rename-into-place because
//! node strips into an already-populated `/usr/local` — the prefix is shared
//! with other tools rather than owned by this one.

use std::fs::{self, File};
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};

use flate2::read::GzDecoder;
use tar::{Archive, EntryType};

use super::MethodContext;
use super::archive_path::{safe_relative_path, strip_prefix_components, validate_link_target};
use super::layout::{install_binaries, prepare_cache_dirs};
use crate::error::{LuggageError, Result};

/// Compression wrapping the tar stream, inferred from the artifact filename.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Compression {
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
///   would escape the extraction prefix.
/// - [`LuggageError::ArchiveExtractionFailed`] when the archive is corrupt or
///   truncated, or an entry cannot be written.
/// - [`LuggageError::Io`] when the staging area, prefix, or bin directories
///   cannot be created or merged.
/// - [`LuggageError::InstallStageFailed`] when a cache-dir `chown` fails.
/// - [`LuggageError::Catalog`] when the method lists `binaries` but no
///   `bin_source_dir` to link them from.
pub fn run(ctx: &MethodContext<'_>) -> Result<()> {
    // 1. Cache dirs first — same contract as script-installer (#462 / #492).
    prepare_cache_dirs(ctx)?;

    let artifact_name = artifact_name(ctx.artifact);
    let compression = detect_compression(&artifact_name)?;
    let prefix = ctx.prefix.map_or_else(|| PathBuf::from(DEFAULT_PREFIX), PathBuf::from);

    // 2. Unpack into a staging dir beside the artifact, so a rejected or
    //    corrupt archive never touches the prefix. `TempDir` cleans itself up
    //    on both the success and error paths.
    let staging = tempfile::Builder::new()
        .prefix("luggage-extract-")
        .tempdir_in(ctx.artifact.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| LuggageError::Io { path: ctx.artifact.to_owned(), source: e })?;

    extract(ctx.artifact, &artifact_name, compression, staging.path(), ctx.strip_components)?;

    // 3. Merge staging into the prefix.
    fs::create_dir_all(&prefix)
        .map_err(|e| LuggageError::Io { path: prefix.clone(), source: e })?;
    merge_dir(staging.path(), &prefix)?;

    // 4. Symlink the catalog's binaries. Unlike script-installer, a tarball's
    //    binaries land under the extraction prefix (go: `go/bin`), not the
    //    cache root, so the prefix is what `bin_source_dir` resolves against.
    install_binaries(ctx, &prefix)
}

/// The artifact's filename, for error messages and format detection.
fn artifact_name(artifact: &Path) -> String {
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
fn detect_compression(name: &str) -> Result<Compression> {
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
fn extract(
    artifact: &Path,
    artifact_name: &str,
    compression: Compression,
    dest: &Path,
    strip: u32,
) -> Result<()> {
    let file = File::open(artifact)
        .map_err(|e| LuggageError::Io { path: artifact.to_owned(), source: e })?;
    let reader = BufReader::new(file);

    match compression {
        Compression::Gzip => {
            // gzip streams straight into the tar reader — no intermediate.
            unpack(Archive::new(GzDecoder::new(reader)), artifact_name, dest, strip)
        }
        Compression::Xz => {
            // `lzma_rs::xz_decompress` writes into a sink rather than
            // exposing a `Read`, so xz lands as a plain `.tar` beside the
            // archive first. The temp file is dropped as soon as the unpack
            // finishes.
            let plain = tempfile::Builder::new()
                .prefix("luggage-xz-")
                .suffix(".tar")
                .tempfile_in(dest.parent().unwrap_or_else(|| Path::new(".")))
                .map_err(|e| LuggageError::Io { path: artifact.to_owned(), source: e })?;
            {
                let mut reader = reader;
                let mut writer = BufWriter::new(plain.as_file());
                lzma_rs::xz_decompress(&mut reader, &mut writer).map_err(|e| {
                    LuggageError::ArchiveExtractionFailed {
                        artifact: artifact_name.to_owned(),
                        message: format!("xz decompression failed: {e}"),
                    }
                })?;
            }
            let tar_file = plain
                .reopen()
                .map_err(|e| LuggageError::Io { path: plain.path().to_owned(), source: e })?;
            unpack(Archive::new(BufReader::new(tar_file)), artifact_name, dest, strip)
        }
    }
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
        // entry written through it lands outside. Reject both link kinds.
        if matches!(entry.header().entry_type(), EntryType::Symlink | EntryType::Link) {
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

        entry.unpack(&target).map_err(|e| LuggageError::ArchiveExtractionFailed {
            artifact: artifact_name.to_owned(),
            message: format!("could not write entry `{}`: {e}", raw.display()),
        })?;
    }

    Ok(())
}

/// Recursively move `src`'s contents into `dst`, merging with whatever is
/// already there.
///
/// A plain rename would be cheaper but cannot work: node strips into an
/// already-populated `/usr/local`, so existing directories must be descended
/// into rather than replaced. Files (and links) at the same path are
/// overwritten — the tool being installed owns them.
fn merge_dir(src: &Path, dst: &Path) -> Result<()> {
    let entries =
        fs::read_dir(src).map_err(|e| LuggageError::Io { path: src.to_owned(), source: e })?;
    for entry in entries {
        let entry = entry.map_err(|e| LuggageError::Io { path: src.to_owned(), source: e })?;
        let from = entry.path();
        let to = dst.join(entry.file_name());

        let file_type =
            entry.file_type().map_err(|e| LuggageError::Io { path: from.clone(), source: e })?;

        if file_type.is_dir() {
            fs::create_dir_all(&to)
                .map_err(|e| LuggageError::Io { path: to.clone(), source: e })?;
            merge_dir(&from, &to)?;
            continue;
        }

        // `symlink_metadata` so an existing *symlink* is removed rather than
        // followed — otherwise the rename would clobber the link's target.
        if fs::symlink_metadata(&to).is_ok() {
            fs::remove_file(&to).map_err(|e| LuggageError::Io { path: to.clone(), source: e })?;
        }
        fs::rename(&from, &to).map_err(|e| LuggageError::Io { path: to.clone(), source: e })?;
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    use std::collections::BTreeMap;
    use std::io::Write as _;

    use tar::{Builder, Header};
    use tempfile::tempdir;

    use crate::installer::methods::RecordingRunner;

    /// Write `path` straight into a header's raw name field.
    ///
    /// `Header::set_path` / `Builder::append_data` refuse paths containing
    /// `..` or a leading `/` — the tar crate will not *produce* a malicious
    /// archive. That is a reasonable default for a writer and a problem for
    /// these tests, which must feed exactly such an archive to the reader.
    /// Writing the 100-byte name field directly is how a hostile archive is
    /// synthesised without a checked-in binary blob.
    fn set_raw_name(header: &mut Header, path: &str) {
        let bytes = path.as_bytes();
        assert!(bytes.len() < 100, "fixture paths must fit the short name field");
        let name = &mut header.as_old_mut().name;
        name.fill(0);
        name[..bytes.len()].copy_from_slice(bytes);
    }

    /// One entry to place in a fixture archive.
    enum Entry<'a> {
        /// A regular file with the given contents.
        File(&'a str, &'a [u8]),
        /// A link of the given kind pointing at the given target.
        Link(&'a str, &'a str, EntryType),
    }

    /// Build an uncompressed tar in memory from a list of entries.
    ///
    /// Fixtures are constructed in-test rather than checked in as binary
    /// blobs so the malicious ones are readable as code — a reviewer can see
    /// exactly what `../../etc/passwd` entry the traversal test asserts is
    /// rejected, which a committed `.tar.gz` would hide.
    fn tar_of(entries: &[Entry<'_>]) -> Vec<u8> {
        let mut builder = Builder::new(Vec::new());
        for entry in entries {
            let mut header = Header::new_gnu();
            match entry {
                Entry::File(path, contents) => {
                    header.set_size(contents.len() as u64);
                    header.set_mode(0o644);
                    set_raw_name(&mut header, path);
                    header.set_cksum();
                    builder.append(&header, *contents).unwrap();
                }
                Entry::Link(path, target, kind) => {
                    header.set_size(0);
                    header.set_mode(0o777);
                    header.set_entry_type(*kind);
                    set_raw_name(&mut header, path);
                    set_raw_linkname(&mut header, target);
                    header.set_cksum();
                    builder.append(&header, std::io::empty()).unwrap();
                }
            }
        }
        builder.into_inner().unwrap()
    }

    /// Shorthand for the common all-files case.
    fn tar_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let entries: Vec<_> = entries.iter().map(|(p, c)| Entry::File(p, c)).collect();
        tar_of(&entries)
    }

    /// Write `target` straight into a header's raw linkname field.
    ///
    /// Same reason as [`set_raw_name`]: `set_link_name` rejects the escaping
    /// targets these fixtures exist to exercise.
    fn set_raw_linkname(header: &mut Header, target: &str) {
        let bytes = target.as_bytes();
        assert!(bytes.len() < 100, "fixture link targets must fit the linkname field");
        let linkname = &mut header.as_old_mut().linkname;
        linkname.fill(0);
        linkname[..bytes.len()].copy_from_slice(bytes);
    }

    /// Build a tar containing a single link entry pointing at `target`.
    fn tar_with_link(link_path: &str, target: &str, kind: EntryType) -> Vec<u8> {
        tar_of(&[Entry::Link(link_path, target, kind)])
    }

    fn gzip(raw: &[u8]) -> Vec<u8> {
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(raw).unwrap();
        encoder.finish().unwrap()
    }

    fn xz(raw: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        lzma_rs::xz_compress(&mut std::io::Cursor::new(raw), &mut out).unwrap();
        out
    }

    /// Owns the tempdirs for a run so they outlive the borrowed context.
    struct Fixture {
        _tmp: tempfile::TempDir,
        cache: tempfile::TempDir,
        bin: tempfile::TempDir,
        prefix: tempfile::TempDir,
        artifact: PathBuf,
        runner: RecordingRunner,
    }

    impl Fixture {
        fn new(name: &str, bytes: &[u8]) -> Self {
            let tmp = tempdir().unwrap();
            let artifact = tmp.path().join(name);
            fs::write(&artifact, bytes).unwrap();
            Self {
                _tmp: tmp,
                cache: tempdir().unwrap(),
                bin: tempdir().unwrap(),
                prefix: tempdir().unwrap(),
                artifact,
                runner: RecordingRunner::new(),
            }
        }

        fn run(
            &self,
            strip: u32,
            user: &str,
            binaries: &[String],
            bin_source_dir: Option<&str>,
            cache_dirs: &BTreeMap<String, String>,
        ) -> Result<()> {
            let args: Vec<String> = vec![];
            let env = BTreeMap::new();
            let prefix = self.prefix.path().display().to_string();
            super::run(&MethodContext {
                artifact: &self.artifact,
                args: &args,
                env: &env,
                user,
                cache_root: self.cache.path(),
                bin_root: self.bin.path(),
                binaries,
                bin_source_dir,
                cache_dirs,
                prefix: Some(&prefix),
                strip_components: strip,
                runner: &self.runner,
            })
        }

        /// The common case: no binaries, no cache dirs, unprivileged user.
        fn run_plain(&self, strip: u32) -> Result<()> {
            self.run(strip, "vscode", &[], None, &BTreeMap::new())
        }
    }

    // ---- happy paths -----------------------------------------------------

    /// go's shape: gzip, strip 0, so the archive's own `go/` top level is
    /// preserved under the prefix.
    #[test]
    fn extracts_gzip_keeping_top_level_at_strip_zero() {
        let raw = tar_bytes(&[("go/bin/go", b"gobin"), ("go/VERSION", b"go1.25.0")]);
        let f = Fixture::new("go1.25.0.linux-amd64.tar.gz", &gzip(&raw));

        f.run_plain(0).unwrap();

        assert_eq!(fs::read(f.prefix.path().join("go/bin/go")).unwrap(), b"gobin");
        assert_eq!(fs::read(f.prefix.path().join("go/VERSION")).unwrap(), b"go1.25.0");
    }

    /// node's shape: xz, strip 1, so the versioned root flattens directly
    /// into the prefix.
    #[test]
    fn extracts_xz_flattening_versioned_root_at_strip_one() {
        let raw = tar_bytes(&[
            ("node-v22.0.0-linux-x64/bin/node", b"nodebin"),
            ("node-v22.0.0-linux-x64/README.md", b"readme"),
        ]);
        let f = Fixture::new("node-v22.0.0-linux-x64.tar.xz", &xz(&raw));

        f.run_plain(1).unwrap();

        assert_eq!(fs::read(f.prefix.path().join("bin/node")).unwrap(), b"nodebin");
        assert_eq!(fs::read(f.prefix.path().join("README.md")).unwrap(), b"readme");
        assert!(
            !f.prefix.path().join("node-v22.0.0-linux-x64").exists(),
            "strip 1 must not leave the versioned root behind"
        );
    }

    /// Both spellings of each compression are accepted.
    #[test]
    fn accepts_short_extension_spellings() {
        for (name, bytes) in [
            ("payload.tgz", gzip(&tar_bytes(&[("a.txt", b"a")]))),
            ("payload.txz", xz(&tar_bytes(&[("a.txt", b"a")]))),
        ] {
            let f = Fixture::new(name, &bytes);
            f.run_plain(0).unwrap_or_else(|e| panic!("{name} should extract, got {e:?}"));
            assert_eq!(fs::read(f.prefix.path().join("a.txt")).unwrap(), b"a", "{name}");
        }
    }

    /// The prefix is shared with other tools (node strips straight into
    /// `/usr/local`), so extraction must merge into existing directories
    /// rather than replace them.
    #[test]
    fn merges_into_a_populated_prefix() {
        let raw = tar_bytes(&[("bin/node", b"nodebin")]);
        let f = Fixture::new("node.tar.gz", &gzip(&raw));

        // A pre-existing sibling that must survive the merge.
        fs::create_dir_all(f.prefix.path().join("bin")).unwrap();
        fs::write(f.prefix.path().join("bin/pre-existing"), b"keep").unwrap();

        f.run_plain(0).unwrap();

        assert_eq!(fs::read(f.prefix.path().join("bin/node")).unwrap(), b"nodebin");
        assert_eq!(
            fs::read(f.prefix.path().join("bin/pre-existing")).unwrap(),
            b"keep",
            "merging must not clobber unrelated files already in the prefix"
        );
    }

    // ---- traversal rejection (the #808 security requirement) -------------

    /// A `..` component must be rejected outright — not sanitized, not
    /// skipped. This is the archive shape that would otherwise let a build
    /// running as root write outside the prefix.
    #[test]
    fn rejects_parent_dir_traversal_entry() {
        let raw = tar_bytes(&[("go/bin/go", b"ok"), ("../../etc/passwd", b"pwned")]);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        let err = f.run_plain(0).unwrap_err();
        match err {
            LuggageError::UnsafeArchiveEntry { entry, reason, .. } => {
                assert!(entry.contains(".."), "error should name the entry: {entry}");
                assert!(reason.contains(".."), "reason should explain: {reason}");
            }
            other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
        }
    }

    /// An absolute entry path ignores `-C` entirely under a naive extractor.
    #[test]
    fn rejects_absolute_entry_path() {
        let raw = tar_bytes(&[("/etc/cron.d/pwn", b"pwned")]);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        let err = f.run_plain(0).unwrap_err();
        match err {
            LuggageError::UnsafeArchiveEntry { reason, .. } => {
                assert!(reason.contains("absolute"), "reason should explain: {reason}");
            }
            other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
        }
    }

    /// The subtle case: the link entry itself sits safely inside the prefix,
    /// but its *target* points out. A later entry written through the link
    /// would land outside, so the link is rejected when it is unpacked.
    #[test]
    fn rejects_symlink_escaping_the_prefix() {
        let raw = tar_with_link("pkg/escape", "../../../etc", EntryType::Symlink);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        let err = f.run_plain(0).unwrap_err();
        match err {
            LuggageError::UnsafeArchiveEntry { reason, .. } => {
                assert!(reason.contains("escapes"), "reason should explain: {reason}");
            }
            other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
        }
    }

    /// An absolute link target is refused without walking components.
    #[test]
    fn rejects_absolute_symlink_target() {
        let raw = tar_with_link("pkg/escape", "/etc/shadow", EntryType::Symlink);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        let err = f.run_plain(0).unwrap_err();
        match err {
            LuggageError::UnsafeArchiveEntry { reason, .. } => {
                assert!(reason.contains("absolute"), "reason should explain: {reason}");
            }
            other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
        }
    }

    /// Hardlinks carry a target just as symlinks do, and are checked the
    /// same way.
    #[test]
    fn rejects_hardlink_escaping_the_prefix() {
        let raw = tar_with_link("pkg/escape", "../../../etc/passwd", EntryType::Link);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        assert!(
            matches!(f.run_plain(0), Err(LuggageError::UnsafeArchiveEntry { .. })),
            "an escaping hardlink must be rejected like a symlink"
        );
    }

    /// A link that stays inside the prefix is legitimate and must extract —
    /// the validation rejects escapes, not links as a category.
    #[test]
    fn allows_symlink_that_stays_inside_the_prefix() {
        let raw = tar_of(&[
            Entry::File("pkg/real.txt", b"real"),
            Entry::Link("pkg/alias.txt", "real.txt", EntryType::Symlink),
        ]);

        let f = Fixture::new("ok.tar.gz", &gzip(&raw));
        f.run_plain(0).unwrap();

        let alias = f.prefix.path().join("pkg/alias.txt");
        assert!(fs::symlink_metadata(&alias).unwrap().file_type().is_symlink());
        assert_eq!(fs::read(&alias).unwrap(), b"real");
    }

    /// Rejection must happen before anything reaches the prefix — a refused
    /// archive leaves no half-installed state behind.
    #[test]
    fn rejected_archive_leaves_the_prefix_untouched() {
        // The benign entry precedes the malicious one, so a naive extractor
        // would already have written it by the time it hit the traversal.
        let raw = tar_bytes(&[("go/bin/go", b"ok"), ("../escape", b"pwned")]);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        assert!(f.run_plain(0).is_err());
        assert!(
            !f.prefix.path().join("go").exists(),
            "no entry may reach the prefix when the archive is rejected"
        );
        assert_eq!(
            fs::read_dir(f.prefix.path()).unwrap().count(),
            0,
            "prefix must be empty after a rejected archive"
        );
    }

    // ---- format + corruption errors --------------------------------------

    /// An unrecognised extension is a typed error, never a silent skip that
    /// would surface much later as a missing binary.
    #[test]
    fn unrecognised_extension_is_a_typed_error() {
        let f = Fixture::new("payload.zip", b"PK\x03\x04");

        let err = f.run_plain(0).unwrap_err();
        match err {
            LuggageError::UnsupportedArchiveFormat { artifact, message } => {
                assert_eq!(artifact, "payload.zip");
                assert!(message.contains(".tar.gz"), "should list what it expected: {message}");
            }
            other => panic!("expected UnsupportedArchiveFormat, got {other:?}"),
        }
        assert_eq!(fs::read_dir(f.prefix.path()).unwrap().count(), 0);
    }

    /// A `.tar.gz` whose bytes are not gzip fails as an extraction error.
    #[test]
    fn corrupt_archive_is_an_extraction_error() {
        let f = Fixture::new("broken.tar.gz", b"not actually gzip at all");

        assert!(
            matches!(f.run_plain(0), Err(LuggageError::ArchiveExtractionFailed { .. })),
            "a corrupt archive should surface as ArchiveExtractionFailed"
        );
        assert_eq!(fs::read_dir(f.prefix.path()).unwrap().count(), 0);
    }

    /// Truncated xz likewise, and specifically from the decompression step.
    #[test]
    fn corrupt_xz_is_an_extraction_error() {
        let mut bytes = xz(&tar_bytes(&[("a.txt", b"a")]));
        bytes.truncate(bytes.len() / 2);
        let f = Fixture::new("broken.tar.xz", &bytes);

        match f.run_plain(0).unwrap_err() {
            LuggageError::ArchiveExtractionFailed { message, .. } => {
                assert!(message.contains("xz"), "should name the failing step: {message}");
            }
            other => panic!("expected ArchiveExtractionFailed, got {other:?}"),
        }
    }

    // ---- #806 parity -----------------------------------------------------

    /// Binaries are symlinked out of the *prefix* (go: `go/bin`), not the
    /// cache root — the one place this method's layout differs from
    /// script-installer's.
    #[test]
    fn symlinks_binaries_from_the_extraction_prefix() {
        let raw = tar_bytes(&[("go/bin/go", b"gobin"), ("go/bin/gofmt", b"gofmtbin")]);
        let f = Fixture::new("go.tar.gz", &gzip(&raw));
        let binaries = vec!["go".to_owned(), "gofmt".to_owned()];

        f.run(0, "vscode", &binaries, Some("go/bin"), &BTreeMap::new()).unwrap();

        for name in &binaries {
            let link = f.bin.path().join(name);
            assert!(
                fs::symlink_metadata(&link).unwrap().file_type().is_symlink(),
                "{name} should be a symlink in bin_root"
            );
            assert_eq!(fs::read_link(&link).unwrap(), f.prefix.path().join("go/bin").join(name));
        }
    }

    /// Cache dirs are created and chowned to the install user, exactly as
    /// script-installer does (#806 parity).
    #[test]
    fn creates_and_chowns_cache_dirs() {
        let raw = tar_bytes(&[("go/bin/go", b"gobin")]);
        let f = Fixture::new("go.tar.gz", &gzip(&raw));
        let cache_dirs = BTreeMap::from([
            ("GOPATH".to_owned(), "go".to_owned()),
            ("GOMODCACHE".to_owned(), "go-mod".to_owned()),
        ]);

        f.run(0, "vscode", &[], None, &cache_dirs).unwrap();

        assert!(f.cache.path().join("go").is_dir());
        assert!(f.cache.path().join("go-mod").is_dir());
        let chowns: Vec<_> = f.runner.calls().into_iter().filter(|(p, _)| p == "chown").collect();
        assert_eq!(chowns.len(), 2, "expected one chown per cache dir, got {chowns:?}");
    }

    /// #492 parity: a root install user gets no chown — root already owns
    /// the freshly-created dirs, and on base images without the resolved
    /// user an unconditional chown would fail outright.
    #[test]
    fn skips_chown_for_a_root_install_user() {
        let raw = tar_bytes(&[("go/bin/go", b"gobin")]);
        let f = Fixture::new("go.tar.gz", &gzip(&raw));
        let cache_dirs = BTreeMap::from([("GOPATH".to_owned(), "go".to_owned())]);

        f.run(0, "root", &[], None, &cache_dirs).unwrap();

        assert!(f.cache.path().join("go").is_dir(), "the dir must still be created");
        assert!(
            !f.runner.calls().iter().any(|(p, _)| p == "chown"),
            "a root install user must not trigger a chown"
        );
    }

    /// Listing binaries without a `bin_source_dir` is a catalog defect, and
    /// must be reported rather than guessed at.
    #[test]
    fn binaries_without_source_dir_is_a_catalog_error() {
        let raw = tar_bytes(&[("go/bin/go", b"gobin")]);
        let f = Fixture::new("go.tar.gz", &gzip(&raw));

        let err = f.run(0, "vscode", &["go".to_owned()], None, &BTreeMap::new()).unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)), "expected a catalog error, got {err:?}");
    }

    // Unit coverage of the path-safety helpers lives beside them, in
    // `archive_path`. The fixture tests above exercise the same rules
    // end-to-end through a real archive.

    #[test]
    fn detect_compression_is_case_insensitive() {
        assert_eq!(detect_compression("GO.TAR.GZ").unwrap(), Compression::Gzip);
        assert_eq!(detect_compression("Node.Tar.Xz").unwrap(), Compression::Xz);
        assert!(detect_compression("payload.tar").is_err());
        assert!(detect_compression("payload").is_err());
    }
}
