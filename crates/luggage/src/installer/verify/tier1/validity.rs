//! Signature and key-validity checks for tier 1: the data signature's own
//! policy, issuer matching, and the signer's self-signature, lifetime and
//! revocation rules. See the module docs in [`super`].

use std::io::Read;
use std::path::Path;

use pgp::composed::{SignedPublicKey, SignedPublicSubKey};
use pgp::crypto::hash::HashAlgorithm;
use pgp::packet::{RevocationCode, Signature, SignatureType};
use pgp::types::{KeyDetails, Tag, VerifyingKey};

use crate::error::{LuggageError, Result};

/// Why [`check_signature`] refused. `Io` stays an I/O error rather than being
/// folded into a verification failure, so a disk problem is not misreported
/// as a bad signature.
#[derive(Debug)]
pub(super) enum CheckError {
    Refused(String),
    Io(LuggageError),
}

impl CheckError {
    pub(super) fn into_error(self, fail: &impl Fn(String) -> LuggageError) -> LuggageError {
        match self {
            Self::Refused(reason) => fail(reason),
            Self::Io(e) => e,
        }
    }
}

impl From<String> for CheckError {
    fn from(reason: String) -> Self {
        Self::Refused(reason)
    }
}

/// One key in the keyring that could have made a signature.
#[derive(Clone, Copy)]
pub(super) enum Signer<'k> {
    Primary(&'k SignedPublicKey),
    Subkey(&'k SignedPublicKey, &'k SignedPublicSubKey),
}

impl Signer<'_> {
    fn verifying_key(&self) -> &dyn VerifyingKeyDyn {
        match self {
            Self::Primary(cert) => &cert.primary_key,
            Self::Subkey(_, sub) => &sub.key,
        }
    }
}

/// Object-safe shim so [`Signer`] can hand out either key type for
/// [`Signature::verify`], whose `impl VerifyingKey` argument is not object
/// safe on its own.
trait VerifyingKeyDyn {
    fn verify_data(&self, sig: &Signature, data: &mut dyn Read) -> pgp::errors::Result<()>;
    fn fingerprint_hex(&self) -> String;
}

impl<K: VerifyingKey> VerifyingKeyDyn for K {
    fn verify_data(&self, sig: &Signature, data: &mut dyn Read) -> pgp::errors::Result<()> {
        sig.verify(self, data)
    }
    fn fingerprint_hex(&self) -> String {
        format!("{:X}", self.fingerprint())
    }
}

/// Check `sig` over the bytes `open` yields against `keys`, at time `now`.
///
/// `open` is called once per candidate key so a streamed artifact can be
/// re-read in the (vanishingly rare) case two keyring entries share a key ID.
pub(super) fn check_signature<'d>(
    sig: &Signature,
    keys: &[SignedPublicKey],
    keyring: &Path,
    now: u64,
    mut open: impl FnMut() -> Result<Box<dyn Read + 'd>>,
) -> std::result::Result<(), CheckError> {
    if sig.typ() != Some(SignatureType::Binary) {
        return Err(format!(
            "signature type is {:?}; only binary-mode detached signatures are accepted",
            sig.typ()
        )
        .into());
    }
    if let Some(alg @ (HashAlgorithm::Md5 | HashAlgorithm::Sha1 | HashAlgorithm::Ripemd160)) =
        sig.hash_alg()
    {
        return Err(format!("signature uses broken hash algorithm {alg:?}").into());
    }
    let created = sig
        .created()
        .map(|t| u64::from(t.as_secs()))
        .ok_or_else(|| "signature carries no creation time".to_owned())?;
    if let Some(end) = expiry(created, sig.signature_expiration_time())
        && now >= end
    {
        return Err(format!("signature expired at unix time {end}").into());
    }

    // An issuer-less signature would make `Signature::verify` try every key;
    // requiring one keeps "which pinned key vouched for this" answerable.
    let issuer = issuer_label(sig).ok_or_else(|| "signature names no issuer".to_owned())?;
    let candidates = issuer_candidates(sig, keys);
    if candidates.is_empty() {
        return Err(format!(
            "signed by {issuer}, which is not in the pinned keyring {}",
            keyring.display()
        )
        .into());
    }

    // Every candidate gets its chance: the same key can sit in two
    // certificates, and refusing on whichever came first would make the
    // verdict depend on keyring order (e.g. an older copy whose self-signature
    // had expired, next to a re-issued one that extends it). Revocations are
    // pooled across copies inside `check_signer`, so order cannot hide one.
    let mut refusals = Vec::new();
    for signer in candidates {
        let key = signer.verifying_key();
        let mut data = open().map_err(CheckError::Io)?;
        let fpr = key.fingerprint_hex();
        match key.verify_data(sig, &mut data) {
            Ok(()) => match check_signer(signer, keys, created) {
                Ok(()) => return Ok(()),
                Err(e) => refusals.push(format!("key {fpr}: {e}")),
            },
            Err(e) => {
                refusals.push(format!("signature does not verify against pinned key {fpr}: {e}"));
            }
        }
    }
    Err(refusals.join("; ").into())
}

