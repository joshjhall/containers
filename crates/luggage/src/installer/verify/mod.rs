//! 4-tier verification dispatch.
//!
//! Catalog `verification.tier` ranges over `1..=4`:
//!
//! - **tier 1** — signatures (GPG / sigstore). Strongest. *Deferred to a
//!   follow-up issue.*
//! - **tier 2** — pinned in-repo checksum. **Implemented** — the digest is a
//!   constant that landed through code review, so verification fetches
//!   nothing and does not trust the publisher's endpoint at fetch time. This
//!   is the remedy tier 4's warning and the strict-mode refusal point at.
//! - **tier 3** — publisher-served checksum file. **Implemented** — this
//!   is what rust@1.95.0 uses.
//! - **tier 4** — TOFU (trust on first use). **Implemented** — the weakest
//!   tier, for publishers that serve no checksum at all (`PyPA`'s
//!   `get-pip.py`).
//!   Accepts only *loudly*: see [`tier4`] and [`VerificationWarning`].
//!
//! Any other tier value is a catalog error.
//!
//! # Why dispatch returns warnings
//!
//! [`dispatch`] returns `Vec<VerificationWarning>` rather than `()`. Tiers 1–3
//! either verify against something external or fail, so they have nothing to
//! say and return an empty vec. Tier 4 has no external reference — its
//! "success" is materially weaker than the others', and the caller has to be
//! able to tell. Returning that fact as data (rather than only printing it) is
//! what lets the installer put it in the install report, where `--json-report`
//! consumers and the evidence pipeline can see that a TOFU artifact was
//! accepted.

pub mod sha;
pub mod tier2;
pub mod tier3;
pub mod tier4;

use containers_common::tooldb::Verification;

use crate::error::{LuggageError, Result};
use crate::installer::download::HttpClient;
use crate::installer::template::Substitutions;

/// A verification that succeeded, but on weaker grounds than a caller should
/// assume without being told.
///
/// Currently only tier 4 (TOFU) produces one. It is carried on
/// [`crate::InstallReport::warnings`] so the acceptance survives past the
/// console into the JSON report and the evidence row — a TOFU artifact that
/// was only ever mentioned in build output is one nobody finds later.
///
/// Defined in `containers-common` because
/// [`containers_common::tooldb::TestEntry`] carries it too and that crate
/// cannot depend on `luggage`; re-exported here (and from the crate root) so
/// luggage's public API is unchanged.
pub use containers_common::tooldb::VerificationWarning;

