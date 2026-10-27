//! Catalog invariant: every node version resolves to the arch-correct
//! artifact, every node and go entry is a well-formed tier-1 entry against a
//! keyring that ships in the catalog, and tier-1 signed-manifest verification
//! over the REAL node entry accepts the arch's own line and refuses the other
//! arch's.
//!
//! node names its amd64 artifact `linux-x64`, but luggage substitutes `{arch}`
//! with the catalog arch verbatim (`amd64`). The catalog therefore carries one
//! install method per arch, each with a literal URL, and relies on the
//! resolver's first-match arch walk to pick it (#812). Two silent-corruption
//! risks follow, and this test locks out both:
//!
//! 1. A version entry whose methods are swapped, duplicated, or mis-predicated
//!    would hand an arm64 host the x64 tarball (or vice versa). That still
//!    *verifies* — the signed manifest lists every arch — so nothing
//!    downstream would notice until `node` failed to exec. Checked for every
//!    vendored version on both arches, not a sample: a single hand-edited
//!    entry is exactly the shape this has to catch.
//! 2. `SHASUMS256.txt` lists every artifact of a release. Manifest mode must
//!    select the line by the artifact's own filename; the other arch's digest,
//!    present in the very same signed manifest, must FAIL.
//!
//! Since #1521 node and go are tier 1 (containers-db#499): the vendored
//! catalog ships `keyrings/`, which the Dockerfile COPYs with the rest of the
//! catalog to `/opt/containers-db`. A version file naming a keyring the
//! catalog does not ship would only fail at install time, inside an image
//! build, so the pre-download shape check is run over every entry here.

use std::path::{Path, PathBuf};

use containers_common::tooldb::Verification;
use luggage::installer::download::HttpClient;
use luggage::installer::template::Substitutions;
use luggage::installer::verify::{self, Artifact, tier1};
use luggage::resolver::resolve;
use luggage::{Catalog, CatalogSource, LuggageError, Platform, Result, VersionSpec};

fn testdata() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn testdata_catalog() -> PathBuf {
    testdata().join("catalog")
}

/// (catalog arch, node's spelling of it in artifact names).
const ARCHES: [(&str, &str); 2] = [("amd64", "x64"), ("arm64", "arm64")];

fn debian13(arch: &str) -> Platform {
    Platform { os: "debian".into(), os_version: Some("13".into()), arch: arch.into() }
}

/// Serves a fixed body per URL; anything else is a download failure.
struct StubClient(Vec<(String, Vec<u8>)>);

impl HttpClient for StubClient {
    fn get(&self, url: &str) -> Result<Vec<u8>> {
        self.0.iter().find(|(u, _)| u == url).map(|(_, b)| b.clone()).ok_or_else(|| {
            LuggageError::DownloadFailed {
                url: url.to_owned(),
                attempts: 1,
                message: "unexpected URL in test".to_owned(),
            }
        })
    }
}

/// Is `v` the tier-1 signed-manifest block node's methods carry?
fn is_node_tier1(v: &Verification) -> bool {
    v.tier == 1
        && v.algorithm.as_deref() == Some("gpg")
        && v.checksum_manifest == Some(true)
        && v.gpg_keyring.as_deref() == Some("keyrings/nodejs.asc")
        && v.gpg_key_url.is_none()
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
            if !is_node_tier1(&r.verification) {
                failures.push(format!("{v}/{arch}: not tier-1 signed-manifest mode"));
            }
        }
    }
    assert!(failures.is_empty(), "node arch resolution defects:\n{}", failures.join("\n"));
}