/// Keys in `keys` whose fingerprint or key ID the signature names as issuer.
pub(super) fn issuer_candidates<'k>(
    sig: &Signature,
    keys: &'k [SignedPublicKey],
) -> Vec<Signer<'k>> {
    let fps = sig.issuer_fingerprint();
    let ids = sig.issuer_key_id();
    let named = |fp: pgp::types::Fingerprint, id: pgp::types::KeyId| {
        fps.iter().any(|f| **f == fp) || ids.iter().any(|i| **i == id)
    };
    let mut out = Vec::new();
    for cert in keys {
        let p = &cert.primary_key;
        if named(p.fingerprint(), p.legacy_key_id()) {
            out.push(Signer::Primary(cert));
        }
        for sub in &cert.public_subkeys {
            if named(sub.key.fingerprint(), sub.key.legacy_key_id()) {
                out.push(Signer::Subkey(cert, sub));
            }
        }
    }
    out
}

/// How to name the signature's issuer in an error; `None` when it names none.
fn issuer_label(sig: &Signature) -> Option<String> {
    sig.issuer_fingerprint()
        .first()
        .map(|fp| format!("key {fp:X}"))
        .or_else(|| sig.issuer_key_id().first().map(|id| format!("key ID {id}")))
}

/// `created + lifetime`, or `None` when the lifetime is absent or zero
/// (`OpenPGP`'s "never").
pub(super) fn expiry(created: u64, lifetime: Option<pgp::types::Duration>) -> Option<u64> {
    let secs = std::time::Duration::from(lifetime?).as_secs();
    (secs != 0).then(|| created.saturating_add(secs))
}

fn sig_time(sig: &Signature) -> Option<u64> {
    sig.created().map(|t| u64::from(t.as_secs()))
}

/// The newest of `sigs` that `valid` accepts, by creation time.
pub(super) fn newest<'s>(
    sigs: impl IntoIterator<Item = &'s Signature>,
    valid: impl Fn(&Signature) -> bool,
) -> Option<&'s Signature> {
    sigs.into_iter().filter(|s| sig_time(s).is_some() && valid(s)).max_by_key(|s| sig_time(s))
}

