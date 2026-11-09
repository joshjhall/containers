//! System-package install dispatch (apt / apk / dnf).
//!
//! Catalog `Dependency.tool` entries (e.g. `ca_certificates`, `gcc`,
//! `libc_dev`) describe abstract system packages that need to be installed
//! before the tool can run. Their per-distro package names come from the
//! catalog's `system_package` entries, resolved onto the plan by
//! [`crate::sysdeps`] (containers-db is the single source of truth; luggage
//! keeps no name table of its own). This module:
//!
//! 1. Detects the host's package manager from a [`crate::Platform`].
//! 2. Shells out to it to install the resolved packages, and queries their
//!    installed versions for the evidence row.

use std::process::Command;

use containers_common::tooldb::InstalledDependency;
use tracing::warn;

use crate::Platform;
use crate::error::{LuggageError, Result};
use crate::sysdeps::ResolvedSystemDeps;

/// Detected host package manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackageManager {
    /// `apt-get` (debian/ubuntu).
    Apt,
    /// `apk` (alpine).
    Apk,
    /// `dnf` (rhel/fedora), or `microdnf` where only that exists: RHEL's
    /// UBI *minimal* images ship `microdnf` and no `dnf`. See
    /// [`resolve_program`].
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
pub fn install_dependencies(
    deps: &ResolvedSystemDeps,
    mgr: PackageManager,
    strict: bool,
) -> Result<()> {
    if strict && !deps.unmapped.is_empty() {
        return Err(LuggageError::UnknownDependency {
            manager: format!("{mgr:?}"),
            ids: deps.unmapped.join(", "),
        });
    }
    for tool in &deps.unmapped {
        warn!(tool = %tool, manager = ?mgr, "no catalog system_package mapping for this distro; skipping");
    }
    let packages: Vec<&str> = deps.packages.iter().map(|p| p.package.as_str()).collect();
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
    let program = resolve_program(program, on_path);
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

/// Build the argv that removes `packages` via `mgr` (#1524).
///
/// Only build-only packages luggage itself installed reach this, and the
/// removal must never reach past them. So each manager is driven at the level
/// that **refuses** rather than cascades:
///
/// - apt: `dpkg --purge`, not `apt-get purge -y`. apt resolves a removal by
///   also removing every installed reverse dependency, and `--auto-remove`
///   would add every auto-installed orphan on the host (base-image leftovers
///   included). dpkg removes only the named packages and refuses, non-zero,
///   if anything still installed depends on one.
/// - apk: `apk del` without `-r` drops the names from `world` and prunes only
///   what no remaining `world` entry needs; a package still required by
///   something else is kept, never forced out.
/// - dnf: `rpm -e`, not `dnf remove -y`, for the same reason as apt: rpm
///   refuses ("Failed dependencies") instead of removing dependents.
///
/// The cost is that a build package's own pulled-in dependencies stay on
/// apt/rpm hosts. Returns `None` when `packages` is empty.
#[must_use]
pub fn remove_argv(mgr: PackageManager, packages: &[&str]) -> Option<(&'static str, Vec<String>)> {
    if packages.is_empty() {
        return None;
    }
    let owned = packages.iter().map(|p| (*p).to_owned());
    let (program, mut args) = match mgr {
        PackageManager::Apt => ("dpkg", vec!["--purge".to_owned()]),
        PackageManager::Apk => ("apk", vec!["del".to_owned(), "--no-cache".to_owned()]),
        PackageManager::Dnf => ("rpm", vec!["-e".to_owned()]),
    };
    args.extend(owned);
    Some((program, args))
}

/// Build the argv that asks whether `package` is installed.
///
/// - apt: `dpkg-query -W -f='${db:Status-Status}\n' <pkg>`; dpkg-query expands
///   the `\n` itself, giving one line per architecture instance.
/// - apk: `apk info -e <pkg>`.
/// - dnf: `rpm -q <pkg>`.
///
/// How each answer is read lives in [`presence_from_output`].
#[must_use]
fn presence_argv(mgr: PackageManager, package: &str) -> (&'static str, Vec<String>) {
    match mgr {
        PackageManager::Apt => (
            "dpkg-query",
            vec!["-W".to_owned(), "-f=${db:Status-Status}\\n".to_owned(), package.to_owned()],
        ),
        PackageManager::Apk => {
            ("apk", vec!["info".to_owned(), "-e".to_owned(), package.to_owned()])
        }
        PackageManager::Dnf => ("rpm", vec!["-q".to_owned(), package.to_owned()]),
    }
}

/// Read a presence query's result, failing **closed**: only an unambiguous
/// "not installed" answer is `false`. Anything else (a launch failure, a
/// locked or corrupt package DB, a permission error, an unexpected exit)
/// reads as present. The caller uses this to decide what is safe to remove,
/// and an unknown must never turn into removing a package luggage did not
/// install.
///
/// - apt: exit 0 is decided by the status words, one line per architecture
///   instance on a multiarch host. Absent only when every line is
///   `not-installed` or `config-files`. Any other state (`installed`,
///   `half-installed`, `unpacked`, `triggers-pending`, ...) or empty output
///   reads as present. A non-zero
///   exit is absence only when dpkg-query says it found no such package.
/// - apk: `info -e` exits 0 when installed and 1 with nothing on stderr when
///   not.
/// - rpm: `-q` exits 1 and prints `package <p> is not installed` when not.
#[must_use]
fn presence_from_output(
    mgr: PackageManager,
    package: &str,
    output: &std::io::Result<std::process::Output>,
) -> bool {
    let Ok(o) = output else { return true };
    let stdout = String::from_utf8_lossy(&o.stdout);
    let stderr = String::from_utf8_lossy(&o.stderr);
    let absent = match (mgr, o.status.code()) {
        // One line per matching architecture instance on a multiarch host.
        // Absent only when every instance is cleanly gone. A partial state
        // (half-installed, unpacked, triggers-pending) or empty output is
        // inconclusive and reads as present.
        (PackageManager::Apt, Some(0)) => {
            let states: Vec<&str> =
                stdout.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
            if states.contains(&"installed") {
                return true;
            }
            !states.is_empty()
                && states.iter().all(|l| matches!(*l, "not-installed" | "config-files"))
        }
        (PackageManager::Apt, Some(1)) => stderr.contains("no packages found matching"),
        (PackageManager::Apk | PackageManager::Dnf, Some(0)) => return true,
        (PackageManager::Apk, Some(1)) => stderr.trim().is_empty(),
        (PackageManager::Dnf, Some(1)) => {
            stdout.trim() == format!("package {package} is not installed")
        }
        _ => false,
    };
    if !absent {
        warn!(package, manager = ?mgr, status = %o.status, "presence query was inconclusive; treating as present");
    }
    !absent
}

/// `true` when `package` is installed on the host, or when that cannot be
/// established (see [`presence_from_output`]).
#[must_use]
pub fn is_installed(mgr: PackageManager, package: &str) -> bool {
    let (program, args) = presence_argv(mgr, package);
    presence_from_output(mgr, package, &Command::new(program).args(&args).output())
}

/// Remove `packages` from the host via `mgr` (#1524). A no-op when empty.
///
/// `rpm -e` is one transaction: if any single package is refused (something
/// installed still depends on it), nothing is removed. `dpkg --purge` removes
/// what it can and exits non-zero for the rest. Either way a failed batch is
/// retried one package at a time, so everything that can go does go, and only
/// the packages still refused on their own are reported. Purging a package
/// that is already gone exits 0 on dpkg, so the retry costs nothing there.
/// (Verified on debian:trixie-slim, 2026-11-09.)
///
/// # Errors
///
/// [`LuggageError::PackageManagerFailed`] when a name is empty or starts with
/// `-` (nothing is run), or naming each package that could not be removed, with the manager's stderr. A package refused because an
/// installed package depends on it means the catalog declared a runtime need
/// as `purpose: build`. That fails loudly rather than shipping a silently
/// broken image.
pub fn remove_packages(packages: &[&str], mgr: PackageManager) -> Result<()> {
    // Names come from the catalog and land in argv after the manager's own
    // flags. One starting with `-` would be parsed as an option, e.g.
    // `--nodeps` or `--force-depends`, defeating the refuse-don't-cascade
    // removal. Refuse the whole removal before anything runs.
    if let Some(bad) = packages.iter().find(|p| p.is_empty() || p.starts_with('-')) {
        return Err(LuggageError::PackageManagerFailed {
            message: format!("refusing to remove package with option-like name {bad:?}"),
        });
    }
    let refused: Vec<String> = match run_removal(mgr, packages) {
        Ok(()) => return Ok(()),
        // A lone package has nothing to retry.
        Err(e) if packages.len() <= 1 => vec![e],
        Err(_) => remove_individually(mgr, packages),
    };
    if refused.is_empty() {
        return Ok(());
    }
    Err(LuggageError::PackageManagerFailed {
        message: format!("could not remove build dependencies: {}", refused.join("; ")),
    })
}

/// Remove each package in its own transaction, returning a description of
/// every one that was still refused.
fn remove_individually(mgr: PackageManager, packages: &[&str]) -> Vec<String> {
    packages
        .iter()
        .filter_map(|p| run_removal(mgr, &[p]).err().map(|e| format!("{p}: {e}")))
        .collect()
}

/// Run one removal transaction. `Ok` when `packages` is empty.
fn run_removal(mgr: PackageManager, packages: &[&str]) -> std::result::Result<(), String> {
    let Some((program, args)) = remove_argv(mgr, packages) else { return Ok(()) };
    let out = Command::new(program)
        .args(&args)
        .output()
        .map_err(|e| format!("{program} failed to launch: {e}"))?;
    if out.status.success() {
        return Ok(());
    }
    Err(format!(
        "{program} {} exited {}: {}",
        args.join(" "),
        out.status,
        String::from_utf8_lossy(&out.stderr).trim_end(),
    ))
}

/// Pick the binary to run for `program` given what is on `PATH`.
///
/// `install_argv` names the canonical program; this resolves the one case
/// where that binary may be absent with a drop-in present: `dnf` on RHEL UBI
/// minimal, which ships only `microdnf` (same `install -y <pkgs>` argv). Every
/// RHEL evidence run failed with `dnf failed to launch: No such file or
/// directory` until this existed. `dnf` is preferred when both exist; any
/// other program is returned unchanged. `on_path` is injected for tests.
#[must_use]
pub fn resolve_program(program: &'static str, on_path: impl Fn(&str) -> bool) -> &'static str {
    if program == "dnf" && !on_path("dnf") && on_path("microdnf") {
        return "microdnf";
    }
    program
}

/// `true` when `name` is an executable file in some `PATH` directory.
fn on_path(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|dir| is_executable(&dir.join(name)))
    })
}

