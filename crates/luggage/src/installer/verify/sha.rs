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
    fn digests_equal_rejects_one_bit_difference() {
        let mut wrong = ABC_SHA256.to_owned();
        wrong.replace_range(0..1, "c"); // flip first nybble
        assert!(!digests_equal(ABC_SHA256, &wrong));
    }
}
