//! HTTP client trait + production [`UreqClient`].
//!
//! The trait exists so tests can swap a deterministic in-memory stub for
//! `ureq` without listening on a port. Production code calls
//! [`UreqClient::default`] and forgets the trait exists.
//!
//! Retry policy mirrors `lib/features/rust.sh`'s `curl --retry 8 --retry-delay 10`.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::Mutex;
use std::thread::sleep;
use std::time::Duration;

use crate::error::{LuggageError, Result};
use crate::installer::verify::sha::DigestWriter;

/// Maximum number of GET attempts before giving up.
const DEFAULT_MAX_ATTEMPTS: u32 = 8;

/// Linear delay between attempts.
const DEFAULT_RETRY_DELAY: Duration = Duration::from_secs(10);

/// Chunk size for the streaming copy in [`UreqClient::get_to_writer`].
///
/// This is the unit peak memory scales with — 64 KiB keeps the syscall count
/// reasonable on a 150MB tarball without holding the artifact.
const STREAM_CHUNK_BYTES: usize = 64 * 1024;

/// A [`Write`] sink that can discard everything written so far.
///
/// Streaming plus retry needs this. A mid-body failure on attempt N leaves
/// bytes already in the sink; attempt N+1 must not append to them or the
/// artifact silently becomes a corrupt concatenation that then fails
/// verification with a confusing digest mismatch. Rather than give up
/// mid-body retries — which is exactly when retry matters most, on the
/// 150MB downloads this streaming path exists for — the sink is asked to
/// reset and the attempt starts clean.
pub trait RestartableSink: Write {
    /// Discard all previously-written bytes, returning to the empty state.
    ///
    /// # Errors
    ///
    /// Returns any I/O error from the underlying reset (e.g. a file truncate
    /// or seek failure).
    fn restart(&mut self) -> std::io::Result<()>;
}

/// `Vec<u8>` is a restartable sink — used by tests and by the default
/// [`HttpClient::get_to_writer`] implementation's callers.
impl RestartableSink for Vec<u8> {
    fn restart(&mut self) -> std::io::Result<()> {
        self.clear();
        Ok(())
    }
}

/// A [`RestartableSink`] that writes to a file while digesting the same bytes.
///
/// This is the composition the streaming download is for: the artifact lands
/// on disk and its digest is computed in the same pass, so verification never
/// re-reads the file and peak memory never scales with artifact size.
///
/// [`RestartableSink::restart`] truncates the file **and** resets the hasher,
/// so a retried attempt produces a digest over only that attempt's bytes.
#[derive(Debug)]
pub struct DigestingFileSink {
    file: File,
    algorithm: Option<String>,
    digest: DigestWriter,
}

impl DigestingFileSink {
    /// Create `path` (truncating any existing file) and digest with `algorithm`.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::Io`] when the file cannot be created.
    /// - Whatever [`DigestWriter::new`] rejects for an unusable algorithm.
    pub fn create(path: &Path, algorithm: Option<&str>) -> Result<Self> {
        let file = File::create(path)
            .map_err(|e| LuggageError::Io { path: path.to_path_buf(), source: e })?;
        Ok(Self {
            file,
            algorithm: algorithm.map(str::to_owned),
            digest: DigestWriter::new(algorithm)?,
        })
    }

    /// Consume the sink and return the lowercase hex digest of what was written.
    #[must_use]
    pub fn finish(self) -> String {
        self.digest.finish()
    }
}

impl Write for DigestingFileSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // Write to disk first: if that fails the digest must not advance past
        // bytes the artifact does not actually contain.
        self.file.write_all(buf)?;
        self.digest.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl RestartableSink for DigestingFileSink {
    fn restart(&mut self) -> std::io::Result<()> {
        self.file.set_len(0)?;
        self.file.seek(SeekFrom::Start(0))?;
        self.digest = DigestWriter::new(self.algorithm.as_deref())
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        Ok(())
    }
}

/// Fetch bytes for a URL.
///
/// Trait-wrapped so tests can inject a stub. Production callers should
/// hold a [`UreqClient`].
pub trait HttpClient: Send + Sync {
    /// Fetch the body at `url` as raw bytes.
    ///
    /// Suitable for small responses — checksum files, manifests. For
    /// artifacts (which can be hundreds of megabytes) prefer
    /// [`HttpClient::get_to_writer`], which does not hold the body.
    ///
    /// # Errors
    ///
    /// Returns [`LuggageError::DownloadFailed`] on network or HTTP errors
    /// after the configured retry budget is exhausted.
    fn get(&self, url: &str) -> Result<Vec<u8>>;

