//! Install execution engine.
//!
//! Consumes a [`crate::ResolvedInstall`] and runs the install: idempotency
//! check, system-package install, download + verification, install-method
//! execution, post-install steps, validation. Reports success or a typed
//! [`crate::LuggageError`].
//!
//! # Pilot scope
//!
//! Issue #405 implements the rust@1.95.0 path end-to-end (rustup-init
//! script-installer + tier 3 published-checksum verification). Other shapes
//! return [`crate::LuggageError::NotImplemented`] and ship in follow-ups.

mod build_deps;
pub mod download;
pub mod idempotency;
#[cfg(unix)]
pub(crate) mod interrupt;
pub mod logging;
pub mod methods;
mod options;
pub mod post_install;
pub mod rustup_target;
mod stages;
pub mod syspackages;
pub mod sysremove;
pub mod template;
pub mod user;
pub mod validate;
pub mod verify;

pub use options::InstallerOptions;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use containers_common::tooldb::InstalledDependency;
use serde::{Deserialize, Serialize};
use tempfile::tempdir_in;

use crate::error::{ErrorClass, LuggageError, Result};
use crate::resolver::ResolvedInstall;

use download::{HttpClient, UreqClient};
use methods::{CommandRunner, ProcessRunner};
use rustup_target::rustup_target_for;
use syspackages::PackageManager;
use template::{Substitutions, substitute_url};

/// Read an operator-tuning env var for a fail-closed parser.
///
/// Unset is `Ok(None)`; a value that is set but not valid UTF-8 is a hard
/// [`LuggageError::Catalog`] naming `name`. The obvious
/// `std::env::var(name).ok()` folds that second case into "unset", so a
/// corrupted value silently became the default — exactly the fallback the
/// `*_from_env` readers promise never happens (#1358).
pub(crate) fn tuning_env_var(name: &str) -> Result<Option<String>> {
    tuning_env_value(name, std::env::var(name))
}

/// The value half of [`tuning_env_var`], taking the lookup result so the
/// `NotUnicode` arm is testable without `std::env::set_var` (forbidden here).
fn tuning_env_value(
    name: &str,
    looked_up: std::result::Result<String, std::env::VarError>,
) -> Result<Option<String>> {
    match looked_up {
        Ok(v) => Ok(Some(v)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(raw)) => {
            Err(LuggageError::Catalog(format!("{name} is not valid UTF-8: `{}`", raw.display())))
        }
    }
}

/// A fully substituted install plan ready to execute.
///
/// Returned by [`Installer::plan`]. With `--dry-run` this is what the CLI
/// prints; otherwise it is consumed internally by [`Installer::run`].
#[derive(Debug, Clone, Serialize)]
pub struct InstallPlan {
    /// Tool id.
    pub tool: String,
    /// Concrete version chosen.
    pub version: String,
    /// `install_methods[].name` of the chosen method.
    pub method_name: String,
    /// Verification tier (`1`–`4`).
    pub verification_tier: u8,
    /// Fully substituted source URL (no `{rustup_target}` placeholders).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    /// Fully substituted checksum URL when applicable (tier 3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksum_url: Option<String>,
    /// Installer argv (from `Invoke::args`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invoke_args: Option<Vec<String>>,
    /// Catalog `Dependency.tool` ids that will be installed via the host
    /// package manager, translated to per-distro names.
    pub system_packages: Vec<String>,
    /// Catalog `Dependency.tool` ids that had no system-package mapping in
    /// this build of luggage. Under strict mode these abort the install;
    /// under `--allow-unknown-deps` they are skipped and surfaced here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped_dependencies: Vec<String>,
    /// Number of post-install steps to run.
    pub post_install_steps: usize,
    /// User the install will run as.
    pub user: String,
}

