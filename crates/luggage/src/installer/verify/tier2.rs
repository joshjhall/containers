//! Tier 2 — pinned in-repo checksum verification.
//!
//! The catalog carries the expected digest itself (`verification.pinned_checksum`),
//! so verification fetches nothing: the digest computed over the downloaded
//! artifact is compared against a constant that landed in the repository
//! through code review.
//!
//! That is what makes tier 2 stronger than tier 3. Tier 3 asks the publisher
//! what the artifact's digest should be *at fetch time*, so whoever controls
//! the checksum endpoint at that moment controls the answer — a compromised
//! publisher can serve a matching checksum for a tampered artifact and tier 3
//! passes. A pinned checksum was fixed earlier, by a different party, and
//! changing it means changing a reviewed file.
//!
//! What it does **not** establish: a pin is only as good as the review that
//! landed it. Nothing here can tell whether the human who added the constant
//! obtained it from a trustworthy source; it only guarantees that the bytes
//! installed today are the bytes that pin describes.
//!
//! Two properties are load-bearing, and both mirror [`super::tier4`]:
//!
//! - **It fails closed.** A tier-2 entry with no `pinned_checksum`, or with a
//!   pin that isn't a digest, is an error rather than a pass.
//! - **It has nothing to warn about.** Unlike tier 4, tier 2 verifies against
//!   an external reference, so [`super::dispatch`] returns no
//!   [`super::VerificationWarning`] for it — the same as tier 3.

use containers_common::tooldb::Verification;

use super::sha::{Algorithm, digests_equal, is_hex_digest};
use crate::error::{LuggageError, Result};

/// Return the entry's pinned checksum once it is known to be usable, or the
/// typed error for why it is not.
///
/// Shared by [`verify`] and [`super::ensure_supported`] so the pre-download
/// guard refuses a pinless, malformed, or wrong-length tier-2 entry with
/// exactly the error dispatch would raise after the download — the same
/// single-source-of-truth role [`super::unsupported_tier`] plays for
/// unimplemented tiers.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.pinned_checksum` is absent.
/// - [`LuggageError::VerificationFailed`] when the pin is not a hex digest.
/// - Whatever [`Algorithm::parse`] rejects for `verification.algorithm` — the
///   error the download's digest sink would otherwise raise once it started.
/// - [`LuggageError::VerificationFailed`] when the pin's length is not the
///   algorithm's digest width (a truncated paste, or a sha256 pin on a sha512
///   entry), which no computed digest could ever match.
pub(super) fn require_pin<'a>(
    tool: &str,
    version: &str,
    verification: &'a Verification,
) -> Result<&'a str> {
    let pinned = verification.pinned_checksum.as_deref().ok_or_else(|| {
        LuggageError::Catalog(format!(
            "tier 2 verification for {tool}@{version} requires a `pinned_checksum` in the \
             catalog entry"
        ))
    })?;

    if !is_hex_digest(pinned) {
        return Err(verification_failed(
            tool,
            version,
            format!(
                "pinned checksum `{pinned}` is not a hex digest; refusing to treat it as a \
                 verification reference"
            ),
        ));
    }

    let algorithm = Algorithm::parse(verification.algorithm.as_deref())?;
    if pinned.len() != algorithm.hex_len() {
        return Err(verification_failed(
            tool,
            version,
            format!(
                "pinned checksum `{pinned}` is {} hex characters, but a {} digest is {}; no \
                 artifact could match it",
                pinned.len(),
                algorithm.name(),
                algorithm.hex_len()
            ),
        ));
    }

    Ok(pinned)
}

fn verification_failed(tool: &str, version: &str, reason: String) -> LuggageError {
    LuggageError::VerificationFailed {
        tool: tool.to_owned(),
        version: version.to_owned(),
        tier: 2,
        reason,
    }
}

