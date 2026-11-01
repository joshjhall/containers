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

mod keyring;
mod validity;

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use containers_common::tooldb::Verification;
use pgp::composed::{Deserializable, DetachedSignature};

use self::keyring::{load_keyring, resolve_keyring};
use self::validity::check_signature;
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
    let fail = failure_for(tool, version);
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
    let fail = failure_for(tool, version);
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
fn failure_for(tool: &str, version: &str) -> impl Fn(String) -> LuggageError {
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

// The tests reach these through `use super::*`, as they did when this was
// one file.
#[cfg(test)]
use self::validity::{CheckError, Signer, issuer_candidates};
#[cfg(test)]
use pgp::{
    composed::SignedPublicKey,
    crypto::hash::HashAlgorithm,
    packet::{RevocationCode, Signature, SignatureType},
    types::KeyDetails,
};

#[cfg(test)]
#[path = "../tier1_tests.rs"]
mod tests;