    /// Stream the body at `url` into `sink`, returning the byte count written.
    ///
    /// The default implementation delegates to [`HttpClient::get`] and writes
    /// the buffer in one shot — correct, but it holds the whole body, so it is
    /// only appropriate for the in-memory test stubs that use it. The
    /// production [`UreqClient`] overrides this with a true chunked copy whose
    /// peak memory is [`STREAM_CHUNK_BYTES`] rather than the artifact size.
    ///
    /// `sink` is a [`RestartableSink`] because retry needs it: an
    /// implementation that fails mid-body calls [`RestartableSink::restart`]
    /// before the next attempt, so a retried download replaces the partial
    /// bytes instead of appending to them.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::DownloadFailed`] on network or HTTP errors after the
    ///   retry budget is exhausted.
    /// - [`LuggageError::DownloadFailed`] when writing to `sink` fails.
    fn get_to_writer(&self, url: &str, sink: &mut dyn RestartableSink) -> Result<u64> {
        let bytes = self.get(url)?;
        // Reset first, exactly as `UreqClient`'s override does, so both
        // implementations honour the same "the sink holds this body and
        // nothing else" contract regardless of the sink's prior state.
        sink.restart().map_err(|e| LuggageError::DownloadFailed {
            url: url.to_owned(),
            attempts: 1,
            message: format!("reset sink: {e}"),
        })?;
        sink.write_all(&bytes).map_err(|e| LuggageError::DownloadFailed {
            url: url.to_owned(),
            attempts: 1,
            message: format!("write body: {e}"),
        })?;
        Ok(bytes.len() as u64)
    }
}

/// Production HTTP client backed by `ureq`.
///
/// Retries up to [`DEFAULT_MAX_ATTEMPTS`] times with [`DEFAULT_RETRY_DELAY`]
/// between attempts. Sleep delay is configurable so tests can avoid
/// real-time waits.
#[derive(Debug, Clone)]
pub struct UreqClient {
    max_attempts: u32,
    retry_delay: Duration,
}

impl Default for UreqClient {
    fn default() -> Self {
        Self { max_attempts: DEFAULT_MAX_ATTEMPTS, retry_delay: DEFAULT_RETRY_DELAY }
    }
}

impl UreqClient {
    /// Build a client with custom retry tuning. Mostly useful in tests.
    #[must_use]
    pub const fn with_retry(max_attempts: u32, retry_delay: Duration) -> Self {
        Self { max_attempts, retry_delay }
    }
}

impl HttpClient for UreqClient {
    fn get(&self, url: &str) -> Result<Vec<u8>> {
        let mut last_message = String::new();
        for attempt in 1..=self.max_attempts {
            match ureq::get(url).call() {
                Ok(resp) => {
                    let mut bytes = Vec::new();
                    if let Err(e) = resp.into_reader().read_to_end(&mut bytes) {
                        last_message = format!("read body: {e}");
                    } else {
                        return Ok(bytes);
                    }
                }
                Err(e) => last_message = format!("{e}"),
            }
            if attempt < self.max_attempts {
                sleep(self.retry_delay);
            }
        }
        Err(LuggageError::DownloadFailed {
            url: url.to_owned(),
            attempts: self.max_attempts,
            message: last_message,
        })
    }

    fn get_to_writer(&self, url: &str, sink: &mut dyn RestartableSink) -> Result<u64> {
        stream_with_retry(url, sink, self.max_attempts, self.retry_delay, || {
            ureq::get(url).call().map(ureq::Response::into_reader).map_err(|e| format!("{e}"))
        })
    }
}

