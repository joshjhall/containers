//! Decompressed-size ceiling for the `binary-tarball` method.
//!
//! A compressed archive can expand by an enormous factor: 153 KB of xz'd zeros
//! decompresses to 1 GiB (a 6867x ratio) in under two seconds, and zeros are
//! not the worst case an attacker can construct. Extraction runs as **root
//! during the image build**, so an unbounded expansion fills the build host's
//! disk rather than merely crashing a process.
//!
//! # Why the ceiling counts real bytes, not header sizes
//!
//! `tar`'s per-entry `size()` is the archive's own **claim** about an entry,
//! and an attacker writes the archive. A bomb can declare `size: 1` and then
//! deliver gigabytes, so a check against the header would wave it straight
//! through. Both wrappers here therefore count bytes that actually move, and
//! the budget is shared across the whole archive — a per-entry cap alone would
//! let ten thousand just-under-the-limit entries through.
//!
//! # Why not `Read::take`
//!
//! [`std::io::Read::take`] is the obvious primitive and is *almost* right, but
//! it signals its limit by returning **EOF**. Feeding that to a tar reader
//! makes a bomb indistinguishable from a legitimately truncated archive, which
//! would report the wrong diagnosis to whoever has to act on it. Both wrappers
//! here instead record that the cap was hit, so the caller can raise
//! [`crate::LuggageError::ArchiveTooLarge`] and leave the truncation error to
//! mean actual truncation.

use std::io::{self, Read, Write};

/// Default ceiling: 2 GiB.
///
/// The largest artifacts this system installs are full language toolchains —
/// go's tarball is roughly 250 MB decompressed, node's roughly 120 MB — so this
/// leaves about 8x headroom over the biggest real case while still refusing a
/// bomb long before it threatens a build host. Override with
/// `LUGGAGE_MAX_EXTRACT_BYTES`.
pub const DEFAULT_MAX_EXTRACT_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Environment variable overriding [`DEFAULT_MAX_EXTRACT_BYTES`].
pub const MAX_EXTRACT_BYTES_ENV: &str = "LUGGAGE_MAX_EXTRACT_BYTES";

/// Reader that stops after `limit` bytes and remembers that it did.
///
/// Wraps the *decompressed* side of a stream, so the count is expansion rather
/// than artifact size. Used for the gzip path, which streams a `GzDecoder`
/// straight into the tar reader.
pub struct LimitedReader<R> {
    inner: R,
    remaining: u64,
    tripped: bool,
}

impl<R: Read> LimitedReader<R> {
    /// Wrap `inner`, allowing at most `limit` bytes through.
    pub const fn new(inner: R, limit: u64) -> Self {
        Self { inner, remaining: limit, tripped: false }
    }

    /// True once the budget was exhausted.
    ///
    /// Checked *after* the read loop finishes: the reader reports EOF at the
    /// cap so the tar layer unwinds normally, and this is what tells the
    /// caller that the EOF meant "bomb" rather than "end of archive".
    pub const fn tripped(&self) -> bool {
        self.tripped
    }
}

impl<R: Read> Read for LimitedReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.remaining == 0 {
            // The budget is spent, but that alone does not mean the archive
            // overran it: a stream ending *exactly* on the cap is legitimate,
            // and `read_to_end` always probes once more to confirm EOF. Ask
            // the inner reader whether anything is actually left — only a
            // non-empty answer is a real overrun.
            //
            // Without this probe an artifact whose decompressed size happens
            // to equal the ceiling would be rejected as a bomb, and the
            // reader would disagree with `LimitedWriter`, which accepts a
            // write landing exactly on the cap.
            let mut probe = [0u8; 1];
            if self.inner.read(&mut probe)? > 0 {
                self.tripped = true;
            }
            return Ok(0);
        }
        // Never read more than the remaining budget, so the count cannot
        // overshoot and the trip fires on the read that would have exceeded it.
        let cap = usize::try_from(self.remaining).unwrap_or(usize::MAX);
        let take = buf.len().min(cap);
        let n = self.inner.read(&mut buf[..take])?;
        self.remaining -= n as u64;
        Ok(n)
    }
}

