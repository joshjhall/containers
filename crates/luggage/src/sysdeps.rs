//! Resolve a tool's catalog dependencies to host system packages.
//!
//! A version file's `install_methods[].dependencies[]` names abstract tools
//! (`gcc`, `libc_dev`, `util_linux`, …). Each is a `kind: system_package`
//! entry in the catalog whose `system_package.platforms` maps a distro to the
//! package name that distro's manager uses. This module joins the two for a
//! concrete host [`Platform`]:
//!
//! 1. Keep only dependencies whose `platforms` selectors match the host
//!    ([`selector_matches`]): `rhel` matches any RHEL release, `rhel:10` only
//!    RHEL 10, and no selectors means every platform.
//! 2. Look each one up in the catalog and take the host distro's package name.
//!
//! The catalog is the single source of truth for package names; per-distro
//! and per-release differences are data (containers-db), not luggage code.

use containers_common::tooldb::Dependency;
use serde::Serialize;

use crate::Platform;
use crate::catalog::Catalog;

/// A dependency resolved to a host package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SystemPackageDep {
    /// Catalog tool id (e.g. `libc_dev`).
    pub tool: String,
    /// The host distro's package name (e.g. `glibc-devel` on rhel).
    pub package: String,
}

/// Outcome of resolving a method's dependencies for one host.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ResolvedSystemDeps {
    /// Dependencies that apply here and have a package for this distro.
    pub packages: Vec<SystemPackageDep>,
    /// Tool ids that apply here but have no package for this distro: missing
    /// from the catalog, not a `system_package`, or no mapping for the distro.
    /// Strict installs refuse these; lenient ones skip them.
    pub unmapped: Vec<String>,
}

/// Does `selector` (`distro` or `distro:release`) match `platform`?
///
/// The release part matches the platform's normalized `os_version` exactly
/// (luggage keys RHEL by major, Alpine by major.minor).
#[must_use]
pub fn selector_matches(selector: &str, platform: &Platform) -> bool {
    match selector.split_once(':') {
        None => selector == platform.os,
        Some((distro, release)) => {
            distro == platform.os && platform.os_version.as_deref() == Some(release)
        }
    }
}

