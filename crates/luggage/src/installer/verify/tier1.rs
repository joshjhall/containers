//! Tier 1 — `OpenPGP` signature verification against a pinned keyring.
//!
//! The strongest tier: the publisher signed the release with a private key,
//! and luggage checks that signature against a public keyring **committed to
//! the catalog** (`verification.gpg_keyring`, a path relative to the catalog
//! root). Because the key landed through code review, whoever controls the
//! publisher's origin at fetch time cannot substitute their own — which is
//! the whole reason to check a signature at all. An entry that names only a
//! remote `gpg_key_url` is refused for exactly that reason.
//!
//! Two shapes, selected by `verification.checksum_manifest`:
//!
//! - **detached** (default) — the signature at `signature_url_template`
//!   covers the artifact itself (Go's `go{version}.linux-{arch}.tar.gz.asc`).
//!   The artifact is streamed from disk through the verifier, never buffered.
//! - **signed manifest** (`checksum_manifest: true`) — the signature covers
//!   the manifest at `checksum_url_template` (Node's `SHASUMS256.txt`). Once
//!   the manifest's signature verifies, the artifact's line is selected by
//!   filename exactly as tier 3 does it, and compared against the digest
//!   computed during download.
//!
//! # What "verifies" means here
//!
//! `pgp`'s `Signature::verify` checks only the cryptography. It knows nothing
//! about revocation, expiry, or key capabilities, so this module enforces
//! those itself, all evaluated at the **data signature's creation time** (the
//! moment the publisher signed this release) — a key that expired or was
//! retired *later* still vouches for what it signed while it was valid:
//!
//! - The data signature must be a binary-mode signature with a creation time,
//!   must name its issuer, must not use a broken hash (MD5, SHA-1,
//!   RIPEMD-160), and must not itself have expired.
//! - The signing key — the primary, or a subkey — must have a valid
//!   self-signature (subkeys: a binding signature with a valid back-signature)
//!   that grants the **sign** capability, must not have been created after
//!   the signature, and must not have expired by the signature's creation.
//!   A subkey signer additionally requires its primary to be unexpired.
//! - A verified revocation of the primary or the signing subkey rejects the
//!   signature. A *soft* revocation (reason "superseded" or "retired") only
//!   rejects signatures made after it, as RFC 9580 § 5.2.3.31 allows; any
//!   other reason, including none, is treated as a compromise and rejects
//!   every signature by that key.
//!
//! Self-signatures, bindings and revocations count only when they verify
//! against the primary key. A forged revocation therefore cannot deny
//! service, and a forged binding cannot extend a key's life.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use containers_common::tooldb::Verification;
use pgp::composed::{Deserializable, DetachedSignature, SignedPublicKey, SignedPublicSubKey};
use pgp::crypto::hash::HashAlgorithm;
use pgp::packet::{RevocationCode, Signature, SignatureType};
use pgp::types::{KeyDetails, Tag, VerifyingKey};

use super::Artifact;
use super::sha::digests_equal;
use super::tier3::{ManifestError, select_manifest_digest};
use crate::error::{LuggageError, Result};
use crate::installer::download::HttpClient;
use crate::installer::template::{Substitutions, substitute_url};

/// The fields of a tier-1 entry this build will act on, validated.
///
/// Built by [`require_shape`], which both the pre-download guard
/// (`ensure_supported`) and [`verify`] call — so the two cannot disagree
/// about what a usable tier-1 entry is.
#[derive(Debug)]
pub(super) struct Shape<'v> {
    /// Canonical path of the pinned keyring, proven to lie under the catalog
    /// root.
    keyring: PathBuf,
    signature_url_template: &'v str,
    /// `Some` in signed-manifest mode: the manifest the signature covers.
    manifest_url_template: Option<&'v str>,
}

