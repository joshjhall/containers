//! Removal and presence checks for build-only system packages (#1524).
//!
//! Split out of [`super::syspackages`], which keeps install dispatch and
//! version queries. Packages are removed at the level that **refuses**
//! rather than cascades (see [`remove_argv`]), and presence is read
//! failing closed (see [`is_installed`]).

use std::process::Command;

use tracing::warn;

use super::syspackages::PackageManager;
use crate::error::{LuggageError, Result};

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
/// [`LuggageError::BuildDepRemovalFailed`] when a name is empty or starts
/// with `-` (nothing is run), or naming each package that could not be
/// removed, with the manager's stderr. A package refused because an
/// installed package depends on it means the catalog declared a runtime need
/// as `purpose: build`. That fails loudly rather than shipping a silently
/// broken image, and is classified as a cleanup failure, not infra (#1668).
///
/// [`LuggageError::PackageManagerFailed`] when the manager cannot be
/// launched: a host fault, classified as infra.
pub fn remove_packages(packages: &[&str], mgr: PackageManager) -> Result<()> {
    // Names come from the catalog and land in argv after the manager's own
    // flags. One starting with `-` would be parsed as an option, e.g.
    // `--nodeps` or `--force-depends`, defeating the refuse-don't-cascade
    // removal. Refuse the whole removal before anything runs.
    if let Some(bad) = packages.iter().find(|p| p.is_empty() || p.starts_with('-')) {
        return Err(LuggageError::BuildDepRemovalFailed {
            message: format!("refusing to remove package with option-like name {bad:?}"),
        });
    }
    remove_with(packages, |pkgs| run_removal(mgr, pkgs))
}

/// Why one removal transaction did not succeed.
#[derive(Debug)]
enum RemovalFault {
    /// The manager could not be started at all: a host fault, not a refusal.
    Launch(String),
    /// The manager ran and exited non-zero.
    Refused(String),
}