/// Resolve `deps` to host packages for `platform` from `catalog`.
#[must_use]
pub fn resolve_system_deps(
    deps: &[Dependency],
    platform: &Platform,
    catalog: &Catalog,
) -> ResolvedSystemDeps {
    let mut out = ResolvedSystemDeps::default();
    for dep in deps {
        let applies = dep
            .platforms
            .as_ref()
            .is_none_or(|sels| sels.iter().any(|s| selector_matches(s, platform)));
        if !applies {
            continue;
        }
        let package = catalog
            .tool(&dep.tool)
            .and_then(|t| t.system_package.as_ref())
            .and_then(|sp| sp.platforms.get(&platform.os))
            .map(|p| p.name.clone());
        match package {
            Some(package) => {
                out.packages.push(SystemPackageDep { tool: dep.tool.clone(), package });
            }
            None => out.unmapped.push(dep.tool.clone()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::CatalogSource;

    fn platform(os: &str, ver: Option<&str>) -> Platform {
        Platform { os: os.into(), os_version: ver.map(Into::into), arch: "amd64".into() }
    }

    fn dep(tool: &str, platforms: Option<&[&str]>) -> Dependency {
        serde_json::from_value(serde_json::json!({
            "tool": tool,
            "platforms": platforms.map(<[&str]>::to_vec),
        }))
        .unwrap()
    }

    /// A catalog with two system packages and one non-system tool.
    fn catalog() -> (tempfile::TempDir, Catalog) {
        let tmp = tempfile::tempdir().unwrap();
        let tools = tmp.path().join("tools");
        let write = |id: &str, body: serde_json::Value| {
            std::fs::create_dir_all(tools.join(id)).unwrap();
            std::fs::write(tools.join(id).join("index.json"), body.to_string()).unwrap();
        };
        let sys = |id: &str, map: serde_json::Value| {
            serde_json::json!({
                "schemaVersion": 1, "id": id, "display_name": id, "kind": "system_package",
                "activity": { "score": "very-active", "scan_cadence_days": 30,
                              "scanned_at": "2026-10-13T00:00:00Z" },
                "system_package": { "platforms": map }
            })
        };
        write(
            "libc_dev",
            sys(
                "libc_dev",
                serde_json::json!({
                    "debian": { "name": "libc6-dev" }, "rhel": { "name": "glibc-devel" }
                }),
            ),
        );
        write(
            "util_linux",
            sys("util_linux", serde_json::json!({ "rhel": { "name": "util-linux" } })),
        );
        let cat = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap();
        (tmp, cat)
    }

    #[test]
    fn selector_matches_distro_and_release() {
        let rhel10 = platform("rhel", Some("10"));
        assert!(selector_matches("rhel", &rhel10), "bare distro matches any release");
        assert!(selector_matches("rhel:10", &rhel10));
        assert!(!selector_matches("rhel:9", &rhel10), "other release does not match");
        assert!(!selector_matches("debian", &rhel10));
        assert!(
            !selector_matches("rhel:10", &platform("rhel", None)),
            "unknown release never matches a scoped selector"
        );
    }

    #[test]
    fn package_name_comes_from_the_catalog_per_distro() {
        let (_t, cat) = catalog();
        let deps = [dep("libc_dev", None)];
        assert_eq!(
            resolve_system_deps(&deps, &platform("rhel", Some("10")), &cat).packages,
            vec![SystemPackageDep { tool: "libc_dev".into(), package: "glibc-devel".into() }]
        );
        assert_eq!(
            resolve_system_deps(&deps, &platform("debian", Some("13")), &cat).packages,
            vec![SystemPackageDep { tool: "libc_dev".into(), package: "libc6-dev".into() }]
        );
    }

    #[test]
    fn platform_selectors_scope_a_dependency() {
        let (_t, cat) = catalog();
        // util_linux declared for rhel only (as rust's catalog entry does).
        let deps = [dep("libc_dev", None), dep("util_linux", Some(&["rhel"]))];
        let on_rhel = resolve_system_deps(&deps, &platform("rhel", Some("10")), &cat);
        assert_eq!(
            on_rhel.packages.iter().map(|p| p.package.as_str()).collect::<Vec<_>>(),
            vec!["glibc-devel", "util-linux"]
        );
        let on_debian = resolve_system_deps(&deps, &platform("debian", Some("13")), &cat);
        assert_eq!(
            on_debian.packages.iter().map(|p| p.package.as_str()).collect::<Vec<_>>(),
            vec!["libc6-dev"],
            "a rhel-scoped dependency is not installed on debian"
        );
        assert!(on_debian.unmapped.is_empty(), "skipped by selector, not unmapped");
    }

    #[test]
    fn release_scoped_selector_applies_to_that_release_only() {
        let (_t, cat) = catalog();
        let deps = [dep("util_linux", Some(&["rhel:10"]))];
        assert_eq!(
            resolve_system_deps(&deps, &platform("rhel", Some("10")), &cat).packages.len(),
            1
        );
        let rhel9 = resolve_system_deps(&deps, &platform("rhel", Some("9")), &cat).packages;
        assert!(rhel9.is_empty(), "expected no packages on rhel 9, got {rhel9:?}");
    }

    #[test]
    fn missing_mapping_is_reported_unmapped() {
        let (_t, cat) = catalog();
        // util_linux has no debian mapping; frobnicator is not in the catalog.
        let deps = [dep("util_linux", None), dep("frobnicator", None)];
        let r = resolve_system_deps(&deps, &platform("debian", Some("13")), &cat);
        assert!(r.packages.is_empty(), "expected no packages, got {:?}", r.packages);
        assert_eq!(r.unmapped, vec!["util_linux".to_string(), "frobnicator".to_string()]);
    }
}
