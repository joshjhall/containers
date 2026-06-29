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

use containers_common::tooldb::{Dependency, InstalledDependency};
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

/// Result of translating catalog dependency ids into per-distro packages.
///
/// `packages` holds the recognized ids' per-distro names; `unknown` holds the
/// raw `Dependency.tool` ids that had no mapping in this build of luggage.
/// Callers decide what to do with `unknown`: the default (strict) install
/// path turns a non-empty `unknown` into [`LuggageError::UnknownDependency`],
/// while the planner and `--allow-unknown-deps` path surface it as a
/// skipped-dependency list instead.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct TranslatedDeps {
    /// Recognized dependency ids, mapped to per-distro package names.
    pub packages: Vec<&'static str>,
    /// Dependency ids with no system-package mapping in this build.
    pub unknown: Vec<String>,
}

/// Translate `dependencies` into per-distro package names.
///
/// Unknown `Dependency.tool` ids emit a `tracing::warn!` and are collected
/// into [`TranslatedDeps::unknown`] rather than silently dropped. The rust
/// pilot's catalog has been hand-audited, but catalogs scanned in by future
/// automation may carry ids we haven't wired yet; the caller decides whether
/// an unrecognized id is fatal (strict mode) or skippable.
#[must_use]
pub fn translate_dependencies(deps: &[Dependency], mgr: PackageManager) -> TranslatedDeps {
    let mut out = TranslatedDeps::default();
    for dep in deps {
        if let Some(name) = package_name(&dep.tool, mgr) {
            out.packages.push(name);
        } else {
            warn!(
                tool = %dep.tool,
                manager = ?mgr,
                "no system-package mapping; skipping (catalog may need an update)",
            );
            out.unknown.push(dep.tool.clone());
        }
    }
    out
}

