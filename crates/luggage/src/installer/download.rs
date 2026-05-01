//! HTTP client trait + production [`UreqClient`].
//!
//! The trait exists so tests can swap a deterministic in-memory stub for
//! `ureq` without listening on a port. Production code calls
//! [`UreqClient::default`] and forgets the trait exists.
//!
//! Retry policy mirrors `lib/features/rust.sh`'s `curl --retry 8 --retry-delay 10`.

use std::collections::HashMap;
use std::sync::Mutex;
use std::thread::sleep;
use std::time::Duration;

use crate::error::{LuggageError, Result};

/// Maximum number of GET attempts before giving up.
const DEFAULT_MAX_ATTEMPTS: u32 = 8;

/// Linear delay between attempts.
const DEFAULT_RETRY_DELAY: Duration = Duration::from_secs(10);

/// Fetch bytes for a URL.
///
/// Trait-wrapped so tests can inject a stub. Production callers should
/// hold a [`UreqClient`].
pub trait HttpClient: Send + Sync {
    /// Fetch the body at `url` as raw bytes.
    ///
    /// # Errors
    ///
    /// Returns [`LuggageError::DownloadFailed`] on network or HTTP errors
    /// after the configured retry budget is exhausted.
    fn get(&self, url: &str) -> Result<Vec<u8>>;
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

// `std::io::Read` is needed for `into_reader().read_to_end(...)` above.
use std::io::Read as _;

#[cfg(test)]
mod tests {
    use super::*;

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
}
