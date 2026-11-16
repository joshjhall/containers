//! Orchestration tests for the build-dependency removal in
//! [`Installer::run_stages`] (#1630).
//!
//! The pieces — candidate selection, the removal re-check, error ranking,
//! report wiring — are unit-tested where they live. What only these tests
//! cover is how `run_stages` sequences them: removal before validate, removal
//! on every failure path, and exactly what landed being what is removed. They
//! drive the real stages end to end with every external effect faked: HTTP via
//! [`MockHttpClient`], the install method via [`RecordingRunner`], and the
//! host package manager via [`FakeSystemPackages`] behind the
//! [`sysops::SystemPackages`] seam. Only the validate probe really executes,
//! as a shell shim under a tempdir `bin_root`.

use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use containers_common::tooldb::DependencyPurpose::{self, Both, Build};
use containers_common::tooldb::{InstallMethodKind, Verification};
use tempfile::TempDir;

use super::download::{HttpClient, MockHttpClient};
use super::methods::{CommandOutcome, CommandRunner, RecordingRunner};
use super::sysops::SystemPackages;
use super::syspackages::PackageManager;
use super::tests::sample_resolved_with_deps;
use super::{Installer, InstallerOptions, StageRun};
use crate::error::{ErrorClass, LuggageError, Result};
use crate::resolver::ResolvedInstall;
use crate::sysdeps::{ResolvedSystemDeps, SystemPackageDep};

const ARTIFACT_URL: &str = "https://example.test/install.sh";

/// An in-memory host package manager.
///
/// `present` is the host's package set; `events` logs every install and
/// removal call, in order, as the test observes them.
#[derive(Default)]
struct FakeSystemPackages {
    present: Mutex<BTreeSet<String>>,
    events: Mutex<Vec<String>>,
    /// Packages `install` actually lands. `None` lands every requested one.
    lands: Option<Vec<String>>,
    /// When set, `install` lands `lands` and then fails with this message.
    install_error: Option<String>,
    /// When set, `remove` fails with this message (after its effects).
    remove_error: Option<String>,
    /// Packages `remove` leaves in place while still exiting 0 — the
    /// `apk del` "still needed by something" case.
    keeps: Vec<String>,
    /// Touched by `remove`, so the validate shim can tell whether it runs
    /// before or after the removal.
    removal_marker: Option<PathBuf>,
}

impl FakeSystemPackages {
    fn with_present(self, pkgs: &[&str]) -> Self {
        self.present.lock().unwrap().extend(pkgs.iter().map(|p| (*p).to_owned()));
        self
    }

    fn events(&self) -> Vec<String> {
        self.events.lock().unwrap().clone()
    }

    /// The package lists `remove` was called with, in call order.
    fn removals(&self) -> Vec<String> {
        self.events().into_iter().filter(|e| e.starts_with("remove ")).collect()
    }
}

impl SystemPackages for FakeSystemPackages {
    fn is_installed(&self, _: PackageManager, package: &str) -> bool {
        self.present.lock().unwrap().contains(package)
    }

    fn install(&self, deps: &ResolvedSystemDeps, _: PackageManager, _: bool) -> Result<()> {
        self.events.lock().unwrap().push("install".into());
        let landed: Vec<String> = self
            .lands
            .clone()
            .unwrap_or_else(|| deps.packages.iter().map(|p| p.package.clone()).collect());
        self.present.lock().unwrap().extend(landed);
        self.install_error
            .as_ref()
            .map_or(Ok(()), |m| Err(LuggageError::PackageManagerFailed { message: m.clone() }))
    }

    fn remove(&self, packages: &[&str], _: PackageManager) -> Result<()> {
        self.events.lock().unwrap().push(format!("remove {}", packages.join(" ")));
        {
            let mut present = self.present.lock().unwrap();
            for p in packages {
                if !self.keeps.iter().any(|k| k == p) {
                    present.remove(*p);
                }
            }
        }
        if let Some(m) = &self.removal_marker {
            fs::write(m, b"removed").unwrap();
        }
        self.remove_error
            .as_ref()
            .map_or(Ok(()), |m| Err(LuggageError::BuildDepRemovalFailed { message: m.clone() }))
    }
}

/// Temp roots plus the validate shim's two side files.
struct Host {
    root: TempDir,
}

