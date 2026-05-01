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

pub mod download;
pub mod idempotency;
pub mod logging;
pub mod methods;
pub mod post_install;
pub mod rustup_target;
pub mod syspackages;
pub mod template;
pub mod user;
pub mod validate;
pub mod verify;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use serde::Serialize;
use tempfile::tempdir_in;

use crate::error::{LuggageError, Result};
use crate::resolver::ResolvedInstall;

use download::{HttpClient, UreqClient};
use methods::{CommandRunner, MethodContext, ProcessRunner};
use rustup_target::rustup_target_for;
use syspackages::{PackageManager, install_dependencies, translate_dependencies};
use template::{Substitutions, substitute_url};

/// Installer configuration.
#[derive(Debug, Clone)]
pub struct InstallerOptions {
    /// Skip side-effects; build the plan and return it.
    pub dry_run: bool,
    /// Bypass the idempotency check and reinstall regardless.
    pub force: bool,
    /// Per-feature log directory (`/var/log/luggage/` in production).
    pub log_dir: PathBuf,
    /// Where binaries are symlinked (default `/usr/local/bin`). Tests override.
    pub bin_root: PathBuf,
    /// Cache root for tool data (default `/cache`). Tests override.
    pub cache_root: PathBuf,
    /// Scratch directory for downloads. Defaults to `/tmp`.
    pub tmp_root: PathBuf,
    /// Optional override for the install user; falls back to `$USERNAME`.
    pub user_override: Option<String>,
    /// When `true`, the installer also runs `apt-get update && apt-get
    /// install -y ...` (or distro equivalent) for catalog dependencies.
    /// Defaults to `true`; tests turn it off to stay hermetic.
    pub install_system_packages: bool,
}

