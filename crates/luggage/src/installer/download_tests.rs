//! Unit tests for the HTTP client trait and the production [`UreqClient`].
//!
//! Split out of `download.rs` to keep that file under the repo's 900-line
//! ceiling (`tests/unit/file-size-ceiling.sh`). Same `#[path]` idiom as
//! `methods/tarball_tests.rs`.
//!
//! The retry, reset, and response-ceiling control flow is exercised through
//! the `stream_with_retry` and `buffer_with_retry` helpers with injected
//! readers, so none of it needs a live network or a listening port. Only the
//! `ureq_*` tests at the end bind a loopback stub, to pin the thin
//! `UreqClient` adapters themselves (#856); none touches an external network.

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

// --- buffered-response ceiling (issue #835) ----------------------------

/// Open a reader over `body` once, for the retry-free happy paths.
fn once(body: Vec<u8>) -> impl FnMut() -> std::result::Result<std::io::Cursor<Vec<u8>>, String> {
    move || Ok(std::io::Cursor::new(body.clone()))
}

/// A realistic checksum document — the overwhelmingly common case — is
/// returned byte-for-byte.
#[test]
fn buffer_with_retry_returns_a_body_under_the_cap() {
    let body = format!("{}  node-v22.12.0-linux-x64.tar.xz\n", "a".repeat(64)).into_bytes();
    let got =
        buffer_with_retry("https://example.test/x", 8, Duration::ZERO, once(body.clone())).unwrap();
    assert_eq!(got, body);
}

/// A body landing EXACTLY on the ceiling is legal, not an overrun. This is
/// what the `limit + 1` read buys, and `archive_limit`'s
/// `limited_reader_exact_fit` regression is why it gets its own test: the
/// first cut of that limiter rejected an exact fit.
#[test]
fn buffer_with_retry_accepts_a_body_exactly_at_the_cap() {
    let n = usize::try_from(MAX_BUFFERED_RESPONSE_BYTES).unwrap();
    let body = vec![b'x'; n];
    let got = buffer_with_retry("https://example.test/x", 8, Duration::ZERO, once(body)).unwrap();
    assert_eq!(got.len(), n);
}

/// One byte past the ceiling is refused — and refused as
/// `ResponseTooLarge`, not as a truncated body that would later surface as
/// a confusing digest mismatch.
#[test]
fn buffer_with_retry_rejects_a_body_one_byte_over_the_cap() {
    let n = usize::try_from(MAX_BUFFERED_RESPONSE_BYTES).unwrap() + 1;
    let err = buffer_with_retry("https://example.test/x", 8, Duration::ZERO, once(vec![b'x'; n]))
        .unwrap_err();
    // The AC requires the rejection name the limit.
    let rendered = err.to_string();
    match err {
        LuggageError::ResponseTooLarge { url, limit } => {
            assert_eq!(url, "https://example.test/x");
            assert_eq!(limit, MAX_BUFFERED_RESPONSE_BYTES);
            assert!(
                rendered.contains(&limit.to_string()),
                "message must name the limit: {rendered}"
            );
        }
        other => panic!("expected ResponseTooLarge, got {other:?}"),
    }
}

/// An oversized body must cost exactly ONE fetch. Retrying it would
/// re-download the same oversized body up to seven more times at ten
/// seconds apart — futile (the size is a property of the endpoint, not a
/// transient fault) and a repeat of the very cost the cap exists to avoid.
#[test]
fn an_oversized_body_does_not_consume_the_retry_budget() {
    let n = usize::try_from(MAX_BUFFERED_RESPONSE_BYTES).unwrap() + 1;
    let mut opens = 0;
    let err = buffer_with_retry("https://example.test/x", 8, Duration::ZERO, || {
        opens += 1;
        Ok(std::io::Cursor::new(vec![b'x'; n]))
    })
    .unwrap_err();
    assert!(matches!(err, LuggageError::ResponseTooLarge { .. }));
    assert_eq!(opens, 1, "an oversized body must not be re-fetched");
}

/// A transient read failure keeps its existing retry behaviour — the cap
/// short-circuits only the deterministic case.
#[test]
fn buffer_with_retry_still_retries_a_mid_body_io_failure() {
    let body = b"the complete body".to_vec();
    let mut attempt = 0;
    let got = buffer_with_retry("https://example.test/x", 8, Duration::ZERO, || {
        attempt += 1;
        Ok(if attempt == 1 {
            FailingReader::failing_after(body.clone(), 7)
        } else {
            FailingReader::clean(body.clone())
        })
    })
    .unwrap();
    assert_eq!(attempt, 2, "should have taken exactly one retry");
    assert_eq!(got, b"the complete body");
}