/// Validate a tier-1 entry without fetching anything.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for `algorithm: "sigstore"`.
/// - [`LuggageError::Catalog`] for any other non-`gpg` algorithm, a missing
///   `signature_url_template`, a `checksum_url_template`/`checksum_manifest`
///   pair that is not both-present-and-true or both-absent, or an entry with
///   no key source at all.
/// - [`LuggageError::VerificationFailed`] for an entry that carries only a
///   remote `gpg_key_url` (a policy refusal — see the module docs), when the
///   installer has no catalog root to resolve the keyring against, and when
///   the keyring path is absolute, contains `..`, does not exist, or resolves
///   (through a symlink) outside the catalog root.
pub(super) fn require_shape<'v>(
    tool: &str,
    version: &str,
    verification: &'v Verification,
    catalog_root: Option<&Path>,
) -> Result<Shape<'v>> {
    let fail = failer(tool, version);
    match verification.algorithm.as_deref() {
        Some("gpg") => {}
        Some("sigstore") => {
            return Err(LuggageError::NotImplemented("tier 1 sigstore verification"));
        }
        other => {
            return Err(LuggageError::Catalog(format!(
                "tier 1 verification requires `algorithm` of `gpg` or `sigstore`, got {other:?}"
            )));
        }
    }
    let signature_url_template =
        verification.signature_url_template.as_deref().ok_or_else(|| {
            LuggageError::Catalog(
                "tier 1 GPG verification requires `signature_url_template` in catalog".to_owned(),
            )
        })?;
    let manifest_url_template =
        match (verification.checksum_manifest, verification.checksum_url_template.as_deref()) {
            (None | Some(false), None) => None,
            (Some(true), Some(url)) => Some(url),
            _ => {
                return Err(LuggageError::Catalog(
                    "tier 1 signed-manifest mode needs both `checksum_url_template` and \
                 `checksum_manifest: true`, or neither"
                        .to_owned(),
                ));
            }
        };
    let Some(keyring) = verification.gpg_keyring.as_deref() else {
        return Err(if verification.gpg_key_url.is_some() {
            fail(
                "this entry names only a remote `gpg_key_url`; a key fetched at install time \
                 is only as trustworthy as the publisher's origin, so luggage requires a \
                 `gpg_keyring` pinned in the catalog"
                    .to_owned(),
            )
        } else {
            LuggageError::Catalog(
                "tier 1 GPG verification requires `gpg_keyring` in catalog".to_owned(),
            )
        });
    };
    let root = catalog_root.ok_or_else(|| {
        fail(format!(
            "cannot locate pinned keyring `{keyring}`: the installer was given no catalog root"
        ))
    })?;
    let keyring = resolve_keyring(root, keyring).map_err(fail)?;
    Ok(Shape { keyring, signature_url_template, manifest_url_template })
}

