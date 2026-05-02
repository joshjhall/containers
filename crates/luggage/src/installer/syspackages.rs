//! System-package install dispatch (apt / apk / dnf).
//!
//! Catalog `Dependency.tool` entries (e.g. `ca_certificates`, `gcc`,
//! `libc_dev`) describe abstract system packages that need to be installed
//! before the tool can run. This module:
//!
//! 1. Detects the host's package manager from a [`crate::Platform`].
//! 2. Maps each abstract `Dependency.tool` id to the per-distro package name.
//! 3. Shells out to the host's package manager to install them.
//!
//! # Pilot scope
//!
//! Only the four IDs rust@1.95.0 declares — `ca_certificates`, `gcc`,
//! `libc_dev`, `musl_dev` — are wired up. Unknown IDs log a warning and
//! continue rather than fail; future issues will widen the table or move
//! it into the catalog as a per-tool override.

use std::process::Command;

use containers_common::tooldb::Dependency;
use tracing::warn;

use crate::Platform;
use crate::error::{LuggageError, Result};

/// Detected host package manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackageManager {
    /// `apt-get` (debian/ubuntu).
    Apt,
    /// `apk` (alpine).
    Apk,
    /// `dnf` (rhel/fedora).
    Dnf,
}

impl PackageManager {
    /// Pick the package manager for `platform.os`.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::NotImplemented`] when the OS does not map to any
    ///   wired-up package manager.
    pub fn for_platform(platform: &Platform) -> Result<Self> {
        Ok(match platform.os.as_str() {
            "debian" | "ubuntu" => Self::Apt,
            "alpine" => Self::Apk,
            "rhel" | "fedora" => Self::Dnf,
            _ => return Err(LuggageError::NotImplemented("package manager for this platform")),
        })
    }
}

/// Map an abstract `Dependency.tool` id to the per-distro package name.
///
/// Returns `None` when the id is unknown to this build of luggage.
#[must_use]
pub fn package_name(tool: &str, mgr: PackageManager) -> Option<&'static str> {
    match (tool, mgr) {
        ("ca_certificates", _) => Some("ca-certificates"),
        ("gcc", _) => Some("gcc"),
        ("libc_dev", PackageManager::Apt) => Some("libc6-dev"),
        ("libc_dev", PackageManager::Dnf) => Some("glibc-devel"),
        ("musl_dev", PackageManager::Apk) => Some("musl-dev"),
        ("pkg_config", _) => Some("pkg-config"),
        _ => None,
    }
}

/// Build the argv that installs `packages` via `mgr`.
///
/// Returned as `(program, args)` so callers can inject a different runner
/// for tests. Returns `None` when `packages` is empty.
#[must_use]
pub fn install_argv(mgr: PackageManager, packages: &[&str]) -> Option<(&'static str, Vec<String>)> {
    if packages.is_empty() {
        return None;
    }
    let owned: Vec<String> = packages.iter().map(|p| (*p).to_owned()).collect();
    Some(match mgr {
        PackageManager::Apt => {
            let mut args =
                vec!["install".to_owned(), "-y".to_owned(), "--no-install-recommends".to_owned()];
            args.extend(owned);
            ("apt-get", args)
        }
        PackageManager::Apk => {
            let mut args = vec!["add".to_owned(), "--no-cache".to_owned()];
            args.extend(owned);
            ("apk", args)
        }
        PackageManager::Dnf => {
            let mut args = vec!["install".to_owned(), "-y".to_owned()];
            args.extend(owned);
            ("dnf", args)
        }
    })
}

/// Translate `dependencies` into per-distro package names.
///
/// Unknown `Dependency.tool` ids emit a `tracing::warn!` and are skipped.
/// This is intentional: the rust pilot's catalog has been hand-audited but
/// catalogs scanned in by future automation may carry IDs we haven't wired
/// yet, and a single unrecognised dep should not block the entire install.
pub fn translate_dependencies(deps: &[Dependency], mgr: PackageManager) -> Vec<&'static str> {
    let mut out = Vec::new();
    for dep in deps {
        if let Some(name) = package_name(&dep.tool, mgr) {
            out.push(name);
        } else {
            warn!(
                tool = %dep.tool,
                manager = ?mgr,
                "no system-package mapping; skipping (catalog may need an update)",
            );
        }
    }
    out
}