/// Writer that fails once more than `limit` bytes are written.
///
/// Used for the xz path, where `lzma_rs::xz_decompress` pushes into a sink
/// rather than exposing a `Read`. Capping the **writer** is what stops the bomb
/// mid-decompression: bounding only the later tar read would leave the fully
/// expanded temp file already on disk, which is the very outcome the ceiling
/// exists to prevent.
///
/// Unlike [`LimitedReader`], this one errors rather than reporting a short
/// write — a truncated write has no benign reading, and `io::Error` is the
/// channel `xz_decompress` already propagates.
pub struct LimitedWriter<W> {
    inner: W,
    remaining: u64,
    tripped: bool,
}

impl<W: Write> LimitedWriter<W> {
    /// Wrap `inner`, allowing at most `limit` bytes through.
    pub const fn new(inner: W, limit: u64) -> Self {
        Self { inner, remaining: limit, tripped: false }
    }

    /// True once a write exceeded the budget.
    ///
    /// The error raised at that moment travels back through
    /// `xz_decompress` as an opaque decompression failure, so the caller
    /// consults this to report the bomb specifically rather than a generic
    /// "xz decompression failed".
    pub const fn tripped(&self) -> bool {
        self.tripped
    }
}

impl<W: Write> Write for LimitedWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let len = buf.len() as u64;
        if len > self.remaining {
            self.tripped = true;
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "decompressed output exceeded the configured extraction ceiling",
            ));
        }
        let n = self.inner.write(buf)?;
        self.remaining -= n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// Resolve the extraction ceiling from the environment.
///
/// Returns [`DEFAULT_MAX_EXTRACT_BYTES`] when `LUGGAGE_MAX_EXTRACT_BYTES` is
/// unset or empty — an exported-but-empty variable is routine in build
/// environments and means "not configured", matching how
/// `require_verified_downloads_from_env` treats the same shape.
///
/// A *malformed* value is a hard error rather than a fallback to the default.
/// Silently ignoring a misconfigured ceiling would leave an operator believing
/// they had raised or lowered the limit when they had not — the same
/// silent-skip class of bug the rest of this method is careful to avoid.
///
/// # Errors
///
/// [`crate::LuggageError::Catalog`] when the value is set but does not parse as
/// a non-zero `u64`.
pub fn max_extract_bytes_from_env() -> crate::error::Result<u64> {
    parse_max_extract_bytes(std::env::var(MAX_EXTRACT_BYTES_ENV).ok().as_deref())
}

