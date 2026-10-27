//! 4-tier verification dispatch.
//!
//! Catalog `verification.tier` ranges over `1..=4`:
//!
//! - **tier 1** — signatures. Strongest. **GPG implemented** against a
//!   keyring pinned in the catalog (`gpg_keyring`), either over the artifact
//!   or over a signed checksum manifest — see [`tier1`]. Sigstore is not yet
//!   implemented.
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
pub mod tier1;
pub mod tier2;
pub mod tier3;
pub mod tier4;

use std::path::Path;

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

/// The downloaded artifact, as verification sees it.
///
/// `digest` is its hex digest, computed while it streamed to disk (see
/// [`digest_algorithm`]); `filename` is its on-disk basename, which manifest
/// modes use to select their line; `path` is where it sits, which only tier
/// 1's detached mode reads — it streams the file through the signature check.
/// Tiers 2–4 compare digests and never re-read a possibly-enormous artifact.
#[derive(Debug, Clone, Copy)]
pub struct Artifact<'a> {
    pub digest: &'a str,
    pub filename: &'a str,
    pub path: &'a Path,
}

/// The digest algorithm the download must compute for `verification`.
///
/// For tiers 2–4 that is `verification.algorithm` itself. A tier-1 entry's
/// `algorithm` names the *signature* scheme (`gpg`), not a digest, so it
/// would be rejected by the digest layer; tier 1 needs sha256 because its
/// signed-manifest mode compares against `SHASUMS256.txt` (detached mode
/// does not use the digest at all).
#[must_use]
pub fn digest_algorithm(verification: &Verification) -> Option<&str> {
    if verification.tier == 1 {
        Some(sha::DEFAULT_ALGORITHM)
    } else {
        verification.algorithm.as_deref()
    }
}

/// Fail fast when `verification` is one this build will not satisfy — an
/// unsupported tier, a tier-1 entry with no usable pinned keyring, or a tier-2
/// entry with no usable `pinned_checksum`.
///
/// Called before the artifact is downloaded, for three reasons. First, it keeps
/// the *tier's* error the one the caller sees: the download path derives a
/// [`crate::installer::verify::sha::DigestWriter`] from
/// `verification.algorithm`, and a tier-1 entry legitimately carries
/// `algorithm: "gpg"` — without this check that would surface as a confusing
/// `unrecognised digest algorithm` catalog error from the digest layer instead
/// of the accurate tier-level error. Second, an unusable entry is
/// knowable before any bytes move, so there is no reason to spend a 150MB
/// download discovering it. Third, `require_verified` refuses tier 4 here for
/// the same reason `lib/features/python.sh` refuses before its fetch: an
/// operator who has said "no unverified downloads" should not pay for the
/// download that is about to be rejected.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] for a tier outside `1..=4` — the same error
///   [`dispatch`] returns for it.
/// - For tier 1, whatever `tier1::require_shape` refuses: sigstore
///   ([`LuggageError::NotImplemented`]), a malformed entry
///   ([`LuggageError::Catalog`]), and a `gpg_key_url`-only entry, a missing
///   `catalog_root`, or a keyring path that is absolute, contains `..`, is
///   missing, or escapes the catalog ([`LuggageError::VerificationFailed`]).
///   [`tier1::verify`] runs the same check, so the two cannot disagree.
/// - [`LuggageError::Catalog`] for a tier-2 entry with no `pinned_checksum`,
///   [`LuggageError::VerificationFailed`] for one whose pin is not a hex
///   digest or not the width of `verification.algorithm`'s digest, and
///   whatever [`sha::Algorithm::parse`] rejects for that algorithm — the same
///   errors [`tier2::verify`] raises, built by the same `tier2::require_pin`,
///   so the guard and dispatch cannot disagree about them.
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
    catalog_root: Option<&Path>,
) -> Result<()> {
    match verification.tier {
        // A signature against a pinned key is the strongest verified download,
        // so tier 1 needs no `require_verified` arm either.
        1 => tier1::require_shape(tool, version, verification, catalog_root).map(|_| ()),
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
        // A tier-2 entry with no pin, or a pin that isn't a digest of the
        // algorithm's width, can never pass, and that is knowable from the
        // catalog alone — refuse it now
        // rather than after the download.
        // Tier 2 needs no `require_verified` arm: a pinned checksum *is* a
        // verified download, so it satisfies the strict posture rather than
        // being excused from it.
        2 => tier2::require_pin(tool, version, verification).map(|_| ()),
        // Both are implemented and, at this point, permitted. Tier 4's
        // *weakness* is not this guard's business — it is surfaced at
        // verification time as a warning (see `tier4`), not by refusing here.
        3..=4 => Ok(()),
        other => Err(unsupported_tier(other)),
    }
}