/// Outcome of an install run — emitted on success, skip, dry-run, and
/// failure paths alike when callers use [`Installer::run_with_report`].
///
/// Evidence-run CI ([containers#473]) feeds this struct (via the CLI's
/// `--json-report` flag) to the `record-evidence` wrapper, which combines
/// it with runner-supplied metadata (image digest, `ci_run`, tuple coords)
/// into a `tested[]` row for containers-db.
///
/// [containers#473]: https://github.com/joshjhall/containers/issues/473
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstallReport {
    /// Tool id.
    pub tool: String,
    /// Concrete version installed.
    pub version: String,
    /// `true` if the idempotency check skipped the install.
    pub already_installed: bool,
    /// Path to the per-feature log file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_path: Option<PathBuf>,
    /// Wallclock duration of [`Installer::run_with_report`] from entry
    /// to return — covers idempotency check + all stages.
    pub duration_seconds: f64,
    /// Trimmed output captured from the validate stage's
    /// `<bin>/<tool> --version` invocation. Populated on success;
    /// `None` on skip, dry-run, and failure paths.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_output: Option<String>,
    /// Stage-aligned failure category. `Some` iff the run failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_class: Option<ErrorClass>,
    /// System dependencies resolved to their concrete installed versions.
    /// Populated on the success path only when
    /// [`InstallerOptions::record_dependency_versions`] is set (the CLI ties
    /// this to `--json-report`); `None` on skip, dry-run, and failure paths
    /// and whenever recording is disabled. Best-effort per dep.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dependencies: Option<Vec<InstalledDependency>>,
    /// Catalog dependency ids that had no system-package mapping and were
    /// skipped. Only populated when the installer ran in non-strict mode
    /// (`--allow-unknown-deps`); strict mode turns the same condition into a
    /// failure. `skip_serializing_if` keeps the wire shape byte-identical to
    /// the pre-#644 report when empty, so existing evidence rows are
    /// unaffected.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped_dependencies: Vec<String>,
    /// Verifications that succeeded on weaker grounds than the tier name
    /// alone suggests — currently only tier-4 TOFU acceptances.
    ///
    /// This is the field that keeps a TOFU acceptance from being a
    /// console-only event: without it, an artifact accepted with no publisher
    /// checksum would look identical to a properly verified one in every
    /// downstream consumer of this report. Like `skipped_dependencies`,
    /// `skip_serializing_if` keeps the wire shape byte-identical to the
    /// pre-#810 report when empty, so existing evidence rows are unaffected.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<verify::VerificationWarning>,
    /// Tier (`1`–`4`) the artifact was verified at. `Some` only when the
    /// verify stage actually ran and passed; `None` on skip, dry-run, and
    /// failure paths, so a consumer can never read a tier off an install
    /// that was not verified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification_tier: Option<u8>,
    /// `purpose: build` system packages this run installed and then removed
    /// once the method finished (#1524). Set on success and on a failed
    /// method alike. `skip_serializing_if` keeps the wire shape byte-identical
    /// to the pre-#1524 report when nothing was removed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_build_dependencies: Vec<String>,
}

/// What a successful stage run produced, on its way into the report.
///
/// A plain pair rather than a tuple so the two values cannot be swapped at a
/// call site, and so a future stage output has an obvious home.
#[derive(Debug)]
struct StageOutcome {
    /// Trimmed `<bin>/<tool> --version` output from the validate stage.
    version_output: String,
    /// Warnings raised during verification (see
    /// [`verify::VerificationWarning`]).
    warnings: Vec<verify::VerificationWarning>,
    /// Dependency versions, captured before build deps were removed.
    dependencies: Option<Vec<InstalledDependency>>,
}

/// What [`Installer::run_stages`] produced: the stage result plus the build
/// deps removed behind it, which a failure report records too (#1524).
///
/// A named struct rather than a `(Vec<String>, Result<..>)` tuple so the
/// removed list cannot be swapped with the other `Vec<String>`
/// (`skipped_dependencies`) that [`Installer::report_from_stages`] takes —
/// that swap compiled and passed every unit test (#1684).
struct StageRun {
    /// `purpose: build` packages removed after the method stage.
    removed_build_dependencies: Vec<String>,
    /// Outcome of the stages themselves.
    result: Result<StageOutcome>,
}