/// Verify `artifact` against the tier-1 entry in `verification`.
///
/// `subs` substitutes placeholders into the signature (and manifest) URL
/// templates; `catalog_root` is where the entry's `gpg_keyring` lives.
///
/// # Errors
///
/// - Everything [`require_shape`] raises.
/// - [`LuggageError::TemplateMissingKey`] for an unknown URL placeholder.
/// - [`LuggageError::DownloadFailed`] when the signature or manifest cannot
///   be fetched.
/// - [`LuggageError::Io`] when the keyring or the artifact cannot be read.
/// - [`LuggageError::VerificationFailed`] for every way the signature can
///   fail to vouch for the artifact: unparsable keyring or signature, an
///   issuer not in the pinned keyring, a bad signature, any of the key-policy
///   failures in the module docs, and — in signed-manifest mode — a manifest
///   with no or a malformed entry for the artifact, or a digest mismatch.
pub fn verify(
    tool: &str,
    version: &str,
    artifact: &Artifact<'_>,
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
    catalog_root: Option<&Path>,
) -> Result<()> {
    let shape = require_shape(tool, version, verification, catalog_root)?;
    let fail = failer(tool, version);
    let keys = load_keyring(&shape.keyring).map_err(&fail)?;

    let sig_url = substitute_url(shape.signature_url_template, subs)?;
    let sig_bytes = fetch(http, &sig_url, &fail)?;
    let (sig, _) = DetachedSignature::from_reader_single(&sig_bytes[..])
        .map_err(|e| fail(format!("signature at {sig_url} is not an OpenPGP signature: {e}")))?;
    let sig = sig.signature;
    let now = unix_now(&fail)?;

    match shape.manifest_url_template {
        None => {
            let open = || -> Result<Box<dyn Read>> {
                let f = File::open(artifact.path).map_err(|e| LuggageError::Io {
                    path: artifact.path.to_path_buf(),
                    source: e,
                })?;
                Ok(Box::new(BufReader::new(f)))
            };
            check_signature(&sig, &keys, &shape.keyring, now, open)
                .map_err(|e| e.into_error(&fail))?;
            Ok(())
        }
        Some(template) => {
            let manifest_url = substitute_url(template, subs)?;
            let manifest = fetch(http, &manifest_url, &fail)?;
            check_signature(&sig, &keys, &shape.keyring, now, || {
                Ok(Box::new(&manifest[..]) as Box<dyn Read + '_>)
            })
            .map_err(|e| e.into_error(&fail))?;

            // Only now — with the manifest proven to be the publisher's — is
            // anything in it worth reading.
            let body = std::str::from_utf8(&manifest).map_err(|_| {
                fail(format!("signed manifest at {manifest_url} is not valid UTF-8"))
            })?;
            let expected = select_manifest_digest(body, artifact.filename).map_err(|e| {
                fail(match e {
                    ManifestError::NoMatch => format!(
                        "signed manifest at {manifest_url} has no entry for artifact `{}`",
                        artifact.filename
                    ),
                    ManifestError::Malformed(line) => {
                        format!("signed manifest at {manifest_url} has a malformed entry: `{line}`")
                    }
                })
            })?;
            if digests_equal(artifact.digest, expected) {
                Ok(())
            } else {
                Err(fail(format!(
                    "digest mismatch: signed manifest says {expected}, computed {}",
                    artifact.digest
                )))
            }
        }
    }
}

/// Build the tier-1 `VerificationFailed` constructor for one tool@version.
fn failer(tool: &str, version: &str) -> impl Fn(String) -> LuggageError {
    let (tool, version) = (tool.to_owned(), version.to_owned());
    move |reason| LuggageError::VerificationFailed {
        tool: tool.clone(),
        version: version.clone(),
        tier: 1,
        reason,
    }
}

/// Buffered fetch with the response ceiling folded into a verification
/// failure, as tier 3 does: an oversized signature or manifest has failed to
/// establish anything.
fn fetch(
    http: &dyn HttpClient,
    url: &str,
    fail: &impl Fn(String) -> LuggageError,
) -> Result<Vec<u8>> {
    http.get(url).map_err(|e| match e {
        LuggageError::ResponseTooLarge { limit, .. } => {
            fail(format!("{url} exceeds the {limit}-byte response ceiling"))
        }
        other => other,
    })
}

/// The current time, failing closed: a clock before the epoch would read as
/// time 0 and quietly disable the signature-expiry check.
fn unix_now(fail: &impl Fn(String) -> LuggageError) -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|_| fail("system clock is before the Unix epoch".to_owned()))
}

/// Resolve `rel` under `root`, refusing anything that could name a file
/// outside the reviewed catalog tree.
///
/// The lexical check (relative, only plain components) rejects `/etc/x.asc`
/// and `../x.asc` before touching the filesystem; the canonical prefix check
/// after it catches a symlink inside the catalog pointing out of it.
fn resolve_keyring(root: &Path, rel: &str) -> std::result::Result<PathBuf, String> {
    let rel_path = Path::new(rel);
    if rel.is_empty() || !rel_path.components().all(|c| matches!(c, Component::Normal(_))) {
        return Err(format!(
            "`gpg_keyring` must be a plain relative path inside the catalog, got `{rel}`"
        ));
    }
    let canonical_root = root
        .canonicalize()
        .map_err(|e| format!("catalog root {} is not accessible: {e}", root.display()))?;
    let resolved = canonical_root
        .join(rel_path)
        .canonicalize()
        .map_err(|e| format!("pinned keyring `{rel}` not found in the catalog: {e}"))?;
    if !resolved.starts_with(&canonical_root) {
        return Err(format!("pinned keyring `{rel}` resolves outside the catalog root"));
    }
    Ok(resolved)
}

