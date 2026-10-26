//! Tests for [`super`] (tier-1 GPG verification), split out to keep the
//! production module readable. Same `#[path]` idiom as `download_tests.rs`.
//!
//! Keys are generated deterministically (seeded `ChaCha8`) and every
//! signature carries an explicit creation time, so the expiry and revocation
//! cases are judged against fixed instants rather than the wall clock. The
//! `real_*` tests use the publishers' actual keyrings and signatures from
//! `testdata/tier1/`.

use std::collections::HashMap;
use std::path::PathBuf;

use pgp::composed::{
    ArmorOptions, KeyType, SecretKeyParamsBuilder, SignedSecretKey, SubkeyParamsBuilder,
};
use pgp::packet::{KeyFlags, SignatureConfig, Subpacket, SubpacketData};
use pgp::types::{Duration, Password, SigningKey, Timestamp};
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;

use super::*;

const T0: u32 = 1_700_000_000;
const DAY: u32 = 86_400;
const NOW: u32 = T0 + 1000 * DAY;
const DATA: &[u8] = b"release bytes";

// ---- fixtures ---------------------------------------------------------------

struct StubClient(HashMap<String, Vec<u8>>);

impl HttpClient for StubClient {
    fn get(&self, url: &str) -> Result<Vec<u8>> {
        self.0.get(url).cloned().ok_or_else(|| LuggageError::DownloadFailed {
            url: url.to_owned(),
            attempts: 1,
            message: "stub: no response wired".into(),
        })
    }
}

/// Ed25519 primary (certify, plus sign when `primary_can_sign`) with one
/// Ed25519 subkey whose sign flag is `subkey_can_sign`, all created at `T0`.
fn keygen(seed: u64, primary_can_sign: bool, subkey_can_sign: bool) -> SignedSecretKey {
    SecretKeyParamsBuilder::default()
        .key_type(KeyType::Ed25519)
        .can_certify(true)
        .can_sign(primary_can_sign)
        .created_at(Timestamp::from_secs(T0))
        .primary_user_id("Release Signer <release@example.test>".into())
        .subkey(
            SubkeyParamsBuilder::default()
                .key_type(KeyType::Ed25519)
                .can_sign(subkey_can_sign)
                .created_at(Timestamp::from_secs(T0))
                .build()
                .unwrap(),
        )
        .build()
        .unwrap()
        .generate(ChaCha8Rng::seed_from_u64(seed))
        .unwrap()
}

fn subkey(key: &SignedSecretKey) -> &pgp::packet::SecretSubkey {
    &key.secret_subkeys[0].key
}

/// A v4 config of `typ` by `signer`, created at `at`, naming its issuer by
/// fingerprint, plus `extra` hashed subpackets.
fn config(
    typ: SignatureType,
    signer: &impl SigningKey,
    at: u32,
    extra: Vec<SubpacketData>,
) -> SignatureConfig {
    let mut c = SignatureConfig::v4(typ, signer.algorithm(), HashAlgorithm::Sha256);
    c.hashed_subpackets = [
        SubpacketData::SignatureCreationTime(Timestamp::from_secs(at)),
        SubpacketData::IssuerFingerprint(signer.fingerprint()),
    ]
    .into_iter()
    .chain(extra)
    .map(|d| Subpacket::regular(d).unwrap())
    .collect();
    c
}

fn sign_data(signer: &impl SigningKey, at: u32, data: &[u8]) -> Signature {
    config(SignatureType::Binary, signer, at, vec![])
        .sign(signer, &Password::empty(), data)
        .unwrap()
}

