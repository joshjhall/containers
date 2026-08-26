//! 4-tier verification dispatch.
//!
//! Catalog `verification.tier` ranges over `1..=4`:
//!
//! - **tier 1** — signatures (GPG / sigstore). Strongest. *Deferred to a
//!   follow-up issue.*
//! - **tier 2** — pinned in-repo checksum. *Deferred.*
//! - **tier 3** — publisher-served checksum file. **Implemented** — this
//!   is what rust@1.95.0 uses and the only path the pilot needs.
//! - **tier 4** — TOFU (trust on first use). *Deferred.*
//!
//! Any other tier value is a catalog error.

pub mod sha;
pub mod tier3;

use containers_common::tooldb::Verification;

use crate::error::{LuggageError, Result};
use crate::installer::download::HttpClient;
use crate::installer::template::Substitutions;

/// Fail fast when `verification.tier` is one this build cannot satisfy.
///
/// Called before the artifact is downloaded, for two reasons. First, it keeps
/// the *tier's* error the one the caller sees: the download path now derives a
/// [`crate::installer::verify::sha::DigestWriter`] from
/// `verification.algorithm`, and a tier-1 entry legitimately carries
/// `algorithm: "gpg"` — without this check that would surface as a confusing
/// `unrecognised digest algorithm` catalog error from the digest layer instead
/// of the accurate "tier 1 not implemented". Second, an unsupported tier is
/// knowable before any bytes move, so there is no reason to spend a 150MB
/// download discovering it.
///
/// # Errors
///
/// The same variants [`dispatch`] returns for those tiers:
/// [`LuggageError::NotImplemented`] for tiers 1, 2 and 4, and
/// [`LuggageError::Catalog`] for a tier outside `1..=4`.
pub fn ensure_supported(verification: &Verification) -> Result<()> {
    match verification.tier {
        3 => Ok(()),
        other => Err(unsupported_tier(other)),
    }
}

/// The error for a tier this build does not implement.
///
/// Single source of truth so [`ensure_supported`] and [`dispatch`] cannot drift
/// into reporting different things about the same tier.
fn unsupported_tier(tier: u8) -> LuggageError {
    match tier {
        1 => LuggageError::NotImplemented("tier 1 GPG/sigstore verification"),
        2 => LuggageError::NotImplemented("tier 2 pinned-checksum verification"),
        4 => LuggageError::NotImplemented("tier 4 TOFU verification"),
        other => LuggageError::Catalog(format!("unknown verification tier {other}")),
    }
}

/// Dispatch verification by tier.
///
/// `actual_digest` is the artifact's hex digest, computed while it streamed to
/// disk; `artifact_filename` is its on-disk basename, which manifest-mode tier
/// 3 uses to select its line. Taking a digest rather than `&[u8]` is
/// deliberate: with the bytes out of scope no tier can re-read a
/// possibly-enormous artifact to hash it a second time.
///
/// `tool` and `version` are used in error messages. `http` is only consumed by
/// tier 3 (and any future tier that fetches over the network).
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for tiers 1, 2, 4 — these will be
///   wired up in follow-up issues.
/// - [`LuggageError::Catalog`] when `verification.tier` is not in `1..=4`.
/// - The same errors tier 3 raises (see [`tier3::verify`]) for tier 3.
pub fn dispatch(
    tool: &str,
    version: &str,
    actual_digest: &str,
    artifact_filename: &str,
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
) -> Result<()> {
    match verification.tier {
        3 => {
            tier3::verify(tool, version, actual_digest, artifact_filename, verification, subs, http)
        }
        other => Err(unsupported_tier(other)),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use containers_common::tooldb::Verification;

    use super::*;
    use crate::installer::download::HttpClient;
    use crate::installer::template::Substitutions;

    struct DeadClient;
    impl HttpClient for DeadClient {
        fn get(&self, url: &str) -> Result<Vec<u8>> {
            Err(LuggageError::DownloadFailed {
                url: url.to_owned(),
                attempts: 1,
                message: "dead client".into(),
            })
        }
    }

    fn verification(tier: u8) -> Verification {
        Verification {
            tier,
            algorithm: None,
            pinned_checksum: None,
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
    fn tier_1_returns_not_implemented() {
        let err = dispatch(
            "rust",
            "1.95.0",
            "deadbeef",
            "artifact.tar.gz",
            &verification(1),
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn tier_2_returns_not_implemented() {
        let err = dispatch(
            "rust",
            "1.95.0",
            "deadbeef",
            "artifact.tar.gz",
            &verification(2),
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn tier_4_returns_not_implemented() {
        let err = dispatch(
            "rust",
            "1.95.0",
            "deadbeef",
            "artifact.tar.gz",
            &verification(4),
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn unknown_tier_returns_catalog_error() {
        let err = dispatch(
            "rust",
            "1.95.0",
            "deadbeef",
            "artifact.tar.gz",
            &verification(9),
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn ensure_supported_accepts_tier_3() {
        ensure_supported(&verification(3)).unwrap();
    }

    /// The guard must reject exactly what `dispatch` rejects, with the same
    /// error — that equivalence is the whole point of routing both through
    /// `unsupported_tier`.
    #[test]
    fn ensure_supported_rejects_the_same_tiers_dispatch_does() {
        for tier in [1u8, 2, 4, 9] {
            let v = verification(tier);
            let guard = ensure_supported(&v).unwrap_err();
            let dispatched = dispatch(
                "rust",
                "1.95.0",
                "deadbeef",
                "artifact.tar.gz",
                &v,
                &Substitutions::default(),
                &DeadClient,
            )
            .unwrap_err();
            assert_eq!(
                guard.to_string(),
                dispatched.to_string(),
                "guard and dispatch disagree about tier {tier}"
            );
        }
    }

    /// A tier-1 entry carries `algorithm: "gpg"`, which is not a digest
    /// algorithm. The guard must report the TIER as unimplemented rather than
    /// letting the digest layer complain about `gpg` (the regression this
    /// check exists to prevent).
    #[test]
    fn tier_1_with_gpg_algorithm_reports_the_tier_not_the_algorithm() {
        let v = Verification { algorithm: Some("gpg".into()), ..verification(1) };
        let err = ensure_supported(&v).unwrap_err();
        match err {
            LuggageError::NotImplemented(msg) => {
                assert!(msg.contains("tier 1"), "got: {msg}");
            }
            other => panic!("expected NotImplemented, got {other:?}"),
        }
    }

    /// Through-the-front-door check that tier 3 actually executes when
    /// dispatched (the deeper tier-3 cases live in `tier3::tests`).
    #[test]
    fn tier_3_executes_via_dispatch() {
        struct OkClient;
        impl HttpClient for OkClient {
            fn get(&self, _url: &str) -> Result<Vec<u8>> {
                let digest = super::sha::digest_hex(Some("sha256"), b"hello").unwrap();
                Ok(format!("{digest}  rustup-init\n").into_bytes())
            }
        }
        let v = Verification {
            tier: 3,
            algorithm: Some("sha256".into()),
            pinned_checksum: None,
            checksum_url_template: Some("https://example.test/{rustup_target}/x.sha256".into()),
            checksum_manifest: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        };
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let digest = super::sha::digest_hex(Some("sha256"), b"hello").unwrap();
        dispatch("rust", "1.95.0", &digest, "rustup-init", &v, &subs, &OkClient).unwrap();
        // Suppress unused-warning for `Mutex`/`HashMap` imports above (kept
        // to mirror the tier3 test fixture style).
        let _: HashMap<&str, &str> = HashMap::new();
        let _: Mutex<()> = Mutex::new(());
    }
}