impl Host {
    fn new() -> Self {
        let host = Self { root: tempfile::tempdir().unwrap() };
        fs::create_dir_all(host.bin_root()).unwrap();
        host.write_validate_shim();
        host
    }

    fn bin_root(&self) -> PathBuf {
        self.root.path().join("bin")
    }

    /// Written by the fake's `remove`.
    fn removal_marker(&self) -> PathBuf {
        self.root.path().join("removed.marker")
    }

    /// Appended to every time validate runs the shim.
    fn validate_log(&self) -> PathBuf {
        self.root.path().join("validate.log")
    }

    /// `bin/rustc` reports the expected version only once the build deps are
    /// gone; run before the removal it fails, the way a tool that still
    /// leans on its build toolchain would be caught.
    fn write_validate_shim(&self) {
        let shim = self.bin_root().join("rustc");
        let marker = self.removal_marker();
        let log = self.validate_log();
        fs::write(
            &shim,
            format!(
                "#!/bin/sh\necho ran >> '{log}'\nif [ -e '{marker}' ]; then echo 'rustc 1.96.0'; \
                 else echo 'validate ran before build-dep removal' >&2; exit 1; fi\n",
                log = log.display(),
                marker = marker.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn validate_ran(&self) -> bool {
        self.validate_log().exists()
    }

    fn options(&self) -> InstallerOptions {
        let r = self.root.path();
        InstallerOptions {
            bin_root: self.bin_root(),
            cache_root: r.join("cache"),
            log_dir: r.join("log"),
            tmp_root: r.join("tmp"),
            user_override: Some("root".into()),
            // The validate shim is already in `bin_root`; without this the
            // idempotency precheck would skip the install entirely.
            force: true,
            ..InstallerOptions::default()
        }
    }

    fn fake(&self) -> FakeSystemPackages {
        FakeSystemPackages { removal_marker: Some(self.removal_marker()), ..Default::default() }
    }
}

/// A debian script-installer install declaring `deps`, downloadable from
/// [`ARTIFACT_URL`] as a tier-4 TOFU artifact (no checksum to wire up).
fn resolved(deps: &[(&str, DependencyPurpose)]) -> ResolvedInstall {
    let mut r = sample_resolved_with_deps();
    r.method_kind = Some(InstallMethodKind::ScriptInstaller);
    r.source_url_template = Some(ARTIFACT_URL.into());
    r.verification_tier = 4;
    r.verification = Verification { tier: 4, tofu: Some(true), ..r.verification };
    r.system_deps = ResolvedSystemDeps {
        packages: deps
            .iter()
            .map(|(p, purpose)| SystemPackageDep {
                tool: (*p).into(),
                package: (*p).into(),
                purpose: *purpose,
            })
            .collect(),
        unmapped: Vec::new(),
    };
    r
}

/// g++ and make are build-only; ca-certificates is needed at runtime too.
fn node_like() -> ResolvedInstall {
    resolved(&[("g++", Build), ("make", Build), ("ca-certificates", Both)])
}

fn installer(
    host: &Host,
    fake: Arc<FakeSystemPackages>,
    runner: Arc<RecordingRunner>,
) -> Installer {
    let http = MockHttpClient::new();
    http.insert(ARTIFACT_URL, b"#!/bin/sh\nexit 0\n".to_vec());
    Installer::with_runners(
        host.options(),
        Arc::new(http) as Arc<dyn HttpClient>,
        runner as Arc<dyn CommandRunner>,
    )
    .unwrap()
    .with_system_packages(fake)
}

fn run(installer: &Installer, resolved: &ResolvedInstall) -> StageRun {
    let plan = installer.plan(resolved).unwrap();
    installer.run_stages(resolved, plan, None)
}

/// The install method (`su -c <artifact>`) exits non-zero.
fn failing_method() -> Arc<RecordingRunner> {
    let runner = RecordingRunner::new();
    runner.set_outcome(
        "su",
        CommandOutcome { status: Some(1), stdout: Vec::new(), stderr: b"build failed".to_vec() },
    );
    Arc::new(runner)
}

/// The result is the script installer's own failure — the method's error,
/// which a later removal or validate error must never replace.
fn assert_method_failed(result: Result<()>) {
    match result {
        Err(LuggageError::PostInstallFailed { step, message }) => {
            assert_eq!(step, "install.sh");
            assert!(message.contains("build failed"), "{message}");
        }
        other => panic!("expected the install method's failure, got {other:?}"),
    }
}

fn su_calls(runner: &RecordingRunner) -> usize {
    runner.calls().iter().filter(|(p, _)| p == "su").count()
}

fn sorted(v: &[String]) -> Vec<String> {
    let mut v = v.to_vec();
    v.sort();
    v
}

/// Removal runs after the method and *before* validate, so a passing validate
/// proves the tool works without its build toolchain (#1524). The shim fails
/// unless the removal has already happened.
#[test]
fn build_deps_are_removed_before_validate() {
    let host = Host::new();
    let fake = Arc::new(host.fake());
    let runner = Arc::new(RecordingRunner::new());
    let installer = installer(&host, fake.clone(), runner.clone());

    let StageRun { removed_build_dependencies, result } = run(&installer, &node_like());

    let outcome = result.expect("removal precedes validate, so the shim passes");
    assert_eq!(outcome.version_output.trim(), "rustc 1.96.0");
    assert!(host.validate_ran(), "validate must actually run");
    assert_eq!(su_calls(&runner), 1, "the install method ran once");
    assert_eq!(fake.events(), ["install", "remove g++ make"], "runtime dep is never removed");
    assert_eq!(removed_build_dependencies, ["g++", "make"]);
    assert!(fake.is_installed(PackageManager::Apt, "ca-certificates"));
}

/// A failed method still removes the build toolchain it installed, and the
/// method's error — not some later stage's — is the result.
#[test]
fn a_failed_method_still_removes_build_deps() {
    let host = Host::new();
    let fake = Arc::new(host.fake());
    let runner = failing_method();
    let installer = installer(&host, fake.clone(), runner.clone());

    let StageRun { removed_build_dependencies, result } = run(&installer, &node_like());

    assert_method_failed(result.map(drop));
    assert_eq!(su_calls(&runner), 1, "the failure came from the method");
    assert_eq!(fake.removals(), ["remove g++ make"]);
    assert_eq!(removed_build_dependencies, ["g++", "make"]);
    assert!(!host.validate_ran(), "validate never runs after a failed method");
}

/// A system-package install that fails partway is not atomic. Only the build
/// deps that actually landed are removed: not one that never installed (`make`
/// — the package manager would reject the whole removal), and not one the host
/// already had (`python3` — never luggage's to remove).
#[test]
fn a_partial_install_removes_only_what_landed() {
    let host = Host::new();
    let fake = Arc::new(
        FakeSystemPackages {
            lands: Some(vec!["g++".into()]),
            install_error: Some("E: Unable to locate package make".into()),
            ..host.fake()
        }
        .with_present(&["python3"]),
    );
    let runner = Arc::new(RecordingRunner::new());
    let installer = installer(&host, fake.clone(), runner.clone());
    let resolved = resolved(&[("g++", Build), ("make", Build), ("python3", Build)]);

    let StageRun { removed_build_dependencies, result } = run(&installer, &resolved);

    match result.unwrap_err() {
        LuggageError::PackageManagerFailed { message } => {
            assert!(message.contains("make"), "{message}");
        }
        other => panic!("expected the install's own error, got {other:?}"),
    }
    assert_eq!(fake.events(), ["install", "remove g++"]);
    assert_eq!(removed_build_dependencies, ["g++"]);
    assert!(fake.is_installed(PackageManager::Apt, "python3"), "pre-existing package kept");
    assert_eq!(su_calls(&runner), 0, "the method never runs after a failed package install");
    assert!(!host.validate_ran());
}

/// On an otherwise good install a failed removal fails the install — an image
/// that silently keeps its toolchain is the defect #1524 prevents — and
/// validate does not run behind it.
#[test]
fn a_removal_failure_fails_an_otherwise_good_install() {
    let host = Host::new();
    let fake = Arc::new(FakeSystemPackages {
        remove_error: Some("g++: needed by (installed) libtool".into()),
        keeps: vec!["g++".into()],
        ..host.fake()
    });
    let runner = Arc::new(RecordingRunner::new());
    let installer = installer(&host, fake, runner.clone());

    let StageRun { removed_build_dependencies, result } = run(&installer, &node_like());

    match result.unwrap_err() {
        LuggageError::BuildDepRemovalFailed { message } => {
            assert!(message.contains("libtool"), "{message}");
        }
        other => panic!("expected the removal failure, got {other:?}"),
    }
    assert_eq!(su_calls(&runner), 1, "the method itself succeeded");
    assert_eq!(removed_build_dependencies, ["make"], "only what is gone counts");
    assert!(!host.validate_ran(), "validate never runs after a failed removal");
}

/// End to end through [`Installer::run_with_report`]: the failure report
/// carries the build deps actually gone (re-checked on the host — `g++` was
/// kept), so an evidence row records what the failed run changed.
#[test]
fn removed_build_deps_reach_the_failure_report() {
    let host = Host::new();
    let fake = Arc::new(FakeSystemPackages { keeps: vec!["g++".into()], ..host.fake() });
    let installer = installer(&host, fake.clone(), failing_method());

    let (report, result) = installer.run_with_report(&node_like());

    assert_method_failed(result);
    assert_eq!(report.error_class, Some(ErrorClass::PostInstall));
    assert_eq!(fake.removals(), ["remove g++ make"]);
    assert_eq!(sorted(&report.removed_build_dependencies), ["make"]);
    assert!(report.log_path.as_deref().is_some_and(Path::exists), "{report:?}");
}

/// The method's failure is the cause the operator needs, so a removal that
/// also fails behind it is logged, never allowed to replace it — exercised
/// through the real `run_stages` sequencing, not just `merge_cleanup`.
#[test]
fn a_method_failure_outranks_a_removal_failure_behind_it() {
    let host = Host::new();
    let fake = Arc::new(FakeSystemPackages {
        remove_error: Some("g++: needed by (installed) libtool".into()),
        keeps: vec!["g++".into()],
        ..host.fake()
    });
    let installer = installer(&host, fake.clone(), failing_method());

    let StageRun { removed_build_dependencies, result } = run(&installer, &node_like());

    assert_method_failed(result.map(drop));
    assert_eq!(fake.removals(), ["remove g++ make"], "removal still attempted");
    assert_eq!(removed_build_dependencies, ["make"]);
}

/// Same ranking on the partial-install path: the package manager's own
/// install error survives a failing cleanup behind it.
#[test]
fn a_partial_install_error_outranks_a_removal_failure_behind_it() {
    let host = Host::new();
    let fake = Arc::new(FakeSystemPackages {
        lands: Some(vec!["g++".into()]),
        install_error: Some("E: Unable to locate package make".into()),
        remove_error: Some("g++: needed by (installed) libtool".into()),
        keeps: vec!["g++".into()],
        ..host.fake()
    });
    let installer = installer(&host, fake.clone(), Arc::new(RecordingRunner::new()));

    let StageRun { removed_build_dependencies, result } = run(&installer, &node_like());

    match result.unwrap_err() {
        LuggageError::PackageManagerFailed { message } => {
            assert!(message.contains("Unable to locate package make"), "{message}");
        }
        other => panic!("expected the install's own error, got {other:?}"),
    }
    assert_eq!(fake.removals(), ["remove g++"]);
    assert_eq!(
        removed_build_dependencies,
        Vec::<String>::new(),
        "g++ was kept, so nothing is gone"
    );
}

/// With no build-only dependency to clean up, removal never reaches the
/// package manager (an empty `dpkg --purge` would fail the install), and
/// validate still runs — here against a host where removal never happened, so
/// the shim's removal gate is pre-satisfied.
#[test]
fn runtime_only_deps_never_reach_removal() {
    let host = Host::new();
    fs::write(host.removal_marker(), b"pre-satisfied").unwrap();
    let fake = Arc::new(FakeSystemPackages { removal_marker: None, ..Default::default() });
    let installer = installer(&host, fake.clone(), Arc::new(RecordingRunner::new()));
    let resolved = resolved(&[("ca-certificates", Both), ("libstdc++", Both)]);

    let StageRun { removed_build_dependencies, result } = run(&installer, &resolved);

    result.expect("a runtime-only install succeeds");
    assert!(host.validate_ran());
    assert_eq!(fake.events(), ["install"], "no removal call at all");
    assert_eq!(removed_build_dependencies, Vec::<String>::new());
}
