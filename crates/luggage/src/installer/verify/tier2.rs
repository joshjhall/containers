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

use super::sha::{digests_equal, is_hex_digest};
use crate::error::{LuggageError, Result};

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
///   digest. A malformed pin cannot establish anything, and treating it as a
///   mismatch (rather than as a pass) is what keeps a typo'd constant from
///   silently disabling verification.
/// - [`LuggageError::VerificationFailed`] when the digests differ.
pub fn verify(
    tool: &str,
    version: &str,
    actual_digest: &str,
    verification: &Verification,
) -> Result<()> {
    let pinned = verification.pinned_checksum.as_deref().ok_or_else(|| {
        LuggageError::Catalog(format!(
            "tier 2 verification for {tool}@{version} requires a `pinned_checksum` in the \
             catalog entry"
        ))
    })?;

    let fail = |reason: String| LuggageError::VerificationFailed {
        tool: tool.to_owned(),
        version: version.to_owned(),
        tier: 2,
        reason,
    };

    if !is_hex_digest(pinned) {
        return Err(fail(format!(
            "pinned checksum `{pinned}` is not a hex digest; refusing to treat it as a \
             verification reference"
        )));
    }

    if digests_equal(actual_digest, pinned) {
        Ok(())
    } else {
        Err(fail(format!("digest mismatch: expected {pinned}, computed {actual_digest}")))
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
    /// not pass. A truncated paste or a leaked error string in the slot would
    /// otherwise be compared against and simply mismatch — which is the right
    /// outcome, but the dedicated message is what tells the operator the
    /// *catalog* is wrong rather than the artifact.
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

    /// An empty pin is the boundary case of the check above: `is_hex_digest`
    /// rejects the empty string specifically so a blank constant cannot match
    /// a blank computed digest and pass.
    #[test]
    fn empty_pin_returns_verification_failed() {
        let err = verify("node", "24.0.0", "", &pinned_verification(Some(""))).unwrap_err();
        assert!(matches!(err, LuggageError::VerificationFailed { tier: 2, .. }));
    }
}
