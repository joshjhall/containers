//! Catalog invariant: no vendored rust version may mark `util-linux` as a
//! build-only package on rhel (#1668).
//!
//! `util_linux` is in rust's catalog only to provide `su`, which luggage
//! itself uses to run install methods as the target user (#1164). It is not a
//! build input of rust. #1621 labelled it `purpose: build`, which put it on the
//! post-install removal list. On UBI 9, gcc pulls in systemd, which hard-depends
//! on util-linux, so `rpm -e util-linux` was refused and every rust install on
//! rhel-9 failed.
//!
//! The build-dep cleanup treats a package as removable only when every
//! dependency resolving to it is `Build`. This test asserts the same condition
//! over the public resolution path, for every vendored version and both rhel
//! majors and arches, so one hand-mirrored entry that regresses fails here.

use std::path::{Path, PathBuf};

use containers_common::tooldb::DependencyPurpose;
use luggage::{Catalog, CatalogSource, Platform, VersionSpec};

fn testdata_catalog() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata").join("catalog")
}

fn rhel(major: &str, arch: &str) -> Platform {
    Platform { os: "rhel".into(), os_version: Some(major.into()), arch: arch.into() }
}

/// The rhel (major, arch) rows every vendored rust version declares in its
/// support matrix. Each must resolve: a row that silently stopped resolving
/// would otherwise just shrink the check.
const RHEL_ROWS: [(&str, &str); 4] =
    [("9", "amd64"), ("9", "arm64"), ("10", "amd64"), ("10", "arm64")];

/// Check every rust version in the catalog at `root`. Returns the number of
/// versions seen, the number of rhel rows checked, and one line per defect.
fn check_util_linux(root: &Path) -> (usize, usize, Vec<String>) {
    let catalog =
        Catalog::load(CatalogSource::LocalPath(root.to_path_buf())).expect("load catalog");
    let entry = catalog.tool_entry("rust").expect("catalog has rust");

    let mut checked = 0;
    let mut failures = Vec::new();
    for doc in entry.versions.values() {
        for (major, arch) in RHEL_ROWS {
            let p = rhel(major, arch);
            // Catalog::resolve, not the bare resolver: only the catalog can
            // map `util_linux` to a host package, so the bare resolver
            // leaves system_deps empty.
            let r = match catalog.resolve("rust", &VersionSpec::Exact(doc.version.clone()), &p) {
                Ok(r) => r,
                Err(e) => {
                    failures
                        .push(format!("{} rhel-{major}-{arch}: did not resolve: {e}", doc.version));
                    continue;
                }
            };
            let util_linux: Vec<_> =
                r.system_deps.packages.iter().filter(|d| d.package == "util-linux").collect();
            // Present at all: guards against the check passing vacuously
            // because the dependency was dropped or renamed. luggage still
            // needs `su` on rhel.
            if util_linux.is_empty() {
                failures
                    .push(format!("{} rhel-{major}-{arch}: util-linux not resolved", doc.version));
                continue;
            }
            checked += 1;
            if util_linux.iter().all(|d| d.purpose == DependencyPurpose::Build) {
                failures.push(format!(
                    "{} rhel-{major}-{arch}: util-linux is build-only and would be removed",
                    doc.version
                ));
            }
        }
    }
    (entry.versions.len(), checked, failures)
}

#[test]
fn util_linux_is_never_a_build_only_package_for_rust_on_rhel() {
    let (versions, checked, failures) = check_util_linux(&testdata_catalog());
    assert!(failures.is_empty(), "rust util-linux defects:\n{}", failures.join("\n"));
    // Every version on every rhel row, exactly: a row that stopped resolving
    // fails above by name, and this pins that the loop covered all of them.
    assert!(versions > 0, "catalog has no rust versions — vacuous pass");
    assert_eq!(checked, versions * RHEL_ROWS.len(), "rhel rows checked vs expected");
}

/// The check above must catch the #1668 defect, not pass for some other
/// reason. Re-add `purpose: build` to one version in a scratch copy of the
/// catalog (never the tracked one) and require exactly that version to fail.
#[test]
fn the_check_catches_a_reintroduced_build_purpose() {
    let scratch = tempfile::tempdir().expect("tempdir");
    copy_dir(&testdata_catalog(), scratch.path());

    let file = scratch.path().join("tools/rust/versions/1.100.0.json");
    let mut doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    let mut patched = 0;
    for method in doc["install_methods"].as_array_mut().unwrap() {
        for dep in method["dependencies"].as_array_mut().into_iter().flatten() {
            if dep["tool"] == "util_linux" {
                dep["purpose"] = "build".into();
                patched += 1;
            }
        }
    }
    assert!(patched > 0, "1.100.0 has no util_linux dependency to patch");
    std::fs::write(&file, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

    let (_, _, failures) = check_util_linux(scratch.path());
    assert!(!failures.is_empty(), "a build-only util-linux went undetected");
    assert!(
        failures.iter().all(|f| f.starts_with("1.100.0 ") && f.contains("build-only")),
        "only the patched version should fail, as build-only:\n{}",
        failures.join("\n")
    );
}

fn copy_dir(from: &Path, to: &Path) {
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let dest = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            std::fs::create_dir_all(&dest).unwrap();
            copy_dir(&entry.path(), &dest);
        } else {
            std::fs::copy(entry.path(), &dest).unwrap();
        }
    }
}
