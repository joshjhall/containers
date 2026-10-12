//! Refresh a catalog's `tested[]` evidence from the published containers-db.
//!
//! The catalog luggage ships (the vendored snapshot the image COPYs to
//! `/opt/containers-db`) gates install data against containers-db, but not
//! evidence: evidence-run appends `tested[]` rows upstream on every merged
//! evidence PR, so a vendored copy is stale by design. [`crate::reconcile`]
//! judges `support_matrix` claims against that evidence, and judging them
//! against a stale copy reports coverage gaps that upstream has already
//! closed.
//!
//! So before reconciling, each version's evidence is replaced with the
//! published copy. The published file is fetched per version and only its
//! `tested[]` is taken; install data stays whatever the caller loaded.
//!
//! ## When the published copy is not available
//!
//! - **Not published** (HTTP 404): containers-db was reached and has no entry
//!   for this version yet. That is an answer, not an outage: the vendored
//!   evidence is all there is, and it is judged normally.
//! - **Unreachable** (network error, 5xx, unparsable body): the vendored
//!   evidence is used, but it may be stale — acceptably so in an offline or
//!   air-gapped environment. The caller reports it as a warning that names
//!   the evidence's newest `tested_at`, and does not let it block.

use std::time::Duration;

use containers_common::tooldb::ToolVersion;
use serde::Serialize;

/// Published containers-db, as raw files on its default branch.
pub const DEFAULT_PUBLISHED_BASE: &str =
    "https://raw.githubusercontent.com/joshjhall/containers-db/main";

/// Outcome of fetching one published version file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fetched {
    /// The file body.
    Found(Vec<u8>),
    /// The server answered that the file does not exist (HTTP 404).
    NotFound,
    /// No authoritative answer: network failure, a non-404 error status, or a
    /// body that could not be read. Carries the reason for the warning.
    Unreachable(String),
}

/// Fetches published containers-db files. Trait-wrapped so tests inject a
/// stub instead of touching the network.
pub trait EvidenceSource {
    /// Fetch `tools/<tool>/versions/<version>.json`.
    fn fetch(&self, tool: &str, version: &str) -> Fetched;
}

/// [`EvidenceSource`] over HTTPS.
///
/// Distinct from the installer's [`crate::installer::download::HttpClient`]
/// on purpose: that contract folds every failure into one error after
/// retrying, and this one must tell "not published" (authoritative, judged
/// normally) from "unreachable" (stale, a warning). A 404 is answered on the
/// first attempt; nothing is retried, so an offline host costs one timeout
/// per version rather than a retry budget.
#[derive(Debug, Clone)]
pub struct HttpEvidenceSource {
    base: String,
    agent: ureq::Agent,
}

impl HttpEvidenceSource {
    /// Source rooted at `base` (no trailing slash), e.g.
    /// [`DEFAULT_PUBLISHED_BASE`].
    #[must_use]
    pub fn new(base: impl Into<String>) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(10)))
            .build()
            .into();
        Self { base: base.into().trim_end_matches('/').to_owned(), agent }
    }
}

impl EvidenceSource for HttpEvidenceSource {
    fn fetch(&self, tool: &str, version: &str) -> Fetched {
        let url = format!("{}/tools/{tool}/versions/{version}.json", self.base);
        match self.agent.get(&url).call() {
            Ok(resp) => {
                let mut body = Vec::new();
                // Version files are a few KiB; 1 MiB bounds a misbehaving
                // server without constraining any real entry.
                match std::io::Read::read_to_end(
                    &mut std::io::Read::take(resp.into_body().into_reader(), 1024 * 1024),
                    &mut body,
                ) {
                    Ok(_) => Fetched::Found(body),
                    Err(e) => Fetched::Unreachable(format!("{url}: reading body: {e}")),
                }
            }
            Err(ureq::Error::StatusCode(404)) => Fetched::NotFound,
            Err(e) => Fetched::Unreachable(format!("{url}: {e}")),
        }
    }
}

/// Where one version's evidence came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum EvidenceOrigin {
    /// Replaced with the published copy.
    Published,
    /// containers-db has no entry for this version; the loaded evidence is
    /// all there is.
    NotPublished,
    /// The published copy could not be read; the loaded evidence was used
    /// and may be stale.
    Fallback {
        /// Why the published copy was unavailable.
        reason: String,
        /// Newest `tested_at` in the evidence that was used, if any — how
        /// stale it might be.
        #[serde(skip_serializing_if = "Option::is_none")]
        newest_tested_at: Option<String>,
    },
}

impl EvidenceOrigin {
    /// `true` when the evidence used may be stale, so findings against it
    /// are warnings rather than gate failures.
    #[must_use]
    pub const fn is_fallback(&self) -> bool {
        matches!(self, Self::Fallback { .. })
    }
}

/// Newest `tested_at` among `doc`'s evidence rows. RFC 3339 UTC timestamps
/// sort chronologically as strings, as [`crate::reconcile`] relies on too.
fn newest_tested_at(doc: &ToolVersion) -> Option<String> {
    doc.tested.iter().map(|t| t.tested_at.clone()).max()
}