/// Stream `open`'s reader into `sink`, restarting the sink and reopening on
/// each attempt, up to `max_attempts` times.
///
/// This is [`UreqClient::get_to_writer`]'s whole body, lifted out and made
/// generic over the reader so the retry/reset control flow can be tested with
/// a fake reader instead of a live HTTP layer (issue #836). `open` yields an
/// already-formatted error string rather than a typed error, which keeps this
/// helper free of any `ureq` dependency while preserving the exact message the
/// caller used to produce.
///
/// # Errors
///
/// - [`LuggageError::DownloadFailed`] naming the reset failure, **immediately**,
///   if [`RestartableSink::restart`] fails — the remaining attempts are skipped
///   deliberately, because a sink that cannot be reset cannot host a clean retry.
/// - [`LuggageError::DownloadFailed`] carrying the last attempt's message once
///   the attempt budget is exhausted.
fn stream_with_retry<R: Read>(
    url: &str,
    sink: &mut dyn RestartableSink,
    max_attempts: u32,
    retry_delay: Duration,
    mut open: impl FnMut() -> std::result::Result<R, String>,
) -> Result<u64> {
    let mut last_message = String::new();
    for attempt in 1..=max_attempts {
        // Every attempt starts from an empty sink. Without this a failure
        // partway through a 150MB body would leave those bytes in place
        // and the retry would append after them.
        if let Err(e) = sink.restart() {
            return Err(LuggageError::DownloadFailed {
                url: url.to_owned(),
                attempts: attempt,
                message: format!("reset sink: {e}"),
            });
        }
        match open() {
            Ok(mut reader) => match copy_chunked(&mut reader, sink) {
                Ok(written) => return Ok(written),
                Err(e) => last_message = format!("stream body: {e}"),
            },
            Err(e) => last_message = e,
        }
        if attempt < max_attempts {
            sleep(retry_delay);
        }
    }
    Err(LuggageError::DownloadFailed {
        url: url.to_owned(),
        attempts: max_attempts,
        message: last_message,
    })
}

/// Copy `reader` into `writer` in [`STREAM_CHUNK_BYTES`] chunks, returning the
/// byte count.
///
/// `std::io::copy` would do this, but an explicit buffer documents the peak
/// memory this path is designed around — the whole point of the streaming
/// download — rather than leaving it to a library implementation detail.
fn copy_chunked(reader: &mut impl Read, writer: &mut dyn Write) -> std::io::Result<u64> {
    let mut buf = vec![0u8; STREAM_CHUNK_BYTES];
    let mut total: u64 = 0;
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            return Ok(total);
        }
        writer.write_all(&buf[..n])?;
        total += n as u64;
    }
}

/// Deterministic in-memory HTTP client for tests.
///
/// Wires URL → response bytes ahead of time. Unknown URLs return
/// [`LuggageError::DownloadFailed`].
#[derive(Debug, Default)]
pub struct MockHttpClient {
    responses: Mutex<HashMap<String, Vec<u8>>>,
}

impl MockHttpClient {
    /// Build an empty mock.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert a (url → body) entry.
    ///
    /// # Panics
    ///
    /// Panics if the inner mutex is poisoned, which only happens if a
    /// previous user of the mock panicked while holding it. Tests treat
    /// that as a bug.
    pub fn insert(&self, url: impl Into<String>, body: impl Into<Vec<u8>>) {
        self.responses.lock().unwrap().insert(url.into(), body.into());
    }
}

