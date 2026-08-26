//! Hash digest helpers used by tier 2 / tier 3 verification.
//!
//! The catalog declares the algorithm name (`sha256` / `sha512`) as a free
//! string in `Verification.algorithm`; this module is the single place
//! where that string is decoded into a digest computation. Adding a new
//! algorithm is a one-line change here.
//!
//! Output is lowercase hex with no separator — the format publishers use in
//! `*.sha256` / `*.sha512` files.

use sha2::{Digest as _, Sha256, Sha512};

use crate::error::{LuggageError, Result};

/// Default algorithm when [`containers_common::tooldb::Verification::algorithm`]
/// is `None`. Matches the publishers' historical default.
pub const DEFAULT_ALGORITHM: &str = "sha256";

/// Compute a hex digest over `bytes` using the named algorithm.
///
/// `algorithm` is matched case-insensitively. Pass `None` to use
/// [`DEFAULT_ALGORITHM`].
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] when the algorithm is recognized as a
///   valid SHA-family name we haven't wired up yet.
/// - [`LuggageError::Catalog`] when the algorithm is unrecognized.
pub fn digest_hex(algorithm: Option<&str>, bytes: &[u8]) -> Result<String> {
    let algo = algorithm.unwrap_or(DEFAULT_ALGORITHM).to_ascii_lowercase();
    match algo.as_str() {
        "sha256" => Ok(hex_lower(&Sha256::digest(bytes))),
        "sha512" => Ok(hex_lower(&Sha512::digest(bytes))),
        // Likely-correct future hash-family names get a clear NotImplemented
        // so a catalog upgrade fails fast without falling through to a
        // generic Catalog error.
        "sha384" | "sha224" | "blake3" => {
            Err(LuggageError::NotImplemented("digest algorithm not wired (only sha256/sha512)"))
        }
        _ => Err(LuggageError::Catalog(format!("unrecognised digest algorithm `{algo}`"))),
    }
}

/// An [`io::Write`] that digests everything written through it.
///
/// This is what lets the download path verify a 150MB artifact without ever
/// holding it: bytes are hashed as they stream to disk, so the digest is
/// finished the moment the last byte lands and nothing re-reads the file.
///
/// The algorithm is decoded by [`digest_hex`]'s same `match` (via
/// [`DigestWriter::new`]) — this module stays the single place a catalog
/// algorithm string turns into a hash computation.
pub struct DigestWriter {
    inner: Hasher,
}

/// The concrete hasher behind a [`DigestWriter`].
enum Hasher {
    /// SHA-256 — the catalog default.
    Sha256(Sha256),
    /// SHA-512.
    Sha512(Sha512),
}

/// Hand-written because the `sha2` hashers are not `Debug`. Prints the
/// algorithm only — never any digest state, which would be misleading
/// mid-stream and is not the caller's business.
impl std::fmt::Debug for DigestWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let algo = match self.inner {
            Hasher::Sha256(_) => "sha256",
            Hasher::Sha512(_) => "sha512",
        };
        f.debug_struct("DigestWriter").field("algorithm", &algo).finish()
    }
}

impl DigestWriter {
    /// Build a writer for the named algorithm.
    ///
    /// `algorithm` is matched case-insensitively; pass `None` for
    /// [`DEFAULT_ALGORITHM`]. Accepts exactly the algorithms [`digest_hex`]
    /// accepts, and rejects the rest with the same errors.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::NotImplemented`] for a recognized-but-unwired
    ///   SHA-family name.
    /// - [`LuggageError::Catalog`] for an unrecognized algorithm.
    pub fn new(algorithm: Option<&str>) -> Result<Self> {
        let algo = algorithm.unwrap_or(DEFAULT_ALGORITHM).to_ascii_lowercase();
        let inner = match algo.as_str() {
            "sha256" => Hasher::Sha256(Sha256::new()),
            "sha512" => Hasher::Sha512(Sha512::new()),
            "sha384" | "sha224" | "blake3" => {
                return Err(LuggageError::NotImplemented(
                    "digest algorithm not wired (only sha256/sha512)",
                ));
            }
            _ => {
                return Err(LuggageError::Catalog(format!(
                    "unrecognised digest algorithm `{algo}`"
                )));
            }
        };
        Ok(Self { inner })
    }

    /// Consume the writer and return the lowercase hex digest.
    #[must_use]
    pub fn finish(self) -> String {
        match self.inner {
            Hasher::Sha256(h) => hex_lower(&h.finalize()),
            Hasher::Sha512(h) => hex_lower(&h.finalize()),
        }
    }
}

