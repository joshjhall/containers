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
        // Checked PER INSTALL METHOD, not pooled across the version.
        //
        // Pooling hid a real defect: the vendored 1.97.x entries listed the
        // full component set on the debian/ubuntu/rhel method but had NO
        // post_install at all on the alpine (musl) one. A union across methods
        // still saw all four components, so the version looked complete while
        // every Alpine build installed rustc/cargo without clippy, rustfmt, or
        // rust-analyzer — precisely the #740 footgun, on one platform. Which
        // method runs is decided by the resolver at install time, so each one
        // must independently carry the full set. (Found while adding the
        // vendored-catalog drift check, #815.)
        for method in &doc.install_methods {
            let components: Vec<&str> = method
                .post_install
                .iter()
                .flatten()
                .filter_map(|step| match step {
                    PostInstall::ComponentAdd { component } => Some(component.as_str()),
                    _ => None,
                })
                .collect();

            let missing: Vec<&str> = REQUIRED_COMPONENTS
                .iter()
                .copied()
                .filter(|req| !components.contains(req))
                .collect();

            if !missing.is_empty() {
                failures.push(format!(
                    "rust@{version} method `{}` missing components: {missing:?}",
                    method.name
                ));
            }
        }
    }

    assert!(
        failures.is_empty(),
        "component-incomplete rust catalog entries:\n  {}",
        failures.join("\n  ")
    );
}

/// The binaries every rust install method must surface in `bin_root`, matching
/// what `lib/features/rust.sh` puts on `PATH`. Was the `RUST_BINARIES` const in
/// luggage until #806 moved it into the catalog.
const REQUIRED_BINARIES: &[&str] =
    &["rustc", "cargo", "rustup", "rust-analyzer", "rustfmt", "clippy-driver"];

/// Every rust install method carries the catalog fields the engine needs:
/// the six-binary set, the dir to link them from, and the cargo/rustup cache
/// layout.
///
/// Checked PER INSTALL METHOD for the same reason as the component set above
/// — the resolver picks exactly one method based on the target platform, so a
/// union across methods answers a question nobody asks. Pooling previously hid
/// an alpine arm with no `post_install` at all (#815); an alpine arm with no
/// `binaries` would fail identically, leaving every Alpine build with a
/// toolchain installed but nothing on `PATH`.
#[test]
fn every_rust_install_method_declares_binaries_and_cache_dirs() {
    let catalog =
        Catalog::load(CatalogSource::LocalPath(testdata_catalog())).expect("load testdata catalog");
    let rust = catalog.tool_entry("rust").expect("catalog has a rust tool entry");

    assert_eq!(
        rust.index.primary_binary.as_deref(),
        Some("rustc"),
        "the rust index must declare primary_binary; the tool-id fallback would probe \
         `<bin_root>/rust`, which never exists",
    );

    let mut failures = Vec::new();

    for (version, doc) in &rust.versions {
        for method in &doc.install_methods {
            let named = |what: &str| format!("rust@{version} method `{}` {what}", method.name);

            match method.binaries.as_deref() {
                None => failures.push(named("declares no `binaries`")),
                Some(binaries) => {
                    let missing: Vec<&str> = REQUIRED_BINARIES
                        .iter()
                        .copied()
                        .filter(|req| !binaries.iter().any(|b| b == req))
                        .collect();
                    if !missing.is_empty() {
                        failures.push(named(&format!("missing binaries: {missing:?}")));
                    }
                }
            }

            if method.bin_source_dir.as_deref() != Some("cargo/bin") {
                failures.push(named(&format!(
                    "has bin_source_dir {:?}, expected `cargo/bin`",
                    method.bin_source_dir,
                )));
            }

            // The cache layout the rustup proxies need: without both, validate
            // falls back to `$HOME/.rustup` and reports "no default toolchain
            // configured" even on a healthy install (#463).
            match method.cache_dirs.as_ref() {
                None => failures.push(named("declares no `cache_dirs`")),
                Some(dirs) => {
                    for (var, expected) in [("CARGO_HOME", "cargo"), ("RUSTUP_HOME", "rustup")] {
                        if dirs.get(var).map(String::as_str) != Some(expected) {
                            failures.push(named(&format!(
                                "has {var} = {:?}, expected {expected:?}",
                                dirs.get(var),
                            )));
                        }
                    }
                }
            }
        }
    }

    assert!(
        failures.is_empty(),
        "rust catalog entries missing #806 install fields:\n  {}",
        failures.join("\n  ")
    );
}