/// Install `dependencies` on the host via `mgr`.
///
/// Skips the call when no dependencies translate to packages. Errors map
/// to [`LuggageError::PackageManagerFailed`] with the package manager's
/// stderr in the message body for diagnostics.
///
/// # Errors
///
/// - [`LuggageError::PackageManagerFailed`] when the package manager exits
///   non-zero or fails to launch.
pub fn install_dependencies(deps: &[Dependency], mgr: PackageManager) -> Result<()> {
    let names = translate_dependencies(deps, mgr);
    let Some((program, args)) = install_argv(mgr, &names) else {
        return Ok(());
    };
    if matches!(mgr, PackageManager::Apt) {
        let update = Command::new("apt-get").arg("update").output().map_err(|e| {
            LuggageError::PackageManagerFailed {
                message: format!("apt-get update failed to launch: {e}"),
            }
        })?;
        if !update.status.success() {
            return Err(LuggageError::PackageManagerFailed {
                message: format!(
                    "apt-get update exited {}: {}",
                    update.status,
                    String::from_utf8_lossy(&update.stderr).trim_end(),
                ),
            });
        }
    }
    let out = Command::new(program).args(&args).output().map_err(|e| {
        LuggageError::PackageManagerFailed { message: format!("{program} failed to launch: {e}") }
    })?;
    if out.status.success() {
        Ok(())
    } else {
        Err(LuggageError::PackageManagerFailed {
            message: format!(
                "{program} exited {}: {}",
                out.status,
                String::from_utf8_lossy(&out.stderr).trim_end(),
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(os: &str) -> Platform {
        Platform { os: os.into(), os_version: None, arch: "amd64".into() }
    }

    #[test]
    fn detects_apt_for_debian_and_ubuntu() {
        assert_eq!(PackageManager::for_platform(&p("debian")).unwrap(), PackageManager::Apt);
        assert_eq!(PackageManager::for_platform(&p("ubuntu")).unwrap(), PackageManager::Apt);
    }

    #[test]
    fn detects_apk_for_alpine() {
        assert_eq!(PackageManager::for_platform(&p("alpine")).unwrap(), PackageManager::Apk);
    }

    #[test]
    fn detects_dnf_for_rhel_and_fedora() {
        assert_eq!(PackageManager::for_platform(&p("rhel")).unwrap(), PackageManager::Dnf);
        assert_eq!(PackageManager::for_platform(&p("fedora")).unwrap(), PackageManager::Dnf);
    }

    #[test]
    fn unknown_os_returns_not_implemented() {
        let err = PackageManager::for_platform(&p("haiku")).unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn package_name_known_mappings() {
        assert_eq!(package_name("gcc", PackageManager::Apt), Some("gcc"));
        assert_eq!(package_name("libc_dev", PackageManager::Apt), Some("libc6-dev"));
        assert_eq!(package_name("musl_dev", PackageManager::Apk), Some("musl-dev"));
        assert_eq!(package_name("ca_certificates", PackageManager::Apk), Some("ca-certificates"));
        assert_eq!(package_name("pkg_config", PackageManager::Dnf), Some("pkg-config"));
    }

    #[test]
    fn package_name_unknown_returns_none() {
        assert_eq!(package_name("frobnicator", PackageManager::Apt), None);
        // Wrong-distro mapping (e.g. musl_dev on apt) also returns None;
        // catalog entries should never produce this combination, but if they
        // do, we'd rather skip than install something wrong.
        assert_eq!(package_name("musl_dev", PackageManager::Apt), None);
    }

    #[test]
    fn install_argv_apt_includes_no_install_recommends() {
        let (prog, args) = install_argv(PackageManager::Apt, &["gcc", "libc6-dev"]).unwrap();
        assert_eq!(prog, "apt-get");
        assert_eq!(args, vec!["install", "-y", "--no-install-recommends", "gcc", "libc6-dev"]);
    }

    #[test]
    fn install_argv_apk_uses_no_cache() {
        let (prog, args) = install_argv(PackageManager::Apk, &["musl-dev"]).unwrap();
        assert_eq!(prog, "apk");
        assert_eq!(args, vec!["add", "--no-cache", "musl-dev"]);
    }

    #[test]
    fn install_argv_dnf_uses_minus_y() {
        let (prog, args) = install_argv(PackageManager::Dnf, &["gcc"]).unwrap();
        assert_eq!(prog, "dnf");
        assert_eq!(args, vec!["install", "-y", "gcc"]);
    }

    #[test]
    fn install_argv_returns_none_when_no_packages() {
        assert!(install_argv(PackageManager::Apt, &[]).is_none());
    }

    #[test]
    fn translate_dependencies_skips_unknown() {
        let deps = vec![
            Dependency {
                tool: "ca_certificates".into(),
                version: None,
                version_constraint: None,
                purpose: None,
                required: None,
                platforms: None,
            },
            Dependency {
                tool: "frobnicator".into(),
                version: None,
                version_constraint: None,
                purpose: None,
                required: None,
                platforms: None,
            },
            Dependency {
                tool: "gcc".into(),
                version: None,
                version_constraint: None,
                purpose: None,
                required: None,
                platforms: None,
            },
        ];
        let pkgs = translate_dependencies(&deps, PackageManager::Apt);
        assert_eq!(pkgs, vec!["ca-certificates", "gcc"]);
    }
}
