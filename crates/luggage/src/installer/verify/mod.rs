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

/// Dispatch verification by tier.
///
/// `bytes` is the artifact under test; `tool` and `version` are used in
/// error messages. `http` is only consumed by tier 3 (and any future tier
/// that fetches over the network).
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
    bytes: &[u8],
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
) -> Result<()> {
    match verification.tier {
        1 => Err(LuggageError::NotImplemented("tier 1 GPG/sigstore verification")),
        2 => Err(LuggageError::NotImplemented("tier 2 pinned-checksum verification")),
        3 => tier3::verify(tool, version, bytes, verification, subs, http),
        4 => Err(LuggageError::NotImplemented("tier 4 TOFU verification")),
        other => Err(LuggageError::Catalog(format!("unknown verification tier {other}"))),
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
            b"x",
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
            b"x",
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
            b"x",
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
            b"x",
            &verification(9),
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
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
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        };
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        dispatch("rust", "1.95.0", b"hello", &v, &subs, &OkClient).unwrap();
        // Suppress unused-warning for `Mutex`/`HashMap` imports above (kept
        // to mirror the tier3 test fixture style).
        let _: HashMap<&str, &str> = HashMap::new();
        let _: Mutex<()> = Mutex::new(());
    }
}