/// The install execution engine.
///
/// Production callers use [`Installer::with_options`]; tests use
/// [`Installer::with_runners`] to inject in-process HTTP and command stubs.
pub struct Installer {
    options: InstallerOptions,
    http: Arc<dyn HttpClient>,
    runner: Arc<dyn CommandRunner>,
}

impl std::fmt::Debug for Installer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Installer").field("options", &self.options).finish_non_exhaustive()
    }
}

impl Installer {
    /// Build with production HTTP + process runners.
    ///
    /// # Errors
    ///
    /// [`LuggageError::Catalog`] when `options` fails
    /// [`InstallerOptions::validate`] — rejected, not clamped (#1399).
    pub fn with_options(options: InstallerOptions) -> Result<Self> {
        Self::with_runners(options, Arc::new(UreqClient::default()), Arc::new(ProcessRunner))
    }

    /// Build with caller-supplied runners. Used by tests.
    ///
    /// # Errors
    ///
    /// [`LuggageError::Catalog`] when `options` fails
    /// [`InstallerOptions::validate`].
    pub fn with_runners(
        options: InstallerOptions,
        http: Arc<dyn HttpClient>,
        runner: Arc<dyn CommandRunner>,
    ) -> Result<Self> {
        options.validate()?;
        Ok(Self { options, http, runner })
    }

    /// Borrow the underlying options.
    #[must_use]
    pub const fn options(&self) -> &InstallerOptions {
        &self.options
    }

    /// Build a plan without performing I/O.
    ///
    /// The plan reflects every substituted URL, the per-distro package
    /// names, and the chosen install user — enough for the CLI's
    /// `--dry-run` mode to print a complete picture.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::TemplateMissingKey`] when a URL template
    ///   references an unsupported placeholder.
    /// - [`LuggageError::NotImplemented`] when the resolved platform is
    ///   not in the rustup-target table or the package manager is unknown.
    /// - Whatever [`verify::ensure_supported`] refuses: an unimplemented or
    ///   unknown verification tier, a tier-2 entry with no `pinned_checksum`
    ///   or a pin that is not a digest of `algorithm`'s width, or tier 4 while
    ///   verified downloads are required.
    pub fn plan(&self, resolved: &ResolvedInstall) -> Result<InstallPlan> {
        // Reject an unsupported verification tier — or a tier-2 entry with no
        // usable `pinned_checksum`, which can never pass — before any work. The
        // download derives its digest algorithm from `verification.algorithm`,
        // and a tier-1 entry legitimately carries `algorithm: "gpg"` — without
        // this the caller would get "unrecognised digest algorithm `gpg`"
        // from the digest layer instead of the accurate "tier 1 not
        // implemented". It also avoids spending a 150MB download to learn
        // something knowable up front.
        //
        // It lives here rather than in `run_stages` because every path goes
        // through `plan()` first: a refused entry must install no system
        // packages, and `--dry-run` (which never reaches `run_stages`) must
        // report the same refusal a real install would (#1042).
        verify::ensure_supported(
            &resolved.tool,
            &resolved.version,
            &resolved.verification,
            self.options.require_verified_downloads,
            self.options.catalog_root.as_deref(),
        )?;

        let target = rustup_target_for(&resolved.platform).ok();
        let subs = Substitutions {
            version: Some(resolved.version.as_str()),
            rustup_target: target,
            arch: Some(resolved.platform.arch.as_str()),
            nproc: None,
        };

        let source_url = match resolved.source_url_template.as_deref() {
            Some(t) => Some(substitute_url(t, &subs)?),
            None => None,
        };
        let checksum_url = match resolved.verification.checksum_url_template.as_deref() {
            Some(t) => Some(substitute_url(t, &subs)?),
            None => None,
        };
        let invoke_args = resolved.invoke.as_ref().and_then(|i| i.args.clone());

        // Package names come from the catalog (resolved onto the plan by
        // `Catalog::resolve`); a host with no package manager installs none.
        let (system_packages, skipped_dependencies) =
            if PackageManager::for_platform(&resolved.platform).is_ok() {
                (
                    resolved.system_deps.packages.iter().map(|p| p.package.clone()).collect(),
                    resolved.system_deps.unmapped.clone(),
                )
            } else {
                (Vec::new(), Vec::new())
            };

        let post_install_steps = resolved.post_install.as_ref().map_or(0, Vec::len);
        let user = user::resolve_install_user(self.options.user_override.as_deref());

        Ok(InstallPlan {
            tool: resolved.tool.clone(),
            version: resolved.version.clone(),
            method_name: resolved.method_name.clone(),
            verification_tier: resolved.verification_tier,
            source_url,
            checksum_url,
            invoke_args,
            system_packages,
            skipped_dependencies,
            post_install_steps,
            user,
        })
    }