/// Enforce key validity for the key that made a signature at `sig_created`.
///
/// `keys` is the whole pinned keyring, consulted only for revocations of the
/// same key held in another certificate.
fn check_signer(
    signer: Signer<'_>,
    keys: &[SignedPublicKey],
    sig_created: u64,
) -> std::result::Result<(), String> {
    let cert = match signer {
        Signer::Primary(c) | Signer::Subkey(c, _) => c,
    };
    let primary = &cert.primary_key;

    // The newest valid self-signature carries the primary's current flags and
    // lifetime: a direct-key signature, or a self-certification of a user ID.
    let direct = newest(&cert.details.direct_signatures, |s| {
        s.typ() == Some(SignatureType::Key) && s.verify_key(primary).is_ok()
    });
    let certified = cert
        .details
        .users
        .iter()
        .filter_map(|u| {
            newest(&u.signatures, |s| {
                s.is_certification()
                    && s.typ() != Some(SignatureType::CertRevocation)
                    && s.verify_certification(primary, Tag::UserId, &u.id).is_ok()
            })
        })
        .max_by_key(|s| sig_time(s));
    let primary_self = [direct, certified]
        .into_iter()
        .flatten()
        .max_by_key(|s| sig_time(s))
        .ok_or_else(|| "primary key has no valid self-signature".to_owned())?;

    let primary_created = u64::from(primary.created_at().as_secs());
    check_lifetime("primary key", primary_created, primary_self, sig_created)?;
    // Revocation is permanent, so it is gathered from EVERY copy of this key
    // in the keyring: a copy that lacks the revocation is the stale one, and
    // must not shadow it. (Lifetime and flags above stay per-copy — a
    // re-issued copy legitimately extends expiry.)
    let primary_fpr = primary.fingerprint();
    check_revocations(
        "primary key",
        keys.iter().filter(|c| c.primary_key.fingerprint() == primary_fpr).flat_map(|c| {
            c.details.revocation_signatures.iter().filter(|s| {
                s.typ() == Some(SignatureType::KeyRevocation)
                    && s.verify_key(&c.primary_key).is_ok()
            })
        }),
        sig_created,
    )?;

    match signer {
        Signer::Primary(_) => {
            if !primary_self.key_flags().sign() {
                return Err("primary key is not signing-capable".to_owned());
            }
        }
        Signer::Subkey(_, sub) => {
            let binding = newest(&sub.signatures, |s| {
                s.typ() == Some(SignatureType::SubkeyBinding)
                    && s.verify_subkey_binding(primary, &sub.key).is_ok()
            })
            .ok_or_else(|| "subkey has no valid binding signature".to_owned())?;
            if !binding.key_flags().sign() {
                return Err("subkey is not signing-capable".to_owned());
            }
            // Without the back-signature anyone could bind someone else's
            // signing subkey to their own primary and claim its signatures.
            binding
                .embedded_signature()
                .ok_or_else(|| "signing subkey has no back-signature".to_owned())?
                .verify_primary_key_binding(&sub.key, primary)
                .map_err(|e| format!("signing subkey back-signature is invalid: {e}"))?;
            let sub_created = u64::from(sub.key.created_at().as_secs());
            check_lifetime("subkey", sub_created, binding, sig_created)?;
            let sub_fpr = sub.key.fingerprint();
            check_revocations(
                "subkey",
                keys.iter()
                    .filter(|c| c.primary_key.fingerprint() == primary_fpr)
                    .flat_map(|c| {
                        c.public_subkeys
                            .iter()
                            .filter(|s| s.key.fingerprint() == sub_fpr)
                            .map(move |s| (c, s))
                    })
                    .flat_map(|(c, s)| {
                        s.signatures.iter().filter(move |r| {
                            r.typ() == Some(SignatureType::SubkeyRevocation)
                                && r.verify_subkey_binding(&c.primary_key, &s.key).is_ok()
                        })
                    }),
                sig_created,
            )?;
        }
    }
    Ok(())
}

/// Reject a signature made before its key existed or after it expired.
fn check_lifetime(
    what: &str,
    key_created: u64,
    self_sig: &Signature,
    sig_created: u64,
) -> std::result::Result<(), String> {
    if sig_created < key_created {
        return Err(format!("{what} was created after the signature"));
    }
    match expiry(key_created, self_sig.key_expiration_time()) {
        Some(end) if sig_created >= end => {
            Err(format!("{what} had expired (unix time {end}) when the signature was made"))
        }
        _ => Ok(()),
    }
}

/// Reject on any applicable revocation among `revocations` (already verified
/// against the primary).
fn check_revocations<'s>(
    what: &str,
    revocations: impl Iterator<Item = &'s Signature>,
    sig_created: u64,
) -> std::result::Result<(), String> {
    for rev in revocations {
        let soft = matches!(
            rev.revocation_reason_code(),
            Some(RevocationCode::KeySuperseded | RevocationCode::KeyRetired)
        );
        match sig_time(rev) {
            Some(revoked_at) if soft && sig_created < revoked_at => {}
            _ => return Err(format!("{what} has been revoked")),
        }
    }
    Ok(())
}