/// [`remove_packages`] with the transaction runner injected, so the batch,
/// retry, and error-class decisions are testable without a package manager.
///
/// A manager that cannot launch fails as [`LuggageError::PackageManagerFailed`]
/// (infra), because nothing about the catalog is implied. Only packages the
/// manager ran and refused become [`LuggageError::BuildDepRemovalFailed`]
/// (#1668).
fn remove_with<'a>(
    packages: &[&'a str],
    mut run: impl FnMut(&[&'a str]) -> std::result::Result<(), RemovalFault>,
) -> Result<()> {
    let refused: Vec<String> = match run(packages) {
        Ok(()) => return Ok(()),
        Err(RemovalFault::Launch(message)) => {
            return Err(LuggageError::PackageManagerFailed { message });
        }
        // A lone package has nothing to retry. Name it the way the per-package
        // retry does, so both paths report the same `"{pkg}: {err}"` shape.
        Err(RemovalFault::Refused(e)) if packages.len() <= 1 => match packages.first() {
            Some(p) => vec![format!("{p}: {e}")],
            None => vec![e],
        },
        // Retry each package on its own; a launch failure mid-retry still
        // wins over any refusal, since the host is what broke.
        Err(RemovalFault::Refused(_)) => {
            let mut launch = None;
            let refused = remove_until_fixed_point(packages, |p| match run(&[p]) {
                Ok(()) => Ok(()),
                Err(RemovalFault::Refused(e)) => Err(e),
                Err(RemovalFault::Launch(m)) => {
                    let e = m.clone();
                    launch.get_or_insert(m);
                    Err(e)
                }
            });
            if let Some(message) = launch {
                return Err(LuggageError::PackageManagerFailed { message });
            }
            refused
        }
    };
    refusals_to_result(&refused)
}

/// Turn the per-package refusals into the removal's result: `Ok` when none,
/// else one [`LuggageError::BuildDepRemovalFailed`] naming every refusal.
/// Split out so the error shape and its class are testable without a
/// package manager (#1668).
fn refusals_to_result(refused: &[String]) -> Result<()> {
    if refused.is_empty() {
        return Ok(());
    }
    // The variant's Display already says "could not remove build
    // dependencies", so the message carries only the refusals.
    Err(LuggageError::BuildDepRemovalFailed { message: refused.join("; ") })
}

/// Pass over `packages` removing each one via `remove`, then pass again over
/// the ones refused, until a pass removes nothing. Returns `"{pkg}: {err}"`
/// for each package still refused at that point.
///
/// One pass is not enough: dpkg and rpm refuse a package while an installed
/// package still depends on it, so when a build dep is listed before the
/// build dep that needs it, the first is refused, the second goes, and only a
/// second pass can take the first. Each extra pass must remove at least one
/// package, so this runs at most `packages.len()` passes.
fn remove_until_fixed_point<'a>(
    packages: &[&'a str],
    mut remove: impl FnMut(&'a str) -> std::result::Result<(), String>,
) -> Vec<String> {
    let mut pending: Vec<&'a str> = packages.to_vec();
    loop {
        let before = pending.len();
        let mut refused = Vec::new();
        for p in pending {
            if let Err(e) = remove(p) {
                refused.push((p, e));
            }
        }
        if refused.is_empty() || refused.len() == before {
            return refused.into_iter().map(|(p, e)| format!("{p}: {e}")).collect();
        }
        pending = refused.into_iter().map(|(p, _)| p).collect();
    }
}

/// Run one removal transaction. `Ok` when `packages` is empty.
fn run_removal(mgr: PackageManager, packages: &[&str]) -> std::result::Result<(), RemovalFault> {
    let Some((program, args)) = remove_argv(mgr, packages) else { return Ok(()) };
    let out = Command::new(program)
        .args(&args)
        .output()
        .map_err(|e| RemovalFault::Launch(format!("{program} failed to launch: {e}")))?;
    if out.status.success() {
        return Ok(());
    }
    Err(RemovalFault::Refused(format!(
        "{program} {} exited {}: {}",
        args.join(" "),
        out.status,
        String::from_utf8_lossy(&out.stderr).trim_end(),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// A fake dpkg/rpm: refuses to remove a package while any package that
    /// depends on it (per `deps`, `(dependent, dependency)`) is still
    /// installed, and records every removal attempt in `calls`.
    fn fake_manager<'a>(
        installed: &'a std::cell::RefCell<Vec<&'static str>>,
        deps: &'a [(&'static str, &'static str)],
        calls: &'a std::cell::RefCell<Vec<&'static str>>,
    ) -> impl FnMut(&'static str) -> std::result::Result<(), String> + 'a {
        move |p| {
            calls.borrow_mut().push(p);
            let mut inst = installed.borrow_mut();
            if let Some((dependent, _)) = deps.iter().find(|(d, dep)| *dep == p && inst.contains(d))
            {
                return Err(format!("dependency problems - {dependent} depends on {p}"));
            }
            inst.retain(|i| *i != p);
            Ok(())
        }
    }

    /// Cycle-8 defect: B depends on A, and A is listed first. A single pass
    /// refuses A (B still installed), removes B, and stops — reporting A as
    /// refused though it is removable. The fixed-point retry must take both.
    #[test]
    fn retry_removes_a_dependency_listed_before_its_dependent() {
        let installed = std::cell::RefCell::new(vec!["libfoo-dev", "foo-build"]);
        let deps = [("foo-build", "libfoo-dev")];
        let calls = std::cell::RefCell::new(Vec::new());

        let refused = remove_until_fixed_point(
            &["libfoo-dev", "foo-build"],
            fake_manager(&installed, &deps, &calls),
        );

        assert!(refused.is_empty(), "nothing should be reported refused: {refused:?}");
        assert!(installed.borrow().is_empty(), "both removed: {:?}", installed.borrow());
        // Proves the fix, not luck: the first attempt on libfoo-dev was
        // refused, and a second pass retried it after foo-build went.
        assert_eq!(*calls.borrow(), ["libfoo-dev", "foo-build", "libfoo-dev"]);
    }

    /// A dependent listed first needs only one pass; no spurious retries.
    #[test]
    fn retry_single_pass_when_dependent_listed_first() {
        let installed = std::cell::RefCell::new(vec!["foo-build", "libfoo-dev"]);
        let deps = [("foo-build", "libfoo-dev")];
        let calls = std::cell::RefCell::new(Vec::new());

        let refused = remove_until_fixed_point(
            &["foo-build", "libfoo-dev"],
            fake_manager(&installed, &deps, &calls),
        );

        assert!(refused.is_empty(), "{refused:?}");
        assert!(installed.borrow().is_empty());
        assert_eq!(*calls.borrow(), ["foo-build", "libfoo-dev"]);
    }

    /// A package held by something outside the removal set is genuinely
    /// refused: the loop stops once a pass makes no progress and reports
    /// exactly that package, after removing everything it could.
    #[test]
    fn retry_stops_and_reports_a_package_still_refused() {
        // `runtime-tool` is installed and needs libfoo-dev; it is not ours to remove.
        let installed = std::cell::RefCell::new(vec!["libfoo-dev", "foo-build", "runtime-tool"]);
        let deps = [("foo-build", "libfoo-dev"), ("runtime-tool", "libfoo-dev")];
        let calls = std::cell::RefCell::new(Vec::new());

        let refused = remove_until_fixed_point(
            &["libfoo-dev", "foo-build"],
            fake_manager(&installed, &deps, &calls),
        );

        assert_eq!(refused.len(), 1, "{refused:?}");
        assert!(refused[0].starts_with("libfoo-dev: "), "{refused:?}");
        assert!(refused[0].contains("runtime-tool depends on libfoo-dev"), "{refused:?}");
        assert_eq!(*installed.borrow(), ["libfoo-dev", "runtime-tool"]);
        // Pass 1: libfoo-dev refused, foo-build removed. Pass 2: libfoo-dev
        // still refused, no progress -> stop (no third attempt).
        assert_eq!(*calls.borrow(), ["libfoo-dev", "foo-build", "libfoo-dev"]);
    }

    /// #1668 end to end, minus the host: on UBI 9, gcc pulls in systemd,
    /// which needs util-linux, so `rpm -e util-linux` is refused with rpm's
    /// own text. The refusal must survive the fixed-point loop, still name
    /// the package and rpm's reason, and classify as a cleanup failure —
    /// not `infra`, which made evidence read it as a CI fault.
    #[test]
    fn a_dependency_refused_build_dep_fails_as_cleanup_not_infra() {
        use crate::error::ErrorClass;
        const RPM: &str = "rpm -e util-linux exited exit status: 1: error: Failed dependencies:\n\
                           \tutil-linux is needed by (installed) systemd-252-79.el9_9.x86_64";
        let mut calls = Vec::new();
        let refused = remove_until_fixed_point(&["util-linux", "make"], |p| {
            calls.push(p);
            if p == "util-linux" { Err(RPM.to_owned()) } else { Ok(()) }
        });
        // make went; util-linux was retried once more and still refused.
        assert_eq!(calls, ["util-linux", "make", "util-linux"]);

        let err = refusals_to_result(&refused).unwrap_err();
        assert!(matches!(err, LuggageError::BuildDepRemovalFailed { .. }), "{err:?}");
        let shown = err.to_string();
        assert!(shown.starts_with("could not remove build dependencies: util-linux: "), "{shown}");
        assert!(shown.contains("needed by (installed) systemd"), "{shown}");
        assert!(!shown.contains("make"), "only the refused package is named: {shown}");
        assert_eq!(ErrorClass::from(&err), ErrorClass::PostInstall);
    }

    #[test]
    fn no_refusals_is_ok() {
        refusals_to_result(&[]).unwrap();
    }

    /// The other half of #1668's classification: a manager that cannot be
    /// started says nothing about the catalog, so it stays infra, whether it
    /// fails on the batch or only on a per-package retry.
    #[test]
    fn a_manager_that_cannot_launch_fails_as_infra() {
        use crate::error::ErrorClass;
        let gone =
            || RemovalFault::Launch("rpm failed to launch: No such file or directory".into());

        let err = remove_with(&["make"], |_| Err(gone())).unwrap_err();
        assert!(matches!(err, LuggageError::PackageManagerFailed { .. }), "{err:?}");
        assert_eq!(ErrorClass::from(&err), ErrorClass::Infra);

        // Batch refused, then the manager vanishes mid-retry: still infra,
        // and the launch failure is what gets reported.
        let mut calls = 0;
        let err = remove_with(&["util-linux", "make"], |_| {
            calls += 1;
            if calls == 1 {
                Err(RemovalFault::Refused("batch refused".into()))
            } else {
                Err(gone())
            }
        })
        .unwrap_err();
        assert!(matches!(err, LuggageError::PackageManagerFailed { .. }), "{err:?}");
        assert!(err.to_string().contains("failed to launch"), "{err}");
        assert!(!err.to_string().contains("batch refused"), "{err}");
        assert_eq!(ErrorClass::from(&err), ErrorClass::Infra);
    }

    /// A refused batch goes through the per-package retry and comes out as a
    /// cleanup failure naming only what stayed refused.
    #[test]
    fn a_refused_batch_is_retried_and_fails_as_cleanup() {
        use crate::error::ErrorClass;
        let mut calls: Vec<Vec<&str>> = Vec::new();
        let err = remove_with(&["util-linux", "make"], |pkgs| {
            calls.push(pkgs.to_vec());
            if pkgs.contains(&"util-linux") {
                Err(RemovalFault::Refused("util-linux is needed by systemd".into()))
            } else {
                Ok(())
            }
        })
        .unwrap_err();
        assert_eq!(
            calls,
            [vec!["util-linux", "make"], vec!["util-linux"], vec!["make"], vec!["util-linux"]]
        );
        assert!(matches!(err, LuggageError::BuildDepRemovalFailed { .. }), "{err:?}");
        assert!(err.to_string().contains("util-linux: util-linux is needed by systemd"), "{err}");
        assert!(!err.to_string().contains("make"), "{err}");
        assert_eq!(ErrorClass::from(&err), ErrorClass::PostInstall);
    }

    /// A lone refused package is named exactly as the per-package retry names
    /// it (#1629). Exact equality, not a substring: the manager's own message
    /// already mentions the package, so `contains` would pass unprefixed.
    #[test]
    fn a_refused_lone_package_is_named_like_a_batch() {
        use crate::error::ErrorClass;
        let refuse = |pkgs: &[&str]| {
            if pkgs.contains(&"util-linux") {
                Err(RemovalFault::Refused("util-linux is needed by systemd".into()))
            } else {
                Ok(())
            }
        };

        let lone = remove_with(&["util-linux"], refuse).unwrap_err();
        assert!(matches!(lone, LuggageError::BuildDepRemovalFailed { .. }), "{lone:?}");
        assert_eq!(ErrorClass::from(&lone), ErrorClass::PostInstall);
        assert_eq!(
            lone.to_string(),
            "could not remove build dependencies: util-linux: util-linux is needed by systemd"
        );

        let batch = remove_with(&["util-linux", "make"], refuse).unwrap_err();
        assert_eq!(lone.to_string(), batch.to_string());

        // No package to name: the refusal is reported as-is rather than
        // panicking on a missing first element.
        let none =
            remove_with(&[], |_| Err(RemovalFault::Refused("nothing to do".into()))).unwrap_err();
        assert_eq!(none.to_string(), "could not remove build dependencies: nothing to do");
    }

    /// Several refusals aggregate into one error naming each refused package,
    /// in input order, and never a package that went (#1631). Exact equality:
    /// a substring check would pass with only the first refusal kept.
    #[test]
    fn every_refused_package_is_named_in_the_aggregate() {
        let err = remove_with(&["a", "b", "c"], |pkgs| {
            if pkgs.len() == 1 && pkgs[0] == "b" {
                Ok(())
            } else {
                Err(RemovalFault::Refused(format!("{} held", pkgs.join(" "))))
            }
        })
        .unwrap_err();
        assert!(matches!(err, LuggageError::BuildDepRemovalFailed { .. }), "{err:?}");
        assert_eq!(err.to_string(), "could not remove build dependencies: a: a held; c: c held");
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
                // The variant, not just the text: a regression back to
                // PackageManagerFailed would classify as infra (#1668).
                assert!(
                    matches!(err, LuggageError::BuildDepRemovalFailed { .. }),
                    "{mgr:?} {bad:?}: {err:?}"
                );
                assert_eq!(
                    crate::error::ErrorClass::from(&err),
                    crate::error::ErrorClass::PostInstall,
                    "{mgr:?} {bad:?}"
                );
            }
        }
    }

    #[test]
    fn remove_packages_is_a_noop_when_empty() {
        // Must not shell out at all: no package manager exists on the test host.
        remove_packages(&[], PackageManager::Apt).unwrap();
    }
}