    /// Execute the install end-to-end, returning a populated
    /// [`InstallReport`] on success.
    ///
    /// Stage order, mirroring `lib/features/rust.sh`:
    ///
    /// 1. Idempotency pre-check (skip if `<bin>/<tool> --version` already
    ///    matches and `force` is false).
    /// 2. Plan, which refuses an unsupported verification tier before any
    ///    side effect (and is where `--dry-run` stops).
    /// 3. Install system packages (apt/apk/dnf).
    /// 4. Download the source artifact.
    /// 5. Verify it via the catalog tier (3 implemented, 1/2/4 deferred).
    /// 6. Run the install method (only `rustup-init` shape implemented).
    /// 7. Run post-install steps.
    /// 8. Validate by re-invoking `<bin>/<tool> --version`.
    ///
    /// # Errors
    ///
    /// Propagates whatever any stage returns. See module-level docs for
    /// the full list of variants.
    pub fn run(&self, resolved: &ResolvedInstall) -> Result<InstallReport> {
        let (report, result) = self.run_with_report(resolved);
        result.map(|()| report)
    }

    /// Execute the install end-to-end, always returning a populated
    /// [`InstallReport`] paired with the run's [`Result`].
    ///
    /// On success, skip, and dry-run paths the `Result<()>` is `Ok`. On
    /// failure it carries the underlying [`LuggageError`] and the report's
    /// `error_class` is set from it; partial fields (`duration_seconds`)
    /// are filled in regardless. Evidence-run CI uses this entry point
    /// so it can record a row even when the install itself failed.
    pub fn run_with_report(&self, resolved: &ResolvedInstall) -> (InstallReport, Result<()>) {
        let started = Instant::now();
        let logger =
            logging::FeatureLogger::open(&self.options.log_dir, &resolved.tool, &resolved.version)
                .ok();
        if let Some(l) = &logger {
            l.feature_start(&resolved.tool, &resolved.version);
        }

        if !self.options.force
            && idempotency::already_installed_within(
                &resolved.primary_binary,
                &resolved.version_args,
                &resolved.version,
                &self.options.bin_root,
                self.options.version_probe_timeout,
            )
        {
            return (
                Self::report_skipped(resolved, logger, started.elapsed().as_secs_f64()),
                Ok(()),
            );
        }

        let plan = match self.plan(resolved) {
            Ok(p) => p,
            Err(e) => {
                let report =
                    Self::report_failure(resolved, &e, logger, started.elapsed().as_secs_f64());
                return (report, Err(e));
            }
        };
        if self.options.dry_run {
            return (Self::report_dry_run(plan, logger, started.elapsed().as_secs_f64()), Ok(()));
        }

        // Capture before `plan` is consumed by `run_stages`, so the success
        // report can carry any non-strict skips through to evidence-run.
        let skipped_dependencies = plan.skipped_dependencies.clone();
        let stages = self.run_stages(resolved, plan, logger.as_ref());
        Self::report_from_stages(
            resolved,
            stages,
            skipped_dependencies,
            logger,
            started.elapsed().as_secs_f64(),
        )
    }