/// Make a direct-key self-signature at `T0` with a lifetime of `days` the
/// primary's only self-signature.
///
/// The builder's user-ID certification is dated at the wall clock, so it
/// would always be the newest self-signature and win; dropping it keeps the
/// lifetime under test the one in force.
fn set_primary_lifetime(key: &mut SignedSecretKey, days: u32) {
    let mut flags = KeyFlags::default();
    flags.set_certify(true);
    flags.set_sign(true);
    for user in &mut key.details.users {
        user.signatures.clear();
    }
    let sig = config(
        SignatureType::Key,
        &key.primary_key,
        T0,
        vec![
            SubpacketData::KeyFlags(flags),
            SubpacketData::KeyExpirationTime(Duration::from_secs(days * DAY)),
        ],
    )
    .sign_key(&key.primary_key, &Password::empty(), key.primary_key.public_key())
    .unwrap();
    key.details.direct_signatures.push(sig);
}

fn revoke_primary(key: &mut SignedSecretKey, at: u32, code: RevocationCode) {
    let sig = config(
        SignatureType::KeyRevocation,
        &key.primary_key,
        at,
        vec![SubpacketData::RevocationReason(code, "test".into())],
    )
    .sign_key(&key.primary_key, &Password::empty(), key.primary_key.public_key())
    .unwrap();
    key.details.revocation_signatures.push(sig);
}

fn revoke_subkey(key: &mut SignedSecretKey, at: u32, code: RevocationCode) {
    let sub = subkey(key).public_key().clone();
    let sig = config(
        SignatureType::SubkeyRevocation,
        &key.primary_key,
        at,
        vec![SubpacketData::RevocationReason(code, "test".into())],
    )
    .sign_subkey_binding(&key.primary_key, key.primary_key.public_key(), &Password::empty(), &sub)
    .unwrap();
    key.secret_subkeys[0].signatures.push(sig);
}

/// Run [`check_signature`] over in-memory `data`, returning the refusal text.
fn check(
    sig: &Signature,
    keys: &[SignedPublicKey],
    data: &[u8],
    now: u32,
) -> std::result::Result<(), String> {
    check_signature(sig, keys, Path::new("test.asc"), u64::from(now), || {
        Ok(Box::new(data) as Box<dyn Read + '_>)
    })
    .map_err(|e| match e {
        CheckError::Refused(r) => r,
        CheckError::Io(e) => panic!("unexpected I/O error: {e}"),
    })
}

// ---- signature / key policy -------------------------------------------------

/// The baseline every negative below is measured against: an unexpired,
/// unrevoked signing subkey with a valid back-signature verifies.
#[test]
fn subkey_signature_verifies() {
    let key = keygen(1, false, true);
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    check(&sig, &[key.to_public_key()], DATA, NOW).unwrap();
}

#[test]
fn primary_signature_verifies_when_primary_can_sign() {
    let key = keygen(2, true, true);
    let sig = sign_data(&key.primary_key, T0 + DAY, DATA);
    check(&sig, &[key.to_public_key()], DATA, NOW).unwrap();
}

#[test]
fn tampered_data_is_refused() {
    let key = keygen(1, false, true);
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], b"release bytez", NOW).unwrap_err();
    assert!(err.contains("does not verify"), "{err}");
}