impl std::io::Write for DigestWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match &mut self.inner {
            Hasher::Sha256(h) => h.update(buf),
            Hasher::Sha512(h) => h.update(buf),
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write as _;
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Constant-time-ish comparison of two hex digest strings.
///
/// Both inputs are folded to lowercase before comparison. Returns `true`
/// only when the strings have equal length and equal contents.
#[must_use]
pub fn digests_equal(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x.to_ascii_lowercase() ^ y.to_ascii_lowercase();
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 6234 / NIST test vectors for "abc".
    const ABC_SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const ABC_SHA512: &str = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";

    #[test]
    fn sha256_of_abc_matches_test_vector() {
        let hex = digest_hex(Some("sha256"), b"abc").unwrap();
        assert_eq!(hex, ABC_SHA256);
    }

    #[test]
    fn sha512_of_abc_matches_test_vector() {
        let hex = digest_hex(Some("sha512"), b"abc").unwrap();
        assert_eq!(hex, ABC_SHA512);
    }

    #[test]
    fn default_algorithm_is_sha256() {
        let hex = digest_hex(None, b"abc").unwrap();
        assert_eq!(hex, ABC_SHA256);
    }

    #[test]
    fn algorithm_match_is_case_insensitive() {
        let hex = digest_hex(Some("SHA256"), b"abc").unwrap();
        assert_eq!(hex, ABC_SHA256);
    }

    #[test]
    fn unsupported_sha_family_returns_not_implemented() {
        let err = digest_hex(Some("sha384"), b"abc").unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn unrecognised_algorithm_returns_catalog_error() {
        let err = digest_hex(Some("md5"), b"abc").unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn digests_equal_handles_case_difference() {
        assert!(digests_equal(ABC_SHA256, &ABC_SHA256.to_ascii_uppercase()));
    }

    #[test]
    fn digests_equal_rejects_different_lengths() {
        assert!(!digests_equal("aa", "aaaa"));
    }

    #[test]
    fn digest_writer_matches_digest_hex_over_the_same_bytes() {
        use std::io::Write as _;
        let mut w = DigestWriter::new(Some("sha256")).unwrap();
        w.write_all(b"abc").unwrap();
        assert_eq!(w.finish(), ABC_SHA256);
    }

    /// The property the streaming download depends on: chunked writes must
    /// produce the same digest as one contiguous buffer.
    #[test]
    fn digest_writer_is_chunk_boundary_independent() {
        use std::io::Write as _;
        let mut w = DigestWriter::new(Some("sha256")).unwrap();
        w.write_all(b"a").unwrap();
        w.write_all(b"b").unwrap();
        w.write_all(b"c").unwrap();
        assert_eq!(w.finish(), ABC_SHA256);
    }

    #[test]
    fn digest_writer_supports_sha512() {
        use std::io::Write as _;
        let mut w = DigestWriter::new(Some("sha512")).unwrap();
        w.write_all(b"abc").unwrap();
        assert_eq!(w.finish(), ABC_SHA512);
    }

    #[test]
    fn digest_writer_defaults_to_sha256() {
        use std::io::Write as _;
        let mut w = DigestWriter::new(None).unwrap();
        w.write_all(b"abc").unwrap();
        assert_eq!(w.finish(), ABC_SHA256);
    }

    #[test]
    fn digest_writer_of_nothing_is_the_empty_digest() {
        const EMPTY_SHA256: &str =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        assert_eq!(DigestWriter::new(Some("sha256")).unwrap().finish(), EMPTY_SHA256);
    }

    /// `DigestWriter::new` must reject exactly what `digest_hex` rejects —
    /// they share the algorithm vocabulary.
    #[test]
    fn digest_writer_rejects_the_same_algorithms_digest_hex_does() {
        assert!(matches!(
            DigestWriter::new(Some("sha384")).unwrap_err(),
            LuggageError::NotImplemented(_)
        ));
        assert!(matches!(DigestWriter::new(Some("md5")).unwrap_err(), LuggageError::Catalog(_)));
    }

    #[test]
    fn digest_writer_algorithm_match_is_case_insensitive() {
        use std::io::Write as _;
        let mut w = DigestWriter::new(Some("SHA256")).unwrap();
        w.write_all(b"abc").unwrap();
        assert_eq!(w.finish(), ABC_SHA256);
    }

    #[test]
    fn digests_equal_rejects_one_bit_difference() {
        let mut wrong = ABC_SHA256.to_owned();
        wrong.replace_range(0..1, "c"); // flip first nybble
        assert!(!digests_equal(ABC_SHA256, &wrong));
    }
}
