//! Unit tests for the `binary-tarball` method.
//!
//! Split out of `tarball.rs` to keep that file under the repo's 900-line
//! ceiling (`tests/unit/file-size-ceiling.sh`) — the fixtures and the
//! adversarial cases together outweigh the production code roughly two to one.
//! Same idiom as `containers-common/src/template/tests.rs`.
//!
//! Fixtures are built in-test rather than checked in as binary blobs, so the
//! malicious archives are readable as code: a reviewer can see exactly which
//! `../../etc/passwd` entry or expansion ratio each case asserts is refused.

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
        self.run_capped(
            strip,
            user,
            binaries,
            bin_source_dir,
            cache_dirs,
            super::super::archive_limit::DEFAULT_MAX_EXTRACT_BYTES,
        )
    }

    fn run_capped(
        &self,
        strip: u32,
        user: &str,
        binaries: &[String],
        bin_source_dir: Option<&str>,
        cache_dirs: &BTreeMap<String, String>,
        max_extract_bytes: u64,
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
            max_extract_bytes,
            runner: &self.runner,
        })
    }

    /// The common case: no binaries, no cache dirs, unprivileged user.
    fn run_plain(&self, strip: u32) -> Result<()> {
        self.run(strip, "vscode", &[], None, &BTreeMap::new())
    }

    /// Run with a deliberately small ceiling, for the bomb tests. Keeps
    /// the suite fast — no multi-GB fixtures in CI.
    fn run_with_cap(&self, cap: u64) -> Result<()> {
        self.run_capped(0, "vscode", &[], None, &BTreeMap::new(), cap)
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

/// A relative `prefix` is a catalog defect, not a silent extraction into
/// whatever directory the build happens to run from.
#[test]
fn relative_prefix_is_a_catalog_error() {
    let err = resolve_prefix(Some("usr/local")).unwrap_err();
    match err {
        LuggageError::Catalog(msg) => {
            assert!(msg.contains("absolute"), "should explain the requirement: {msg}");
            assert!(msg.contains("usr/local"), "should quote the bad value: {msg}");
        }
        other => panic!("expected Catalog, got {other:?}"),
    }
    assert_eq!(resolve_prefix(None).unwrap(), PathBuf::from(DEFAULT_PREFIX));
    assert_eq!(resolve_prefix(Some("/opt/tool")).unwrap(), PathBuf::from("/opt/tool"));
}

/// A symlink already sitting where an extracted directory belongs must be
/// replaced, not descended through — otherwise the subtree's writes are
/// redirected to wherever it points.
#[test]
fn merge_replaces_a_symlink_standing_in_for_a_directory() {
    let raw = tar_bytes(&[("bin/node", b"nodebin")]);
    let f = Fixture::new("node.tar.gz", &gzip(&raw));

    // Somewhere the archive must not reach.
    let elsewhere = tempdir().unwrap();
    std::os::unix::fs::symlink(elsewhere.path(), f.prefix.path().join("bin")).unwrap();

    f.run_plain(0).unwrap();

    let bin = f.prefix.path().join("bin");
    assert!(
        !fs::symlink_metadata(&bin).unwrap().file_type().is_symlink(),
        "the stand-in symlink should have been replaced by a real directory"
    );
    assert_eq!(fs::read(bin.join("node")).unwrap(), b"nodebin");
    assert_eq!(
        fs::read_dir(elsewhere.path()).unwrap().count(),
        0,
        "nothing may be written through the symlink's target"
    );
}

/// The leaf counterpart: a symlink where a *file* lands is replaced too,
/// rather than followed and its target clobbered.
#[test]
fn merge_replaces_a_symlink_standing_in_for_a_file() {
    let raw = tar_bytes(&[("README.md", b"fresh")]);
    let f = Fixture::new("tool.tar.gz", &gzip(&raw));

    let elsewhere = tempdir().unwrap();
    let victim = elsewhere.path().join("victim");
    fs::write(&victim, b"untouched").unwrap();
    std::os::unix::fs::symlink(&victim, f.prefix.path().join("README.md")).unwrap();

    f.run_plain(0).unwrap();

    assert_eq!(fs::read(f.prefix.path().join("README.md")).unwrap(), b"fresh");
    assert_eq!(
        fs::read(&victim).unwrap(),
        b"untouched",
        "the symlink's target must not be written through"
    );
}

// ---- decompression-bomb ceiling --------------------------------------

/// Build a tar whose single entry carries `size` bytes of zeros — highly
/// compressible, so a few KB of archive expands far past a small cap.
fn bomb_tar(size: usize) -> Vec<u8> {
    tar_bytes(&[("payload.bin", &vec![0u8; size])])
}

/// gzip path: the ceiling must fire, and must report a *bomb* rather than
/// the truncation error a bare `Read::take` would produce.
#[test]
fn gzip_over_the_ceiling_is_rejected() {
    let f = Fixture::new("bomb.tar.gz", &gzip(&bomb_tar(256 * 1024)));

    match f.run_with_cap(8 * 1024).unwrap_err() {
        LuggageError::ArchiveTooLarge { artifact, limit } => {
            assert_eq!(artifact, "bomb.tar.gz");
            assert_eq!(limit, 8 * 1024);
        }
        other => panic!("expected ArchiveTooLarge, got {other:?}"),
    }
    assert_eq!(
        fs::read_dir(f.prefix.path()).unwrap().count(),
        0,
        "a refused bomb must leave the prefix empty"
    );
}

/// xz path: same, and the one that matters most — this path materialises
/// the whole decompressed stream before reading any entry, so the cap has
/// to fire mid-decompression rather than after the temp file is written.
#[test]
fn xz_over_the_ceiling_is_rejected() {
    let f = Fixture::new("bomb.tar.xz", &xz(&bomb_tar(256 * 1024)));

    match f.run_with_cap(8 * 1024).unwrap_err() {
        LuggageError::ArchiveTooLarge { artifact, limit } => {
            assert_eq!(artifact, "bomb.tar.xz");
            assert_eq!(limit, 8 * 1024);
        }
        other => panic!("expected ArchiveTooLarge, got {other:?}"),
    }
    assert_eq!(fs::read_dir(f.prefix.path()).unwrap().count(), 0);
}

/// An entry that lies about its size is refused one way or another — it
/// never extracts.
///
/// Which error comes back depends on what follows the declared length,
/// and both outcomes are correct: tar reads `size` bytes and then expects
/// the next header, so a payload overrun is detected as a malformed
/// archive (as here), while a *truthful* header large enough to blow the
/// budget trips the ceiling instead (`gzip_over_the_ceiling_is_rejected`).
/// The point this pins down is that the header's claim is never taken as
/// permission to write more than the budget allows.
///
/// The payload is deliberately **non-zero**: two zero-filled blocks are
/// tar's end-of-archive marker, so an all-zero overrun would make the
/// reader stop cleanly after the declared byte and this test would pass
/// without exercising anything.
#[test]
fn lying_size_header_does_not_extract() {
    let payload = vec![0xABu8; 256 * 1024];
    let mut builder = Builder::new(Vec::new());
    let mut header = Header::new_gnu();
    // Claim one byte while delivering 256 KiB. `Builder::append` copies
    // the whole stream regardless of the header, so the archive really
    // does carry the overrun.
    header.set_size(1);
    header.set_mode(0o644);
    set_raw_name(&mut header, "liar.bin");
    header.set_cksum();
    builder.append(&header, &payload[..]).unwrap();
    let raw = builder.into_inner().unwrap();

    let f = Fixture::new("liar.tar.gz", &gzip(&raw));

    let got = f.run_with_cap(8 * 1024);
    assert!(
        matches!(
            got,
            Err(LuggageError::ArchiveTooLarge { .. } | LuggageError::ArchiveExtractionFailed { .. })
        ),
        "a size-lying entry must be refused, not extracted; got {got:?}"
    );
    assert_eq!(fs::read_dir(f.prefix.path()).unwrap().count(), 0, "nothing may reach the prefix");
}

/// The budget is shared across the whole archive: many entries each under
/// the cap must still trip it in aggregate, or a bomb just splits itself
/// into pieces.
#[test]
fn many_small_entries_exhaust_the_shared_budget() {
    let chunk = vec![0u8; 4096];
    let entries: Vec<_> = (0..64).map(|i| (format!("part{i}.bin"), chunk.clone())).collect();
    let refs: Vec<(&str, &[u8])> =
        entries.iter().map(|(n, c)| (n.as_str(), c.as_slice())).collect();
    let f = Fixture::new("many.tar.gz", &gzip(&tar_bytes(&refs)));

    assert!(
        matches!(f.run_with_cap(32 * 1024), Err(LuggageError::ArchiveTooLarge { .. })),
        "64 x 4 KiB must exceed a 32 KiB budget even though each entry is under it"
    );
}

/// A legitimate archive comfortably under the cap still extracts — guards
/// against a "fix" that simply rejects everything.
#[test]
fn archive_under_the_ceiling_still_extracts() {
    let raw = tar_bytes(&[("go/bin/go", b"gobin")]);
    let f = Fixture::new("go.tar.gz", &gzip(&raw));

    f.run_with_cap(1024 * 1024).unwrap();

    assert_eq!(fs::read(f.prefix.path().join("go/bin/go")).unwrap(), b"gobin");
}

/// A genuinely truncated archive must still report truncation, not the
/// bomb error — both stop the read early, and conflating them would point
/// whoever debugs it at the wrong problem.
#[test]
fn truncated_archive_is_not_reported_as_too_large() {
    let mut bytes = gzip(&tar_bytes(&[("a.txt", b"aaaa")]));
    bytes.truncate(bytes.len() / 2);
    let f = Fixture::new("cut.tar.gz", &bytes);

    // Cap far above anything this archive could produce, so a
    // ArchiveTooLarge here could only be a misdiagnosis.
    match f.run_with_cap(64 * 1024 * 1024) {
        Err(LuggageError::ArchiveExtractionFailed { .. }) => {}
        Err(LuggageError::ArchiveTooLarge { .. }) => {
            panic!("a truncated archive must not be reported as a bomb")
        }
        other => panic!("expected ArchiveExtractionFailed, got {other:?}"),
    }
}

#[test]
fn detect_compression_is_case_insensitive() {
    assert_eq!(detect_compression("GO.TAR.GZ").unwrap(), Compression::Gzip);
    assert_eq!(detect_compression("Node.Tar.Xz").unwrap(), Compression::Xz);
    assert!(detect_compression("payload.tar").is_err());
    assert!(detect_compression("payload").is_err());
}