#[test]
fn signer_not_in_pinned_keyring_is_refused() {
    let pinned = keygen(1, false, true);
    let stranger = keygen(3, false, true);
    let sig = sign_data(subkey(&stranger), T0 + DAY, DATA);
    let err = check(&sig, &[pinned.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("not in the pinned keyring"), "{err}");
}

/// The issuer subpacket is attacker-controlled: a stranger claiming a pinned
/// key's fingerprint still has to produce a signature that verifies under
/// the pinned key's material.
#[test]
fn forged_issuer_fingerprint_is_refused() {
    let pinned = keygen(1, false, true);
    let stranger = keygen(3, false, true);
    let mut c = config(SignatureType::Binary, subkey(&stranger), T0 + DAY, vec![]);
    c.hashed_subpackets[1] =
        Subpacket::regular(SubpacketData::IssuerFingerprint(subkey(&pinned).fingerprint()))
            .unwrap();
    let sig = c.sign(subkey(&stranger), &Password::empty(), DATA).unwrap();
    let err = check(&sig, &[pinned.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("does not verify"), "{err}");
}

#[test]
fn subkey_without_sign_flag_is_refused() {
    let key = keygen(4, false, false);
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("subkey is not signing-capable"), "{err}");
}

#[test]
fn primary_without_sign_flag_is_refused() {
    let key = keygen(5, false, true);
    let sig = sign_data(&key.primary_key, T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("primary key is not signing-capable"), "{err}");
}

/// Expiry is judged at the signature's creation: the same expired key passes
/// for a signature made inside its lifetime and fails for one made after —
/// which is what keeps old releases verifiable after a key rotation.
#[test]
fn primary_expiry_is_judged_at_signature_time() {
    let mut key = keygen(6, true, true);
    set_primary_lifetime(&mut key, 10);
    let keys = [key.to_public_key()];

    check(&sign_data(&key.primary_key, T0 + 9 * DAY, DATA), &keys, DATA, NOW).unwrap();

    let err =
        check(&sign_data(&key.primary_key, T0 + 10 * DAY, DATA), &keys, DATA, NOW).unwrap_err();
    assert!(err.contains("primary key had expired"), "{err}");
}

/// A subkey cannot outlive its primary.
#[test]
fn expired_primary_rejects_its_subkeys_signatures() {
    let mut key = keygen(7, false, true);
    set_primary_lifetime(&mut key, 10);
    let sig = sign_data(subkey(&key), T0 + 11 * DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("primary key had expired"), "{err}");
}

#[test]
fn signature_predating_its_key_is_refused() {
    let key = keygen(8, true, true);
    let sig = sign_data(&key.primary_key, T0 - 1, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("created after the signature"), "{err}");
}

/// A compromise (or an unstated reason) taints every signature the key ever
/// made, including ones dated before the revocation — whoever holds a stolen
/// key can back-date.
#[test]
fn hard_revocation_rejects_even_earlier_signatures() {
    for code in [RevocationCode::KeyCompromised, RevocationCode::NoReason] {
        let mut key = keygen(9, true, true);
        revoke_primary(&mut key, T0 + 100 * DAY, code);
        let sig = sign_data(&key.primary_key, T0 + DAY, DATA);
        let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
        assert!(err.contains("primary key has been revoked"), "{code:?}: {err}");
    }
}

#[test]
fn soft_revocation_rejects_only_later_signatures() {
    let mut key = keygen(10, true, true);
    revoke_primary(&mut key, T0 + 100 * DAY, RevocationCode::KeyRetired);
    let keys = [key.to_public_key()];

    check(&sign_data(&key.primary_key, T0 + DAY, DATA), &keys, DATA, NOW).unwrap();
    let err =
        check(&sign_data(&key.primary_key, T0 + 101 * DAY, DATA), &keys, DATA, NOW).unwrap_err();
    assert!(err.contains("primary key has been revoked"), "{err}");
}

/// Without a back-signature, a binding only proves the PRIMARY wanted the
/// subkey — anyone can bind someone else's signing subkey to their own
/// primary that way. The subkey's consent (the embedded primary-key binding)
/// is what makes its signatures the primary holder's.
#[test]
fn signing_subkey_without_back_signature_is_refused() {
    let mut key = keygen(18, false, true);
    let sub = subkey(&key).public_key().clone();
    let mut flags = KeyFlags::default();
    flags.set_sign(true);
    // Newer than the builder's binding (dated at the wall clock), so it wins.
    let at = u32::try_from(unix_now()).unwrap() + DAY;
    let bare = config(
        SignatureType::SubkeyBinding,
        &key.primary_key,
        at,
        vec![SubpacketData::KeyFlags(flags)],
    )
    .sign_subkey_binding(&key.primary_key, key.primary_key.public_key(), &Password::empty(), &sub)
    .unwrap();
    key.secret_subkeys[0].signatures = vec![bare];
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("no back-signature"), "{err}");
}