/// The error for a tier outside `1..=4`.
///
/// Single source of truth so [`ensure_supported`] and [`dispatch`] cannot drift
/// into reporting different things about the same tier.
fn unsupported_tier(tier: u8) -> LuggageError {
    LuggageError::Catalog(format!("unknown verification tier {tier}"))
}

/// Dispatch verification by tier.
///
/// `artifact` carries the digest computed during download, the on-disk
/// basename manifest modes select by, and the path tier 1's detached mode
/// streams through the signature check (see [`Artifact`]).
///
/// `tool` and `version` are used in error messages. `http` is consumed by
/// tiers 1 and 3, which fetch a signature or checksum file. `catalog_root` is
/// where tier 1 finds the entry's pinned `gpg_keyring`; other tiers ignore it.
///
/// Returns the warnings the verification produced — empty for tiers 1–3, one
/// entry for a tier-4 acceptance (see the module docs).
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.tier` is not in `1..=4`.
/// - The same errors each tier raises: tier 1 (see [`tier1::verify`]), tier 2
///   (see [`tier2::verify`]), tier 3 (see [`tier3::verify`]), tier 4 (see
///   [`tier4::verify`]).
pub fn dispatch(
    tool: &str,
    version: &str,
    artifact: &Artifact<'_>,
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
    catalog_root: Option<&Path>,
) -> Result<Vec<VerificationWarning>> {
    match verification.tier {
        1 => {
            tier1::verify(tool, version, artifact, verification, subs, http, catalog_root)?;
            Ok(Vec::new())
        }
        2 => {
            tier2::verify(tool, version, artifact.digest, verification)?;
            Ok(Vec::new())
        }
        3 => {
            tier3::verify(
                tool,
                version,
                artifact.digest,
                artifact.filename,
                verification,
                subs,
                http,
            )?;
            Ok(Vec::new())
        }
        4 => Ok(vec![tier4::verify(tool, version, artifact.digest, verification)?]),
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
            gpg_keyring: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        }
    }

    /// Sigstore is the half of tier 1 that is still out of scope; it must say
    /// so rather than fall through to the GPG path or pass.
    #[test]
    fn tier_1_sigstore_returns_not_implemented() {
        let v = Verification { algorithm: Some("sigstore".into()), ..verification(1) };
        let err = dispatch(
            "rust",
            "1.95.0",
            &Artifact {
                digest: "deadbeef",
                filename: "artifact.tar.gz",
                path: Path::new("artifact.tar.gz"),
            },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(m) if m.contains("sigstore")));
    }

    /// In the installer [`ensure_supported`] now refuses this entry first; this
    /// pins `dispatch`'s own fail-closed behaviour for any direct caller.
    ///
    /// A tier-2 entry that reaches `dispatch` with no pin is catalog drift —
    /// the tier is implemented, so the error must be `Catalog`, not
    /// `NotImplemented`.
    #[test]
    fn tier_2_without_a_pin_is_a_catalog_error() {
        let err = dispatch(
            "rust",
            "1.95.0",
            &Artifact {
                digest: "deadbeef",
                filename: "artifact.tar.gz",
                path: Path::new("artifact.tar.gz"),
            },
            &verification(2),
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)), "got {err:?}");
    }

    /// `stage_verify` only ever reaches tier 2 through `dispatch`, so the
    /// mismatch must surface here exactly as `tier2::verify` raised it — not
    /// swallowed, and not downgraded to a warning.
    #[test]
    fn tier_2_mismatch_via_dispatch_is_verification_failed() {
        let pin = super::sha::digest_hex(Some("sha256"), b"hello").unwrap();
        let v = Verification { pinned_checksum: Some(pin), ..verification(2) };
        let err = dispatch(
            "node",
            "24.0.0",
            &Artifact {
                digest: &"0".repeat(64),
                filename: "node.tar.gz",
                path: Path::new("node.tar.gz"),
            },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier, tool, version, reason } => {
                assert_eq!(tier, 2);
                assert_eq!(tool, "node");
                assert_eq!(version, "24.0.0");
                assert!(reason.contains("digest mismatch"), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    /// A malformed pin must likewise stay a hard failure through `dispatch` —
    /// a typo'd constant that read as a pass or a warning here would silently
    /// disable verification for that entry.
    #[test]
    fn tier_2_malformed_pin_via_dispatch_is_verification_failed() {
        let v = Verification { pinned_checksum: Some("not-a-digest".into()), ..verification(2) };
        let err = dispatch(
            "node",
            "24.0.0",
            &Artifact {
                digest: "deadbeef",
                filename: "node.tar.gz",
                path: Path::new("node.tar.gz"),
            },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 2, reason, .. } => {
                assert!(reason.contains("not a hex digest"), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
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
            &Artifact { digest: "deadbeef", filename: "get-pip.py", path: Path::new("get-pip.py") },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
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
            &Artifact { digest: &digest, filename: "node.tar.gz", path: Path::new("node.tar.gz") },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap();
        assert!(warnings.is_empty(), "expected empty, got {warnings:?}");
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
            &Artifact { digest: &digest, filename: "node.tar.gz", path: Path::new("node.tar.gz") },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap();
    }

    #[test]
    fn unknown_tier_returns_catalog_error() {
        let err = dispatch(
            "rust",
            "1.95.0",
            &Artifact {
                digest: "deadbeef",
                filename: "artifact.tar.gz",
                path: Path::new("artifact.tar.gz"),
            },
            &verification(9),
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    /// A tier-2 entry carrying a pin — what every real tier-2 catalog entry
    /// looks like. `verification(2)` alone has no pin and is refused.
    fn pinned_tier_2() -> Verification {
        Verification {
            pinned_checksum: Some(super::sha::digest_hex(Some("sha256"), b"pinned").unwrap()),
            ..verification(2)
        }
    }

    #[test]
    fn ensure_supported_accepts_tier_2() {
        ensure_supported("node", "24.0.0", &pinned_tier_2(), false, None).unwrap();
    }

    /// The width check must accept a correct non-default width, not just
    /// refuse wrong ones — in both postures, and exactly where dispatch would
    /// go on to pass the matching artifact.
    #[test]
    fn ensure_supported_accepts_a_sha512_width_pin_on_a_sha512_entry() {
        let pin = super::sha::digest_hex(Some("sha512"), b"pinned").unwrap();
        let v = Verification {
            algorithm: Some("sha512".into()),
            pinned_checksum: Some(pin.clone()),
            ..verification(2)
        };
        for strict in [false, true] {
            ensure_supported("node", "24.0.0", &v, strict, None)
                .unwrap_or_else(|e| panic!("strict={strict}: {e:?}"));
        }
        let warnings = dispatch(
            "node",
            "24.0.0",
            &Artifact {
                digest: &pin,
                filename: "artifact.tar.gz",
                path: Path::new("artifact.tar.gz"),
            },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap();
        assert!(warnings.is_empty(), "got: {warnings:?}");
    }

    /// A pinless tier-2 entry can never pass dispatch, so the guard must refuse
    /// it before the download — in both postures, since strict mode only ever
    /// adds refusals.
    #[test]
    fn ensure_supported_refuses_tier_2_without_a_pin() {
        for strict in [false, true] {
            let err =
                ensure_supported("node", "24.0.0", &verification(2), strict, None).unwrap_err();
            match err {
                LuggageError::Catalog(ref msg) => {
                    assert!(msg.contains("pinned_checksum"), "got: {msg}");
                    assert!(msg.contains("node@24.0.0"), "got: {msg}");
                }
                other => panic!("expected Catalog (strict={strict}), got {other:?}"),
            }
        }
    }

    /// The early refusal must be the error dispatch raises for the same entry,
    /// not a near-copy of it.
    #[test]
    fn ensure_supported_refuses_a_pinless_tier_2_exactly_as_dispatch_does() {
        let v = verification(2);
        let guard = ensure_supported("node", "24.0.0", &v, false, None).unwrap_err();
        let dispatched = dispatch(
            "node",
            "24.0.0",
            &Artifact {
                digest: "deadbeef",
                filename: "artifact.tar.gz",
                path: Path::new("artifact.tar.gz"),
            },
            &v,
            &Substitutions::default(),
            &DeadClient,
            None,
        )
        .unwrap_err();
        assert_eq!(guard.to_string(), dispatched.to_string());
    }

    /// A pin that is present but not a digest is just as knowable from the
    /// catalog as a missing one, so the guard refuses it too (#1041) — in both
    /// postures.
    #[test]
    fn ensure_supported_refuses_a_malformed_tier_2_pin() {
        let v = Verification { pinned_checksum: Some("not-a-digest".into()), ..verification(2) };
        for strict in [false, true] {
            match ensure_supported("node", "24.0.0", &v, strict, None).unwrap_err() {
                LuggageError::VerificationFailed { tier: 2, ref reason, .. } => {
                    assert!(reason.contains("not a hex digest"), "got: {reason}");
                }
                other => panic!("expected VerificationFailed (strict={strict}), got {other:?}"),
            }
        }
    }

    /// The early malformed-pin refusal must be dispatch's error, variant and
    /// all — a `Catalog` error with similar text would classify differently.
    #[test]
    fn ensure_supported_refuses_a_malformed_pin_exactly_as_dispatch_does() {
        for pin in ["", "not-a-digest"] {
            let v = Verification { pinned_checksum: Some(pin.into()), ..verification(2) };
            let guard = ensure_supported("node", "24.0.0", &v, false, None).unwrap_err();
            let dispatched = dispatch(
                "node",
                "24.0.0",
                &Artifact {
                    digest: "deadbeef",
                    filename: "artifact.tar.gz",
                    path: Path::new("artifact.tar.gz"),
                },
                &v,
                &Substitutions::default(),
                &DeadClient,
                None,
            )
            .unwrap_err();
            assert!(
                matches!(guard, LuggageError::VerificationFailed { tier: 2, .. }),
                "pin {pin:?}: guard gave {guard:?}"
            );
            assert!(
                matches!(dispatched, LuggageError::VerificationFailed { tier: 2, .. }),
                "pin {pin:?}: dispatch gave {dispatched:?}"
            );
            assert_eq!(guard.to_string(), dispatched.to_string(), "pin {pin:?}");
        }
    }

    /// The width and algorithm refusals (#1311) hold the same contract at this
    /// boundary: dispatch's exact error, in both postures.
    #[test]
    fn ensure_supported_refuses_an_unusable_pin_width_exactly_as_dispatch_does() {
        let sha256 = super::sha::digest_hex(Some("sha256"), b"pinned").unwrap();
        let sha512 = super::sha::digest_hex(Some("sha512"), b"pinned").unwrap();
        let cases = [
            (None, "9f86d081".to_owned()),
            (None, sha512),
            (Some("sha512"), sha256.clone()),
            (Some("md5"), sha256.clone()),
            (Some("sha384"), sha256),
        ];
        for (algorithm, pin) in cases {
            let v = Verification {
                algorithm: algorithm.map(Into::into),
                pinned_checksum: Some(pin),
                ..verification(2)
            };
            let dispatched = dispatch(
                "node",
                "24.0.0",
                &Artifact {
                    digest: "deadbeef",
                    filename: "artifact.tar.gz",
                    path: Path::new("artifact.tar.gz"),
                },
                &v,
                &Substitutions::default(),
                &DeadClient,
                None,
            )
            .unwrap_err();
            for strict in [false, true] {
                let guard = ensure_supported("node", "24.0.0", &v, strict, None).unwrap_err();
                assert_eq!(
                    format!("{guard:?}"),
                    format!("{dispatched:?}"),
                    "algorithm {algorithm:?}, strict={strict}"
                );
            }
        }
    }

    /// Strict mode demands verified downloads; a pinned checksum *is* one, so
    /// the guard must let tier 2 through rather than treating "stricter" as
    /// "fewer tiers". This is the case #849 exists for: the operator who hits
    /// the tier-4 refusal and follows its advice to pin a checksum must end up
    /// with a build that passes.
    #[test]
    fn strict_mode_accepts_tier_2() {
        ensure_supported("node", "24.0.0", &pinned_tier_2(), true, None).unwrap();
    }

    #[test]
    fn ensure_supported_accepts_tier_3() {
        ensure_supported("rust", "1.95.0", &verification(3), false, None).unwrap();
    }

    #[test]
    fn ensure_supported_accepts_tier_4_when_not_strict() {
        ensure_supported("python", "3.13.0", &verification(4), false, None).unwrap();
    }

    /// Strict mode turns a TOFU acceptance into a hard failure, and the
    /// failure has to tell the operator how to get out of it — otherwise the
    /// refusal is just an unexplained wall.
    #[test]
    fn strict_mode_refuses_tier_4_and_names_the_pin_remedy() {
        let err = ensure_supported("python", "3.13.0", &verification(4), true, None).unwrap_err();
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
        let err = ensure_supported("python", "3.13.0", &verification(4), true, None).unwrap_err();
        assert_eq!(crate::error::ErrorClass::from(&err), crate::error::ErrorClass::Verify);
    }

    /// Strict mode is about TOFU only — it must not start rejecting tier 3.
    #[test]
    fn strict_mode_leaves_tier_3_alone() {
        ensure_supported("rust", "1.95.0", &verification(3), true, None).unwrap();
    }

    /// The guard must reject exactly what `dispatch` rejects, with the same
    /// error — that equivalence is the whole point of routing both through
    /// `unsupported_tier`.
    #[test]
    fn ensure_supported_rejects_the_same_tiers_dispatch_does() {
        // Tier 2 left this set in #849: it is supported, so a pinless tier-2
        // entry is refused for its missing pin rather than for its tier — that
        // equivalence is covered by
        // `ensure_supported_refuses_a_pinless_tier_2_exactly_as_dispatch_does`.
        // Tier 1's shape check is shared the same way (`tier1::require_shape`);
        // a bare tier-1 entry has no `algorithm`, which both must refuse.
        for tier in [1u8, 9] {
            let v = verification(tier);
            let guard = ensure_supported("rust", "1.95.0", &v, false, None).unwrap_err();
            let dispatched = dispatch(
                "rust",
                "1.95.0",
                &Artifact {
                    digest: "deadbeef",
                    filename: "artifact.tar.gz",
                    path: Path::new("artifact.tar.gz"),
                },
                &v,
                &Substitutions::default(),
                &DeadClient,
                None,
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
    /// algorithm. The guard must report what is wrong with the TIER-1 entry
    /// rather than letting the digest layer complain about `gpg` (the
    /// regression this check exists to prevent) — and the download must hash
    /// with sha256, not `gpg`.
    #[test]
    fn tier_1_with_gpg_algorithm_reports_the_tier_not_the_algorithm() {
        let v = Verification { algorithm: Some("gpg".into()), ..verification(1) };
        let err = ensure_supported("rust", "1.95.0", &v, false, None).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => {
                assert!(msg.contains("signature_url_template"), "got: {msg}");
            }
            other => panic!("expected Catalog, got {other:?}"),
        }
        assert_eq!(digest_algorithm(&v), Some("sha256"));
        assert_eq!(
            digest_algorithm(&Verification { algorithm: Some("sha512".into()), ..verification(3) }),
            Some("sha512")
        );
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
            gpg_keyring: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        };
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let digest = super::sha::digest_hex(Some("sha256"), b"hello").unwrap();
        let warnings = dispatch(
            "rust",
            "1.95.0",
            &Artifact { digest: &digest, filename: "rustup-init", path: Path::new("rustup-init") },
            &v,
            &subs,
            &OkClient,
            None,
        )
        .unwrap();
        // Tier 3 verified against an external reference, so it has nothing to
        // warn about — only tier 4 does.
        assert!(warnings.is_empty(), "expected empty, got {warnings:?}");
        // Suppress unused-warning for `Mutex`/`HashMap` imports above (kept
        // to mirror the tier3 test fixture style).
        let _: HashMap<&str, &str> = HashMap::new();
        let _: Mutex<()> = Mutex::new(());
    }
}