/// Install `dependencies` on the host via `mgr`.
///
/// Skips the call when no dependencies translate to packages. When `strict`
/// is `true` (the production default) and any dependency id has no mapping,
/// returns [`LuggageError::UnknownDependency`] *before* shelling out to the
/// package manager — so a catalog that drifted ahead of luggage's mapping
/// table fails loudly rather than installing a partial dependency set. When
/// `strict` is `false`, unknown ids are warned-and-skipped (the legacy
/// behavior, opted into via `--allow-unknown-deps`).
///
/// Otherwise, errors map to [`LuggageError::PackageManagerFailed`] with the
/// package manager's stderr in the message body for diagnostics.
///
/// # Errors
///
/// - [`LuggageError::UnknownDependency`] when `strict` and at least one
///   dependency id has no system-package mapping.
/// - [`LuggageError::PackageManagerFailed`] when the package manager exits
///   non-zero or fails to launch.
pub fn install_dependencies(deps: &[Dependency], mgr: PackageManager, strict: bool) -> Result<()> {
    let TranslatedDeps { packages, unknown } = translate_dependencies(deps, mgr);
    if strict && !unknown.is_empty() {
        return Err(LuggageError::UnknownDependency {
            manager: format!("{mgr:?}"),
            ids: unknown.join(", "),
        });
    }
    let Some((program, args)) = install_argv(mgr, &packages) else {
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

/// Build the argv that prints the installed version of `package` via `mgr`.
///
/// Returned as `(program, args)` so the queries stay close to
/// [`install_argv`] and are unit-testable without shelling out. Each manager
/// is asked to print *only* the version with no surrounding noise:
///
/// - apt: `dpkg-query -W -f=${Version} <pkg>` → bare version, e.g. `4:12.2.0-3`.
/// - apk: `apk info -v <pkg>` → `<pkg>-<version>`, stripped by
///   [`parse_apk_version`] (apk has no format-string flag). `-v` alone lists
///   the installed package with its version and exits 0 when present; the
///   `-e`/`--installed` flag is intentionally omitted — it matches a full
///   `name-version-release` spec, so passing a bare package name exits
///   non-zero even when the package is installed.
/// - dnf: `rpm -q --qf %{VERSION}-%{RELEASE} <pkg>` → `12.2.0-3`.
#[must_use]
fn query_version_argv(mgr: PackageManager, package: &str) -> (&'static str, Vec<String>) {
    match mgr {
        PackageManager::Apt => {
            ("dpkg-query", vec!["-W".to_owned(), "-f=${Version}".to_owned(), package.to_owned()])
        }
        PackageManager::Apk => {
            ("apk", vec!["info".to_owned(), "-v".to_owned(), package.to_owned()])
        }
        PackageManager::Dnf => (
            "rpm",
            vec![
                "-q".to_owned(),
                "--qf".to_owned(),
                "%{VERSION}-%{RELEASE}".to_owned(),
                package.to_owned(),
            ],
        ),
    }
}

/// Recover the version from `apk info -v` output, which prints
/// `<package>-<version>` (e.g. `musl-dev-1.2.5-r0` → `1.2.5-r0`).
///
/// apk package names can themselves contain hyphens, so we strip the exact
/// `"<package>-"` prefix rather than splitting on the last hyphen. Returns
/// `None` when the line does not start with the expected prefix.
#[must_use]
fn parse_apk_version(package: &str, line: &str) -> Option<String> {
    let trimmed = line.trim();
    trimmed
        .strip_prefix(package)
        .and_then(|rest| rest.strip_prefix('-'))
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
}

/// Recover the version from `dpkg-query`/`rpm` output, which print the bare
/// version string. Returns `None` for empty or whitespace-only output —
/// `dpkg-query` can exit 0 yet print nothing for a not-fully-installed package.
#[must_use]
fn parse_apt_dnf_version(stdout: &str) -> Option<String> {
    let v = stdout.trim();
    (!v.is_empty()).then(|| v.to_owned())
}

/// Resolve the installed versions of `deps` via `mgr`, best-effort.
///
/// Returns one [`InstalledDependency`] per dep that maps to a known package
/// name (unknown ids are skipped with a warning, exactly as
/// [`translate_dependencies`] does). `version` is `None` when the package
/// manager query fails to launch, exits non-zero, or prints nothing — a
/// missing version must never abort an otherwise-successful install, so this
/// function returns no error. Used to populate evidence rows ([containers#642]).
///
/// [containers#642]: https://github.com/joshjhall/containers/issues/642
#[must_use]
pub fn resolve_installed_versions(
    deps: &[Dependency],
    mgr: PackageManager,
) -> Vec<InstalledDependency> {
    let mut out = Vec::new();
    for dep in deps {
        let Some(package) = package_name(&dep.tool, mgr) else {
            warn!(
                tool = %dep.tool,
                manager = ?mgr,
                "no system-package mapping; skipping version capture",
            );
            continue;
        };
        let version = query_installed_version(mgr, package);
        out.push(InstalledDependency {
            tool: dep.tool.clone(),
            package: package.to_owned(),
            version,
        });
    }
    out
}

/// Run the package-manager query for `package` and return the parsed version,
/// or `None` on any failure (launch error, non-zero exit, empty output).
#[must_use]
fn query_installed_version(mgr: PackageManager, package: &str) -> Option<String> {
    let (program, args) = query_version_argv(mgr, package);
    let output = match Command::new(program).args(&args).output() {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            warn!(
                package,
                manager = ?mgr,
                status = %o.status,
                "version query exited non-zero; recording version as unknown",
            );
            return None;
        }
        Err(e) => {
            warn!(
                package,
                manager = ?mgr,
                error = %e,
                "version query failed to launch; recording version as unknown",
            );
            return None;
        }
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let version = match mgr {
        PackageManager::Apk => parse_apk_version(package, &stdout),
        PackageManager::Apt | PackageManager::Dnf => parse_apt_dnf_version(&stdout),
    };
    if version.is_none() {
        warn!(package, manager = ?mgr, "version query returned no parseable version");
    }
    version
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
        let translated = translate_dependencies(&deps, PackageManager::Apt);
        assert_eq!(translated.packages, vec!["ca-certificates", "gcc"]);
        assert_eq!(translated.unknown, vec!["frobnicator".to_owned()]);
    }

    fn dep(tool: &str) -> Dependency {
        Dependency {
            tool: tool.into(),
            version: None,
            version_constraint: None,
            purpose: None,
            required: None,
            platforms: None,
        }
    }

    #[test]
    fn install_dependencies_strict_errors_on_unknown() {
        // Pure: the strict check returns before any package-manager shell-out,
        // so no real apt/apk/dnf is needed.
        let deps = vec![dep("gcc"), dep("frobnicator")];
        let err = install_dependencies(&deps, PackageManager::Apt, true).unwrap_err();
        match err {
            LuggageError::UnknownDependency { manager, ids } => {
                assert_eq!(manager, "Apt");
                assert_eq!(ids, "frobnicator");
            }
            other => panic!("expected UnknownDependency, got {other:?}"),
        }
    }

    #[test]
    fn install_dependencies_strict_ok_when_all_known_and_empty() {
        // No unknown ids and no packages to install → strict mode still
        // returns Ok without shelling out (install_argv is None for []).
        assert!(install_dependencies(&[], PackageManager::Apt, true).is_ok());
    }

    #[test]
    fn query_version_argv_apt_uses_dpkg_query_format() {
        let (prog, args) = query_version_argv(PackageManager::Apt, "libc6-dev");
        assert_eq!(prog, "dpkg-query");
        assert_eq!(args, vec!["-W", "-f=${Version}", "libc6-dev"]);
    }

    #[test]
    fn query_version_argv_apk_uses_info_v() {
        // `-v` only (no `-e`): `-e` matches a full name-version-release spec,
        // so a bare package name would exit non-zero even when installed.
        let (prog, args) = query_version_argv(PackageManager::Apk, "musl-dev");
        assert_eq!(prog, "apk");
        assert_eq!(args, vec!["info", "-v", "musl-dev"]);
    }

    #[test]
    fn query_version_argv_dnf_uses_rpm_qf() {
        let (prog, args) = query_version_argv(PackageManager::Dnf, "glibc-devel");
        assert_eq!(prog, "rpm");
        assert_eq!(args, vec!["-q", "--qf", "%{VERSION}-%{RELEASE}", "glibc-devel"]);
    }

    #[test]
    fn parse_apk_version_strips_package_prefix() {
        // apk prints `<package>-<version>`; the package name itself contains a
        // hyphen, so we must strip the exact prefix, not split on last `-`.
        assert_eq!(parse_apk_version("musl-dev", "musl-dev-1.2.5-r0"), Some("1.2.5-r0".into()));
        assert_eq!(
            parse_apk_version("ca-certificates", "ca-certificates-20240705-r0\n"),
            Some("20240705-r0".into()),
        );
    }

    #[test]
    fn parse_apk_version_rejects_mismatched_line() {
        assert_eq!(parse_apk_version("gcc", "something-else-1.0"), None);
        // Prefix present but no version after it.
        assert_eq!(parse_apk_version("gcc", "gcc-"), None);
    }

    #[test]
    fn resolve_installed_versions_skips_unknown_ids() {
        // `frobnicator` has no package mapping, so it is dropped entirely —
        // the known deps still produce an entry (version is best-effort and
        // may be None on a host without the package, which is fine here).
        let deps = vec![dep("ca_certificates"), dep("frobnicator"), dep("gcc")];
        let resolved = resolve_installed_versions(&deps, PackageManager::Apt);
        let tools: Vec<&str> = resolved.iter().map(|d| d.tool.as_str()).collect();
        assert_eq!(tools, vec!["ca_certificates", "gcc"]);
        let packages: Vec<&str> = resolved.iter().map(|d| d.package.as_str()).collect();
        assert_eq!(packages, vec!["ca-certificates", "gcc"]);
    }

    #[test]
    fn resolve_installed_versions_empty_deps_returns_empty() {
        assert!(resolve_installed_versions(&[], PackageManager::Apt).is_empty());
    }

    #[test]
    fn parse_apt_dnf_version_trims_and_returns() {
        assert_eq!(parse_apt_dnf_version("4:12.2.0-3\n"), Some("4:12.2.0-3".into()));
        assert_eq!(parse_apt_dnf_version("  2.36-9+deb12u7  "), Some("2.36-9+deb12u7".into()));
    }

    #[test]
    fn parse_apt_dnf_version_none_for_empty_or_whitespace() {
        // dpkg-query can exit 0 but print nothing for a not-fully-installed pkg.
        assert!(parse_apt_dnf_version("").is_none());
        assert!(parse_apt_dnf_version("   \n").is_none());
    }
}
