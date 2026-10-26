//! Catalog invariant: every node version resolves to the arch-correct
//! artifact, and tier-3 manifest verification refuses the other arch's line.
//!
//! node names its amd64 artifact `linux-x64`, but luggage substitutes `{arch}`
//! with the catalog arch verbatim (`amd64`). The catalog therefore carries one
//! install method per arch, each with a literal URL, and relies on the
//! resolver's first-match arch walk to pick it (#812). Two silent-corruption
//! risks follow, and this test locks out both:
//!
//! 1. A version entry whose methods are swapped, duplicated, or mis-predicated
//!    would hand an arm64 host the x64 tarball (or vice versa). That still
//!    *verifies* — the manifest lists every arch — so nothing downstream
//!    would notice until `node` failed to exec. Checked for every vendored
//!    version on both arches, not a sample: a single hand-edited entry is
//!    exactly the shape this has to catch.
//! 2. `SHASUMS256.txt` lists every artifact of a release. Manifest mode must
//!    select the line by the artifact's own filename; a manifest carrying only
//!    the other arch's line must FAIL rather than verify against it.

use std::path::PathBuf;

use luggage::installer::download::HttpClient;
use luggage::installer::template::Substitutions;
use luggage::installer::verify::tier3;
use luggage::resolver::resolve;
use luggage::{Catalog, CatalogSource, LuggageError, Platform, Result, VersionSpec};

fn testdata_catalog() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata").join("catalog")
}

/// (catalog arch, node's spelling of it in artifact names).
const ARCHES: [(&str, &str); 2] = [("amd64", "x64"), ("arm64", "arm64")];

fn debian13(arch: &str) -> Platform {
    Platform { os: "debian".into(), os_version: Some("13".into()), arch: arch.into() }
}

/// Serves one fixed body for one URL; anything else is a download failure.
struct StubClient {
    url: String,
    body: Vec<u8>,
}

impl HttpClient for StubClient {
    fn get(&self, url: &str) -> Result<Vec<u8>> {
        if url == self.url {
            Ok(self.body.clone())
        } else {
            Err(LuggageError::DownloadFailed {
                url: url.to_owned(),
                attempts: 1,
                message: "unexpected URL in test".to_owned(),
            })
        }
    }
}

#[test]
fn every_node_version_resolves_to_its_arch_artifact() {
    let catalog =
        Catalog::load(CatalogSource::LocalPath(testdata_catalog())).expect("load testdata catalog");
    let node = catalog.tool_entry("node").expect("catalog has a node tool entry");
    assert!(!node.versions.is_empty(), "node entry has no versions");

    let mut failures = Vec::new();
    for doc in node.versions.values() {
        let v = &doc.version;
        for (arch, node_arch) in ARCHES {
            let r = match resolve(node, &VersionSpec::Exact(v.clone()), &debian13(arch)) {
                Ok(r) => r,
                Err(e) => {
                    failures.push(format!("{v}/{arch}: resolve failed: {e}"));
                    continue;
                }
            };
            let want = format!(
                "https://nodejs.org/dist/v{{version}}/node-v{{version}}-linux-{node_arch}.tar.xz"
            );
            if r.source_url_template.as_deref() != Some(want.as_str()) {
                failures.push(format!(
                    "{v}/{arch}: source_url_template {:?}, want {want:?}",
                    r.source_url_template
                ));
            }
            if r.method_name != format!("node-tarball-{arch}") {
                failures.push(format!("{v}/{arch}: method {}", r.method_name));
            }
            if r.verification.checksum_manifest != Some(true) || r.verification.tier != 3 {
                failures.push(format!("{v}/{arch}: not tier-3 manifest mode"));
            }
        }
    }
    assert!(failures.is_empty(), "node arch resolution defects:\n{}", failures.join("\n"));
}

/// A `SHASUMS256.txt` shaped like nodejs.org's: many artifacts, each arch's
/// tarball with a distinct digest. `omit` drops one filename's line.
fn shasums(version: &str, omit: Option<&str>) -> String {
    let lines = [
        ('1', format!("node-v{version}-darwin-arm64.tar.gz")),
        ('2', format!("node-v{version}-linux-arm64.tar.xz")),
        ('3', format!("node-v{version}-linux-x64.tar.xz")),
        ('4', format!("node-v{version}-linux-x64.tar.gz")),
        ('5', format!("node-v{version}-win-x64.zip")),
    ];
    let mut body = String::new();
    for (d, name) in lines.iter().filter(|(_, name)| Some(name.as_str()) != omit) {
        body.push_str(&d.to_string().repeat(64));
        body.push_str("  ");
        body.push_str(name);
        body.push('\n');
    }
    body
}

#[test]
fn manifest_verification_is_arch_correct_over_the_real_node_entry() {
    let catalog =
        Catalog::load(CatalogSource::LocalPath(testdata_catalog())).expect("load testdata catalog");
    let node = catalog.tool_entry("node").expect("catalog has a node tool entry");
    let version = &node.index.default_version.clone().expect("node has a default_version");

    for (arch, node_arch) in ARCHES {
        let r = resolve(node, &VersionSpec::Exact(version.clone()), &debian13(arch))
            .expect("default version resolves");
        let subs = Substitutions { version: Some(version), ..Substitutions::default() };
        let url = format!("https://nodejs.org/dist/v{version}/SHASUMS256.txt");
        let artifact = format!("node-v{version}-linux-{node_arch}.tar.xz");
        let own = if node_arch == "x64" { '3' } else { '2' }.to_string().repeat(64);
        let other = if node_arch == "x64" { '2' } else { '3' }.to_string().repeat(64);

        // The arch's own digest verifies.
        let full = StubClient { url: url.clone(), body: shasums(version, None).into_bytes() };
        tier3::verify("node", version, &own, &artifact, &r.verification, &subs, &full)
            .unwrap_or_else(|e| panic!("{arch}: own digest must verify: {e}"));

        // The other arch's digest — present in the same manifest — must not.
        let err = tier3::verify("node", version, &other, &artifact, &r.verification, &subs, &full)
            .expect_err("other arch's digest must not verify");
        assert!(matches!(err, LuggageError::VerificationFailed { .. }), "{arch}: {err:?}");

        // A manifest missing this arch's line fails, rather than falling back
        // to some other entry (the other arch's tarball is still listed).
        let missing =
            StubClient { url: url.clone(), body: shasums(version, Some(&artifact)).into_bytes() };
        let err =
            tier3::verify("node", version, &other, &artifact, &r.verification, &subs, &missing)
                .expect_err("manifest without this arch's line must fail");
        assert!(
            err.to_string().contains(&artifact),
            "{arch}: failure names the sought artifact: {err}"
        );
    }
}