#[cfg(unix)]
fn is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

// luggage installs only on Linux, but the workspace also builds on Windows
// (stibbons CI), where there is no exec bit to check.
#[cfg(not(unix))]
fn is_executable(path: &std::path::Path) -> bool {
    path.is_file()
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
/// Returns one [`InstalledDependency`] per resolved package (tools with no
/// catalog mapping for the distro were left out by [`crate::sysdeps`]). `version` is `None` when the package
/// manager query fails to launch, exits non-zero, or prints nothing — a
/// missing version must never abort an otherwise-successful install, so this
/// function returns no error. Used to populate evidence rows ([containers#642]).
///
/// [containers#642]: https://github.com/joshjhall/containers/issues/642
#[must_use]
pub fn resolve_installed_versions(
    deps: &ResolvedSystemDeps,
    mgr: PackageManager,
) -> Vec<InstalledDependency> {
    deps.packages
        .iter()
        .map(|p| InstalledDependency {
            tool: p.tool.clone(),
            package: p.package.clone(),
            version: query_installed_version(mgr, &p.package),
        })
        .collect()
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
    fn resolve_program_falls_back_to_microdnf_on_ubi_minimal() {
        // UBI minimal: microdnf present, dnf absent (probed on base-rhel-9/10).
        assert_eq!(resolve_program("dnf", |n| n == "microdnf"), "microdnf");
    }

    #[test]
    fn resolve_program_prefers_dnf_when_present() {
        assert_eq!(resolve_program("dnf", |_| true), "dnf");
        assert_eq!(resolve_program("dnf", |n| n == "dnf"), "dnf");
    }

    #[test]
    fn resolve_program_keeps_dnf_when_neither_exists() {
        // Fails later with a clear "dnf failed to launch", not a wrong name.
        assert_eq!(resolve_program("dnf", |_| false), "dnf");
    }

    #[test]
    fn resolve_program_leaves_other_managers_alone() {
        assert_eq!(resolve_program("apt-get", |_| false), "apt-get");
        assert_eq!(resolve_program("apk", |n| n == "microdnf"), "apk");
    }

    #[test]
    fn install_argv_returns_none_when_no_packages() {
        assert!(install_argv(PackageManager::Apt, &[]).is_none());
    }

    fn resolved(packages: &[(&str, &str)], unmapped: &[&str]) -> ResolvedSystemDeps {
        ResolvedSystemDeps {
            packages: packages
                .iter()
                .map(|(t, p)| crate::sysdeps::SystemPackageDep {
                    tool: (*t).into(),
                    package: (*p).into(),
                    purpose: containers_common::tooldb::DependencyPurpose::Both,
                })
                .collect(),
            unmapped: unmapped.iter().map(|u| (*u).to_string()).collect(),
        }
    }

    #[test]
    fn remove_argv_per_manager() {
        let argv = |prog: &'static str, args: &[&str]| {
            Some((prog, args.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>()))
        };
        assert_eq!(
            remove_argv(PackageManager::Apt, &["g++", "make"]),
            argv("dpkg", &["--purge", "g++", "make"])
        );
        assert_eq!(
            remove_argv(PackageManager::Apk, &["g++"]),
            argv("apk", &["del", "--no-cache", "g++"])
        );
        assert_eq!(remove_argv(PackageManager::Dnf, &["gcc-c++"]), argv("rpm", &["-e", "gcc-c++"]));
        assert_eq!(remove_argv(PackageManager::Apk, &[]), None);
    }

    /// The front ends that resolve a removal by also removing reverse
    /// dependents (`apt-get`, `dnf`), auto-removing orphans, or recursing
    /// (`apk del -r`) must never be used: each reaches past the named set.
    #[test]
    fn removal_never_cascades_past_the_named_packages() {
        for mgr in [PackageManager::Apt, PackageManager::Apk, PackageManager::Dnf] {
            let (prog, args) = remove_argv(mgr, &["g++"]).unwrap();
            assert!(!matches!(prog, "apt-get" | "dnf" | "microdnf"), "{mgr:?}: {prog}");
            for flag in ["--auto-remove", "autoremove", "-r", "--rdepends", "-y"] {
                assert!(!args.iter().any(|a| a == flag), "{mgr:?}: {args:?} has {flag}");
            }
        }
    }

    #[test]
    fn presence_argv_per_manager() {
        assert_eq!(
            presence_argv(PackageManager::Apt, "make"),
            (
                "dpkg-query",
                vec!["-W".to_owned(), "-f=${db:Status-Status}\\n".to_owned(), "make".to_owned()]
            )
        );
        assert_eq!(
            presence_argv(PackageManager::Apk, "make"),
            ("apk", vec!["info".to_owned(), "-e".to_owned(), "make".to_owned()])
        );
        assert_eq!(
            presence_argv(PackageManager::Dnf, "make"),
            ("rpm", vec!["-q".to_owned(), "make".to_owned()])
        );
    }

    #[cfg(unix)]
    fn out(code: i32, stdout: &str, stderr: &str) -> std::process::Output {
        use std::os::unix::process::ExitStatusExt as _;
        std::process::Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        }
    }

    #[cfg(unix)]
    #[test]
    fn presence_is_absent_only_on_an_unambiguous_not_installed() {
        use PackageManager::{Apk, Apt, Dnf};
        let present = |m, o| presence_from_output(m, "make", &Ok(o));
        // apt: exit 0 is read from the status word.
        assert!(present(Apt, out(0, "installed\n", "")));
        assert!(!present(Apt, out(0, "config-files\n", "")));
        // Multiarch: one status line per architecture instance.
        assert!(present(Apt, out(0, "installed\ninstalled\n", "")));
        assert!(present(Apt, out(0, "config-files\ninstalled\n", "")));
        assert!(!present(Apt, out(0, "config-files\nnot-installed\n", "")));
        // Partial states and empty output are inconclusive: present.
        for partial in ["half-installed", "unpacked", "half-configured", "triggers-pending"] {
            assert!(present(Apt, out(0, &format!("{partial}\n"), "")), "{partial}");
        }
        assert!(present(Apt, out(0, "not-installed\nunpacked\n", "")));
        assert!(present(Apt, out(0, "", "")));
        assert!(!present(Apt, out(1, "", "dpkg-query: no packages found matching make")));
        // apk / rpm: their documented "not installed" answers.
        assert!(present(Apk, out(0, "", "")));
        assert!(!present(Apk, out(1, "", "")));
        assert!(present(Dnf, out(0, "make-4.3-1.el9", "")));
        assert!(!present(Dnf, out(1, "package make is not installed\n", "")));
    }

    /// Every probe failure that is not a clear "not installed" — a launch
    /// failure, a locked DB, an unexpected exit — reads as present, for every
    /// manager. Asserted unconditionally: nothing depends on the test host.
    #[cfg(unix)]
    #[test]
    fn inconclusive_presence_fails_closed() {
        for mgr in [PackageManager::Apt, PackageManager::Apk, PackageManager::Dnf] {
            let launch = Err(std::io::Error::from(std::io::ErrorKind::NotFound));
            assert!(presence_from_output(mgr, "make", &launch), "{mgr:?}: launch failure");
            let locked = Ok(out(1, "", "error: database is locked"));
            assert!(presence_from_output(mgr, "make", &locked), "{mgr:?}: locked db");
            assert!(presence_from_output(mgr, "make", &Ok(out(2, "", ""))), "{mgr:?}: exit 2");
        }
        // rpm's exit 1 for a *different* package is not this one's absence.
        let other = Ok(out(1, "package gmake is not installed", ""));
        assert!(presence_from_output(PackageManager::Dnf, "make", &other));
    }

    /// An option-looking name is refused before any package manager runs
    /// (none exists on the test host, so reaching one would surface as a
    /// launch error naming the program, not this message).
    #[test]
    fn remove_packages_refuses_option_like_names() {
        for mgr in [PackageManager::Apt, PackageManager::Apk, PackageManager::Dnf] {
            for bad in ["--nodeps", "-r", ""] {
                let err = remove_packages(&["make", bad], mgr).unwrap_err();
                assert!(err.to_string().contains("option-like name"), "{mgr:?} {bad:?}: {err}");
            }
        }
    }

    #[test]
    fn remove_packages_is_a_noop_when_empty() {
        // Must not shell out at all: no package manager exists on the test host.
        remove_packages(&[], PackageManager::Apt).unwrap();
    }

    #[test]
    fn install_dependencies_strict_errors_on_unmapped() {
        // A dep with no catalog mapping for this distro is refused in strict
        // mode before any package manager runs.
        let deps = resolved(&[("ca_certificates", "ca-certificates")], &["frobnicator"]);
        match install_dependencies(&deps, PackageManager::Apt, true) {
            Err(LuggageError::UnknownDependency { ids, .. }) => assert_eq!(ids, "frobnicator"),
            other => panic!("expected UnknownDependency, got {other:?}"),
        }
    }

    #[test]
    fn install_dependencies_ok_when_nothing_to_install() {
        // Nothing mapped and nothing unmapped: strict mode returns Ok without
        // shelling out (install_argv is None for []).
        assert!(install_dependencies(&resolved(&[], &[]), PackageManager::Apt, true).is_ok());
    }

    #[test]
    fn resolve_installed_versions_follows_the_resolved_packages() {
        // One entry per resolved package, named by the catalog's package (not
        // the tool id); unmapped tools are not queried.
        let deps = resolved(&[("libc_dev", "glibc-devel")], &["frobnicator"]);
        let out = resolve_installed_versions(&deps, PackageManager::Dnf);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].tool, "libc_dev");
        assert_eq!(out[0].package, "glibc-devel");
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
