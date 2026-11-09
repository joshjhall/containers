//! Remove `purpose: build` system packages once the install method is done
//! (#1524).
//!
//! A `source-build` method needs a compiler toolchain at install time only —
//! node's alpine method declares `g++`, `make`, `linux-headers` and `python3`
//! as `purpose: build`. Without this module every one of them stays in the
//! final image.
//!
//! The rule has two halves, both conservative:
//!
//! 1. **Build-only.** A package is a candidate only when *every* dependency
//!    resolving to it is `Build`. A `Runtime`/`Both` declaration — including
//!    the default when `purpose` is absent — for the same package wins.
//! 2. **Luggage installed it.** Candidates already on the host before the
//!    system-package stage ran are dropped, so a package the base image (or
//!    an earlier install) brought is never removed.
//!
//! The removal runs after the method and post-install steps and *before*
//! validation, so a passing validate proves the tool runs without them. It
//! also runs when the method fails, so a failed build does not leave the
//! toolchain behind either.

use crate::error::Result;
use crate::sysdeps::ResolvedSystemDeps;
use containers_common::tooldb::DependencyPurpose;
use tracing::warn;

use super::logging;
use super::syspackages::{PackageManager, remove_packages};

/// Build-only packages the system-package stage newly installed, awaiting
/// removal. Empty when there is nothing to remove.
#[derive(Debug, Default)]
pub(super) struct PendingBuildDeps {
    mgr: Option<PackageManager>,
    packages: Vec<String>,
}

impl PendingBuildDeps {
    pub(super) const fn new(mgr: PackageManager, packages: Vec<String>) -> Self {
        Self { mgr: Some(mgr), packages }
    }

    /// Keep only the pending packages that are actually installed now. Used
    /// after a partial install failure, so removal targets exactly what
    /// landed and a package that never installed is not passed to the
    /// package manager (which would fail the removal outright).
    #[must_use]
    pub(super) fn retain_installed(mut self, is_present: impl Fn(&str) -> bool) -> Self {
        self.packages.retain(|p| is_present(p));
        self
    }
}

/// Package names whose every resolved dependency is `purpose: build`,
/// deduplicated in first-seen order.
#[must_use]
pub(super) fn build_only_packages(deps: &ResolvedSystemDeps) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::new();
    for p in &deps.packages {
        let build_only = deps
            .packages
            .iter()
            .filter(|q| q.package == p.package)
            .all(|q| q.purpose == DependencyPurpose::Build);
        if build_only && !out.contains(&p.package.as_str()) {
            out.push(&p.package);
        }
    }
    out
}

/// The build-only packages of `deps` that are absent before the install —
/// i.e. the ones this run will add and may therefore remove. `is_present` is
/// injected so the selection is testable without a package manager.
#[must_use]
pub(super) fn removal_candidates(
    deps: &ResolvedSystemDeps,
    is_present: impl Fn(&str) -> bool,
) -> Vec<String> {
    build_only_packages(deps).into_iter().filter(|p| !is_present(p)).map(str::to_owned).collect()
}

/// Remove the pending build-only packages.
///
/// Returns the removed package names (empty when nothing was pending or
/// the removal failed) alongside the removal's own result, so the caller
/// decides how a removal failure ranks against an earlier stage error.
pub(super) fn remove_build_deps(
    pending: PendingBuildDeps,
    logger: Option<&logging::FeatureLogger>,
) -> (Vec<String>, Result<()>) {
    let Some(mgr) = pending.mgr else { return (Vec::new(), Ok(())) };
    if pending.packages.is_empty() {
        return (Vec::new(), Ok(()));
    }
    if let Some(l) = logger {
        l.step(&format!("remove build dependencies: {}", pending.packages.join(" ")));
    }
    let names: Vec<&str> = pending.packages.iter().map(String::as_str).collect();
    match remove_packages(&names, mgr) {
        Ok(()) => (pending.packages, Ok(())),
        Err(e) => (Vec::new(), Err(e)),
    }
}