    /// Turn the outcome of [`Self::run_stages`] into the install report.
    ///
    /// Split out of [`Self::run_with_report`] so the wiring — notably that
    /// the removed build-dependency list reaches the report on success and on
    /// failure alike — is unit-testable without running any stage (#1635).
    fn report_from_stages(
        resolved: &ResolvedInstall,
        stages: StageRun,
        skipped_dependencies: Vec<String>,
        logger: Option<logging::FeatureLogger>,
        duration_seconds: f64,
    ) -> (InstallReport, Result<()>) {
        let StageRun { removed_build_dependencies, result } = stages;
        match result {
            Ok(StageOutcome { version_output, warnings, dependencies }) => {
                if let Some(l) = &logger {
                    l.feature_end();
                }
                let report = InstallReport {
                    tool: resolved.tool.clone(),
                    version: resolved.version.clone(),
                    already_installed: false,
                    log_path: logger.map(|l| l.path().to_owned()),
                    duration_seconds,
                    version_output: Some(version_output),
                    error_class: None,
                    dependencies,
                    skipped_dependencies,
                    warnings,
                    verification_tier: Some(resolved.verification_tier),
                    removed_build_dependencies,
                };
                (report, Ok(()))
            }
            Err(e) => {
                let mut report = Self::report_failure(resolved, &e, logger, duration_seconds);
                report.removed_build_dependencies = removed_build_dependencies;
                (report, Err(e))
            }
        }
    }

    fn report_skipped(
        resolved: &ResolvedInstall,
        logger: Option<logging::FeatureLogger>,
        duration_seconds: f64,
    ) -> InstallReport {
        if let Some(l) = &logger {
            l.message(&format!(
                "{}@{} already installed; skipping",
                resolved.tool, resolved.version
            ));
            l.feature_end();
        }
        InstallReport {
            tool: resolved.tool.clone(),
            version: resolved.version.clone(),
            already_installed: true,
            log_path: logger.map(|l| l.path().to_owned()),
            duration_seconds,
            version_output: None,
            error_class: None,
            dependencies: None,
            skipped_dependencies: Vec::new(),
            warnings: Vec::new(),
            verification_tier: None,
            removed_build_dependencies: Vec::new(),
        }
    }

    fn report_dry_run(
        plan: InstallPlan,
        logger: Option<logging::FeatureLogger>,
        duration_seconds: f64,
    ) -> InstallReport {
        if let Some(l) = &logger {
            l.message("dry-run: stopping after plan");
            l.feature_end();
        }
        InstallReport {
            tool: plan.tool,
            version: plan.version,
            already_installed: false,
            log_path: logger.map(|l| l.path().to_owned()),
            duration_seconds,
            version_output: None,
            error_class: None,
            dependencies: None,
            skipped_dependencies: plan.skipped_dependencies,
            warnings: Vec::new(),
            verification_tier: None,
            removed_build_dependencies: Vec::new(),
        }
    }

    fn report_failure(
        resolved: &ResolvedInstall,
        err: &LuggageError,
        logger: Option<logging::FeatureLogger>,
        duration_seconds: f64,
    ) -> InstallReport {
        if let Some(l) = &logger {
            l.message(&format!("install failed: {err}"));
            l.feature_end();
        }
        InstallReport {
            tool: resolved.tool.clone(),
            version: resolved.version.clone(),
            already_installed: false,
            log_path: logger.map(|l| l.path().to_owned()),
            duration_seconds,
            version_output: None,
            error_class: Some(ErrorClass::from(err)),
            dependencies: None,
            skipped_dependencies: Vec::new(),
            warnings: Vec::new(),
            verification_tier: None,
            removed_build_dependencies: Vec::new(),
        }
    }

