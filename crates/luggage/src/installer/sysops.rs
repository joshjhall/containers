//! The host package-manager operations the install orchestration performs,
//! behind one injectable seam (#1630).
//!
//! `Installer::run_stages` installs system packages, snapshots which
//! build-only ones were already present, and removes the ones it added once
//! the method is done (#1524). Every one of those steps shells out to the
//! host package manager, which left the orchestration — the ordering and the
//! cleanup on each failure path — testable only by a Docker build. Routing
//! them through [`SystemPackages`] lets unit tests drive the real
//! orchestration against an in-memory host.
//!
//! Version capture for the evidence row
//! ([`super::syspackages::resolve_installed_versions`]) is deliberately not
//! part of the seam: it is best-effort, off by default, and has no bearing on
//! what gets installed or removed.

use crate::error::Result;
use crate::sysdeps::ResolvedSystemDeps;

use super::syspackages::{self, PackageManager};
use super::sysremove;

/// Install, presence and removal against the host package manager.
pub trait SystemPackages: Send + Sync {
    /// Whether `package` is installed. Fails closed: an unreadable answer is
    /// `false` (see [`sysremove::is_installed`]).
    fn is_installed(&self, mgr: PackageManager, package: &str) -> bool;

    /// Install every resolved package (see
    /// [`syspackages::install_dependencies`]).
    fn install(&self, deps: &ResolvedSystemDeps, mgr: PackageManager, strict: bool) -> Result<()>;

    /// Remove `packages` at the refuse-don't-cascade level (see
    /// [`sysremove::remove_packages`]).
    fn remove(&self, packages: &[&str], mgr: PackageManager) -> Result<()>;
}

/// The production [`SystemPackages`]: the real host package manager.
#[derive(Debug, Default, Clone, Copy)]
pub struct HostSystemPackages;

impl SystemPackages for HostSystemPackages {
    fn is_installed(&self, mgr: PackageManager, package: &str) -> bool {
        sysremove::is_installed(mgr, package)
    }

    fn install(&self, deps: &ResolvedSystemDeps, mgr: PackageManager, strict: bool) -> Result<()> {
        syspackages::install_dependencies(deps, mgr, strict)
    }

    fn remove(&self, packages: &[&str], mgr: PackageManager) -> Result<()> {
        sysremove::remove_packages(packages, mgr)
    }
}
