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
//!
//! Two response shapes are supported, selected by the catalog's
//! `verification.checksum_manifest`:
//!
//! - **single checksum** (default) — the whole response is *the* digest for
//!   *the* artifact, as in rust's `rustup-init.sha256`.
//! - **manifest** (`checksum_manifest: true`) — one `<digest>  <filename>`
//!   line per artifact in the release, as in Node's `SHASUMS256.txt`. The
//!   line is selected by the resolved artifact filename. Selecting by
//!   position instead would verify a different architecture's binary and
//!   pass, so manifest mode never guesses: an absent or unparseable entry
//!   fails verification.

use containers_common::tooldb::Verification;

use super::sha::digests_equal;
use crate::error::{LuggageError, Result};
use crate::installer::download::HttpClient;
use crate::installer::template::{Substitutions, substitute_url};

/// Verify a precomputed artifact digest against the publisher-served checksum
/// URL in `verification`.
///
/// `actual_digest` is the artifact's hex digest, computed while the artifact
/// streamed to disk — this function never sees or re-reads the bytes, which is
/// what keeps peak memory independent of artifact size.
/// `artifact_filename` is the artifact's on-disk basename, used to select the
/// right line in manifest mode (ignored in single-checksum mode).
/// `subs` substitutes placeholders (e.g. `{rustup_target}`) into the checksum
/// URL template before fetching. `tool` and `version` are error-message context.
///
/// # Errors
///
/// - [`LuggageError::Catalog`] when `verification.checksum_url_template` is
///   missing — required for tier 3.
/// - [`LuggageError::TemplateMissingKey`] when the checksum URL template
///   references an unknown placeholder.
/// - [`LuggageError::DownloadFailed`] when the checksum file cannot be
///   fetched.
/// - [`LuggageError::VerificationFailed`] when the response is not UTF-8, the
///   expected digest cannot be parsed, a manifest has no line for
///   `artifact_filename`, a manifest line is malformed, or the digests differ.
pub fn verify(
    tool: &str,
    version: &str,
    actual_digest: &str,
    artifact_filename: &str,
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

    let fail = |reason: String| LuggageError::VerificationFailed {
        tool: tool.to_owned(),
        version: version.to_owned(),
        tier: 3,
        reason,
    };

    // The checksum document itself is small by construction (a digest, or one
    // short line per release artifact), so the buffered `get` is right here —
    // and the parsers below want a `&str`.
    let body = http.get(&url)?;
    let body_str = std::str::from_utf8(&body)
        .map_err(|_| fail(format!("checksum file at {url} is not valid UTF-8")))?;

    let expected = if verification.checksum_manifest.unwrap_or(false) {
        select_manifest_digest(body_str, artifact_filename).map_err(|e| {
            fail(match e {
                ManifestError::NoMatch => format!(
                    "checksum manifest at {url} has no entry for artifact `{artifact_filename}`"
                ),
                ManifestError::Malformed(line) => format!(
                    "checksum manifest at {url} has a malformed entry: `{line}` \
                     (while looking for `{artifact_filename}`)"
                ),
            })
        })?
    } else {
        parse_checksum_field(body_str)
            .ok_or_else(|| fail(format!("could not parse a digest out of {url}")))?
    };

    if digests_equal(actual_digest, expected) {
        Ok(())
    } else {
        Err(fail(format!("digest mismatch: expected {expected}, computed {actual_digest}")))
    }
}

/// Why a checksum manifest did not yield a digest.
#[derive(Debug)]
enum ManifestError {
    /// Every line parsed, but none named the artifact.
    NoMatch,
    /// A line was not `<hex-digest>  <filename>`. Carries the offending line.
    Malformed(String),
}

/// Select the digest for `artifact_filename` from a multi-entry checksum
/// manifest (`<digest>  <filename>` per line, as in Node's `SHASUMS256.txt`).
///
/// Fails closed in both directions — a malformed line is an error rather than
/// something to skip past, and a manifest with no matching entry is an error
/// rather than a fallback to the first line. Picking the wrong line here
/// verifies the wrong architecture's binary *successfully*, so there is no
/// safe way to guess.
///
/// Blank lines are ignored; publishers routinely end the file with a newline.
fn select_manifest_digest<'a>(
    body: &'a str,
    artifact_filename: &str,
) -> std::result::Result<&'a str, ManifestError> {
    for raw in body.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split_whitespace();
        let (Some(digest), Some(name)) = (fields.next(), fields.next()) else {
            return Err(ManifestError::Malformed(line.to_owned()));
        };
        if !is_hex(digest) {
            return Err(ManifestError::Malformed(line.to_owned()));
        }
        // Publishers prefix the filename with `*` in binary mode
        // (`sha256sum -b`), and some list a path rather than a bare name.
        let name = name.strip_prefix('*').unwrap_or(name);
        let name = name.rsplit('/').next().unwrap_or(name);
        if name == artifact_filename {
            return Ok(digest);
        }
    }
    Err(ManifestError::NoMatch)
}

