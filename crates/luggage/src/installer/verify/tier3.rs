//! Tier 3 — published-checksum verification.
//!
//! The catalog points at a checksum file the publisher hosts (e.g.
//! `https://static.rust-lang.org/rustup/dist/{rustup_target}/rustup-init.sha256`).
//! Tier 3 fetches that file, parses out the expected digest, computes the
//! same digest over the downloaded artifact, and compares.
//!
//! This is "trust the publisher's TLS endpoint" — weaker than tier 1
//! (signatures) and tier 2 (pinned in-repo checksum) but stronger than
//! tier 4 (TOFU). It is what rust@1.95.0 uses.

use containers_common::tooldb::Verification;

use super::sha::{digest_hex, digests_equal};
use crate::error::{LuggageError, Result};
use crate::installer::download::HttpClient;
use crate::installer::template::{Substitutions, substitute_url};

/// Verify `bytes` against the publisher-served checksum URL in `verification`.
///
/// `subs` is used to substitute placeholders (e.g. `{rustup_target}`) into
/// the checksum URL template before fetching. `tool` and `version` are
/// only used for error message context.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.checksum_url_template` is
///   missing — required for tier 3.
/// - [`LuggageError::TemplateMissingKey`] when the checksum URL template
///   references an unknown placeholder.
/// - [`LuggageError::DownloadFailed`] when the checksum file cannot be
///   fetched.
/// - [`LuggageError::VerificationFailed`] when the expected digest cannot
///   be parsed out of the response or does not match the bytes' digest.
pub fn verify(
    tool: &str,
    version: &str,
    bytes: &[u8],
    verification: &Verification,
    subs: &Substitutions<'_>,
    http: &dyn HttpClient,
) -> Result<()> {
    let template = verification.checksum_url_template.as_deref().ok_or_else(|| {
        LuggageError::Catalog(
            "tier 3 verification requires `checksum_url_template` in catalog".to_owned(),
        )
    })?;
    let url = substitute_url(template, subs)?;

    let body = http.get(&url)?;
    let body_str = std::str::from_utf8(&body).map_err(|_| LuggageError::VerificationFailed {
        tool: tool.to_owned(),
        version: version.to_owned(),
        tier: 3,
        reason: format!("checksum file at {url} is not valid UTF-8"),
    })?;

    let expected =
        parse_checksum_field(body_str).ok_or_else(|| LuggageError::VerificationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            tier: 3,
            reason: format!("could not parse a digest out of {url}"),
        })?;

    let actual = digest_hex(verification.algorithm.as_deref(), bytes)?;

    if digests_equal(&actual, expected) {
        Ok(())
    } else {
        Err(LuggageError::VerificationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            tier: 3,
            reason: format!("digest mismatch: expected {expected}, computed {actual}"),
        })
    }
}

/// Pull the digest token out of a publisher-style checksum response.
///
/// Accepts the two common shapes:
///
/// - `<hex>` (digest only, optional trailing newline)
/// - `<hex>  <filename>` (sha256sum/coreutils format)
fn parse_checksum_field(body: &str) -> Option<&str> {
    let line = body.lines().next()?.trim();
    let token = line.split_whitespace().next()?;
    if token.is_empty() {
        return None;
    }
    if !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::collections::HashMap;
    use std::sync::Mutex;

    use containers_common::tooldb::Verification;

    use crate::installer::download::HttpClient;
    use crate::installer::template::Substitutions;
    use crate::installer::verify::sha::digest_hex;

    /// Deterministic in-memory HTTP stub.
    struct StubClient {
        responses: Mutex<HashMap<String, Vec<u8>>>,
    }

    impl StubClient {
        fn with(url: &str, body: &[u8]) -> Self {
            let mut m = HashMap::new();
            m.insert(url.to_owned(), body.to_vec());
            Self { responses: Mutex::new(m) }
        }
    }

    impl HttpClient for StubClient {
        fn get(&self, url: &str) -> Result<Vec<u8>> {
            self.responses.lock().unwrap().get(url).cloned().ok_or_else(|| {
                LuggageError::DownloadFailed {
                    url: url.to_owned(),
                    attempts: 1,
                    message: "stub: no response wired".into(),
                }
            })
        }
    }

    fn verification(template: &str) -> Verification {
        Verification {
            tier: 3,
            algorithm: Some("sha256".into()),
            pinned_checksum: None,
            checksum_url_template: Some(template.into()),
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        }
    }

    #[test]
    fn matching_digest_passes() {
        let bytes = b"hello rustup-init body";
        let digest = digest_hex(Some("sha256"), bytes).unwrap();
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, format!("{digest}  rustup-init\n").as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        verify("rust", "1.95.0", bytes, &v, &subs, &stub).unwrap();
    }

    #[test]
    fn digest_only_response_is_accepted() {
        let bytes = b"x";
        let digest = digest_hex(Some("sha256"), bytes).unwrap();
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, digest.as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        verify("rust", "1.95.0", bytes, &v, &subs, &stub).unwrap();
    }

    #[test]
    fn mismatched_digest_returns_verification_failed() {
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let bogus = "0".repeat(64);
        let stub = StubClient::with(url, format!("{bogus}  rustup-init\n").as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let err = verify("rust", "1.95.0", b"different bytes", &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier, tool, version, reason } => {
                assert_eq!(tier, 3);
                assert_eq!(tool, "rust");
                assert_eq!(version, "1.95.0");
                assert!(reason.contains("digest mismatch"));
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    #[test]
    fn missing_template_is_catalog_error() {
        let v = Verification {
            tier: 3,
            algorithm: Some("sha256".into()),
            pinned_checksum: None,
            checksum_url_template: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        };
        let stub = StubClient::with("ignored", b"");
        let subs = Substitutions::default();
        let err = verify("rust", "1.95.0", b"x", &v, &subs, &stub).unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn unparseable_response_returns_verification_failed() {
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, b"not a hex digest at all\n");
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let err = verify("rust", "1.95.0", b"x", &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 3, reason, .. } => {
                assert!(reason.contains("could not parse"));
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    #[test]
    fn parse_checksum_field_handles_digest_with_filename() {
        let token = parse_checksum_field("abcdef0123  rustup-init\n").unwrap();
        assert_eq!(token, "abcdef0123");
    }

    #[test]
    fn parse_checksum_field_handles_bare_digest() {
        assert_eq!(parse_checksum_field("abcdef0123\n").unwrap(), "abcdef0123");
    }

    #[test]
    fn parse_checksum_field_rejects_non_hex() {
        assert!(parse_checksum_field("garbage line\n").is_none());
    }

    #[test]
    fn parse_checksum_field_rejects_empty() {
        assert!(parse_checksum_field("").is_none());
    }
}
