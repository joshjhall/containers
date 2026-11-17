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
    /// A regular file whose header declares the given mode.
    FileMode(&'a str, &'a [u8], u32),
    /// A directory entry with the given mode.
    Dir(&'a str, u32),
    /// A header-only entry of an arbitrary type — device nodes, fifos.
    /// `Builder` has no safe API for these, so the typeflag is set directly.
    Special(&'a str, EntryType),
    /// An entry of an arbitrary type carrying `contents` (pax global header).
    Typed(&'a str, EntryType, &'a [u8]),
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
            Entry::FileMode(path, contents, mode) => {
                header.set_size(contents.len() as u64);
                header.set_mode(*mode);
                set_raw_name(&mut header, path);
                header.set_cksum();
                builder.append(&header, *contents).unwrap();
            }
            Entry::Dir(path, mode) => {
                header.set_size(0);
                header.set_mode(*mode);
                header.set_entry_type(EntryType::Directory);
                set_raw_name(&mut header, path);
                header.set_cksum();
                builder.append(&header, std::io::empty()).unwrap();
            }
            Entry::Special(path, kind) => {
                header.set_size(0);
                header.set_mode(0o644);
                header.set_entry_type(*kind);
                set_raw_name(&mut header, path);
                header.set_cksum();
                builder.append(&header, std::io::empty()).unwrap();
            }
            Entry::Typed(path, kind, contents) => {
                header.set_size(contents.len() as u64);
                header.set_mode(0o644);
                header.set_entry_type(*kind);
                set_raw_name(&mut header, path);
                header.set_cksum();
                builder.append(&header, *contents).unwrap();
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
            build_steps: &[],
            compiler_launcher: None,
            log: None,
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

/// A hard link with an escaping target is refused — but by its *type*,
/// before `validate_link_target` ever runs: every hard link is refused
/// (issue #862), so this pins the allowlist, not hard-link target
/// validation. Re-allowing `Link` fails this test whatever the target.
#[test]
fn rejects_hardlink_by_type_even_with_an_escaping_target() {
    let raw = tar_with_link("pkg/escape", "../../../etc/passwd", EntryType::Link);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/escape", "Link");
}

/// Even a hard link whose target *looks* inside the prefix is refused.
/// tar-rs resolves a lone entry's hard-link source against the process
/// cwd, not the extraction root, so `Cargo.toml` here would link the
/// crate's own manifest — a file outside the prefix — into it (issue #862).
#[test]
fn rejects_hardlink_even_with_an_in_prefix_looking_target() {
    let raw = tar_of(&[
        Entry::File("pkg/real.txt", b"real"),
        Entry::Link("pkg/stolen", "Cargo.toml", EntryType::Link),
    ]);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/stolen", "Link");
    assert_prefix_empty(&f);
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

// ---- chained symlinks (issue #1698) ------------------------------------

/// Assert nothing was written beside the staging dir. Staging is created
/// in the artifact's own directory (`Fixture::_tmp`), so an entry that
/// escaped staging by one level lands there; after `run` returns, the
/// staging dir is gone and only the artifact may remain.
fn assert_nothing_escaped(f: &Fixture) {
    let stray: Vec<_> = fs::read_dir(f.artifact.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| *p != f.artifact)
        .collect();
    assert!(stray.is_empty(), "nothing may land beside staging, found {stray:?}");
}

/// Run a chained-symlink archive and assert it is refused at `entry_name`
/// for writing through the earlier link `link` (named by its post-strip
/// path), with nothing reaching the prefix or staging's parent.
fn assert_chain_rejected(entries: &[Entry<'_>], entry_name: &str, link: &str) {
    assert_chain_rejected_at_strip(entries, entry_name, link, 0);
}

/// [`assert_chain_rejected`] at a given strip depth.
fn assert_chain_rejected_at_strip(entries: &[Entry<'_>], entry_name: &str, link: &str, strip: u32) {
    let f = Fixture::new("evil.tar.gz", &gzip(&tar_of(entries)));

    match f.run_plain(strip).unwrap_err() {
        LuggageError::UnsafeArchiveEntry { entry, reason, .. } => {
            assert_eq!(entry, entry_name, "error should name the entry");
            assert!(
                reason.contains(&format!("passes through symlink `{link}` ")),
                "reason should name the earlier link `{link}`: {reason}"
            );
        }
        other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
    }
    assert_prefix_empty(&f);
    assert_nothing_escaped(&f);
}

/// `a -> .` and `a/b -> ..` each stay inside lexically, but `a/b` is
/// written through `a` into staging itself, pointing at staging's parent —
/// so `a/b/evil` would land outside. Refused at `a/b`, the first entry
/// written through a link, so the payload is never reached.
#[test]
fn rejects_symlink_chain_through_self_link() {
    assert_chain_rejected(
        &[
            Entry::Link("a", ".", EntryType::Symlink),
            Entry::Link("a/b", "..", EntryType::Symlink),
            Entry::File("a/b/evil", b"pwned"),
        ],
        "a/b",
        "a",
    );
}

/// The issue's second shape: the payload would be written via the link's
/// resolved location (`b/evil`) rather than through `a`. It trips at the
/// same `a/b` entry as the shape above — pinned separately because, before
/// the fix, each shape escaped by its own path.
#[test]
fn rejects_symlink_chain_writing_beside_the_link() {
    assert_chain_rejected(
        &[
            Entry::Link("a", ".", EntryType::Symlink),
            Entry::Link("a/b", "..", EntryType::Symlink),
            Entry::File("b/evil", b"pwned"),
        ],
        "a/b",
        "a",
    );
}

/// A longer chain: no link is written through another, but `l2`'s target
/// `x/l1/..` resolves physically through `x/l1 -> ..`, landing on staging's
/// parent. Refused at the payload, which is the first write through a link.
#[test]
fn rejects_longer_symlink_chain() {
    assert_chain_rejected(
        &[
            Entry::Link("x/l1", "..", EntryType::Symlink),
            Entry::Link("l2", "x/l1/..", EntryType::Symlink),
            Entry::File("l2/evil", b"pwned"),
        ],
        "l2/evil",
        "l2",
    );
}

/// Deliberate behaviour change: writing through *any* earlier symlink is
/// refused, even a directory alias that stays inside the prefix. Resolving
/// it physically and re-checking would be more permissive and racier, so
/// an archive that needs this is refused rather than half-trusted.
#[test]
fn rejects_write_through_benign_in_prefix_dir_alias() {
    assert_chain_rejected(
        &[
            Entry::Dir("real/", 0o755),
            Entry::Link("lib", "real", EntryType::Symlink),
            Entry::File("lib/libfoo.so", b"elf"),
        ],
        "lib/libfoo.so",
        "lib",
    );
}

/// A directory entry under an earlier link is refused before
/// `create_dir_all` can follow the link.
#[test]
fn rejects_dir_entry_under_an_earlier_symlink() {
    assert_chain_rejected(
        &[Entry::Link("a", ".", EntryType::Symlink), Entry::Dir("a/sub/", 0o755)],
        "a/sub/",
        "a",
    );
}

/// The check runs on the post-strip path: the issue's first chain nested
/// under a versioned top-level directory is refused at strip 1 too.
#[test]
fn rejects_symlink_chain_after_stripping() {
    assert_chain_rejected_at_strip(
        &[
            Entry::Link("pkg-v1/a", ".", EntryType::Symlink),
            Entry::Link("pkg-v1/a/b", "..", EntryType::Symlink),
            Entry::File("pkg-v1/a/b/evil", b"pwned"),
        ],
        "pkg-v1/a/b",
        "a",
        1,
    );
}

/// The walk continues past real directories: a link deeper in the parent
/// chain (`d/l`, under a real `d/`) is still caught, not just the first
/// component.
#[test]
fn rejects_symlink_deeper_in_the_parent_chain() {
    assert_chain_rejected(
        &[
            Entry::Dir("d/", 0o755),
            Entry::Link("d/l", ".", EntryType::Symlink),
            Entry::File("d/l/x", b"pwned"),
        ],
        "d/l/x",
        "d/l",
    );
}

/// An existing *file* as an ancestor is not a link, so the walk lets it
/// through — and `create_dir_all` then fails on that file (a file cannot
/// hold children), leaving the prefix untouched and nothing outside staging.
#[test]
fn file_as_ancestor_is_still_refused_without_touching_the_prefix() {
    let raw = tar_of(&[Entry::File("a", b"file"), Entry::File("a/b", b"child")]);
    let f = Fixture::new("bad.tar.gz", &gzip(&raw));

    let err = f.run_plain(0).unwrap_err();
    assert!(
        matches!(err, LuggageError::Io { ref path, .. } if path.ends_with("a")),
        "the parent dir create must fail on the file `a`, got {err:?}"
    );
    assert_prefix_empty(&f);
    assert_nothing_escaped(&f);
}

/// A directory entry landing *on* an earlier symlink is not treated as
/// that directory: tar-rs checks the existing path with
/// `symlink_metadata`, so the link is not followed and the archive fails
/// — the link's target keeps its own mode. Pinned because
/// `reject_symlinked_ancestor` skips the final component on the strength
/// of this behaviour. (`d` points in-prefix so the lexical link check
/// passes and this behaviour is what decides the outcome.)
#[test]
fn dir_entry_on_an_earlier_symlink_is_refused() {
    let raw = tar_of(&[
        Entry::Dir("real/", 0o755),
        Entry::Link("d", "real", EntryType::Symlink),
        Entry::Dir("d/", 0o700),
    ]);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    let err = f.run_plain(0).unwrap_err();
    assert!(
        matches!(err, LuggageError::ArchiveExtractionFailed { ref message, .. }
            if message.contains("`d/`")),
        "expected the dir entry to fail, got {err:?}"
    );
    assert_prefix_empty(&f);
    assert_nothing_escaped(&f);
}

/// A link at the *final* component is not written through: tar-rs
/// replaces it with the file entry (`create_new` after unlink), so the
/// link's target is untouched. This is why `reject_symlinked_ancestor`
/// checks only the parent chain.
#[test]
fn file_entry_replaces_a_symlink_at_its_own_path() {
    let raw = tar_of(&[
        Entry::File("pkg/real.txt", b"real"),
        Entry::Link("pkg/x", "real.txt", EntryType::Symlink),
        Entry::File("pkg/x", b"replaced"),
    ]);
    let f = Fixture::new("ok.tar.gz", &gzip(&raw));
    f.run_plain(0).unwrap();

    let x = f.prefix.path().join("pkg/x");
    assert!(fs::symlink_metadata(&x).unwrap().file_type().is_file(), "link must be replaced");
    assert_eq!(fs::read(&x).unwrap(), b"replaced");
    assert_eq!(fs::read(f.prefix.path().join("pkg/real.txt")).unwrap(), b"real");
}

// ---- entry-type allowlist (issue #862) --------------------------------

/// Assert `err` is an `UnsafeArchiveEntry` naming `entry` and the type.
///
/// Matching the type name in the reason is what makes these tests
/// discriminate: an archive that ended early (a fixture swallowed by a
/// zero-block end marker) would extract successfully, not produce this.
fn assert_type_rejected(err: LuggageError, entry_name: &str, type_name: &str) {
    match err {
        LuggageError::UnsafeArchiveEntry { entry, reason, .. } => {
            assert_eq!(entry, entry_name, "error should name the entry");
            assert!(
                reason.contains(&format!("entry type {type_name} ")),
                "reason should name the type {type_name}: {reason}"
            );
        }
        other => panic!("expected UnsafeArchiveEntry, got {other:?}"),
    }
}

/// Assert nothing reached the prefix.
fn assert_prefix_empty(f: &Fixture) {
    assert_eq!(
        fs::read_dir(f.prefix.path()).unwrap().count(),
        0,
        "prefix must be empty after a rejected archive"
    );
}

/// A character device is refused outright. tar-rs would today write it as
/// an empty regular file; the allowlist makes the refusal ours.
#[test]
fn rejects_char_device_entry() {
    let raw = tar_of(&[
        Entry::File("pkg/bin/tool", b"ok"),
        Entry::Special("pkg/dev/kmem", EntryType::Char),
    ]);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/dev/kmem", "Char");
    assert_prefix_empty(&f);
}

/// Contiguous (`7`) entries are refused, as is a typeflag tar-rs does not
/// recognise. These pin the `other` catch-all arm: a denylist of just the
/// device and fifo types would let them through. (GNU sparse is not
/// fixtured: tar-rs parses its extended header before yielding the entry,
/// so a synthetic one fails in the reader rather than reaching our check.)
#[test]
fn rejects_contiguous_and_unknown_entry_types() {
    for kind in [EntryType::Continuous, EntryType::new(b'Z')] {
        let raw = tar_of(&[Entry::Special("pkg/odd", kind)]);
        let f = Fixture::new("evil.tar.gz", &gzip(&raw));

        // The expected name is derived, not hardcoded: an unknown flag's
        // Debug form is a tar-rs internal that may change across releases.
        assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/odd", &format!("{kind:?}"));
        assert_prefix_empty(&f);
    }
}

/// A block device is refused outright.
#[test]
fn rejects_block_device_entry() {
    let raw = tar_of(&[Entry::Special("pkg/dev/sda", EntryType::Block)]);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/dev/sda", "Block");
    assert_prefix_empty(&f);
}

/// A fifo is refused outright.
#[test]
fn rejects_fifo_entry() {
    let raw = tar_of(&[
        Entry::File("pkg/bin/tool", b"ok"),
        Entry::Special("pkg/run/pipe", EntryType::Fifo),
    ]);
    let f = Fixture::new("evil.tar.xz", &xz(&raw));

    assert_type_rejected(f.run_plain(0).unwrap_err(), "pkg/run/pipe", "Fifo");
    assert_prefix_empty(&f);
}

/// The type check runs before stripping: a device node shallow enough to
/// be flattened away by `strip 1` still rejects the archive, so whether an
/// archive is accepted never depends on the catalog's strip depth.
#[test]
fn rejects_disallowed_type_even_when_stripped_away() {
    let raw =
        tar_of(&[Entry::Special("kmem", EntryType::Char), Entry::File("node-v1/bin/node", b"ok")]);
    let f = Fixture::new("evil.tar.gz", &gzip(&raw));

    assert_type_rejected(f.run_plain(1).unwrap_err(), "kmem", "Char");
    assert_prefix_empty(&f);
}

/// A header declaring `04755` lands as `0755`: setuid is cleared by our
/// explicit mask, not left to tar-rs's `preserve_permissions` default.
#[cfg(unix)]
#[test]
fn clears_setuid_bit_on_extracted_file() {
    use std::os::unix::fs::PermissionsExt as _;

    let raw = tar_of(&[
        Entry::FileMode("pkg/bin/suid", b"#!/bin/sh\n", 0o4755),
        Entry::FileMode("pkg/bin/sgid", b"#!/bin/sh\n", 0o2755),
    ]);
    let f = Fixture::new("ok.tar.gz", &gzip(&raw));
    f.run_plain(0).unwrap();

    for name in ["suid", "sgid"] {
        let mode =
            fs::metadata(f.prefix.path().join("pkg/bin").join(name)).unwrap().permissions().mode();
        assert_eq!(mode & 0o7777, 0o755, "{name}: special bits must be cleared, got {mode:o}");
    }
}

/// Special bits on a *directory* entry are cleared too — a sticky or setgid
/// directory in the prefix would change how later installs behave there.
#[cfg(unix)]
#[test]
fn clears_sticky_and_setgid_bits_on_extracted_directory() {
    use std::os::unix::fs::PermissionsExt as _;

    let raw = tar_of(&[Entry::Dir("pkg/tmp/", 0o1777), Entry::Dir("pkg/shared/", 0o2775)]);
    let f = Fixture::new("ok.tar.gz", &gzip(&raw));
    f.run_plain(0).unwrap();

    // Only the special bits are asserted: the permission bits a directory
    // ends up with also depend on the process umask during the merge.
    for name in ["tmp", "shared"] {
        let path = f.prefix.path().join("pkg").join(name);
        assert!(path.is_dir(), "{name} must extract as a directory");
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o7000, 0, "{name}: special bits must be cleared, got {mode:o}");
    }
}

/// The mask is ours, not tar-rs's default: with `preserve_permissions`
/// forced *on* — the change a future maintainer might make — `write_entry`
/// still clears setuid, setgid and sticky. Without its mask this test
/// fails, which the end-to-end setuid test above cannot show (tar-rs's
/// default strips the bits there either way). `write_entry` is the only
/// writer in `unpack_entries`, so this covers the production path.
#[cfg(unix)]
#[test]
fn write_entry_masks_special_bits_even_with_preserve_permissions() {
    use std::os::unix::fs::PermissionsExt as _;

    let raw = tar_of(&[Entry::FileMode("suid", b"x", 0o7755)]);
    let dir = tempdir().unwrap();
    let mut archive = Archive::new(raw.as_slice());
    let mut entry = archive.entries().unwrap().next().unwrap().unwrap();

    entry.set_preserve_permissions(true);
    let target = dir.path().join("suid");
    write_entry(&mut entry, &target).unwrap();

    let mode = fs::metadata(&target).unwrap().permissions().mode();
    assert_eq!(mode & 0o7777, 0o755, "special bits must be masked, got {mode:o}");
}

/// The extraction loop itself masks special bits — not just `write_entry`
/// in isolation. `preserve_permissions` is forced on at the *archive*
/// level (tar-rs copies it into every entry), so tar-rs's default no longer
/// strips anything and the only thing standing between a `07755` header
/// and a setuid file is our mask. If `unpack_entries` ever wrote an entry
/// without going through `write_entry`, this fails; the end-to-end tests
/// above cannot catch that, since the default hides it. Covers a file and a
/// directory, since both are written through the same path.
#[cfg(unix)]
#[test]
fn unpack_entries_masks_special_bits_even_with_preserve_permissions() {
    use std::os::unix::fs::PermissionsExt as _;

    let raw = tar_of(&[Entry::Dir("pkg/", 0o3777), Entry::FileMode("pkg/suid", b"x", 0o7755)]);
    let dest = tempdir().unwrap();
    let mut archive = Archive::new(raw.as_slice());
    archive.set_preserve_permissions(true);
    unpack_entries(&mut archive, "ok.tar", dest.path(), 0).unwrap();

    let mode = |p: &str| fs::metadata(dest.path().join(p)).unwrap().permissions().mode();
    // A directory's permission bits are also subject to umask on creation,
    // so only its special bits are compared; the file must match exactly.
    assert_eq!(mode("pkg") & 0o7000, 0, "dir: special bits must be masked, got {:o}", mode("pkg"));
    assert_eq!(mode("pkg/suid") & 0o7777, 0o755, "file: special bits must be masked");
}

/// go's real shape — explicit directory entries, files and an internal
/// symlink at strip 0 — still extracts under the allowlist.
#[test]
fn extracts_go_shaped_archive_with_dirs_and_symlink() {
    let raw = tar_of(&[
        Entry::Dir("go/", 0o755),
        Entry::Dir("go/bin/", 0o755),
        Entry::FileMode("go/bin/go", b"go", 0o755),
        Entry::Dir("go/pkg/", 0o755),
        Entry::Link("go/bin/golang", "go", EntryType::Symlink),
    ]);
    let f = Fixture::new("go.tar.gz", &gzip(&raw));
    f.run_plain(0).unwrap();

    let p = f.prefix.path();
    assert!(p.join("go/pkg").is_dir());
    assert_eq!(fs::read(p.join("go/bin/go")).unwrap(), b"go");
    let link = p.join("go/bin/golang");
    assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    assert_eq!(fs::read(&link).unwrap(), b"go");
}

/// node's real shape — versioned root flattened by strip 1, xz — still
/// extracts under the allowlist, including the `bin/npm` symlink.
#[test]
fn extracts_node_shaped_archive_with_dirs_and_symlink() {
    let raw = tar_of(&[
        Entry::Dir("node-v22.0.0-linux-x64/", 0o755),
        Entry::Dir("node-v22.0.0-linux-x64/bin/", 0o755),
        Entry::FileMode("node-v22.0.0-linux-x64/bin/node", b"node", 0o755),
        Entry::Dir("node-v22.0.0-linux-x64/lib/node_modules/npm/bin/", 0o755),
        Entry::FileMode(
            "node-v22.0.0-linux-x64/lib/node_modules/npm/bin/npm-cli.js",
            b"npm",
            0o755,
        ),
        Entry::Link(
            "node-v22.0.0-linux-x64/bin/npm",
            "../lib/node_modules/npm/bin/npm-cli.js",
            EntryType::Symlink,
        ),
    ]);
    let f = Fixture::new("node.tar.xz", &xz(&raw));
    f.run_plain(1).unwrap();

    let p = f.prefix.path();
    assert_eq!(fs::read(p.join("bin/node")).unwrap(), b"node");
    let npm = p.join("bin/npm");
    assert!(fs::symlink_metadata(&npm).unwrap().file_type().is_symlink());
    assert_eq!(fs::read(&npm).unwrap(), b"npm");
}

/// Paths over 100 bytes are real in node's `node_modules`, and tar carries
/// them in extension headers that precede the entry they describe: GNU
/// `L` (long name) and `K` (long link target), or a per-entry pax `x`
/// header. The allowlist refuses those typeflags if it ever *sees* them,
/// so a real node install depends on tar-rs consuming them first. This
/// pins that assumption: if a tar upgrade leaked one into the entry
/// stream, every long-path archive would be rejected while the
/// short-name fixtures above stayed green.
#[test]
fn extracts_long_paths_carried_by_gnu_and_pax_extension_headers() {
    let deep = format!("node-v22/lib/node_modules/{}/index.js", "a".repeat(120));
    let link = format!("node-v22/lib/node_modules/{}/alias.js", "b".repeat(120));
    let link_target = format!("../{}/index.js", "a".repeat(120));
    let pax_name = format!("node-v22/lib/{}/pax.js", "c".repeat(120));
    assert!(deep.len() > 100 && link_target.len() > 100 && pax_name.len() > 100);

    let mut builder = Builder::new(Vec::new());

    // GNU `L` for the long file name (Builder emits it for a GNU header).
    let mut header = Header::new_gnu();
    header.set_size(4);
    header.set_mode(0o644);
    builder.append_data(&mut header, &deep, &b"deep"[..]).unwrap();

    // GNU `L` for the name *and* `K` for the long symlink target.
    let mut header = Header::new_gnu();
    header.set_entry_type(EntryType::Symlink);
    header.set_size(0);
    header.set_mode(0o777);
    builder.append_link(&mut header, &link, &link_target).unwrap();

    // A per-entry pax `x` header carrying the path, ahead of a ustar entry
    // whose own name field holds only a placeholder.
    builder.append_pax_extensions([("path", pax_name.as_bytes())]).unwrap();
    let mut header = Header::new_ustar();
    header.set_path("placeholder").unwrap();
    header.set_size(3);
    header.set_mode(0o644);
    header.set_cksum();
    builder.append(&header, &b"pax"[..]).unwrap();

    let raw = builder.into_inner().unwrap();
    // Guard against a vacuous fixture: the extension typeflags must really
    // be in the stream, or this would only re-test short names.
    let flags: Vec<u8> = raw.chunks(512).filter(|b| b.len() == 512).map(|b| b[156]).collect();
    for flag in *b"LKx" {
        assert!(flags.contains(&flag), "fixture must contain a `{}` header", flag as char);
    }

    let f = Fixture::new("node.tar.xz", &xz(&raw));
    f.run_plain(1).unwrap();

    let p = f.prefix.path();
    let strip = |s: &str| s.trim_start_matches("node-v22/").to_owned();
    assert_eq!(fs::read(p.join(strip(&deep))).unwrap(), b"deep");
    let alias = p.join(strip(&link));
    assert!(fs::symlink_metadata(&alias).unwrap().file_type().is_symlink());
    assert_eq!(fs::read(&alias).unwrap(), b"deep");
    assert_eq!(fs::read(p.join(strip(&pax_name))).unwrap(), b"pax");
}

/// A pax global header (`git archive` emits one first) carries metadata
/// only. It is skipped, not rejected, and writes nothing to the prefix.
#[test]
fn skips_pax_global_header() {
    // A pax record's length prefix counts the whole record, newline included.
    let record: &[u8] = b"19 comment=abcdefg\n";
    assert_eq!(record.len(), 19);
    let raw = tar_of(&[
        Entry::Typed("pax_global_header", EntryType::XGlobalHeader, record),
        Entry::File("pkg/bin/tool", b"ok"),
    ]);
    let f = Fixture::new("ok.tar.gz", &gzip(&raw));
    f.run_plain(0).unwrap();

    let p = f.prefix.path();
    assert_eq!(fs::read(p.join("pkg/bin/tool")).unwrap(), b"ok");
    assert!(!p.join("pax_global_header").exists(), "the global header must not be written");
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

// ---- partial-merge diagnostics (#863) --------------------------------

/// A merge that fails partway must say how far it got and where. A regular
/// file planted where the archive needs a directory makes `create_dir_all`
/// fail mid-merge — unlike a `chmod`-based unwritable target, this still
/// fails when the tests run as root. Entries merge in name order, so `a.txt`
/// and `b.txt` land before `c/` is reached.
#[test]
fn merge_failure_reports_how_far_it_got() {
    let raw = tar_bytes(&[("a.txt", b"a"), ("b.txt", b"b"), ("c/x", b"x")]);
    let f = Fixture::new("tool.tar.gz", &gzip(&raw));
    fs::write(f.prefix.path().join("c"), b"in the way").unwrap();

    let err = f.run_plain(0).unwrap_err();
    let message = err.to_string();

    let LuggageError::ArchiveMergeFailed(failure) = err else {
        panic!("expected ArchiveMergeFailed, got {message}");
    };
    let ArchiveMergeFailure { artifact, prefix, merged, total, path, .. } = *failure;
    assert_eq!(artifact, "tool.tar.gz");
    assert_eq!(prefix, f.prefix.path());
    assert_eq!(
        (merged, total),
        (2, EntryTotal::Exact(3)),
        "two of the three entries landed before `c/` failed"
    );
    assert_eq!(path, f.prefix.path().join("c"));

    assert!(message.contains("2 of 3"), "progress missing from: {message}");
    assert!(!message.contains("at least"), "a complete count must read as exact: {message}");
    assert!(
        message.contains(&f.prefix.path().display().to_string()),
        "prefix missing from: {message}"
    );

    // The report must be truthful: what it says landed really did.
    assert_eq!(fs::read(f.prefix.path().join("a.txt")).unwrap(), b"a");
    assert_eq!(fs::read(f.prefix.path().join("b.txt")).unwrap(), b"b");
    assert_eq!(fs::read(f.prefix.path().join("c")).unwrap(), b"in the way");
}

/// Progress must accumulate across recursion: a failure inside a nested
/// directory counts what landed in its parent and siblings, and the total
/// includes the leaves of the subtree that never merged.
#[test]
fn nested_merge_failure_counts_across_recursion() {
    let raw = tar_bytes(&[("a/1", b"1"), ("a/2", b"2"), ("a/sub/x", b"x"), ("a/sub/y", b"y")]);
    let f = Fixture::new("tool.tar.gz", &gzip(&raw));
    fs::create_dir_all(f.prefix.path().join("a")).unwrap();
    fs::write(f.prefix.path().join("a/sub"), b"in the way").unwrap();

    let err = f.run_plain(0).unwrap_err();
    let LuggageError::ArchiveMergeFailed(failure) = err else {
        panic!("expected ArchiveMergeFailed, got {err}");
    };
    let ArchiveMergeFailure { merged, total, path, .. } = *failure;
    assert_eq!((merged, total), (2, EntryTotal::Exact(4)));
    assert_eq!(path, f.prefix.path().join("a/sub"));
}

/// The lower bound must survive the whole merge-failure path, not just its
/// parts (#1712): a real merge failure whose staging walk cannot read a
/// subtree reports `at least` rather than an exact total. Staging is built by
/// hand so the denied subdir's path is known. Entries merge in name order, so
/// `a.txt` and `b.txt` land, `c/` hits the planted file, and `c/x` plus the
/// never-reached `d/y` stay in staging.
#[test]
fn merge_failure_with_an_unreadable_staging_subtree_reports_a_lower_bound() {
    let setup = || {
        let staging = tempdir().unwrap();
        let prefix = tempdir().unwrap();
        fs::create_dir_all(staging.path().join("c")).unwrap();
        fs::create_dir_all(staging.path().join("d")).unwrap();
        for (name, body) in [("a.txt", "a"), ("b.txt", "b"), ("c/x", "x"), ("d/y", "y")] {
            fs::write(staging.path().join(name), body).unwrap();
        }
        fs::write(prefix.path().join("c"), b"in the way").unwrap();
        (staging, prefix)
    };

    let (staging, prefix) = setup();
    let denied = staging.path().join("d");
    let lister = |d: &Path| {
        if d == denied {
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
        } else {
            list_dir(d)
        }
    };
    let err =
        merge_into_prefix_with(staging.path(), prefix.path(), "tool.tar.gz", &lister).unwrap_err();
    let message = err.to_string();
    let LuggageError::ArchiveMergeFailed(failure) = err else {
        panic!("expected ArchiveMergeFailed, got {message}");
    };
    let ArchiveMergeFailure { merged, total, path, .. } = *failure;
    // 2 landed + c/x readable in staging; d/y is hidden, so only a lower bound.
    assert_eq!((merged, total), (2, EntryTotal::AtLeast(3)));
    assert_eq!(path, prefix.path().join("c"));
    assert!(message.contains("after 2 of at least 3 entries"), "{message}");

    // The same merge with nothing denied is exact — the lister alone changes it.
    let (staging, prefix) = setup();
    let err = merge_into_prefix_with(staging.path(), prefix.path(), "tool.tar.gz", &list_dir)
        .unwrap_err();
    let LuggageError::ArchiveMergeFailed(failure) = err else {
        panic!("expected ArchiveMergeFailed, got {err}");
    };
    assert_eq!((failure.merged, failure.total), (2, EntryTotal::Exact(4)));
}

/// The staging walk only feeds the failure report, so a merge that succeeds
/// must never call the lister — walking staging on every install would cost
/// real time on node-sized archives and no failure-path test would notice.
#[test]
fn successful_merge_never_walks_staging() {
    let staging = tempdir().unwrap();
    let prefix = tempdir().unwrap();
    fs::create_dir_all(staging.path().join("bin")).unwrap();
    fs::write(staging.path().join("bin/tool"), b"t").unwrap();

    let called = std::cell::Cell::new(false);
    let lister = |d: &Path| {
        called.set(true);
        list_dir(d)
    };
    merge_into_prefix_with(staging.path(), prefix.path(), "tool.tar.gz", &lister).unwrap();

    assert!(!called.get(), "a successful merge consulted the staging lister");
    assert_eq!(fs::read(prefix.path().join("bin/tool")).unwrap(), b"t");
}

/// An existing prefix file is overwritten by the archive's copy. The merge
/// now relies on `rename` replacing it atomically (no `remove_file` first,
/// so a failed rename can't leave the prefix missing the file); this guards
/// that the success-path result is unchanged by that.
#[test]
fn merge_overwrites_an_existing_file_in_place() {
    let raw = tar_bytes(&[("bin/tool", b"new")]);
    let f = Fixture::new("tool.tar.gz", &gzip(&raw));
    fs::create_dir_all(f.prefix.path().join("bin")).unwrap();
    fs::write(f.prefix.path().join("bin/tool"), b"old").unwrap();

    f.run_plain(0).unwrap();

    assert_eq!(fs::read(f.prefix.path().join("bin/tool")).unwrap(), b"new");
}

/// `count_leaves` counts files and links at every depth, and treats a
/// symlink to a directory as one leaf rather than descending into it.
#[test]
fn count_leaves_counts_nested_files_and_does_not_follow_dir_links() {
    let root = tempdir().unwrap();
    fs::create_dir_all(root.path().join("a/b")).unwrap();
    fs::write(root.path().join("top"), b"").unwrap();
    fs::write(root.path().join("a/one"), b"").unwrap();
    fs::write(root.path().join("a/b/two"), b"").unwrap();
    std::os::unix::fs::symlink(root.path().join("a"), root.path().join("link-to-a")).unwrap();
    fs::create_dir(root.path().join("empty")).unwrap();

    // top, a/one, a/b/two, link-to-a (one leaf, not its 2-file target).
    assert_eq!(count_leaves(root.path()), EntryTotal::Exact(4));
    // An unreadable root is "unknown", not "empty".
    assert_eq!(count_leaves(&root.path().join("missing")), EntryTotal::AtLeast(0));
}

/// A subtree that cannot be read must turn the count into a lower bound
/// rather than silently counting as empty (#1688). Injected through the
/// `read_dir` seam because tests may run as root, where `chmod 000` would
/// not stop the walk.
#[test]
fn count_leaves_marks_an_unreadable_subtree_as_a_lower_bound() {
    let root = tempdir().unwrap();
    fs::create_dir_all(root.path().join("ok")).unwrap();
    fs::create_dir_all(root.path().join("locked/deep")).unwrap();
    fs::write(root.path().join("top"), b"").unwrap();
    fs::write(root.path().join("ok/one"), b"").unwrap();
    fs::write(root.path().join("locked/hidden"), b"").unwrap();
    fs::write(root.path().join("locked/deep/hidden"), b"").unwrap();

    let locked = root.path().join("locked");
    let lister = |d: &Path| {
        if d == locked {
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
        } else {
            list_dir(d)
        }
    };

    // top + ok/one are readable; locked/'s two files are not.
    assert_eq!(count_leaves_with(root.path(), &lister), EntryTotal::AtLeast(2));
    // The same tree with nothing blocked is exact — the seam alone changes it.
    assert_eq!(count_leaves_with(root.path(), &list_dir), EntryTotal::Exact(4));
}

/// An entry the listing could not read, or whose file type could not be
/// read, is not counted — it might be an empty directory, and `AtLeast` must
/// never overshoot — and either way the total becomes a lower bound.
#[test]
fn count_leaves_marks_unreadable_entries_and_file_types_as_a_lower_bound() {
    let denied = || std::io::Error::from(std::io::ErrorKind::PermissionDenied);
    let file = |name: &str| Ok((PathBuf::from(name), Ok(false)));

    let bad_entry = |_: &Path| Ok(vec![file("a"), Err(denied()), file("b")]);
    assert_eq!(count_leaves_with(Path::new("/x"), &bad_entry), EntryTotal::AtLeast(2));

    let bad_type = |_: &Path| Ok(vec![file("a"), Ok((PathBuf::from("b"), Err(denied())))]);
    assert_eq!(count_leaves_with(Path::new("/x"), &bad_type), EntryTotal::AtLeast(1));

    let all_good = |_: &Path| Ok(vec![file("a"), file("b")]);
    assert_eq!(count_leaves_with(Path::new("/x"), &all_good), EntryTotal::Exact(2));
}

/// The merge-failure total adds what already landed to what is still in
/// staging; an incomplete staging count must stay a lower bound after that
/// sum rather than being promoted to exact.
#[test]
fn add_moved_preserves_whether_the_total_is_exact() {
    assert_eq!(add_moved(2, EntryTotal::Exact(1)), EntryTotal::Exact(3));
    assert_eq!(add_moved(2, EntryTotal::AtLeast(1)), EntryTotal::AtLeast(3));
    assert_eq!(add_moved(0, EntryTotal::AtLeast(0)), EntryTotal::AtLeast(0));
}

#[test]
fn landed_summary_lists_everything_under_the_limit() {
    let moved = vec![PathBuf::from("/p/a"), PathBuf::from("/p/b")];
    assert_eq!(landed_summary(&moved, 50), "[/p/a, /p/b]");
    assert_eq!(landed_summary(&[], 50), "[]");
}

#[test]
fn landed_summary_truncates_over_the_limit() {
    let moved: Vec<_> = (0..5).map(|i| PathBuf::from(format!("/p/{i}"))).collect();
    assert_eq!(landed_summary(&moved, 2), "[/p/0, /p/1] ...and 3 more");
    assert_eq!(landed_summary(&moved, 5), "[/p/0, /p/1, /p/2, /p/3, /p/4]");
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

/// A cap set to exactly the bytes the reader consumes must still extract, and
/// one byte fewer must not.
///
/// Scope note, so this is not mistaken for more than it is: the boundary
/// *behaviour* of the limiter — that a stream ending precisely on the cap does
/// not trip — is pinned by `limited_reader_exact_fit_reports_all_bytes` in
/// `archive_limit`, which is the test that fails if the EOF probe is removed.
/// This one cannot reach that state through a real archive, because tar stops
/// at the end-of-archive marker rather than reading to the stream's end, so it
/// verifies the surrounding contract (exact cap works, one less does not)
/// rather than the probe itself.
#[test]
fn archive_at_the_exact_consumed_ceiling_still_extracts() {
    let raw = tar_bytes(&[("go/bin/go", b"gobin")]);
    let compressed = gzip(&raw);

    // Find the smallest cap the archive extracts under — that is exactly how
    // many bytes the reader consumes.
    let mut consumed = None;
    for cap in 1..=(raw.len() as u64) {
        let probe = Fixture::new("go.tar.gz", &compressed);
        if probe.run_with_cap(cap).is_ok() {
            consumed = Some(cap);
            break;
        }
    }
    let consumed = consumed.expect("archive should extract under some cap");

    // At exactly that many bytes, nothing was exceeded — it must still work,
    // and must not be misreported as a bomb.
    let f = Fixture::new("go.tar.gz", &compressed);
    f.run_with_cap(consumed).unwrap_or_else(|e| {
        panic!("a cap of exactly the {consumed} consumed bytes must not trip: {e:?}")
    });
    assert_eq!(fs::read(f.prefix.path().join("go/bin/go")).unwrap(), b"gobin");

    // One byte less genuinely truncates the read, so it must be refused —
    // this is what proves the cap above really is the boundary.
    let tight = Fixture::new("go.tar.gz", &compressed);
    assert!(
        tight.run_with_cap(consumed - 1).is_err(),
        "one byte under the consumed size must not extract"
    );
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