/// A back-signature that is present but was made by a different key (here:
/// the stranger's subkey "consenting" to our primary) must not pass for the
/// real subkey's consent.
#[test]
fn signing_subkey_with_foreign_back_signature_is_refused() {
    let mut key = keygen(19, false, true);
    let stranger = keygen(24, false, true);
    let sub = subkey(&key).public_key().clone();
    let foreign_backsig = config(SignatureType::KeyBinding, subkey(&stranger), T0, vec![])
        .sign_primary_key_binding(
            subkey(&stranger),
            subkey(&stranger).public_key(),
            &Password::empty(),
            key.primary_key.public_key(),
        )
        .unwrap();
    let mut flags = KeyFlags::default();
    flags.set_sign(true);
    let at = u32::try_from(unix_now()).unwrap() + DAY;
    let binding = config(
        SignatureType::SubkeyBinding,
        &key.primary_key,
        at,
        vec![
            SubpacketData::KeyFlags(flags),
            SubpacketData::EmbeddedSignature(Box::new(foreign_backsig)),
        ],
    )
    .sign_subkey_binding(&key.primary_key, key.primary_key.public_key(), &Password::empty(), &sub)
    .unwrap();
    key.secret_subkeys[0].signatures = vec![binding];
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("back-signature is invalid"), "{err}");
}

#[test]
fn revoked_subkey_is_refused() {
    let mut key = keygen(11, false, true);
    revoke_subkey(&mut key, T0 + 100 * DAY, RevocationCode::KeyCompromised);
    let sig = sign_data(subkey(&key), T0 + DAY, DATA);
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("subkey has been revoked"), "{err}");
}

/// A revocation that does not verify against the primary is noise anyone
/// could append to a published keyring; it must not deny service.
#[test]
fn forged_revocation_is_ignored() {
    let mut key = keygen(12, true, true);
    let attacker = keygen(13, true, true);
    let forged = config(SignatureType::KeyRevocation, &attacker.primary_key, T0 + DAY, vec![])
        .sign_key(&attacker.primary_key, &Password::empty(), key.primary_key.public_key())
        .unwrap();
    key.details.revocation_signatures.push(forged);
    let sig = sign_data(&key.primary_key, T0 + 2 * DAY, DATA);
    check(&sig, &[key.to_public_key()], DATA, NOW).unwrap();
}

#[test]
fn expired_signature_is_refused() {
    let key = keygen(14, true, true);
    let sig = config(
        SignatureType::Binary,
        &key.primary_key,
        T0 + DAY,
        vec![SubpacketData::SignatureExpirationTime(Duration::from_secs(DAY))],
    )
    .sign(&key.primary_key, &Password::empty(), DATA)
    .unwrap();
    let keys = [key.to_public_key()];
    check(&sig, &keys, DATA, T0 + DAY + 10).unwrap();
    let err = check(&sig, &keys, DATA, T0 + 2 * DAY).unwrap_err();
    assert!(err.contains("signature expired"), "{err}");
}

#[test]
fn text_mode_signature_is_refused() {
    let key = keygen(15, true, true);
    let sig = config(SignatureType::Text, &key.primary_key, T0 + DAY, vec![])
        .sign(&key.primary_key, &Password::empty(), DATA)
        .unwrap();
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("only binary-mode"), "{err}");
}

/// pgp itself refuses SHA-1 for `EdDSA` and ECDSA, but verifies it for RSA and
/// DSA — the algorithms most publisher keys in the pinned keyrings use — so
/// this check is luggage's to make.
#[test]
fn sha1_signature_is_refused() {
    let key = SecretKeyParamsBuilder::default()
        .key_type(KeyType::Rsa(2048))
        .can_certify(true)
        .can_sign(true)
        .created_at(Timestamp::from_secs(T0))
        .primary_user_id("Legacy <legacy@example.test>".into())
        .build()
        .unwrap()
        .generate(ChaCha8Rng::seed_from_u64(16))
        .unwrap();
    let mut c = config(SignatureType::Binary, &key.primary_key, T0 + DAY, vec![]);
    c.hash_alg = HashAlgorithm::Sha1;
    let sig = c.sign(&key.primary_key, &Password::empty(), DATA).unwrap();
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("broken hash"), "{err}");
}