/// Exhausting the budget on I/O failures still reports `DownloadFailed`
/// with the last message — unchanged by the cap.
#[test]
fn buffer_with_retry_exhausts_attempt_budget_with_last_message() {
    let mut opens = 0;
    let err = buffer_with_retry("https://example.test/x", 3, Duration::ZERO, || {
        opens += 1;
        Err::<std::io::Cursor<Vec<u8>>, String>("connection refused".to_owned())
    })
    .unwrap_err();
    assert_eq!(opens, 3);
    match err {
        LuggageError::DownloadFailed { attempts, message, .. } => {
            assert_eq!(attempts, 3);
            assert!(message.contains("connection refused"), "got: {message}");
        }
        other => panic!("expected DownloadFailed, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// `UreqClient` adapter wiring (#856)
//
// Everything above drives the retry helpers directly or goes through
// `MockHttpClient`'s default trait impl. These tests drive `UreqClient`'s own
// overrides against a loopback stub, so they pin what the adapters add on
// top of the helpers: that `max_attempts` / `retry_delay` reach the loop
// unchanged and that a ureq call error surfaces in its documented form.
// Every client is built `.without_proxy()` so a CI `HTTP(S)_PROXY` cannot
// route the loopback requests elsewhere (no `set_var` needed).
// ---------------------------------------------------------------------------

/// A one-thread loopback HTTP stub that answers every request with `status`
/// and `body`, counting requests. Same shape as `tests/cli.rs`'s
/// `evidence_server`; serves until the test process exits.
fn counting_server(
    status: u16,
    body: Vec<u8>,
) -> (String, std::sync::Arc<std::sync::atomic::AtomicU32>) {
    use std::io::{BufRead, BufReader};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stub");
    let url = format!("http://{}/artifact", listener.local_addr().unwrap());
    let hits = Arc::new(AtomicU32::new(0));
    let counter = Arc::clone(&hits);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            // Drain the request head so ureq never sees a reset mid-send.
            let mut reader = BufReader::new(&stream);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|n| n > 0) && line != "\r\n" {
                line.clear();
            }
            counter.fetch_add(1, Ordering::SeqCst);
            let head = format!(
                "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body);
        }
    });
    (url, hits)
}

/// `get_to_writer` spends exactly `max_attempts` requests, and a ureq call
/// error (here a 500) surfaces as `DownloadFailed` carrying ureq's message.
#[test]
fn ureq_get_to_writer_forwards_max_attempts_and_error_message() {
    let (url, hits) = counting_server(500, b"boom".to_vec());
    let client = UreqClient::with_retry(3, Duration::ZERO).without_proxy();
    let mut sink: Vec<u8> = Vec::new();
    let err = client.get_to_writer(&url, &mut sink).unwrap_err();
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 3);
    match err {
        LuggageError::DownloadFailed { url: got_url, attempts, message } => {
            assert_eq!(got_url, url);
            assert_eq!(attempts, 3);
            assert_eq!(message, "http status: 500");
        }
        other => panic!("expected DownloadFailed, got {other:?}"),
    }
    assert!(sink.is_empty(), "a failed download must leave the sink empty");
}

/// `retry_delay` reaches the loop: two attempts means one sleep, so the call
/// cannot finish faster than the configured delay.
#[test]
fn ureq_get_to_writer_forwards_retry_delay() {
    let (url, hits) = counting_server(500, Vec::new());
    let delay = Duration::from_millis(150);
    let client = UreqClient::with_retry(2, delay).without_proxy();
    let mut sink: Vec<u8> = Vec::new();
    let started = std::time::Instant::now();
    client.get_to_writer(&url, &mut sink).unwrap_err();
    let elapsed = started.elapsed();
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert!(elapsed >= delay, "expected >= {delay:?} between attempts, took {elapsed:?}");
}

/// The happy path through the real adapter: a multi-chunk 200 body lands in
/// the sink byte-for-byte on a single request.
#[test]
fn ureq_get_to_writer_streams_a_2xx_body() {
    let body: Vec<u8> =
        (0..STREAM_CHUNK_BYTES * 2 + 17).map(|i| u8::try_from(i % 251).unwrap()).collect();
    let (url, hits) = counting_server(200, body.clone());
    let client = UreqClient::with_retry(3, Duration::ZERO).without_proxy();
    let mut sink: Vec<u8> = Vec::new();
    let n = client.get_to_writer(&url, &mut sink).unwrap();
    assert_eq!(n, body.len() as u64);
    assert_eq!(sink, body);
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
}

/// The buffered `get` adapter forwards `max_attempts` and the error form the
/// same way.
#[test]
fn ureq_get_forwards_max_attempts_and_error_message() {
    let (url, hits) = counting_server(500, Vec::new());
    let client = UreqClient::with_retry(2, Duration::ZERO).without_proxy();
    let err = client.get(&url).unwrap_err();
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 2);
    match err {
        LuggageError::DownloadFailed { attempts, message, .. } => {
            assert_eq!(attempts, 2);
            assert_eq!(message, "http status: 500");
        }
        other => panic!("expected DownloadFailed, got {other:?}"),
    }
}

/// The buffered `get` adapter's happy path: a 200 body comes back intact on a
/// single request.
#[test]
fn ureq_get_returns_a_2xx_body() {
    let (url, hits) = counting_server(200, b"sha256  artifact.tar.gz\n".to_vec());
    let client = UreqClient::with_retry(3, Duration::ZERO).without_proxy();
    let bytes = client.get(&url).unwrap();
    assert_eq!(bytes, b"sha256  artifact.tar.gz\n");
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
}
