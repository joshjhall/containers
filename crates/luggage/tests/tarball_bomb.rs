//! Real-scale decompression-bomb check for the `binary-tarball` method.
//!
//! The unit tests in `installer::methods::tarball` use small caps and small
//! fixtures so the suite stays fast. That proves the ceiling *fires*, but not
//! that it holds against a genuinely explosive artifact at a scale where an
//! absent ceiling would actually hurt. This builds the real thing: a tiny
//! artifact that expands to 256 MiB — a ratio in the hundreds — and asserts luggage
//! refuses it quickly, without materialising the expansion.
//!
//! # Why gzip rather than xz
//!
//! xz is the more dangerous path in production (it writes the whole
//! decompressed stream to a temp file before reading any entry, which is why
//! the ceiling there sits on the *writer*), and its unit test covers exactly
//! that. But `lzma_rs`'s encoder has no preset tuning and does not compress
//! zeros well — a zero payload comes back roughly its own size, which is a large
//! file, not a bomb. `flate2` deflates zeros properly, so the gzip path is
//! where a *real* ratio can be built in-crate without shelling out to `xz` or
//! committing a binary fixture. The mechanism under test — a ceiling counting
//! decompressed bytes — is shared by both paths.

use std::collections::BTreeMap;
use std::io::Write as _;

use luggage::LuggageError;
use luggage::installer::methods::{MethodContext, RecordingRunner, tarball};

/// One tar entry of `size` zero bytes.
fn bomb_tar(size: usize) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_gnu();
    header.set_size(size as u64);
    header.set_mode(0o644);
    header.set_cksum();
    let zeros = vec![0u8; size];
    builder.append_data(&mut header, "payload.bin", &zeros[..]).unwrap();
    builder.into_inner().unwrap()
}

#[test]
fn real_scale_bomb_is_refused_without_materialising_it() {
    const PAYLOAD: usize = 256 * 1024 * 1024; // 256 MiB decompressed
    const CEILING: u64 = 16 * 1024 * 1024; // far below the payload, far above the artifact

    let tmp = tempfile::tempdir().unwrap();
    let artifact = tmp.path().join("bomb.tar.gz");

    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(&bomb_tar(PAYLOAD)).unwrap();
    let compressed = encoder.finish().unwrap();
    let artifact_len = compressed.len() as u64;
    std::fs::write(&artifact, &compressed).unwrap();
    drop(compressed);

    // The premise of the test: a small artifact claiming an enormous
    // expansion. If this ever stops holding, the test is no longer exercising
    // a bomb and the assertions below would pass for the wrong reason.
    assert!(
        artifact_len < 8 * 1024 * 1024,
        "fixture must stay small to be a bomb; got {artifact_len} bytes"
    );
    let ratio = PAYLOAD as u64 / artifact_len.max(1);
    assert!(ratio > 100, "expected a high expansion ratio, got {ratio}x");

    let cache = tempfile::tempdir().unwrap();
    let bin = tempfile::tempdir().unwrap();
    let prefix = tempfile::tempdir().unwrap();
    let runner = RecordingRunner::new();
    let args: Vec<String> = vec![];
    let env = BTreeMap::new();
    let cache_dirs = BTreeMap::new();
    let prefix_str = prefix.path().display().to_string();

    let started = std::time::Instant::now();
    let result = tarball::run(&MethodContext {
        artifact: &artifact,
        args: &args,
        env: &env,
        user: "vscode",
        cache_root: cache.path(),
        bin_root: bin.path(),
        binaries: &[],
        bin_source_dir: None,
        cache_dirs: &cache_dirs,
        prefix: Some(&prefix_str),
        strip_components: 0,
        max_extract_bytes: CEILING,
        runner: &runner,
    });
    let elapsed = started.elapsed();

    match result {
        Err(LuggageError::ArchiveTooLarge { limit, .. }) => assert_eq!(limit, CEILING),
        other => panic!("a {ratio}x bomb must be refused, got {other:?}"),
    }

    assert_eq!(
        std::fs::read_dir(prefix.path()).unwrap().count(),
        0,
        "nothing may reach the prefix"
    );
    // Bounded work rather than a full 256 MiB decompression. Generous enough not
    // to flake on a loaded runner, tight enough to fail if the ceiling stopped
    // working and the whole payload were processed.
    assert!(elapsed.as_secs() < 30, "refusal should be quick, took {elapsed:?}");

    // The staging tempdir is created beside the artifact and dropped on the
    // error path, so nothing but the artifact should be left behind.
    let leftovers: Vec<_> = std::fs::read_dir(tmp.path())
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n != "bomb.tar.gz")
        .collect();
    assert!(leftovers.is_empty(), "expansion scratch must not survive: {leftovers:?}");
}