#[test]
fn issuerless_signature_is_refused() {
    let key = keygen(17, true, true);
    let mut c = config(SignatureType::Binary, &key.primary_key, T0 + DAY, vec![]);
    c.hashed_subpackets.truncate(1);
    let sig = c.sign(&key.primary_key, &Password::empty(), DATA).unwrap();
    let err = check(&sig, &[key.to_public_key()], DATA, NOW).unwrap_err();
    assert!(err.contains("names no issuer"), "{err}");
}

// ---- real publisher material ------------------------------------------------

fn testdata(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/tier1").join(name)
}

fn read(name: &str) -> Vec<u8> {
    std::fs::read(testdata(name)).unwrap()
}

fn real_sig(name: &str) -> Signature {
    DetachedSignature::from_reader_single(&read(name)[..]).unwrap().0.signature
}

/// Node's real keyring carries expired keys, revoked user IDs and a revoked
/// subkey; none of that may stop the actual release key's signature over the
/// real `SHASUMS256.txt` from verifying — and one flipped byte must.
#[test]
fn real_node_signature_verifies_and_tamper_fails() {
    let keys = load_keyring(&testdata("nodejs.asc")).unwrap();
    let sig = real_sig("node-v22.23.4-SHASUMS256.txt.sig");
    let manifest = read("node-v22.23.4-SHASUMS256.txt");
    let now = u32::try_from(unix_now()).unwrap();
    check(&sig, &keys, &manifest, now).unwrap();

    let mut tampered = manifest;
    tampered[0] ^= 1;
    let err = check(&sig, &keys, &tampered, now).unwrap_err();
    assert!(err.contains("does not verify"), "{err}");
}

/// Go's real `.asc` names a subkey of the Google Linux signing key: the
/// pinned golang keyring must resolve it to that subkey, and node's must not
/// resolve it at all. (The 70MB tarball it covers is not committed.)
#[test]
fn real_go_signature_resolves_to_the_pinned_subkey() {
    let sig = real_sig("go1.27.3.linux-amd64.tar.gz.asc");
    let golang = load_keyring(&testdata("golang.asc")).unwrap();
    assert!(matches!(issuer_candidates(&sig, &golang)[..], [Signer::Subkey(..)]));
    let node = load_keyring(&testdata("nodejs.asc")).unwrap();
    assert!(issuer_candidates(&sig, &node).is_empty());
}

// ---- entry shape and keyring path -------------------------------------------

fn gpg_verification(keyring: &str) -> Verification {
    Verification {
        tier: 1,
        algorithm: Some("gpg".into()),
        pinned_checksum: None,
        checksum_url_template: None,
        checksum_manifest: None,
        gpg_key_url: None,
        gpg_keyring: Some(keyring.into()),
        signature_url_template: Some("https://example.test/{version}/art.sig".into()),
        sigstore_identity: None,
        sigstore_issuer: None,
        tofu: None,
    }
}

fn shape_err(v: &Verification, root: Option<&Path>) -> LuggageError {
    require_shape("tool", "1.0.0", v, root).unwrap_err()
}

fn reason(e: &LuggageError) -> &str {
    match e {
        LuggageError::VerificationFailed { tier: 1, reason, .. } => reason,
        other => panic!("expected tier-1 VerificationFailed, got {other:?}"),
    }
}

#[test]
fn key_url_only_entry_is_refused_as_a_verification_failure() {
    let mut v = gpg_verification("x.asc");
    v.gpg_keyring = None;
    v.gpg_key_url = Some("https://example.test/key.asc".into());
    let dir = tempfile::tempdir().unwrap();
    let err = shape_err(&v, Some(dir.path()));
    assert!(reason(&err).contains("pinned in the catalog"), "{err}");
}

#[test]
fn no_key_source_is_a_catalog_error() {
    let mut v = gpg_verification("x.asc");
    v.gpg_keyring = None;
    let dir = tempfile::tempdir().unwrap();
    assert!(
        matches!(shape_err(&v, Some(dir.path())), LuggageError::Catalog(m) if m.contains("gpg_keyring"))
    );
}