/// Verify a precomputed artifact digest against the catalog's pinned checksum.
///
/// `actual_digest` is the artifact's hex digest, computed while the artifact
/// streamed to disk (see [`crate::installer::download::DigestingFileSink`]).
/// As in tier 3, taking the digest rather than the bytes is what keeps peak
/// memory independent of artifact size.
///
/// `tool` and `version` are recorded in error messages.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.pinned_checksum` is absent.
///   The catalog schema requires it on every tier-2 entry, so its absence is
///   drift — and the fail-closed reading is the only safe one: an entry that
///   never said what digest to expect must not pass by default.
/// - [`LuggageError::VerificationFailed`] when the pinned checksum is not a hex
///   digest, or not the algorithm's digest width (raised by [`require_pin`]).
///   A malformed pin cannot establish anything, and treating it as a mismatch
///   (rather than as a pass) is what keeps a typo'd constant from silently
///   disabling verification.
/// - Whatever [`Algorithm::parse`] rejects for `verification.algorithm`.
/// - [`LuggageError::VerificationFailed`] when the digests differ.
pub fn verify(
    tool: &str,
    version: &str,
    actual_digest: &str,
    verification: &Verification,
) -> Result<()> {
    let pinned = require_pin(tool, version, verification)?;

    if digests_equal(actual_digest, pinned) {
        Ok(())
    } else {
        Err(verification_failed(
            tool,
            version,
            format!("digest mismatch: expected {pinned}, computed {actual_digest}"),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIGEST: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    fn pinned_verification(pin: Option<&str>) -> Verification {
        Verification {
            tier: 2,
            algorithm: Some("sha256".into()),
            pinned_checksum: pin.map(Into::into),
            checksum_url_template: None,
            checksum_manifest: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        }
    }

    #[test]
    fn matching_digest_passes() {
        verify("node", "24.0.0", DIGEST, &pinned_verification(Some(DIGEST))).unwrap();
    }

    /// A pin pasted from a publisher's release page or a vendor advisory often
    /// arrives uppercase; `digests_equal` folds case, and this locks that in so
    /// a future comparison change cannot silently start rejecting valid pins.
    #[test]
    fn case_differences_still_match() {
        let upper = DIGEST.to_ascii_uppercase();
        verify("node", "24.0.0", DIGEST, &pinned_verification(Some(&upper))).unwrap();
    }

    #[test]
    fn mismatched_digest_returns_verification_failed() {
        let actual = "0".repeat(64);
        let err =
            verify("node", "24.0.0", &actual, &pinned_verification(Some(DIGEST))).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier, tool, version, reason } => {
                assert_eq!(tier, 2);
                assert_eq!(tool, "node");
                assert_eq!(version, "24.0.0");
                assert!(reason.contains("digest mismatch"), "got: {reason}");
                // Both sides belong in the message — an operator diagnosing a
                // mismatch needs to know which one to go check.
                assert!(reason.contains(DIGEST), "got: {reason}");
                assert!(reason.contains(&actual), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    /// A tier-2 entry with no pin is catalog drift, not a verification result —
    /// the schema requires the field. It must be a typed `Catalog` error so it
    /// classifies as catalog drift rather than as a failed verification.
    #[test]
    fn missing_pinned_checksum_is_catalog_error() {
        let err = verify("node", "24.0.0", DIGEST, &pinned_verification(None)).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => {
                assert!(msg.contains("pinned_checksum"), "got: {msg}");
            }
            other => panic!("expected Catalog, got {other:?}"),
        }
    }

    /// The dangerous shape: a pin that is present but not a digest must fail,
    /// not pass. A paste carrying a filename or a leaked error string in the
    /// slot would otherwise be compared against and simply mismatch — which is
    /// the right outcome, but the dedicated message is what tells the operator
    /// the *catalog* is wrong rather than the artifact.
    #[test]
    fn non_hex_pin_returns_verification_failed() {
        for pin in ["not-a-digest", "zzzz", "9f86d081  node.tar.gz"] {
            let err =
                verify("node", "24.0.0", DIGEST, &pinned_verification(Some(pin))).unwrap_err();
            match err {
                LuggageError::VerificationFailed { tier: 2, reason, .. } => {
                    assert!(reason.contains("not a hex digest"), "pin {pin}: got {reason}");
                }
                other => panic!("pin {pin}: expected VerificationFailed, got {other:?}"),
            }
        }
    }

    /// The pre-download guard leans on `require_pin` alone (#1041), so the
    /// malformed-pin refusal must live there — not only in `verify`, where it
    /// would fire after the artifact had already been fetched.
    #[test]
    fn require_pin_rejects_a_non_hex_pin() {
        for pin in ["", "not-a-digest", "9f86d081  node.tar.gz"] {
            let err = require_pin("node", "24.0.0", &pinned_verification(Some(pin))).unwrap_err();
            match err {
                LuggageError::VerificationFailed { tier: 2, reason, .. } => {
                    assert!(reason.contains("not a hex digest"), "pin {pin:?}: got {reason}");
                }
                other => panic!("pin {pin:?}: expected VerificationFailed, got {other:?}"),
            }
        }
    }

    #[test]
    fn require_pin_returns_a_hex_pin() {
        assert_eq!(
            require_pin("node", "24.0.0", &pinned_verification(Some(DIGEST))).unwrap(),
            DIGEST
        );
    }

    /// A hex pin of the wrong width for its algorithm can never match, so the
    /// pre-download guard refuses it (#1311) — and `verify` raises the very
    /// same error rather than a later "digest mismatch".
    #[test]
    fn require_pin_rejects_a_wrong_length_hex_pin() {
        let sha512 = |pin: &str| Verification {
            algorithm: Some("sha512".into()),
            ..pinned_verification(Some(pin))
        };
        let too_long = format!("{DIGEST}{DIGEST}");
        let one_over = format!("{DIGEST}0");
        // Both directions: a guard that only refused short pins would let an
        // over-long one through to a post-download mismatch again.
        let cases = [
            // A truncated paste on the default-width entry.
            (pinned_verification(Some(&DIGEST[..8])), "is 8 hex characters", "sha256 digest is 64"),
            // A correct-looking sha256 pin on a sha512 entry.
            (sha512(DIGEST), "is 64 hex characters", "sha512 digest is 128"),
            // A sha512-width pin on the default-width entry.
            (pinned_verification(Some(&too_long)), "is 128 hex characters", "sha256 digest is 64"),
            // A sha256 pin with stray hex pasted after it.
            (pinned_verification(Some(&one_over)), "is 65 hex characters", "sha256 digest is 64"),
        ];
        for (verification, got_len, want_len) in cases {
            let guard = require_pin("node", "24.0.0", &verification).unwrap_err();
            match &guard {
                LuggageError::VerificationFailed { tier: 2, reason, .. } => {
                    assert!(reason.contains(got_len), "got: {reason}");
                    assert!(reason.contains(want_len), "got: {reason}");
                }
                other => panic!("expected VerificationFailed, got {other:?}"),
            }
            // A digest of the algorithm's real width, so only the pin is wrong.
            let actual =
                "0".repeat(Algorithm::parse(verification.algorithm.as_deref()).unwrap().hex_len());
            let dispatch = verify("node", "24.0.0", &actual, &verification).unwrap_err();
            assert_eq!(format!("{dispatch:?}"), format!("{guard:?}"));
        }
    }

    #[test]
    fn require_pin_accepts_a_sha512_width_pin_on_a_sha512_entry() {
        let pin = "a".repeat(128);
        let v =
            Verification { algorithm: Some("SHA512".into()), ..pinned_verification(Some(&pin)) };
        assert_eq!(require_pin("node", "24.0.0", &v).unwrap(), pin);
    }

    /// An algorithm the digest layer cannot compute is refused by the guard
    /// with the digest layer's own error, rather than only once the download
    /// had started — and `verify` raises the same one.
    #[test]
    fn require_pin_rejects_an_algorithm_the_digest_layer_cannot_compute() {
        for algorithm in ["md5", "sha384"] {
            let v = Verification {
                algorithm: Some(algorithm.into()),
                ..pinned_verification(Some(DIGEST))
            };
            let guard = require_pin("node", "24.0.0", &v).unwrap_err();
            match (algorithm, &guard) {
                ("md5", LuggageError::Catalog(msg)) => assert!(msg.contains("md5"), "got: {msg}"),
                ("sha384", LuggageError::NotImplemented(_)) => {}
                (_, other) => panic!("{algorithm}: unexpected {other:?}"),
            }
            let dispatch = verify("node", "24.0.0", DIGEST, &v).unwrap_err();
            assert_eq!(format!("{dispatch:?}"), format!("{guard:?}"), "{algorithm}");
        }
    }

    /// `require_pin` checks in a fixed order — absent, not hex, algorithm,
    /// width — and each entry here fails two of them, so only the order
    /// decides which error comes back. `verify` must agree on every one.
    #[test]
    fn require_pin_refusal_precedence_with_multiple_failures() {
        let with = |algorithm: &str, pin: Option<&str>| Verification {
            algorithm: Some(algorithm.into()),
            ..pinned_verification(pin)
        };
        let short = &DIGEST[..8];
        let cases = [
            // Absent beats an unparseable algorithm.
            (with("md5", None), "absent"),
            // Not-hex beats an unparseable or unwired algorithm.
            (with("md5", Some("zzzz")), "not hex"),
            (with("sha384", Some("")), "not hex"),
            // The algorithm beats a wrong width.
            (with("sha384", Some(short)), "unwired"),
            (with("md5", Some(short)), "unrecognised"),
        ];
        for (verification, want) in cases {
            let guard = require_pin("node", "24.0.0", &verification).unwrap_err();
            match (want, &guard) {
                ("absent", LuggageError::Catalog(msg)) => {
                    assert!(msg.contains("pinned_checksum"), "got: {msg}");
                }
                ("not hex", LuggageError::VerificationFailed { tier: 2, reason, .. }) => {
                    assert!(reason.contains("not a hex digest"), "got: {reason}");
                }
                ("unwired", LuggageError::NotImplemented(_)) => {}
                ("unrecognised", LuggageError::Catalog(msg)) => {
                    assert!(msg.contains("md5"), "got: {msg}");
                }
                (_, other) => panic!("{want}: unexpected {other:?}"),
            }
            let dispatch = verify("node", "24.0.0", DIGEST, &verification).unwrap_err();
            assert_eq!(format!("{dispatch:?}"), format!("{guard:?}"), "{want}");
        }
    }

    /// An empty pin is the boundary case of the check above: `is_hex_digest`
    /// rejects the empty string specifically so a blank constant cannot match
    /// a blank computed digest and pass.
    #[test]
    fn empty_pin_returns_verification_failed() {
        let err = verify("node", "24.0.0", "", &pinned_verification(Some(""))).unwrap_err();
        assert!(matches!(err, LuggageError::VerificationFailed { tier: 2, .. }));
    }
}