/// Replace `doc.tested` with the published copy from `source`, and report
/// where the evidence now in `doc` came from.
///
/// A published file for a *different* tool/version (a misrouted response) is
/// treated as unreachable rather than trusted.
pub fn refresh_evidence(doc: &mut ToolVersion, source: &dyn EvidenceSource) -> EvidenceOrigin {
    match source.fetch(&doc.tool, &doc.version) {
        Fetched::Found(body) => match serde_json::from_slice::<ToolVersion>(&body) {
            Ok(published) if published.tool == doc.tool && published.version == doc.version => {
                doc.tested = published.tested;
                EvidenceOrigin::Published
            }
            Ok(published) => EvidenceOrigin::Fallback {
                reason: format!(
                    "published file names {}@{}, expected {}@{}",
                    published.tool, published.version, doc.tool, doc.version
                ),
                newest_tested_at: newest_tested_at(doc),
            },
            Err(e) => EvidenceOrigin::Fallback {
                reason: format!("published file did not parse: {e}"),
                newest_tested_at: newest_tested_at(doc),
            },
        },
        Fetched::NotFound => EvidenceOrigin::NotPublished,
        Fetched::Unreachable(reason) => {
            EvidenceOrigin::Fallback { reason, newest_tested_at: newest_tested_at(doc) }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use containers_common::tooldb::{InstallMethod, TestEntry, TestResult, VersionMetadata};

    struct Stub(Fetched);

    impl EvidenceSource for Stub {
        fn fetch(&self, _tool: &str, _version: &str) -> Fetched {
            self.0.clone()
        }
    }

    fn row(tested_at: &str) -> TestEntry {
        serde_json::from_value(serde_json::json!({
            "os": "debian", "os_version": "12", "arch": "amd64",
            "tested_at": tested_at, "result": "pass"
        }))
        .unwrap()
    }

    fn doc(version: &str, tested: Vec<TestEntry>) -> ToolVersion {
        ToolVersion {
            schema_version: 1,
            tool: "rust".into(),
            version: version.into(),
            released: None,
            channel: None,
            support_matrix: vec![],
            tested,
            requires: None,
            install_methods: Vec::<InstallMethod>::new(),
            uninstall: None,
            metadata: VersionMetadata {
                added_at: "2026-06-01T00:00:00Z".into(),
                updated_at: None,
                schema_version: 1,
            },
        }
    }

    fn body(d: &ToolVersion) -> Vec<u8> {
        serde_json::to_vec(d).unwrap()
    }

    #[test]
    fn published_evidence_replaces_the_loaded_rows() {
        let mut d = doc("1.95.0", vec![row("2026-01-01T00:00:00Z")]);
        let published = doc("1.95.0", vec![row("2026-10-12T04:01:42Z")]);
        let origin = refresh_evidence(&mut d, &Stub(Fetched::Found(body(&published))));
        assert_eq!(origin, EvidenceOrigin::Published);
        assert_eq!(d.tested.len(), 1);
        assert_eq!(d.tested[0].tested_at, "2026-10-12T04:01:42Z");
        assert_eq!(d.tested[0].result, TestResult::Pass);
    }

    #[test]
    fn not_published_keeps_the_loaded_rows_and_is_not_a_fallback() {
        let mut d = doc("1.99.0", vec![row("2026-10-01T00:00:00Z")]);
        let origin = refresh_evidence(&mut d, &Stub(Fetched::NotFound));
        assert_eq!(origin, EvidenceOrigin::NotPublished);
        assert!(!origin.is_fallback());
        assert_eq!(d.tested.len(), 1);
    }

    #[test]
    fn unreachable_falls_back_and_names_the_newest_evidence() {
        let mut d = doc("1.95.0", vec![row("2026-03-01T00:00:00Z"), row("2026-09-30T12:00:00Z")]);
        let origin =
            refresh_evidence(&mut d, &Stub(Fetched::Unreachable("connection refused".into())));
        assert_eq!(
            origin,
            EvidenceOrigin::Fallback {
                reason: "connection refused".into(),
                newest_tested_at: Some("2026-09-30T12:00:00Z".into()),
            }
        );
        assert!(origin.is_fallback());
        assert_eq!(d.tested.len(), 2, "fallback keeps the loaded evidence");
    }

    #[test]
    fn fallback_with_no_evidence_has_no_timestamp() {
        let mut d = doc("1.95.0", vec![]);
        let origin = refresh_evidence(&mut d, &Stub(Fetched::Unreachable("offline".into())));
        assert_eq!(
            origin,
            EvidenceOrigin::Fallback { reason: "offline".into(), newest_tested_at: None }
        );
    }

    #[test]
    fn a_misrouted_published_file_is_not_trusted() {
        let mut d = doc("1.95.0", vec![row("2026-01-01T00:00:00Z")]);
        let wrong = doc("1.96.0", vec![row("2026-10-12T00:00:00Z")]);
        let origin = refresh_evidence(&mut d, &Stub(Fetched::Found(body(&wrong))));
        assert!(origin.is_fallback(), "got {origin:?}");
        assert_eq!(d.tested[0].tested_at, "2026-01-01T00:00:00Z", "loaded rows untouched");
    }

    #[test]
    fn an_unparsable_published_file_falls_back() {
        let mut d = doc("1.95.0", vec![row("2026-01-01T00:00:00Z")]);
        let origin =
            refresh_evidence(&mut d, &Stub(Fetched::Found(b"<html>rate limited</html>".to_vec())));
        assert!(origin.is_fallback(), "got {origin:?}");
        assert_eq!(d.tested.len(), 1);
    }

    #[test]
    fn origin_serializes_with_a_source_tag() {
        let v = serde_json::to_value(EvidenceOrigin::Fallback {
            reason: "offline".into(),
            newest_tested_at: Some("2026-09-30T12:00:00Z".into()),
        })
        .unwrap();
        assert_eq!(
            v,
            serde_json::json!({
                "source": "fallback",
                "reason": "offline",
                "newest_tested_at": "2026-09-30T12:00:00Z"
            })
        );
        assert_eq!(
            serde_json::to_value(EvidenceOrigin::Published).unwrap(),
            serde_json::json!({"source": "published"})
        );
    }
}