#[test]
fn missing_catalog_root_is_refused() {
    let err = shape_err(&gpg_verification("keyrings/x.asc"), None);
    assert!(reason(&err).contains("no catalog root"), "{err}");
}

#[test]
fn keyring_path_escapes_are_refused() {
    let outer = tempfile::tempdir().unwrap();
    let root = outer.path().join("catalog");
    std::fs::create_dir_all(root.join("keyrings")).unwrap();
    std::fs::write(outer.path().join("evil.asc"), b"x").unwrap();
    std::fs::write(root.join("keyrings/ok.asc"), b"x").unwrap();

    require_shape("tool", "1.0.0", &gpg_verification("keyrings/ok.asc"), Some(&root)).unwrap();

    let abs = outer.path().join("evil.asc").display().to_string();
    for rel in ["../evil.asc", "keyrings/../../evil.asc", "./keyrings/ok.asc", abs.as_str(), ""] {
        let err = shape_err(&gpg_verification(rel), Some(&root));
        assert!(reason(&err).contains("plain relative path"), "{rel:?}: {err}");
    }
    let err = shape_err(&gpg_verification("keyrings/missing.asc"), Some(&root));
    assert!(reason(&err).contains("not found"), "{err}");
}

/// The lexical check cannot see a symlink; the canonical-prefix check must.
#[cfg(unix)]
#[test]
fn keyring_symlink_out_of_the_catalog_is_refused() {
    let outer = tempfile::tempdir().unwrap();
    let root = outer.path().join("catalog");
    std::fs::create_dir_all(root.join("keyrings")).unwrap();
    std::fs::write(outer.path().join("evil.asc"), b"x").unwrap();
    std::os::unix::fs::symlink(outer.path().join("evil.asc"), root.join("keyrings/link.asc"))
        .unwrap();
    let err = shape_err(&gpg_verification("keyrings/link.asc"), Some(&root));
    assert!(reason(&err).contains("outside the catalog root"), "{err}");
}

#[test]
fn half_specified_manifest_mode_is_a_catalog_error() {
    let dir = tempfile::tempdir().unwrap();
    for (url, flag) in [(Some("https://x/SHASUMS256.txt"), None), (None, Some(true))] {
        let mut v = gpg_verification("k.asc");
        v.checksum_url_template = url.map(Into::into);
        v.checksum_manifest = flag;
        assert!(matches!(shape_err(&v, Some(dir.path())), LuggageError::Catalog(_)), "{v:?}");
    }
}

// ---- end to end through `verify` --------------------------------------------

/// A catalog root holding the key's public half at `keyrings/pub.asc`.
fn catalog_with(key: &SignedSecretKey) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("keyrings")).unwrap();
    let armored = key.to_public_key().to_armored_bytes(ArmorOptions::default()).unwrap();
    std::fs::write(dir.path().join("keyrings/pub.asc"), armored).unwrap();
    dir
}

fn armored(sig: Signature) -> Vec<u8> {
    DetachedSignature::new(sig).to_armored_bytes(ArmorOptions::default()).unwrap()
}

fn subs() -> Substitutions<'static> {
    Substitutions { version: Some("1.0.0"), ..Substitutions::default() }
}

const SIG_URL: &str = "https://example.test/1.0.0/art.sig";
const MANIFEST_URL: &str = "https://example.test/1.0.0/SHASUMS256.txt";

fn manifest_verification() -> Verification {
    Verification {
        checksum_url_template: Some("https://example.test/{version}/SHASUMS256.txt".into()),
        checksum_manifest: Some(true),
        ..gpg_verification("keyrings/pub.asc")
    }
}

fn not_on_disk<'a>(digest: &'a str, filename: &'a str) -> Artifact<'a> {
    Artifact { digest, filename, path: Path::new("/nonexistent/artifact") }
}