/// The value half of [`max_extract_bytes_from_env`], split out so it can be
/// tested directly.
///
/// The workspace sets `unsafe_code = "forbid"`, and edition 2024 makes
/// `std::env::set_var` unsafe, so a test cannot legally mutate the environment
/// to exercise the parsing. Taking the raw value as a parameter makes every
/// branch reachable without that — the same split
/// `require_verified_downloads_from_env` uses for the same reason.
///
/// # Errors
///
/// [`crate::LuggageError::Catalog`] when the value is set but does not parse as
/// a non-zero `u64`.
pub fn parse_max_extract_bytes(raw: Option<&str>) -> crate::error::Result<u64> {
    let Some(raw) = raw else { return Ok(DEFAULT_MAX_EXTRACT_BYTES) };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(DEFAULT_MAX_EXTRACT_BYTES);
    }
    match trimmed.parse::<u64>() {
        Ok(0) => Err(crate::error::LuggageError::Catalog(format!(
            "{MAX_EXTRACT_BYTES_ENV} is `0`, which would refuse every archive; \
             unset it to use the default of {DEFAULT_MAX_EXTRACT_BYTES} bytes",
        ))),
        Ok(n) => Ok(n),
        Err(e) => Err(crate::error::LuggageError::Catalog(format!(
            "{MAX_EXTRACT_BYTES_ENV} must be a positive byte count, got `{raw}`: {e}",
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Cursor;

    #[test]
    fn limited_reader_passes_through_under_the_cap() {
        let data = b"hello world";
        let mut r = LimitedReader::new(Cursor::new(data), 64);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
        assert!(!r.tripped(), "a stream under the cap must not trip");
    }

    /// At the cap the reader reports EOF (so the tar layer unwinds cleanly)
    /// and records the trip, which is what lets the caller tell a bomb from a
    /// truncated archive.
    #[test]
    fn limited_reader_trips_at_the_cap() {
        let data = vec![0u8; 1024];
        let mut r = LimitedReader::new(Cursor::new(data), 16);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out.len(), 16, "must stop exactly at the budget");
        assert!(r.tripped());
    }

    /// Exactly-at-the-cap is not an overrun on its own; the trip fires on the
    /// read that would exceed it.
    #[test]
    fn limited_reader_exact_fit_reports_all_bytes() {
        let data = vec![7u8; 32];
        let mut r = LimitedReader::new(Cursor::new(data), 32);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out.len(), 32);
        assert!(
            !r.tripped(),
            "a stream ending exactly on the cap did not overrun it and must not trip — \
             `read_to_end` probes once more to confirm EOF, and that probe must not be \
             mistaken for truncation"
        );
    }

    #[test]
    fn limited_writer_passes_through_under_the_cap() {
        let mut w = LimitedWriter::new(Vec::new(), 64);
        w.write_all(b"hello").unwrap();
        assert!(!w.tripped());
    }

    /// The writer errors rather than short-writing: a truncated write has no
    /// benign reading, and the error is the channel `xz_decompress`
    /// propagates.
    #[test]
    fn limited_writer_errors_past_the_cap() {
        let mut w = LimitedWriter::new(Vec::new(), 4);
        let err = w.write_all(b"way too much").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::WriteZero);
        assert!(w.tripped());
    }

    /// Unset or empty means "not configured" — an exported-but-empty variable
    /// is routine in build environments.
    #[test]
    fn env_absent_or_empty_uses_the_default() {
        assert_eq!(parse_max_extract_bytes(None).unwrap(), DEFAULT_MAX_EXTRACT_BYTES);
        assert_eq!(parse_max_extract_bytes(Some("")).unwrap(), DEFAULT_MAX_EXTRACT_BYTES);
        assert_eq!(parse_max_extract_bytes(Some("   ")).unwrap(), DEFAULT_MAX_EXTRACT_BYTES);
    }

    #[test]
    fn env_valid_value_overrides_the_default() {
        assert_eq!(parse_max_extract_bytes(Some("4096")).unwrap(), 4096);
        assert_eq!(parse_max_extract_bytes(Some("  4096  ")).unwrap(), 4096);
    }

    /// A malformed ceiling is loud, never a silent fall back to the default —
    /// an operator who set it wrong must hear about it rather than quietly
    /// getting a limit they did not choose.
    #[test]
    fn env_malformed_value_is_an_error() {
        for bad in ["banana", "-1", "1.5", "10MB", "2 GiB"] {
            let err = parse_max_extract_bytes(Some(bad)).unwrap_err();
            assert!(
                matches!(err, crate::error::LuggageError::Catalog(_)),
                "`{bad}` should be a loud error, got {err:?}"
            );
        }
    }

    /// Zero would refuse every archive, which is far more likely a mistake
    /// than an intent — and it names the default so the fix is obvious.
    #[test]
    fn env_zero_is_an_error() {
        let err = parse_max_extract_bytes(Some("0")).unwrap_err();
        match err {
            crate::error::LuggageError::Catalog(msg) => {
                assert!(msg.contains("every archive"), "should explain: {msg}");
            }
            other => panic!("expected Catalog, got {other:?}"),
        }
    }
}
