//! Tier 4 — TOFU (trust on first use) verification.
//!
//! The weakest tier. There is no external reference to compare against: the
//! publisher serves no checksum, so the only digest available is the one
//! computed over the bytes we just downloaded. Verifying a digest against
//! itself proves the artifact did not change *between download and use inside
//! this run* — it proves nothing about **authenticity**. A
//! machine-in-the-middle, a compromised mirror, or a compromised upstream all
//! sail straight through.
//!
//! It exists because some publishers genuinely ship nothing better. `PyPA`'s
//! `get-pip.py` is the motivating case (`lib/features/python.sh`), and the bash
//! implementation this ports (`lib/base/checksum-tier4.sh`) handles it the same
//! way: accept, but *loudly*, and refuse outright under
//! `REQUIRE_VERIFIED_DOWNLOADS`.
//!
//! Two properties are therefore load-bearing here, and both are the point of
//! the issue that added this module:
//!
//! - **Acceptance is never silent.** It returns a [`VerificationWarning`] that
//!   the installer both logs and records in the install report, so a TOFU
//!   artifact is visible to `--json-report` consumers and the evidence
//!   pipeline — not just to whoever was watching the console.
//! - **It fails closed.** A tier-4 catalog entry without the explicit
//!   `tofu: true` acknowledgment, or with a digest that isn't a digest, is an
//!   error rather than a pass.
//!
//! The strict-mode refusal itself lives in
//! [`super::ensure_supported`], not here — it must fire *before* the download,
//! the way the bash script refuses before spending the fetch.

use containers_common::tooldb::Verification;

use super::VerificationWarning;
use super::sha::{DEFAULT_ALGORITHM, is_hex_digest};
use crate::error::{LuggageError, Result};

/// Accept a TOFU artifact, returning the warning that acceptance must carry.
///
/// `actual_digest` is the artifact's hex digest, computed while it streamed to
/// disk (see [`crate::installer::download::DigestingFileSink`]). As in tier 3,
/// taking the digest rather than the bytes is what keeps peak memory
/// independent of artifact size — and here it is also the *only* digest that
/// exists, since there is nothing to fetch and compare against.
///
/// `tool` and `version` are recorded on the warning and used in error
/// messages.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.tofu` is not `Some(true)`.
///   The catalog schema requires that explicit acknowledgment on every tier-4
///   entry, so its absence is drift — and the fail-closed reading is the only
///   safe one: an entry that never said "yes, I accept TOFU here" must not get
///   TOFU by accident.
/// - [`LuggageError::VerificationFailed`] when `actual_digest` is empty or not
///   hex. There is no external digest to compare against, so this
///   well-formedness check is the only thing standing between a blank digest
///   and a silent pass.
pub fn verify(
    tool: &str,
    version: &str,
    actual_digest: &str,
    verification: &Verification,
) -> Result<VerificationWarning> {
    if verification.tofu != Some(true) {
        return Err(LuggageError::Catalog(format!(
            "tier 4 verification for {tool}@{version} requires an explicit `tofu: true` \
             acknowledgment in the catalog entry"
        )));
    }

    if !is_hex_digest(actual_digest) {
        return Err(LuggageError::VerificationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            tier: 4,
            reason: format!(
                "computed digest `{actual_digest}` is not a hex digest; \
                 refusing to record it as a TOFU baseline"
            ),
        });
    }

    let algorithm_name = verification.algorithm.as_deref().unwrap_or(DEFAULT_ALGORITHM);
    let message = tofu_message(tool, version, algorithm_name, actual_digest);

    Ok(VerificationWarning {
        tier: 4,
        tool: tool.to_owned(),
        version: version.to_owned(),
        algorithm: verification.algorithm.clone(),
        digest: actual_digest.to_owned(),
        message,
    })
}