/// Detached mode streams the artifact from disk through the check.
#[test]
fn detached_mode_end_to_end() {
    let key = keygen(20, false, true);
    let catalog = catalog_with(&key);
    let art_dir = tempfile::tempdir().unwrap();
    let path = art_dir.path().join("art.tar.gz");
    std::fs::write(&path, DATA).unwrap();
    let http = StubClient(HashMap::from([(
        SIG_URL.to_owned(),
        armored(sign_data(subkey(&key), T0 + DAY, DATA)),
    )]));
    let artifact = Artifact { digest: "unused", filename: "art.tar.gz", path: &path };
    let v = gpg_verification("keyrings/pub.asc");
    let root = Some(catalog.path());
    verify("tool", "1.0.0", &artifact, &v, &subs(), &http, root).unwrap();

    std::fs::write(&path, b"swapped").unwrap();
    let err = verify("tool", "1.0.0", &artifact, &v, &subs(), &http, root).unwrap_err();
    assert!(reason(&err).contains("does not verify"), "{err}");
}

/// Signed-manifest mode: the signature covers the manifest, and the
/// artifact's digest must then match ITS line — not a neighbour's.
#[test]
fn signed_manifest_mode_end_to_end() {
    let key = keygen(21, false, true);
    let catalog = catalog_with(&key);
    let (good, other, bad) = ("a".repeat(64), "b".repeat(64), "c".repeat(64));
    let manifest = format!("{other}  other.tar.gz\n{good}  art.tar.gz\n");
    let http = StubClient(HashMap::from([
        (MANIFEST_URL.to_owned(), manifest.clone().into_bytes()),
        (SIG_URL.to_owned(), armored(sign_data(subkey(&key), T0 + DAY, manifest.as_bytes()))),
    ]));
    let v = manifest_verification();
    let root = Some(catalog.path());
    let run = |a: Artifact<'_>| verify("tool", "1.0.0", &a, &v, &subs(), &http, root);

    run(not_on_disk(&good, "art.tar.gz")).unwrap();

    let err = run(not_on_disk(&good, "missing.tar.gz")).unwrap_err();
    assert!(reason(&err).contains("no entry for artifact"), "{err}");

    // The neighbour's digest is in the signed manifest too; it must not pass.
    for digest in [&bad, &other] {
        let err = run(not_on_disk(digest, "art.tar.gz")).unwrap_err();
        assert!(reason(&err).contains("digest mismatch"), "{err}");
    }
}

/// A manifest edited after signing fails on the signature, before its
/// attacker-chosen digest is ever compared.
#[test]
fn tampered_signed_manifest_is_refused() {
    let key = keygen(22, false, true);
    let catalog = catalog_with(&key);
    let signed = format!("{}  art.tar.gz\n", "a".repeat(64));
    let evil = "c".repeat(64);
    let served = format!("{evil}  art.tar.gz\n");
    let http = StubClient(HashMap::from([
        (MANIFEST_URL.to_owned(), served.into_bytes()),
        (SIG_URL.to_owned(), armored(sign_data(subkey(&key), T0 + DAY, signed.as_bytes()))),
    ]));
    let err = verify(
        "tool",
        "1.0.0",
        &not_on_disk(&evil, "art.tar.gz"),
        &manifest_verification(),
        &subs(),
        &http,
        Some(catalog.path()),
    )
    .unwrap_err();
    assert!(reason(&err).contains("does not verify"), "{err}");
}

#[test]
fn garbage_signature_is_a_verification_failure() {
    let key = keygen(23, false, true);
    let catalog = catalog_with(&key);
    let http = StubClient(HashMap::from([(SIG_URL.to_owned(), b"not a signature".to_vec())]));
    let err = verify(
        "tool",
        "1.0.0",
        &not_on_disk("x", "art.tar.gz"),
        &gpg_verification("keyrings/pub.asc"),
        &subs(),
        &http,
        Some(catalog.path()),
    )
    .unwrap_err();
    assert!(reason(&err).contains("not an OpenPGP signature"), "{err}");
}

/// A keyring file that holds no certificate fails closed, not open.
#[test]
fn empty_keyring_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("empty.asc");
    std::fs::write(&path, b"").unwrap();
    assert!(load_keyring(&path).is_err());
}