/// Every node and go version, on every catalog platform, passes the
/// pre-download tier-1 check against the vendored catalog root — the check a
/// real install runs first, which resolves `gpg_keyring` under the root and
/// refuses a missing or escaping keyring. Plus each pinned keyring parses.
#[test]
fn every_node_and_go_entry_is_installable_at_tier_1_from_the_vendored_catalog() {
    let root = testdata_catalog();
    let catalog = Catalog::load(CatalogSource::LocalPath(root.clone())).expect("load catalog");
    let platforms = [
        debian13("amd64"),
        debian13("arm64"),
        Platform { os: "alpine".into(), os_version: Some("3.22".into()), arch: "arm64".into() },
        Platform { os: "rhel".into(), os_version: Some("9".into()), arch: "amd64".into() },
    ];

    let mut checked = 0;
    let mut failures = Vec::new();
    for tool in ["node", "go"] {
        let entry = catalog.tool_entry(tool).expect("catalog has the tool");
        for doc in entry.versions.values() {
            for p in &platforms {
                let Ok(r) = resolve(entry, &VersionSpec::Exact(doc.version.clone()), p) else {
                    continue; // platform not in this version's support matrix
                };
                checked += 1;
                if r.verification.tier != 1 {
                    failures
                        .push(format!("{tool}@{} {p:?}: tier {}", r.version, r.verification.tier));
                    continue;
                }
                if let Err(e) =
                    verify::ensure_supported(tool, &r.version, &r.verification, true, Some(&root))
                {
                    failures.push(format!("{tool}@{} {p:?}: {e}", r.version));
                }
            }
        }
    }
    assert!(checked > 290, "only {checked} tool/platform pairs resolved — catalog shrank?");
    assert!(failures.is_empty(), "tier-1 entry defects:\n{}", failures.join("\n"));
}

/// The REAL node release key's signature over the REAL v22.23.4
/// `SHASUMS256.txt`, verified through the real catalog entry against the
/// vendored keyring: each arch's own digest verifies, the other arch's —
/// present in the same signed manifest — does not.
#[test]
fn signed_manifest_verification_is_arch_correct_over_the_real_node_entry() {
    let root = testdata_catalog();
    let catalog = Catalog::load(CatalogSource::LocalPath(root.clone())).expect("load catalog");
    let node = catalog.tool_entry("node").expect("catalog has a node tool entry");
    let version = "22.23.4";
    let manifest = std::fs::read(testdata().join("tier1/node-v22.23.4-SHASUMS256.txt")).unwrap();
    let sig = std::fs::read(testdata().join("tier1/node-v22.23.4-SHASUMS256.txt.sig")).unwrap();
    let base = format!("https://nodejs.org/dist/v{version}");
    let http = StubClient(vec![
        (format!("{base}/SHASUMS256.txt"), manifest.clone()),
        (format!("{base}/SHASUMS256.txt.sig"), sig),
    ]);
    let line_for = |artifact: &str| -> String {
        let body = std::str::from_utf8(&manifest).unwrap();
        body.lines()
            .find(|l| l.ends_with(&format!("  {artifact}")))
            .and_then(|l| l.split_whitespace().next())
            .unwrap_or_else(|| panic!("real manifest lists {artifact}"))
            .to_owned()
    };

    for (arch, node_arch) in ARCHES {
        let r = resolve(node, &VersionSpec::Exact(version.parse().unwrap()), &debian13(arch))
            .expect("v22.23.4 resolves");
        let subs = Substitutions { version: Some(version), ..Substitutions::default() };
        let artifact = format!("node-v{version}-linux-{node_arch}.tar.xz");
        let other_arch = if node_arch == "x64" { "arm64" } else { "x64" };
        let own = line_for(&artifact);
        let other = line_for(&format!("node-v{version}-linux-{other_arch}.tar.xz"));
        let at = |digest: &str| {
            let a = Artifact { digest, filename: &artifact, path: Path::new("/nonexistent") };
            tier1::verify("node", version, &a, &r.verification, &subs, &http, Some(&root))
        };

        at(&own).unwrap_or_else(|e| panic!("{arch}: own digest must verify: {e}"));
        let err = at(&other).expect_err("the other arch's digest must not verify");
        assert!(
            matches!(&err, LuggageError::VerificationFailed { tier: 1, reason, .. }
                if reason.contains("digest mismatch")),
            "{arch}: {err:?}"
        );
    }
}