impl Default for InstallerOptions {
    fn default() -> Self {
        Self {
            dry_run: false,
            force: false,
            log_dir: PathBuf::from("/var/log/luggage"),
            bin_root: PathBuf::from("/usr/local/bin"),
            cache_root: PathBuf::from("/cache"),
            tmp_root: PathBuf::from("/tmp"),
            user_override: None,
            install_system_packages: true,
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
    /// Number of post-install steps to run.
    pub post_install_steps: usize,
    /// User the install will run as.
    pub user: String,
}

/// Outcome of a successful install run.
#[derive(Debug, Clone, Serialize)]
pub struct InstallReport {
    /// Tool id.
    pub tool: String,
    /// Concrete version installed.
    pub version: String,
    /// `true` if the idempotency check skipped the install.
    pub already_installed: bool,
    /// Path to the per-feature log file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log_path: Option<PathBuf>,
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
    #[must_use]
    pub fn with_options(options: InstallerOptions) -> Self {
        Self { options, http: Arc::new(UreqClient::default()), runner: Arc::new(ProcessRunner) }
    }

    /// Build with caller-supplied runners. Used by tests.
    pub fn with_runners(
        options: InstallerOptions,
        http: Arc<dyn HttpClient>,
        runner: Arc<dyn CommandRunner>,
    ) -> Self {
        Self { options, http, runner }
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
    pub fn plan(&self, resolved: &ResolvedInstall) -> Result<InstallPlan> {
        let target = rustup_target_for(&resolved.platform).ok();
        let subs =
            Substitutions { version: Some(resolved.version.as_str()), rustup_target: target };

        let source_url = match resolved.source_url_template.as_deref() {
            Some(t) => Some(substitute_url(t, &subs)?),
            None => None,
        };
        let checksum_url = match resolved.verification.checksum_url_template.as_deref() {
            Some(t) => Some(substitute_url(t, &subs)?),
            None => None,
        };
        let invoke_args = resolved.invoke.as_ref().and_then(|i| i.args.clone());

        let pkg_mgr = PackageManager::for_platform(&resolved.platform).ok();
        let system_packages = match (pkg_mgr, resolved.dependencies.as_deref()) {
            (Some(mgr), Some(deps)) => {
                translate_dependencies(deps, mgr).into_iter().map(str::to_owned).collect()
            }
            _ => Vec::new(),
        };

        let post_install_steps = resolved.post_install.as_ref().map_or(0, Vec::len);
        let user = user::resolve_user(self.options.user_override.as_deref());

        Ok(InstallPlan {
            tool: resolved.tool.clone(),
            version: resolved.version.clone(),
            method_name: resolved.method_name.clone(),
            verification_tier: resolved.verification_tier,
            source_url,
            checksum_url,
            invoke_args,
            system_packages,
            post_install_steps,
            user,
        })
    }

    /// Execute the install end-to-end.
    ///
    /// Stage order, mirroring `lib/features/rust.sh`:
    ///
    /// 1. Idempotency pre-check (skip if `<bin>/<tool> --version` already
    ///    matches and `force` is false).
    /// 2. Install system packages (apt/apk/dnf).
    /// 3. Download the source artifact.
    /// 4. Verify it via the catalog tier (3 implemented, 1/2/4 deferred).
    /// 5. Run the install method (only `rustup-init` shape implemented).
    /// 6. Run post-install steps.
    /// 7. Validate by re-invoking `<bin>/<tool> --version`.
    ///
    /// # Errors
    ///
    /// Propagates whatever any stage returns. See module-level docs for
    /// the full list of variants.
    pub fn run(&self, resolved: &ResolvedInstall) -> Result<InstallReport> {
        let logger =
            logging::FeatureLogger::open(&self.options.log_dir, &resolved.tool, &resolved.version)
                .ok();
        if let Some(l) = &logger {
            l.feature_start(&resolved.tool, &resolved.version);
        }

        if !self.options.force
            && idempotency::already_installed(
                &resolved.tool,
                &resolved.version,
                &self.options.bin_root,
            )
        {
            return Ok(Self::report_skipped(resolved, logger));
        }

        let plan = self.plan(resolved)?;
        if self.options.dry_run {
            return Ok(Self::report_dry_run(plan, logger));
        }

        self.run_stages(resolved, plan, logger.as_ref())?;

        if let Some(l) = &logger {
            l.feature_end();
        }
        Ok(InstallReport {
            tool: resolved.tool.clone(),
            version: resolved.version.clone(),
            already_installed: false,
            log_path: logger.map(|l| l.path().to_owned()),
        })
    }

    fn report_skipped(
        resolved: &ResolvedInstall,
        logger: Option<logging::FeatureLogger>,
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
        }
    }

    fn report_dry_run(plan: InstallPlan, logger: Option<logging::FeatureLogger>) -> InstallReport {
        if let Some(l) = &logger {
            l.message("dry-run: stopping after plan");
            l.feature_end();
        }
        InstallReport {
            tool: plan.tool,
            version: plan.version,
            already_installed: false,
            log_path: logger.map(|l| l.path().to_owned()),
        }
    }

    fn run_stages(
        &self,
        resolved: &ResolvedInstall,
        plan: InstallPlan,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        self.stage_system_packages(resolved, logger)?;
        let bytes = self.stage_download(&plan, logger)?;
        self.stage_verify(resolved, &bytes, logger)?;
        fs::create_dir_all(&self.options.tmp_root)
            .map_err(|e| LuggageError::Io { path: self.options.tmp_root.clone(), source: e })?;
        let scratch = tempdir_in(&self.options.tmp_root)
            .map_err(|e| LuggageError::Io { path: self.options.tmp_root.clone(), source: e })?;
        let source_url = plan.source_url.as_deref().expect("download stage validated source_url");
        let artifact = scratch.path().join(install_basename(source_url));
        fs::write(&artifact, &bytes)
            .map_err(|e| LuggageError::Io { path: artifact.clone(), source: e })?;

        let env_map = invoke_env_map(resolved);
        let invoke_args = plan.invoke_args.clone().unwrap_or_default();
        let user = plan.user;
        self.stage_method(resolved, &artifact, &invoke_args, &env_map, &user, logger)?;
        self.stage_post_install(resolved, &user, env_map, logger)?;
        self.stage_validate(resolved, logger)
    }

    fn stage_system_packages(
        &self,
        resolved: &ResolvedInstall,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        if !self.options.install_system_packages {
            return Ok(());
        }
        let Ok(mgr) = PackageManager::for_platform(&resolved.platform) else { return Ok(()) };
        let Some(deps) = resolved.dependencies.as_deref() else { return Ok(()) };
        if deps.is_empty() {
            return Ok(());
        }
        if let Some(l) = logger {
            l.step("install system packages");
        }
        install_dependencies(deps, mgr)
    }

    fn stage_download(
        &self,
        plan: &InstallPlan,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<Vec<u8>> {
        let url = plan.source_url.as_deref().ok_or_else(|| {
            LuggageError::Catalog(
                "install method has no source_url_template (cannot download)".into(),
            )
        })?;
        if let Some(l) = logger {
            l.step(&format!("download {url}"));
        }
        self.http.get(url)
    }

    fn stage_verify(
        &self,
        resolved: &ResolvedInstall,
        bytes: &[u8],
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        let target = rustup_target_for(&resolved.platform).ok();
        let subs =
            Substitutions { version: Some(resolved.version.as_str()), rustup_target: target };
        if let Some(l) = logger {
            l.step(&format!("verify (tier {})", resolved.verification_tier));
        }
        verify::dispatch(
            &resolved.tool,
            &resolved.version,
            bytes,
            &resolved.verification,
            &subs,
            self.http.as_ref(),
        )
    }

    fn stage_method(
        &self,
        resolved: &ResolvedInstall,
        artifact: &std::path::Path,
        invoke_args: &[String],
        env_map: &BTreeMap<String, String>,
        user: &str,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        if let Some(l) = logger {
            l.step(&format!("run install method `{}`", resolved.method_name));
        }
        methods::dispatch(
            &resolved.method_name,
            &MethodContext {
                artifact,
                args: invoke_args,
                env: env_map,
                user,
                cache_root: &self.options.cache_root,
                bin_root: &self.options.bin_root,
                runner: self.runner.as_ref(),
            },
        )
    }

    fn stage_post_install(
        &self,
        resolved: &ResolvedInstall,
        user: &str,
        mut env_map: BTreeMap<String, String>,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        // Post-install runs in a fresh `su -` so it needs the same env the
        // install method exported. If the catalog didn't pin them, add the
        // pilot defaults under `cache_root`.
        env_map
            .entry("CARGO_HOME".to_owned())
            .or_insert_with(|| self.options.cache_root.join("cargo").display().to_string());
        env_map
            .entry("RUSTUP_HOME".to_owned())
            .or_insert_with(|| self.options.cache_root.join("rustup").display().to_string());

        let Some(steps) = resolved.post_install.as_deref() else { return Ok(()) };
        if steps.is_empty() {
            return Ok(());
        }
        if let Some(l) = logger {
            l.step(&format!("post-install ({} steps)", steps.len()));
        }
        post_install::run_steps(steps, user, &env_map, self.runner.as_ref())
    }

    fn stage_validate(
        &self,
        resolved: &ResolvedInstall,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        if let Some(l) = logger {
            l.step("validate");
        }
        validate::check(&resolved.tool, &resolved.version, &self.options.bin_root)
    }
}

fn invoke_env_map(resolved: &ResolvedInstall) -> BTreeMap<String, String> {
    resolved
        .invoke
        .as_ref()
        .and_then(|i| i.env.clone())
        .map(|m| m.into_iter().collect())
        .unwrap_or_default()
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
mod tests {
    use super::*;

    #[test]
    fn default_options_use_production_paths() {
        let o = InstallerOptions::default();
        assert_eq!(o.bin_root, PathBuf::from("/usr/local/bin"));
        assert_eq!(o.cache_root, PathBuf::from("/cache"));
        assert_eq!(o.log_dir, PathBuf::from("/var/log/luggage"));
        assert_eq!(o.tmp_root, PathBuf::from("/tmp"));
        assert!(!o.dry_run);
        assert!(!o.force);
        assert!(o.install_system_packages);
    }

    #[test]
    fn install_basename_extracts_last_segment() {
        assert_eq!(
            install_basename("https://example.test/x86_64-unknown-linux-gnu/rustup-init"),
            "rustup-init",
        );
    }

    #[test]
    fn install_basename_handles_query_string() {
        assert_eq!(install_basename("https://example.test/x?token=abc"), "x");
    }

    #[test]
    fn install_basename_falls_back_when_path_empty() {
        assert_eq!(install_basename("https://example.test/"), "download");
    }
}
