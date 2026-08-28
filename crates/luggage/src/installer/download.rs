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

/// Ceiling on a body read into memory by [`HttpClient::get`].
///
/// The buffered `get` exists for checksum documents, and nothing about the
/// wire protocol enforces that a response *is* one. Without this cap a
/// publisher endpoint could return an arbitrarily large body and the build
/// container would faithfully buffer all of it — the same memory-blowup class
/// [`HttpClient::get_to_writer`] exists to avoid on the artifact path, and
/// [`crate::installer::methods::archive_limit`] on the extraction path.
///
/// This is **availability, not integrity**: the endpoint is the same TLS
/// publisher tier 3 already trusts for the digest value itself, so anyone able
/// to serve a 10 GB checksum file could equally serve a *wrong* digest. The
/// guard is here because it is cheap and the failure mode is an OOM during an
/// image build, not because it closes a trust boundary.
///
/// 1 MiB is roughly 100x the largest real case — Node's `SHASUMS256.txt`, the
/// biggest manifest this fetches, is well under 10 KB. Deliberately **not**
/// operator-overridable, unlike
/// [`crate::installer::methods::archive_limit::MAX_EXTRACT_BYTES_ENV`]: real
/// toolchains span 120–250 MB decompressed so an extraction ceiling has a
/// legitimate need for headroom, whereas a checksum document approaching 1 MiB
/// is a malfunction in every case, not a large-but-valid one.
const MAX_BUFFERED_RESPONSE_BYTES: u64 = 1024 * 1024;

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
    /// For small responses — checksum files, manifests — and bounded to
    /// [`MAX_BUFFERED_RESPONSE_BYTES`] accordingly: an implementation backed
    /// by a real network MUST refuse a larger body rather than buffer it. For
    /// artifacts (which can be hundreds of megabytes) use
    /// [`HttpClient::get_to_writer`], which does not hold the body at all.
    ///
    /// The cap is part of the contract rather than a detail of one
    /// implementation, because callers rely on it: they parse the returned
    /// `Vec<u8>` without any size check of their own.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::DownloadFailed`] on network or HTTP errors after the
    ///   configured retry budget is exhausted.
    /// - [`LuggageError::ResponseTooLarge`] when the body exceeds
    ///   [`MAX_BUFFERED_RESPONSE_BYTES`].
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
        buffer_with_retry(url, self.max_attempts, self.retry_delay, || {
            ureq::get(url).call().map(ureq::Response::into_reader).map_err(|e| format!("{e}"))
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

/// Buffer `open`'s reader into memory under [`MAX_BUFFERED_RESPONSE_BYTES`],
/// reopening on each attempt, up to `max_attempts` times.
///
/// This is [`UreqClient::get`]'s whole body, lifted out and made generic over
/// the reader so the retry / cap control flow can be tested with a fake reader
/// instead of a live HTTP layer — the same split `stream_with_retry` uses for
/// the streaming path, and for the same reason. `open` yields an
/// already-formatted error string, which keeps this helper free of any `ureq`
/// dependency.
///
/// # Errors
///
/// - [`LuggageError::ResponseTooLarge`] **immediately** when a body exceeds the
///   ceiling, without spending the remaining attempts. An oversized body is a
///   property of the endpoint, not a transient fault: retrying re-downloads
///   the same oversized body, which is both futile and the very cost the cap
///   exists to avoid paying once.
/// - [`LuggageError::DownloadFailed`] carrying the last attempt's message once
///   the attempt budget is exhausted.
fn buffer_with_retry<R: Read>(
    url: &str,
    max_attempts: u32,
    retry_delay: Duration,
    mut open: impl FnMut() -> std::result::Result<R, String>,
) -> Result<Vec<u8>> {
    let mut last_message = String::new();
    for attempt in 1..=max_attempts {
        match open() {
            Ok(reader) => match read_bounded(reader, MAX_BUFFERED_RESPONSE_BYTES) {
                Ok(bytes) => return Ok(bytes),
                Err(BoundedReadError::TooLarge) => {
                    return Err(LuggageError::ResponseTooLarge {
                        url: url.to_owned(),
                        limit: MAX_BUFFERED_RESPONSE_BYTES,
                    });
                }
                Err(BoundedReadError::Io(e)) => last_message = format!("read body: {e}"),
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

/// Why [`read_bounded`] did not return a body.
///
/// The two are kept apart because the caller reacts differently to each: an
/// I/O error is transient and feeds the retry loop, while an overrun is
/// deterministic and short-circuits it.
enum BoundedReadError {
    /// The body exceeded the limit.
    TooLarge,
    /// The underlying read failed.
    Io(std::io::Error),
}

/// Read `reader` fully into memory, refusing a body larger than `limit`.
///
/// Reads up to `limit + 1` bytes and treats the extra one as proof of an
/// overrun. That extra byte is what makes "exactly `limit` bytes" a legal body
/// rather than a rejected one, and it is why the limit cannot be enforced by
/// simply stopping at `limit`.
///
/// # Why this rejects rather than truncates
///
/// [`std::io::Read::take`] would cap the read, but it signals its limit as
/// **EOF** — the caller would receive a silently severed checksum document,
/// parse a partial digest out of it, and report a *digest mismatch*. That
/// diagnosis points at the artifact when the real fault is the response size,
/// which is precisely the confusion this must avoid. Same reasoning
/// [`crate::installer::methods::archive_limit`] records for its own limiters.
fn read_bounded(
    mut reader: impl Read,
    limit: u64,
) -> std::result::Result<Vec<u8>, BoundedReadError> {
    // `limit + 1` cannot overflow: `limit` is a compile-time constant far from
    // `u64::MAX`, and `read_to_end` on a `take` allocates lazily as bytes
    // arrive, so this bound costs nothing on a small body.
    let mut bytes = Vec::new();
    let read =
        (&mut reader).take(limit + 1).read_to_end(&mut bytes).map_err(BoundedReadError::Io)?;
    if read as u64 > limit {
        return Err(BoundedReadError::TooLarge);
    }
    Ok(bytes)
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
#[path = "download_tests.rs"]
mod tests;