    /// Run every stage, removing `purpose: build` packages after the method
    /// (#1524). Returns the removed package names alongside the result (as a
    /// [`StageRun`]) so a failure report records them too.
    fn run_stages(
        &self,
        resolved: &ResolvedInstall,
        plan: InstallPlan,
        logger: Option<&logging::FeatureLogger>,
    ) -> StageRun {
        // The verification guard already ran in `plan()`, which produced `plan`.
        let (pending, installed) = self.stage_system_packages(resolved, logger);
        if let Err(e) = installed {
            // Still remove whatever build deps a partial install left behind.
            let (removed_build_dependencies, cleanup) =
                build_deps::remove_build_deps(pending, logger);
            return StageRun {
                removed_build_dependencies,
                result: build_deps::merge_cleanup(Err(e), cleanup, logger),
            };
        }
        // Queried now, while the build deps are still installed, so the
        // evidence row records every dependency the build used.
        let dependencies = self.captured_dependency_versions(resolved);
        let built = self.run_method_stages(resolved, plan, logger);
        // Removed before validate, on success and failure alike: a passing
        // validate then proves the tool runs without its build deps.
        let (removed_build_dependencies, cleanup) = build_deps::remove_build_deps(pending, logger);
        let result =
            build_deps::merge_cleanup(built, cleanup, logger).and_then(|(env_map, warnings)| {
                let version_output = self.stage_validate(resolved, &env_map, logger)?;
                Ok(StageOutcome { version_output, warnings, dependencies })
            });
        StageRun { removed_build_dependencies, result }
    }

    /// Download, verify, install method and post-install. Returns the shared
    /// env map validate needs and the verification warnings.
    fn run_method_stages(
        &self,
        resolved: &ResolvedInstall,
        plan: InstallPlan,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<(BTreeMap<String, String>, Vec<verify::VerificationWarning>)> {
        // Scratch dir is created BEFORE the download so the artifact can stream
        // straight into it — nothing buffers the whole artifact in memory, which
        // matters at 150MB (go) as much as it did not at 15MB (rustup-init).
        //
        // `scratch` is a TempDir bound for the rest of this function, so its
        // Drop removes the artifact on every exit path: the success return
        // below, and any `?` unwinding out of verify/method/post-install.
        fs::create_dir_all(&self.options.tmp_root)
            .map_err(|e| LuggageError::Io { path: self.options.tmp_root.clone(), source: e })?;
        let scratch = tempdir_in(&self.options.tmp_root)
            .map_err(|e| LuggageError::Io { path: self.options.tmp_root.clone(), source: e })?;
        let source_url = plan.source_url.as_deref().ok_or_else(|| {
            LuggageError::Catalog(
                "install method has no source_url_template (cannot download)".into(),
            )
        })?;
        let artifact_filename = install_basename(source_url);
        let artifact = scratch.path().join(&artifact_filename);

        let digest = self.stage_download(resolved, source_url, &artifact, logger)?;
        let warnings = self.stage_verify(
            resolved,
            &verify::Artifact { digest: &digest, filename: &artifact_filename, path: &artifact },
            logger,
        )?;

        // Build the env map once so every stage that shells out (install
        // method, post-install steps, post-install validate) sees the same
        // cache-dir exports. validate previously relied on the parent
        // process's exports and failed when the rustup proxy fell back to
        // `$HOME/.rustup` (issue #463).
        //
        // The variables come from the catalog's `cache_dirs`; `or_insert`
        // keeps an explicit `invoke.env` value winning over the derived path.
        let mut env_map = invoke_env_map(resolved);
        for (var, rel) in resolved.cache_dirs.iter().flatten() {
            env_map
                .entry(var.clone())
                .or_insert_with(|| self.options.cache_root.join(rel).display().to_string());
        }
        let invoke_args = plan.invoke_args.clone().unwrap_or_default();
        let user = plan.user;
        self.stage_method(resolved, &artifact, &invoke_args, &env_map, &user, logger)?;
        self.stage_post_install(resolved, &user, &env_map, logger)?;
        Ok((env_map, warnings))
    }
}

fn invoke_env_map(resolved: &ResolvedInstall) -> BTreeMap<String, String> {
    resolved
        .invoke
        .as_ref()
        .and_then(|i| i.env.clone())
        .map_or_else(BTreeMap::new, |m| m.into_iter().collect())
}

/// Strip the trailing path segment from a URL for use as the on-disk
/// filename. Falls back to `download` when the URL is path-empty.
fn install_basename(url: &str) -> String {
    let trimmed = url.split('?').next().unwrap_or(url);
    trimmed
        .rsplit_once('/')
        .map(|(_, last)| last)
        .filter(|s| !s.is_empty())
        .unwrap_or("download")
        .to_owned()
}

#[cfg(test)]
#[path = "mod_tests.rs"]
mod tests;