/// The acceptance warning's text.
///
/// Split out so the wording is testable in one place. It has a job beyond
/// "something happened": whoever reads it — in a build log, in an evidence
/// row, months later — must be able to tell what this verification did and did
/// not establish, without already knowing what TOFU means. So it states the
/// guarantee, states the non-guarantee, and names the remedy.
fn tofu_message(tool: &str, version: &str, algorithm: &str, digest: &str) -> String {
    format!(
        "TIER 4 TOFU: accepted {tool}@{version} on trust-on-first-use \
         ({algorithm}:{digest}). This publisher serves no checksum, so the digest was \
         self-computed from the bytes just downloaded. GUARANTEES: the artifact did not \
         change between download and use in this run. DOES NOT GUARANTEE authenticity — \
         a machine-in-the-middle, a compromised mirror, or a compromised upstream would \
         not be detected. To get real verification, pin a known-good checksum for \
         {tool}@{version} in the catalog (tier 2); to refuse TOFU outright, pass \
         `--require-verified-downloads` (REQUIRE_VERIFIED_DOWNLOADS=true)."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tofu_verification() -> Verification {
        Verification {
            tier: 4,
            algorithm: Some("sha256".into()),
            pinned_checksum: None,
            checksum_url_template: None,
            checksum_manifest: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: Some(true),
        }
    }

    const DIGEST: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    #[test]
    fn accepts_and_returns_the_computed_digest() {
        let w = verify("python", "3.13.0", DIGEST, &tofu_verification()).unwrap();
        assert_eq!(w.tier, 4);
        assert_eq!(w.tool, "python");
        assert_eq!(w.version, "3.13.0");
        assert_eq!(w.digest, DIGEST);
        assert_eq!(w.algorithm.as_deref(), Some("sha256"));
    }

    /// The whole reason tier 4 is allowed to pass at all is that it says out
    /// loud what it is. A message that only announced success would be the
    /// silent-weakening failure this module exists to prevent.
    #[test]
    fn warning_states_both_the_guarantee_and_the_non_guarantee() {
        let w = verify("python", "3.13.0", DIGEST, &tofu_verification()).unwrap();
        let m = w.message.to_lowercase();
        assert!(m.contains("tofu"), "{}", w.message);
        assert!(m.contains("guarantees"), "names what it does guarantee: {}", w.message);
        assert!(
            m.contains("does not guarantee"),
            "names what it does NOT guarantee: {}",
            w.message
        );
        assert!(m.contains("authenticity"), "{}", w.message);
        // And the remedy, so the reader knows what to do about it.
        assert!(m.contains("pin"), "{}", w.message);
        assert!(m.contains("require-verified-downloads"), "{}", w.message);
        // The subject and the evidence.
        assert!(w.message.contains("python@3.13.0"), "{}", w.message);
        assert!(w.message.contains(DIGEST), "{}", w.message);
    }

    #[test]
    fn message_falls_back_to_the_default_algorithm_name() {
        let v = Verification { algorithm: None, ..tofu_verification() };
        let w = verify("python", "3.13.0", DIGEST, &v).unwrap();
        assert!(w.algorithm.is_none());
        assert!(w.message.contains(DEFAULT_ALGORITHM), "{}", w.message);
    }

    /// Fail closed: no explicit acknowledgment, no TOFU.
    #[test]
    fn missing_tofu_acknowledgment_is_a_catalog_error() {
        for tofu in [None, Some(false)] {
            let v = Verification { tofu, ..tofu_verification() };
            let err = verify("python", "3.13.0", DIGEST, &v).unwrap_err();
            match err {
                LuggageError::Catalog(msg) => {
                    assert!(msg.contains("tofu"), "got: {msg}");
                }
                other => panic!("expected Catalog for tofu={tofu:?}, got {other:?}"),
            }
        }
    }

    /// A blank or malformed digest must not read as a successful TOFU
    /// baseline — with nothing to compare against, this check is the only
    /// thing between it and a silent pass.
    #[test]
    fn a_non_digest_is_rejected() {
        for bad in ["", "not-a-digest", "abc123!", " "] {
            let err = verify("python", "3.13.0", bad, &tofu_verification()).unwrap_err();
            match err {
                LuggageError::VerificationFailed { tier, .. } => assert_eq!(tier, 4),
                other => panic!("expected VerificationFailed for {bad:?}, got {other:?}"),
            }
        }
    }

    #[test]
    fn is_hex_digest_accepts_mixed_case_hex_only() {
        assert!(is_hex_digest("DEADbeef00"));
        assert!(!is_hex_digest(""));
        assert!(!is_hex_digest("deadbeeg"));
    }
}