/// Fail fast when `verification.tier` is one this build will not satisfy.
///
/// Called before the artifact is downloaded, for three reasons. First, it keeps
/// the *tier's* error the one the caller sees: the download path derives a
/// [`crate::installer::verify::sha::DigestWriter`] from
/// `verification.algorithm`, and a tier-1 entry legitimately carries
/// `algorithm: "gpg"` — without this check that would surface as a confusing
/// `unrecognised digest algorithm` catalog error from the digest layer instead
/// of the accurate "tier 1 not implemented". Second, an unsupported tier is
/// knowable before any bytes move, so there is no reason to spend a 150MB
/// download discovering it. Third, `require_verified` refuses tier 4 here for
/// the same reason `lib/features/python.sh` refuses before its fetch: an
/// operator who has said "no unverified downloads" should not pay for the
/// download that is about to be rejected.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for tier 1, and
///   [`LuggageError::Catalog`] for a tier outside `1..=4` — the same variants
///   [`dispatch`] returns for those tiers.
/// - [`LuggageError::VerificationFailed`] for tier 4 when `require_verified`
///   is set. This is a *policy* refusal of a supported tier, not an
///   unimplemented one, so it is deliberately not a `NotImplemented`: it maps
///   to [`crate::ErrorClass::Verify`] and so classifies correctly in an
///   evidence row.
pub fn ensure_supported(
    tool: &str,
    version: &str,
    verification: &Verification,
    require_verified: bool,
) -> Result<()> {
    match verification.tier {
        4 if require_verified => Err(LuggageError::VerificationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            tier: 4,
            reason: "tier 4 TOFU verification is not allowed while verified downloads are \
                     required: this publisher serves no checksum, so nothing establishes the \
                     artifact's authenticity. Pin a known-good checksum for it in the catalog \
                     (tier 2), or — to accept the risk — drop the \
                     `--require-verified-downloads` flag and set \
                     REQUIRE_VERIFIED_DOWNLOADS=false"
                .to_owned(),
        }),
        // All three are implemented and, at this point, permitted. Tier 4's
        // *weakness* is not this guard's business — it is surfaced at
        // verification time as a warning (see `tier4`), not by refusing here.
        // Tier 2 needs no `require_verified` arm: a pinned checksum *is* a
        // verified download, so it satisfies the strict posture rather than
        // being excused from it.
        2..=4 => Ok(()),
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
/// Returns the warnings the verification produced — empty for tiers 1–3, one
/// entry for a tier-4 acceptance (see the module docs).
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for tier 1 — wired up in a follow-up
///   issue.
/// - [`LuggageError::Catalog`] when `verification.tier` is not in `1..=4`.
/// - The same errors each implemented tier raises: tier 2 (see
///   [`tier2::verify`]), tier 3 (see [`tier3::verify`]), tier 4 (see
///   [`tier4::verify`]).
pub fn dispatch(
    tool: &str,
    version: &str,
    actual_digest: &str,
    artifact_filename: &str,
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
) -> Result<Vec<VerificationWarning>> {
    match verification.tier {
        2 => {
            tier2::verify(tool, version, actual_digest, verification)?;
            Ok(Vec::new())
        }
        3 => {
            tier3::verify(
                tool,
                version,
                actual_digest,
                artifact_filename,
                verification,
                subs,
                http,
            )?;
            Ok(Vec::new())
        }
        4 => Ok(vec![tier4::verify(tool, version, actual_digest, verification)?]),
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

    /// Tier 1 (GPG/sigstore) stays out of scope. #849 moved tier 2 out of the
    /// unimplemented set; this is what keeps tier 1 from being swept along
    /// with it.
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

    /// A tier-2 entry that reaches `dispatch` with no pin is catalog drift —
    /// the tier is implemented, so the error must be `Catalog`, not
    /// `NotImplemented`.
    #[test]
    fn tier_2_without_a_pin_is_a_catalog_error() {
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
        assert!(matches!(err, LuggageError::Catalog(_)), "got {err:?}");
    }

    /// Tier 4 is implemented now, and dispatching it must surface the
    /// acceptance as a warning rather than as a bare `Ok` — a silent tier-4
    /// pass is precisely the weakening this tier's implementation guards
    /// against.
    #[test]
    fn tier_4_dispatches_and_returns_one_warning() {
        let v = Verification { tofu: Some(true), ..verification(4) };
        let warnings = dispatch(
            "python",
            "3.13.0",
            "deadbeef",
            "get-pip.py",
            &v,
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap();
        assert_eq!(warnings.len(), 1);
        assert_eq!(warnings[0].tier, 4);
        assert_eq!(warnings[0].digest, "deadbeef");
    }

    /// Through-the-front-door check that tier 2 actually executes when
    /// dispatched, and — the part that matters for the report — that it adds
    /// no warning. Only tier 4's materially-weaker acceptance does.
    /// (The deeper tier-2 cases live in `tier2::tests`.)
    #[test]
    fn tier_2_executes_via_dispatch() {
        let digest = super::sha::digest_hex(Some("sha256"), b"hello").unwrap();
        let v = Verification { pinned_checksum: Some(digest.clone()), ..verification(2) };
        let warnings = dispatch(
            "node",
            "24.0.0",
            &digest,
            "node.tar.gz",
            &v,
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap();
        assert!(warnings.is_empty());
    }

    /// Tier 2 fetches nothing, so dispatching it must not touch the HTTP
    /// client at all — that offline property is what distinguishes it from
    /// tier 3 operationally, and it is the reason a pin does not trust the
    /// publisher's endpoint at fetch time.
    #[test]
    fn tier_2_dispatch_makes_no_http_request() {
        let digest = super::sha::digest_hex(Some("sha256"), b"offline").unwrap();
        let v = Verification { pinned_checksum: Some(digest.clone()), ..verification(2) };
        // Every `DeadClient::get` returns `DownloadFailed`, so any fetch would
        // surface here as an `Err`. Reaching `Ok` proves none was made.
        dispatch(
            "node",
            "24.0.0",
            &digest,
            "node.tar.gz",
            &v,
            &Substitutions::default(),
            &DeadClient,
        )
        .unwrap();
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
    fn ensure_supported_accepts_tier_2() {
        ensure_supported("node", "24.0.0", &verification(2), false).unwrap();
    }

    /// Strict mode demands verified downloads; a pinned checksum *is* one, so
    /// the guard must let tier 2 through rather than treating "stricter" as
    /// "fewer tiers". This is the case #849 exists for: the operator who hits
    /// the tier-4 refusal and follows its advice to pin a checksum must end up
    /// with a build that passes.
    #[test]
    fn strict_mode_accepts_tier_2() {
        ensure_supported("node", "24.0.0", &verification(2), true).unwrap();
    }

    #[test]
    fn ensure_supported_accepts_tier_3() {
        ensure_supported("rust", "1.95.0", &verification(3), false).unwrap();
    }

    #[test]
    fn ensure_supported_accepts_tier_4_when_not_strict() {
        ensure_supported("python", "3.13.0", &verification(4), false).unwrap();
    }

    /// Strict mode turns a TOFU acceptance into a hard failure, and the
    /// failure has to tell the operator how to get out of it — otherwise the
    /// refusal is just an unexplained wall.
    #[test]
    fn strict_mode_refuses_tier_4_and_names_the_pin_remedy() {
        let err = ensure_supported("python", "3.13.0", &verification(4), true).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier, ref tool, ref version, ref reason } => {
                assert_eq!(tier, 4);
                assert_eq!(tool, "python");
                assert_eq!(version, "3.13.0");
                let r = reason.to_lowercase();
                assert!(r.contains("pin"), "names the pin remedy: {reason}");
                assert!(r.contains("require-verified-downloads"), "{reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
        // The whole error, as rendered, must still identify the tool.
        assert!(err.to_string().contains("python@3.13.0"), "{err}");
    }

    /// The refusal is a policy decision about a *supported* tier, so it must
    /// classify as a verification failure in the evidence row — not land in
    /// `Unknown` the way `NotImplemented` does.
    #[test]
    fn strict_mode_refusal_classifies_as_a_verify_error() {
        let err = ensure_supported("python", "3.13.0", &verification(4), true).unwrap_err();
        assert_eq!(crate::error::ErrorClass::from(&err), crate::error::ErrorClass::Verify);
    }

    /// Strict mode is about TOFU only — it must not start rejecting tier 3.
    #[test]
    fn strict_mode_leaves_tier_3_alone() {
        ensure_supported("rust", "1.95.0", &verification(3), true).unwrap();
    }

    /// The guard must reject exactly what `dispatch` rejects, with the same
    /// error — that equivalence is the whole point of routing both through
    /// `unsupported_tier`.
    #[test]
    fn ensure_supported_rejects_the_same_tiers_dispatch_does() {
        // Tier 2 left this set in #849. The guard answers "is this tier
        // supported", which tier 2 now is; whether a *particular* tier-2 entry
        // carries a usable pin is a dispatch-time question (see
        // `tier_2_without_a_pin_is_a_catalog_error`), so the two legitimately
        // differ there and only the unsupported tiers belong here.
        for tier in [1u8, 9] {
            let v = verification(tier);
            let guard = ensure_supported("rust", "1.95.0", &v, false).unwrap_err();
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
        let err = ensure_supported("rust", "1.95.0", &v, false).unwrap_err();
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
        let warnings =
            dispatch("rust", "1.95.0", &digest, "rustup-init", &v, &subs, &OkClient).unwrap();
        // Tier 3 verified against an external reference, so it has nothing to
        // warn about — only tier 4 does.
        assert!(warnings.is_empty());
        // Suppress unused-warning for `Mutex`/`HashMap` imports above (kept
        // to mirror the tier3 test fixture style).
        let _: HashMap<&str, &str> = HashMap::new();
        let _: Mutex<()> = Mutex::new(());
    }
}