impl HttpClient for MockHttpClient {
    fn get(&self, url: &str) -> Result<Vec<u8>> {
        self.responses.lock().unwrap().get(url).cloned().ok_or_else(|| {
            LuggageError::DownloadFailed {
                url: url.to_owned(),
                attempts: 1,
                message: "mock: no response wired".into(),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A reader over `body` that errors after `fail_after` bytes, or streams
    /// the whole body cleanly when `fail_after` is `None`.
    ///
    /// `copy_chunked` reads into a 64 KiB buffer, so the partial bytes reach
    /// the sink before the error surfaces — exactly the mid-body failure the
    /// restart-and-retry logic exists for.
    struct FailingReader {
        body: Vec<u8>,
        pos: usize,
        fail_after: Option<usize>,
    }

    impl FailingReader {
        /// Streams `body` in full, no error.
        fn clean(body: Vec<u8>) -> Self {
            Self { body, pos: 0, fail_after: None }
        }

        /// Streams `n` bytes of `body`, then errors.
        fn failing_after(body: Vec<u8>, n: usize) -> Self {
            Self { body, pos: 0, fail_after: Some(n) }
        }
    }

    impl Read for FailingReader {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let limit = self.fail_after.unwrap_or(self.body.len());
            if self.pos >= limit {
                return if self.fail_after.is_some() {
                    Err(std::io::Error::other("connection reset mid-body"))
                } else {
                    Ok(0) // clean EOF
                };
            }
            let n = (limit - self.pos).min(buf.len());
            buf[..n].copy_from_slice(&self.body[self.pos..self.pos + n]);
            self.pos += n;
            Ok(n)
        }
    }

    /// A sink whose `restart()` fails on the `fail_on_call`-th invocation.
    ///
    /// Writes delegate to an inner `Vec<u8>`, so a test can inspect exactly
    /// what survived the aborted run.
    struct RestartFailingSink {
        inner: Vec<u8>,
        calls: u32,
        fail_on_call: u32,
    }

    impl Write for RestartFailingSink {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.inner.write(buf)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.inner.flush()
        }
    }

    impl RestartableSink for RestartFailingSink {
        fn restart(&mut self) -> std::io::Result<()> {
            self.calls += 1;
            if self.calls == self.fail_on_call {
                return Err(std::io::Error::other("truncate refused"));
            }
            self.inner.clear();
            Ok(())
        }
    }

    #[test]
    fn mock_returns_inserted_body() {
        let m = MockHttpClient::new();
        m.insert("https://example.test/x", b"payload".to_vec());
        let body = m.get("https://example.test/x").unwrap();
        assert_eq!(body, b"payload");
    }

    #[test]
    fn mock_unknown_url_returns_download_failed() {
        let m = MockHttpClient::new();
        let err = m.get("https://example.test/missing").unwrap_err();
        match err {
            LuggageError::DownloadFailed { attempts: 1, url, .. } => {
                assert_eq!(url, "https://example.test/missing");
            }
            other => panic!("expected DownloadFailed, got {other:?}"),
        }
    }

    #[test]
    fn ureq_default_uses_published_constants() {
        let c = UreqClient::default();
        assert_eq!(c.max_attempts, DEFAULT_MAX_ATTEMPTS);
        assert_eq!(c.retry_delay, DEFAULT_RETRY_DELAY);
    }

    #[test]
    fn get_to_writer_default_impl_streams_the_body() {
        let m = MockHttpClient::new();
        m.insert("https://example.test/x", b"payload".to_vec());
        let mut sink: Vec<u8> = Vec::new();
        let n = m.get_to_writer("https://example.test/x", &mut sink).unwrap();
        assert_eq!(n, 7);
        assert_eq!(sink, b"payload");
    }

    #[test]
    fn get_to_writer_propagates_download_failure() {
        let m = MockHttpClient::new();
        let mut sink: Vec<u8> = Vec::new();
        let err = m.get_to_writer("https://example.test/missing", &mut sink).unwrap_err();
        assert!(matches!(err, LuggageError::DownloadFailed { .. }));
        assert!(sink.is_empty(), "nothing should be written on failure");
    }

    /// Both `get_to_writer` implementations must leave the sink holding this
    /// body and nothing else, even when handed a pre-populated sink.
    #[test]
    fn get_to_writer_default_impl_resets_a_prepopulated_sink() {
        let m = MockHttpClient::new();
        m.insert("https://example.test/x", b"payload".to_vec());
        let mut sink: Vec<u8> = b"stale bytes from an earlier attempt".to_vec();
        let n = m.get_to_writer("https://example.test/x", &mut sink).unwrap();
        assert_eq!(n, 7);
        assert_eq!(sink, b"payload");
    }

    #[test]
    fn vec_sink_restart_discards_prior_bytes() {
        let mut sink: Vec<u8> = Vec::new();
        sink.write_all(b"partial").unwrap();
        sink.restart().unwrap();
        sink.write_all(b"complete").unwrap();
        assert_eq!(sink, b"complete");
    }

    // --- DigestingFileSink -------------------------------------------------

    /// The core guarantee of the streaming path: the file on disk holds the
    /// artifact and the returned digest is that artifact's, in one pass.
    #[test]
    fn digesting_file_sink_writes_file_and_digests_in_one_pass() {
        use crate::installer::verify::sha::digest_hex;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("artifact.tar.gz");
        let mut sink = DigestingFileSink::create(&path, Some("sha256")).unwrap();
        // Deliberately chunked, as a streaming copy would be.
        sink.write_all(b"hello ").unwrap();
        sink.write_all(b"world").unwrap();
        sink.flush().unwrap();
        let digest = sink.finish();
        assert_eq!(std::fs::read(&path).unwrap(), b"hello world");
        assert_eq!(digest, digest_hex(Some("sha256"), b"hello world").unwrap());
    }

    /// Retry safety: a restart must leave neither the file nor the digest
    /// carrying the abandoned attempt's bytes. Without this a mid-body retry
    /// would silently produce a corrupt concatenation.
    #[test]
    fn digesting_file_sink_restart_clears_both_file_and_digest() {
        use crate::installer::verify::sha::digest_hex;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("artifact.bin");
        let mut sink = DigestingFileSink::create(&path, Some("sha256")).unwrap();
        sink.write_all(b"a failed partial attempt").unwrap();
        sink.restart().unwrap();
        sink.write_all(b"the real body").unwrap();
        sink.flush().unwrap();
        let digest = sink.finish();
        assert_eq!(std::fs::read(&path).unwrap(), b"the real body");
        assert_eq!(digest, digest_hex(Some("sha256"), b"the real body").unwrap());
    }

    /// A restart after a LONGER attempt must truncate, not leave a tail of the
    /// old bytes past the new content's end.
    #[test]
    fn digesting_file_sink_restart_truncates_a_longer_prior_attempt() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("artifact.bin");
        let mut sink = DigestingFileSink::create(&path, Some("sha256")).unwrap();
        sink.write_all(&[b'x'; 4096]).unwrap();
        sink.restart().unwrap();
        sink.write_all(b"short").unwrap();
        sink.flush().unwrap();
        let _ = sink.finish();
        assert_eq!(std::fs::read(&path).unwrap(), b"short");
    }

    #[test]
    fn digesting_file_sink_rejects_an_unusable_algorithm() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("artifact.bin");
        let err = DigestingFileSink::create(&path, Some("md5")).unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    // --- stream_with_retry orchestration (issue #836) ----------------------

    /// The happy path must not retry: one open, one copy, no sleep.
    #[test]
    fn stream_with_retry_succeeds_on_first_attempt() {
        let mut opens = 0;
        let mut sink: Vec<u8> = Vec::new();
        let n = stream_with_retry("https://example.test/x", &mut sink, 8, Duration::ZERO, || {
            opens += 1;
            Ok(std::io::Cursor::new(b"payload".to_vec()))
        })
        .unwrap();
        assert_eq!(n, 7);
        assert_eq!(sink, b"payload");
        assert_eq!(opens, 1, "a successful attempt must not reopen");
    }

    /// The core retry guarantee: the retried attempt's bytes must REPLACE the
    /// failed attempt's partial bytes, not be appended after them. A regression
    /// here produces a silently corrupt concatenation.
    #[test]
    fn stream_with_retry_replaces_partial_bytes_after_mid_stream_failure() {
        let body = b"the complete body".to_vec();
        let mut attempt = 0;
        let mut sink: Vec<u8> = Vec::new();
        let n = stream_with_retry("https://example.test/x", &mut sink, 8, Duration::ZERO, || {
            attempt += 1;
            // First attempt dies after 7 bytes; the second streams cleanly.
            Ok(if attempt == 1 {
                FailingReader::failing_after(body.clone(), 7)
            } else {
                FailingReader::clean(body.clone())
            })
        })
        .unwrap();
        assert_eq!(attempt, 2, "should have taken exactly one retry");
        assert_eq!(sink, b"the complete body", "retry must replace, not append");
        assert_eq!(usize::try_from(n).unwrap(), sink.len());
    }

    /// A sink that cannot be reset cannot host a clean retry, so the loop
    /// short-circuits: immediate `DownloadFailed` naming the reset failure,
    /// with every remaining attempt skipped.
    #[test]
    fn stream_with_retry_aborts_immediately_when_restart_fails() {
        let mut opens = 0;
        let mut sink = RestartFailingSink { inner: Vec::new(), calls: 0, fail_on_call: 1 };
        let err = stream_with_retry("https://example.test/x", &mut sink, 8, Duration::ZERO, || {
            opens += 1;
            Ok(std::io::Cursor::new(b"payload".to_vec()))
        })
        .unwrap_err();
        match err {
            LuggageError::DownloadFailed { url, attempts, message } => {
                assert_eq!(url, "https://example.test/x");
                assert_eq!(attempts, 1, "must report the attempt it died on, not the budget");
                assert!(message.contains("reset sink"), "message should name the reset: {message}");
                assert!(message.contains("truncate refused"), "should carry the io error");
            }
            other => panic!("expected DownloadFailed, got {other:?}"),
        }
        assert_eq!(opens, 0, "no attempt may proceed past a failed reset");
        assert_eq!(sink.calls, 1, "remaining attempts must be skipped");
    }

    /// A restart failure on a LATER attempt short-circuits just the same — the
    /// budget is abandoned wherever the reset breaks, not only on attempt 1.
    #[test]
    fn stream_with_retry_aborts_when_a_later_restart_fails() {
        let mut opens = 0;
        let mut sink = RestartFailingSink { inner: Vec::new(), calls: 0, fail_on_call: 3 };
        let err = stream_with_retry("https://example.test/x", &mut sink, 8, Duration::ZERO, || {
            opens += 1;
            Err::<std::io::Cursor<Vec<u8>>, _>("connection refused".to_owned())
        })
        .unwrap_err();
        match err {
            LuggageError::DownloadFailed { attempts, message, .. } => {
                assert_eq!(attempts, 3);
                assert!(message.contains("reset sink"), "got {message}");
            }
            other => panic!("expected DownloadFailed, got {other:?}"),
        }
        assert_eq!(opens, 2, "attempts 1 and 2 ran; attempt 3 died at the reset");
    }

    /// Exhausting the budget reports the configured attempt count and carries
    /// the LAST attempt's message, not the first.
    #[test]
    fn stream_with_retry_exhausts_attempt_budget_with_last_message() {
        let mut attempt = 0;
        let mut sink: Vec<u8> = Vec::new();
        let err = stream_with_retry("https://example.test/x", &mut sink, 3, Duration::ZERO, || {
            attempt += 1;
            Err::<std::io::Cursor<Vec<u8>>, _>(format!("attempt {attempt} refused"))
        })
        .unwrap_err();
        match err {
            LuggageError::DownloadFailed { url, attempts, message } => {
                assert_eq!(url, "https://example.test/x");
                assert_eq!(attempts, 3);
                assert_eq!(message, "attempt 3 refused", "must carry the last message");
            }
            other => panic!("expected DownloadFailed, got {other:?}"),
        }
        assert_eq!(attempt, 3, "should have used the whole budget");
        assert!(sink.is_empty(), "nothing should survive a fully-failed download");
    }

    /// A mid-body failure that reaches the sink must also be erased from the
    /// DIGEST, not just the file — otherwise a retried download verifies
    /// against a hash of partial+full bytes and fails with a confusing
    /// mismatch. The digest after a retry must equal a clean download's.
    #[test]
    fn stream_with_retry_digest_after_retry_matches_clean_download() {
        use crate::installer::verify::sha::digest_hex;
        // Multi-chunk, so the partial attempt writes real chunks to disk.
        let body: Vec<u8> =
            (0..(STREAM_CHUNK_BYTES * 2 + 17)).map(|i| u8::try_from(i % 251).unwrap()).collect();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("retried.tar.gz");
        let mut sink = DigestingFileSink::create(&path, Some("sha256")).unwrap();

        let mut attempt = 0;
        let n = stream_with_retry("https://example.test/big", &mut sink, 8, Duration::ZERO, || {
            attempt += 1;
            Ok(if attempt == 1 {
                FailingReader::failing_after(body.clone(), STREAM_CHUNK_BYTES + 5)
            } else {
                FailingReader::clean(body.clone())
            })
        })
        .unwrap();
        sink.flush().unwrap();
        let digest = sink.finish();

        assert_eq!(attempt, 2);
        assert_eq!(usize::try_from(n).unwrap(), body.len());
        assert_eq!(std::fs::read(&path).unwrap(), body, "file must hold only the retry's bytes");
        assert_eq!(digest, digest_hex(Some("sha256"), &body).unwrap());
    }

    /// Streaming a body larger than one chunk must round-trip intact — the
    /// case the whole change exists for.
    #[test]
    fn get_to_writer_round_trips_a_multi_chunk_body() {
        use crate::installer::verify::sha::digest_hex;
        let body: Vec<u8> =
            (0..(STREAM_CHUNK_BYTES * 2 + 17)).map(|i| u8::try_from(i % 251).unwrap()).collect();
        let m = MockHttpClient::new();
        m.insert("https://example.test/big", body.clone());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big.tar.gz");
        let mut sink = DigestingFileSink::create(&path, Some("sha256")).unwrap();
        let n = m.get_to_writer("https://example.test/big", &mut sink).unwrap();
        sink.flush().unwrap();
        let digest = sink.finish();
        assert_eq!(usize::try_from(n).unwrap(), body.len());
        assert_eq!(std::fs::read(&path).unwrap(), body);
        assert_eq!(digest, digest_hex(Some("sha256"), &body).unwrap());
    }
}