/// Parse every certificate in an armored keyring.
///
/// A certificate the parser cannot handle (an obsolete algorithm, say) is
/// skipped rather than failing the whole keyring: it simply cannot be the
/// signer, and a signature by it is then refused as "not in the keyring". A
/// keyring that yields no usable certificate at all is an error.
fn load_keyring(path: &Path) -> std::result::Result<Vec<SignedPublicKey>, String> {
    let file = File::open(path)
        .map_err(|e| format!("cannot read pinned keyring {}: {e}", path.display()))?;
    let (iter, _) = SignedPublicKey::from_armor_many(file)
        .map_err(|e| format!("pinned keyring {} is not an armored keyring: {e}", path.display()))?;
    let keys: Vec<_> = iter
        .filter_map(|k| {
            k.map_err(|e| {
                tracing::warn!("skipping unparsable certificate in {}: {e}", path.display());
            })
            .ok()
        })
        .collect();
    if keys.is_empty() {
        return Err(format!("pinned keyring {} holds no usable certificate", path.display()));
    }
    Ok(keys)
}

/// Why [`check_signature`] refused. `Io` stays an I/O error rather than being
/// folded into a verification failure, so a disk problem is not misreported
/// as a bad signature.
#[derive(Debug)]
enum CheckError {
    Refused(String),
    Io(LuggageError),
}

impl CheckError {
    fn into_error(self, fail: &impl Fn(String) -> LuggageError) -> LuggageError {
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
enum Signer<'k> {
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
fn check_signature<'d>(
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
    // certificates (one stale), and refusing on whichever came first would
    // make the verdict depend on keyring order.
    let mut refusals = Vec::new();
    for signer in candidates {
        let key = signer.verifying_key();
        let mut data = open().map_err(CheckError::Io)?;
        let fpr = key.fingerprint_hex();
        match key.verify_data(sig, &mut data) {
            Ok(()) => match check_signer(signer, created) {
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
fn issuer_candidates<'k>(sig: &Signature, keys: &'k [SignedPublicKey]) -> Vec<Signer<'k>> {
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
fn expiry(created: u64, lifetime: Option<pgp::types::Duration>) -> Option<u64> {
    let secs = std::time::Duration::from(lifetime?).as_secs();
    (secs != 0).then(|| created.saturating_add(secs))
}

fn sig_time(sig: &Signature) -> Option<u64> {
    sig.created().map(|t| u64::from(t.as_secs()))
}

/// The newest of `sigs` that `valid` accepts, by creation time.
fn newest<'s>(
    sigs: impl IntoIterator<Item = &'s Signature>,
    valid: impl Fn(&Signature) -> bool,
) -> Option<&'s Signature> {
    sigs.into_iter().filter(|s| sig_time(s).is_some() && valid(s)).max_by_key(|s| sig_time(s))
}

/// Enforce key validity for the key that made a signature at `sig_created`.
fn check_signer(signer: Signer<'_>, sig_created: u64) -> std::result::Result<(), String> {
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
    check_revocations(
        "primary key",
        cert.details.revocation_signatures.iter().filter(|s| {
            s.typ() == Some(SignatureType::KeyRevocation) && s.verify_key(primary).is_ok()
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
            check_revocations(
                "subkey",
                sub.signatures.iter().filter(|s| {
                    s.typ() == Some(SignatureType::SubkeyRevocation)
                        && s.verify_subkey_binding(primary, &sub.key).is_ok()
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

#[cfg(test)]
#[path = "tier1_tests.rs"]
mod tests;