/// Fold the build-dep removal result into the install result.
///
/// An earlier stage error wins — it is the cause the operator needs — and a
/// removal error behind it is logged rather than lost. On an otherwise
/// successful install a removal failure fails the install: an image that
/// silently keeps the toolchain is the defect #1524 exists to prevent.
pub(super) fn merge_cleanup<T>(
    installed: Result<T>,
    cleanup: Result<()>,
    logger: Option<&logging::FeatureLogger>,
) -> Result<T> {
    match (installed, cleanup) {
        (Ok(v), Ok(())) => Ok(v),
        (Ok(_), Err(e)) | (Err(e), Ok(())) => Err(e),
        (Err(e), Err(cleanup_err)) => {
            warn!(error = %cleanup_err, "build-dependency removal also failed after a failed install");
            if let Some(l) = logger {
                l.message(&format!("build-dependency removal also failed: {cleanup_err}"));
            }
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::LuggageError;
    use crate::sysdeps::SystemPackageDep;
    use containers_common::tooldb::DependencyPurpose::{Both, Build, Runtime};

    fn deps(entries: &[(&str, &str, DependencyPurpose)]) -> ResolvedSystemDeps {
        ResolvedSystemDeps {
            packages: entries
                .iter()
                .map(|(t, p, purpose)| SystemPackageDep {
                    tool: (*t).into(),
                    package: (*p).into(),
                    purpose: *purpose,
                })
                .collect(),
            unmapped: Vec::new(),
        }
    }

    /// node's alpine source-build method, as containers-db#483 declares it.
    fn node_alpine() -> ResolvedSystemDeps {
        deps(&[
            ("ca_certificates", "ca-certificates", Both),
            ("gxx", "g++", Build),
            ("make", "make", Build),
            ("linux_headers", "linux-headers", Build),
            ("python3", "python3", Build),
            ("libstdcxx", "libstdc++", Runtime),
            ("libgcc", "libgcc", Runtime),
        ])
    }

    #[test]
    fn only_build_purpose_packages_are_candidates() {
        assert_eq!(
            build_only_packages(&node_alpine()),
            vec!["g++", "make", "linux-headers", "python3"]
        );
    }

    #[test]
    fn a_runtime_or_both_declaration_of_the_same_package_wins() {
        // Two tool ids mapping to one package: any non-build declaration
        // keeps it, whichever order they appear in.
        for purpose in [Runtime, Both] {
            let d =
                deps(&[("gxx", "g++", Build), ("cxx", "g++", purpose), ("make", "make", Build)]);
            assert_eq!(build_only_packages(&d), vec!["make"], "{purpose:?}");
            let d = deps(&[("cxx", "g++", purpose), ("gxx", "g++", Build)]);
            assert!(build_only_packages(&d).is_empty(), "{purpose:?}");
        }
    }

    #[test]
    fn duplicate_build_entries_collapse_to_one_package() {
        let d = deps(&[("gxx", "g++", Build), ("cxx", "g++", Build)]);
        assert_eq!(build_only_packages(&d), vec!["g++"]);
    }

    #[test]
    fn packages_present_before_the_install_are_never_candidates() {
        let present = ["make", "python3"];
        assert_eq!(
            removal_candidates(&node_alpine(), |p| present.contains(&p)),
            vec!["g++".to_owned(), "linux-headers".to_owned()]
        );
    }

    #[test]
    fn no_build_deps_means_nothing_to_remove() {
        let d = deps(&[("gcc", "gcc", Both), ("libgcc", "libgcc", Runtime)]);
        // The presence probe must not even be consulted.
        assert_eq!(
            removal_candidates(&d, |_| panic!("probed with nothing to remove")),
            Vec::<String>::new()
        );
    }

    #[test]
    fn empty_pending_set_removes_nothing() {
        // Neither shape may shell out: no package manager exists here.
        let (removed, r) = remove_build_deps(PendingBuildDeps::default(), None);
        assert_eq!(removed, Vec::<String>::new());
        r.unwrap();
        let (removed, r) =
            remove_build_deps(PendingBuildDeps::new(PackageManager::Apk, vec![]), None);
        assert_eq!(removed, Vec::<String>::new());
        r.unwrap();
    }

    #[test]
    fn retain_installed_keeps_only_what_landed() {
        // A partial install: g++ went in, make did not.
        let pending = PendingBuildDeps::new(PackageManager::Apk, vec!["g++".into(), "make".into()])
            .retain_installed(|p| p == "g++");
        assert_eq!(pending.packages, vec!["g++".to_owned()]);
    }

    fn pm_err(msg: &str) -> LuggageError {
        LuggageError::PackageManagerFailed { message: msg.into() }
    }

    #[test]
    fn merge_cleanup_ranks_errors() {
        assert_eq!(merge_cleanup(Ok(1), Ok(()), None).unwrap(), 1);
        // A removal failure fails an otherwise-good install.
        let e = merge_cleanup(Ok(1), Err(pm_err("del")), None).unwrap_err();
        assert!(e.to_string().contains("del"), "{e}");
        // The original stage error wins over a removal failure behind it.
        let e = merge_cleanup::<()>(Err(pm_err("build")), Err(pm_err("del")), None).unwrap_err();
        assert!(e.to_string().contains("build") && !e.to_string().contains("del"), "{e}");
        let e = merge_cleanup::<()>(Err(pm_err("build")), Ok(()), None).unwrap_err();
        assert!(e.to_string().contains("build"), "{e}");
    }

    /// The field rides the evidence report: present when something was
    /// removed, and a pre-#1524 report (no key) still deserializes.
    #[test]
    fn report_records_removed_build_dependencies() {
        let mut report = crate::installer::Installer::report_failure(
            &crate::installer::tests::sample_resolved_with_deps(),
            &pm_err("x"),
            None,
            0.0,
        );
        assert_eq!(report.removed_build_dependencies, Vec::<String>::new());
        report.removed_build_dependencies = vec!["g++".into(), "make".into()];
        let mut json = serde_json::to_value(&report).unwrap();
        assert_eq!(json["removed_build_dependencies"], serde_json::json!(["g++", "make"]));
        json.as_object_mut().unwrap().remove("removed_build_dependencies");
        let old: crate::installer::InstallReport = serde_json::from_value(json).unwrap();
        assert_eq!(old.removed_build_dependencies, Vec::<String>::new());
    }
}
