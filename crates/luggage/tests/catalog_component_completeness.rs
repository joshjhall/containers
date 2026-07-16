//! Catalog invariant: every Rust version entry carries the full rustup
//! component set.
//!
//! When a consumer repo pins a Rust version divergent from the image default,
//! the runtime reconciler and the luggage installer both drive the pinned
//! toolchain's `component_add` post-install steps. If a catalog version is
//! missing `rust-analyzer`/`clippy`/`rustfmt`, that pinned toolchain lands
//! without cargo subcommands or LSP support — the half-install footgun from
//! #740. This test locks in that *every* rust version resolves with the same
//! four components, so a future `catalog add-version` (or a hand-edited entry)
//! can't silently reintroduce a component-incomplete version.

use std::path::PathBuf;

use containers_common::tooldb::PostInstall;
use luggage::{Catalog, CatalogSource};

fn testdata_catalog() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata").join("catalog")
}

/// The components every rust toolchain must carry to be usable for
/// development (cargo subcommands + LSP), beyond the base `rustc`/`cargo`
/// that ship with the default profile.
const REQUIRED_COMPONENTS: &[&str] = &["rust-src", "rust-analyzer", "clippy", "rustfmt"];

#[test]
fn every_rust_version_carries_full_component_set() {
    let catalog =
        Catalog::load(CatalogSource::LocalPath(testdata_catalog())).expect("load testdata catalog");
    let rust = catalog.tool_entry("rust").expect("catalog has a rust tool entry");

    let mut failures = Vec::new();

    for (version, doc) in &rust.versions {
        // Gather every component added by any install method's post-install
        // steps for this version.
        let components: Vec<&str> = doc
            .install_methods
            .iter()
            .flat_map(|m| m.post_install.iter().flatten())
            .filter_map(|step| match step {
                PostInstall::ComponentAdd { component } => Some(component.as_str()),
                _ => None,
            })
            .collect();

        let missing: Vec<&str> =
            REQUIRED_COMPONENTS.iter().copied().filter(|req| !components.contains(req)).collect();

        if !missing.is_empty() {
            failures.push(format!("rust@{version} missing components: {missing:?}"));
        }
    }

    assert!(
        failures.is_empty(),
        "component-incomplete rust catalog entries:\n  {}",
        failures.join("\n  ")
    );
}