/// Pull the digest token out of a publisher-style single-checksum response.
///
/// Accepts the two common shapes:
///
/// - `<hex>` (digest only, optional trailing newline)
/// - `<hex>  <filename>` (sha256sum/coreutils format)
fn parse_checksum_field(body: &str) -> Option<&str> {
    let line = body.lines().next()?.trim();
    let token = line.split_whitespace().next()?;
    if !is_hex(token) {
        return None;
    }
    Some(token)
}

/// True when `s` is non-empty and entirely ASCII hex digits.
fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit())
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
            checksum_manifest: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        }
    }

    /// Same as [`verification`] but in multi-entry manifest mode.
    fn manifest_verification(template: &str) -> Verification {
        Verification { checksum_manifest: Some(true), ..verification(template) }
    }

    #[test]
    fn matching_digest_passes() {
        let bytes = b"hello rustup-init body";
        let digest = digest_hex(Some("sha256"), bytes).unwrap();
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, format!("{digest}  rustup-init\n").as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        verify("rust", "1.95.0", &digest, "rustup-init", &v, &subs, &stub).unwrap();
    }

    #[test]
    fn digest_only_response_is_accepted() {
        let bytes = b"x";
        let digest = digest_hex(Some("sha256"), bytes).unwrap();
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, digest.as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        verify("rust", "1.95.0", &digest, "rustup-init", &v, &subs, &stub).unwrap();
    }

    #[test]
    fn mismatched_digest_returns_verification_failed() {
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let bogus = "0".repeat(64);
        let stub = StubClient::with(url, format!("{bogus}  rustup-init\n").as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let actual = digest_hex(Some("sha256"), b"different bytes").unwrap();
        let err = verify("rust", "1.95.0", &actual, "rustup-init", &v, &subs, &stub).unwrap_err();
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
            checksum_manifest: None,
            gpg_key_url: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        };
        let stub = StubClient::with("ignored", b"");
        let subs = Substitutions::default();
        let err = verify("rust", "1.95.0", "aa", "rustup-init", &v, &subs, &stub).unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn unparsable_response_returns_verification_failed() {
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, b"not a hex digest at all\n");
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let err = verify("rust", "1.95.0", "aa", "rustup-init", &v, &subs, &stub).unwrap_err();
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

    // --- multi-entry checksum manifest (Node's SHASUMS256.txt shape) --------

    const MANIFEST_URL: &str = "https://example.test/v22.12.0/SHASUMS256.txt";
    const MANIFEST_TEMPLATE: &str = "https://example.test/v{version}/SHASUMS256.txt";

    /// A manifest listing several architectures, with `wanted`'s digest on a
    /// line that is deliberately NOT first — a first-line parse would pick the
    /// wrong architecture and pass.
    fn manifest_listing(wanted: &str, wanted_digest: &str) -> String {
        let other = "1".repeat(64);
        format!(
            "{other}  node-v22.12.0-linux-x64.tar.xz\n\
             {other}  node-v22.12.0-darwin-arm64.tar.gz\n\
             {wanted_digest}  {wanted}\n\
             {other}  node-v22.12.0-headers.tar.gz\n"
        )
    }

    #[test]
    fn manifest_selects_line_matching_artifact_filename() {
        let artifact = "node-v22.12.0-linux-arm64.tar.xz";
        let digest = digest_hex(Some("sha256"), b"arm64 tarball bytes").unwrap();
        let stub = StubClient::with(MANIFEST_URL, manifest_listing(artifact, &digest).as_bytes());
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "aarch64-unknown-linux-gnu");
        verify("node", "22.12.0", &digest, artifact, &v, &subs, &stub).unwrap();
    }

    /// The silent-correctness case the issue is really about: the digest of a
    /// DIFFERENT architecture's artifact must not verify just because it is
    /// present in the manifest.
    #[test]
    fn manifest_rejects_digest_of_a_different_architecture() {
        let artifact = "node-v22.12.0-linux-arm64.tar.xz";
        let arm64_digest = digest_hex(Some("sha256"), b"arm64 tarball bytes").unwrap();
        let stub =
            StubClient::with(MANIFEST_URL, manifest_listing(artifact, &arm64_digest).as_bytes());
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "aarch64-unknown-linux-gnu");
        // The x64 line's digest ("1"*64) paired with the arm64 filename.
        let x64_digest = "1".repeat(64);
        let err = verify("node", "22.12.0", &x64_digest, artifact, &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 3, reason, .. } => {
                assert!(reason.contains("digest mismatch"), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    #[test]
    fn manifest_without_matching_filename_names_the_sought_file() {
        let stub = StubClient::with(
            MANIFEST_URL,
            manifest_listing("node-v22.12.0-linux-x64.tar.xz", &"2".repeat(64)).as_bytes(),
        );
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "riscv64gc-unknown-linux-gnu");
        let missing = "node-v22.12.0-linux-riscv64.tar.xz";
        let err =
            verify("node", "22.12.0", &"2".repeat(64), missing, &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 3, reason, .. } => {
                // The AC requires the message name the filename searched for.
                assert!(reason.contains(missing), "message must name the artifact: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    #[test]
    fn manifest_with_malformed_line_fails_rather_than_skipping() {
        let digest = "3".repeat(64);
        let artifact = "node-v22.12.0-linux-x64.tar.xz";
        // A digest with no filename — must fail, NOT be skipped on the way to
        // the valid line below it.
        let body = format!("{digest}\n{digest}  {artifact}\n");
        let stub = StubClient::with(MANIFEST_URL, body.as_bytes());
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "x86_64-unknown-linux-gnu");
        let err = verify("node", "22.12.0", &digest, artifact, &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 3, reason, .. } => {
                assert!(reason.contains("malformed"), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    #[test]
    fn manifest_with_non_hex_digest_is_malformed() {
        let artifact = "node-v22.12.0-linux-x64.tar.xz";
        let body = format!("not-a-digest  {artifact}\n");
        let stub = StubClient::with(MANIFEST_URL, body.as_bytes());
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "x86_64-unknown-linux-gnu");
        let err =
            verify("node", "22.12.0", &"4".repeat(64), artifact, &v, &subs, &stub).unwrap_err();
        match err {
            LuggageError::VerificationFailed { tier: 3, reason, .. } => {
                assert!(reason.contains("malformed"), "got: {reason}");
            }
            other => panic!("expected VerificationFailed, got {other:?}"),
        }
    }

    /// An empty manifest must fail closed, not vacuously pass.
    #[test]
    fn empty_manifest_is_a_verification_failure() {
        let stub = StubClient::with(MANIFEST_URL, b"\n\n");
        let v = manifest_verification(MANIFEST_TEMPLATE);
        let subs = Substitutions::new("22.12.0", "x86_64-unknown-linux-gnu");
        let err =
            verify("node", "22.12.0", &"5".repeat(64), "x.tar.xz", &v, &subs, &stub).unwrap_err();
        assert!(matches!(err, LuggageError::VerificationFailed { tier: 3, .. }));
    }

    #[test]
    fn select_manifest_digest_handles_binary_mode_star_prefix() {
        let digest = "6".repeat(64);
        let body = format!("{digest} *node-v22.12.0-linux-x64.tar.xz\n");
        let got = select_manifest_digest(&body, "node-v22.12.0-linux-x64.tar.xz").unwrap();
        assert_eq!(got, digest);
    }

    #[test]
    fn select_manifest_digest_matches_on_basename_of_a_path() {
        let digest = "7".repeat(64);
        let body = format!("{digest}  ./dist/node-v22.12.0-linux-x64.tar.xz\n");
        let got = select_manifest_digest(&body, "node-v22.12.0-linux-x64.tar.xz").unwrap();
        assert_eq!(got, digest);
    }

    #[test]
    fn select_manifest_digest_ignores_blank_lines() {
        let digest = "8".repeat(64);
        let body = format!("\n{digest}  a.tar.xz\n\n");
        assert_eq!(select_manifest_digest(&body, "a.tar.xz").unwrap(), digest);
    }

    /// Manifest mode is opt-in: a manifest body under the DEFAULT
    /// (single-checksum) mode still takes the first line, unchanged.
    #[test]
    fn single_checksum_mode_is_unaffected_by_manifest_shaped_body() {
        let digest = "9".repeat(64);
        let body = format!("{digest}  first.tar.xz\n{}  second.tar.xz\n", "a".repeat(64));
        let url = "https://example.test/x86_64-unknown-linux-gnu/rustup-init.sha256";
        let stub = StubClient::with(url, body.as_bytes());
        let v = verification("https://example.test/{rustup_target}/rustup-init.sha256");
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        // Filename is ignored in single-checksum mode — first line wins.
        verify("rust", "1.95.0", &digest, "totally-unrelated-name", &v, &subs, &stub).unwrap();
    }
}
