//! The ordered install stages `Installer::run_stages` drives.
//!
//! Each function here is one step of a single install, in the order the
//! orchestrator calls them: system packages, download, verify, install method,
//! post-install, validate. They are deliberately thin — the real work lives in
//! the sibling modules ([`super::syspackages`], [`super::download`],
//! [`super::verify`], [`super::methods`], [`super::post_install`],
//! [`super::validate`]) — so each one reads as "log the step, delegate, map the
//! error".
//!
//! The orchestrator itself stays in [`super`]: sequencing, the scratch
//! directory's lifetime, and the shared env map are its concerns, not any one
//! stage's. This split exists so neither half has to be read to understand the
//! other.

use std::collections::BTreeMap;
use std::io::Write as _;

use containers_common::tooldb::InstalledDependency;

use crate::error::{LuggageError, Result};
use crate::resolver::ResolvedInstall;

use super::download::DigestingFileSink;
use super::methods::MethodContext;
use super::rustup_target::rustup_target_for;
use super::syspackages::{PackageManager, install_dependencies, resolve_installed_versions};
use super::template::Substitutions;
use super::{Installer, logging, methods, post_install, validate, verify};

impl Installer {
    pub(super) fn stage_system_packages(
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
        install_dependencies(deps, mgr, self.options.fail_on_unknown_deps)
    }

    /// Query the host package manager for each dependency's resolved version,
    /// for the evidence row. Returns `None` (recording nothing) unless
    /// recording is enabled, system packages were installed this run, and the
    /// platform has a known package manager with non-empty dependencies.
    /// Best-effort: a query that fails leaves that dep's version `None` rather
    /// than failing the install (see [`resolve_installed_versions`]).
    pub(super) fn captured_dependency_versions(
        &self,
        resolved: &ResolvedInstall,
    ) -> Option<Vec<InstalledDependency>> {
        if !self.options.record_dependency_versions || !self.options.install_system_packages {
            return None;
        }
        let mgr = PackageManager::for_platform(&resolved.platform).ok()?;
        let deps = resolved.dependencies.as_deref()?;
        if deps.is_empty() {
            return None;
        }
        // `resolve_installed_versions` skips deps with no package mapping, so a
        // list of only-unknown ids yields an empty vec. Collapse that to `None`
        // so the report omits the field entirely rather than serializing an
        // ambiguous `"dependencies": []`.
        let versions = resolve_installed_versions(deps, mgr);
        if versions.is_empty() {
            return None;
        }
        Some(versions)
    }

    /// Stream the artifact to `artifact`, returning its hex digest.
    ///
    /// The digest is computed as the bytes land (see [`DigestingFileSink`]),
    /// so verification never re-reads the file and peak memory is a fixed
    /// chunk rather than the artifact size.
    pub(super) fn stage_download(
        &self,
        resolved: &ResolvedInstall,
        url: &str,
        artifact: &std::path::Path,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<String> {
        if let Some(l) = logger {
            l.step(&format!("download {url}"));
        }
        let mut sink =
            DigestingFileSink::create(artifact, resolved.verification.algorithm.as_deref())?;
        self.http.get_to_writer(url, &mut sink)?;
        sink.flush().map_err(|e| LuggageError::Io { path: artifact.to_path_buf(), source: e })?;
        Ok(sink.finish())
    }

    /// Verify the downloaded artifact, returning any warnings the tier
    /// produced.
    ///
    /// Each warning is logged here as well as returned. The two destinations
    /// serve different readers and neither substitutes for the other: the log
    /// line is what someone watching the build (or reading
    /// `check-build-logs.sh` output later) sees, and the returned value is
    /// what reaches the install report, `--json-report`, and the evidence
    /// pipeline.
    pub(super) fn stage_verify(
        &self,
        resolved: &ResolvedInstall,
        actual_digest: &str,
        artifact_filename: &str,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<Vec<verify::VerificationWarning>> {
        let target = rustup_target_for(&resolved.platform).ok();
        let subs =
            Substitutions { version: Some(resolved.version.as_str()), rustup_target: target };
        if let Some(l) = logger {
            l.step(&format!("verify (tier {})", resolved.verification_tier));
        }
        let warnings = verify::dispatch(
            &resolved.tool,
            &resolved.version,
            actual_digest,
            artifact_filename,
            &resolved.verification,
            &subs,
            self.http.as_ref(),
        )?;
        for w in &warnings {
            if let Some(l) = logger {
                l.message(&format!("WARNING: {}", w.message));
            } else {
                // No per-feature log file this run (its directory could not be
                // opened). The warning still has to be said out loud — a TOFU
                // acceptance must never be silent just because logging
                // degraded.
                tracing::warn!("{}", w.message);
            }
        }
        Ok(warnings)
    }

    pub(super) fn stage_method(
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
        let cache_dirs = resolved.cache_dirs.clone().unwrap_or_default();
        methods::dispatch(
            resolved.method_kind,
            &resolved.method_name,
            &MethodContext {
                artifact,
                args: invoke_args,
                env: env_map,
                user,
                cache_root: &self.options.cache_root,
                bin_root: &self.options.bin_root,
                binaries: resolved.binaries.as_deref().unwrap_or(&[]),
                bin_source_dir: resolved.bin_source_dir.as_deref(),
                cache_dirs: &cache_dirs,
                prefix: resolved.prefix.as_deref(),
                strip_components: resolved.strip_components.unwrap_or(0),
                runner: self.runner.as_ref(),
            },
        )
    }

    pub(super) fn stage_post_install(
        &self,
        resolved: &ResolvedInstall,
        user: &str,
        env_map: &BTreeMap<String, String>,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<()> {
        // Post-install runs in a fresh `su -` so it needs the same env the
        // install method exported. `run_stages` prefills the cache-root
        // CARGO_HOME / RUSTUP_HOME defaults so every stage shares one map.
        let Some(steps) = resolved.post_install.as_deref() else { return Ok(()) };
        if steps.is_empty() {
            return Ok(());
        }
        if let Some(l) = logger {
            l.step(&format!("post-install ({} steps)", steps.len()));
        }
        post_install::run_steps(steps, user, env_map, self.runner.as_ref())
    }

    pub(super) fn stage_validate(
        &self,
        resolved: &ResolvedInstall,
        env_map: &BTreeMap<String, String>,
        logger: Option<&logging::FeatureLogger>,
    ) -> Result<String> {
        if let Some(l) = logger {
            l.step("validate");
        }
        validate::check(
            &resolved.tool,
            &resolved.primary_binary,
            &resolved.version,
            &self.options.bin_root,
            env_map,
        )
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::Arc;

    use containers_common::tooldb::Verification;

    use super::*;
    use crate::Platform;
    use crate::installer::download::MockHttpClient;
    use crate::installer::verify::sha::digest_hex;
    use crate::installer::{InstallerOptions, tests::sample_resolved_with_deps};

    /// The wiring between verification and the report is what makes a TOFU
    /// acceptance visible, and it spans `stage_verify` → `run_stages` →
    /// `run_with_report`. Unit-testing each layer alone would still pass if a
    /// warning were dropped in between, so drive the real `stage_verify` and
    /// assert the warning comes back out.
    ///
    /// Exercises the `logger: None` branch specifically — the one where the
    /// per-feature log file could not be opened, and `tracing::warn!` is the
    /// only thing keeping the acceptance from being silent.
    #[test]
    fn stage_verify_returns_the_tofu_warning_with_no_logger() {
        let mut resolved = sample_resolved_with_deps();
        resolved.verification_tier = 4;
        resolved.verification = Verification { tier: 4, tofu: Some(true), ..resolved.verification };

        let installer = Installer::with_options(InstallerOptions {
            install_system_packages: false,
            ..InstallerOptions::default()
        });
        let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let warnings = installer.stage_verify(&resolved, digest, "get-pip.py", None).unwrap();

        assert_eq!(warnings.len(), 1, "a TOFU acceptance must produce exactly one warning");
        assert_eq!(warnings[0].tier, 4);
        assert_eq!(warnings[0].digest, digest);
        assert!(warnings[0].message.contains("TOFU"), "{}", warnings[0].message);
    }

    /// The same path with a real logger: the warning must reach the
    /// per-feature log file, not only the return value. `check-build-logs.sh`
    /// and anyone reading build output depend on this half.
    #[test]
    fn stage_verify_writes_the_tofu_warning_to_the_feature_log() {
        let mut resolved = sample_resolved_with_deps();
        resolved.verification_tier = 4;
        resolved.verification = Verification { tier: 4, tofu: Some(true), ..resolved.verification };

        let dir = tempfile::tempdir().unwrap();
        let logger = logging::FeatureLogger::open(dir.path(), "python", "3.13.0").unwrap();
        let installer = Installer::with_options(InstallerOptions {
            install_system_packages: false,
            ..InstallerOptions::default()
        });
        let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let warnings =
            installer.stage_verify(&resolved, digest, "get-pip.py", Some(&logger)).unwrap();
        assert_eq!(warnings.len(), 1);

        let body = fs::read_to_string(logger.path()).unwrap();
        assert!(body.contains("WARNING:"), "{body}");
        assert!(body.contains("TOFU"), "{body}");
    }

    /// Tier 3 goes through the same `stage_verify` and must stay silent —
    /// otherwise the warning stops meaning "this one was weaker".
    #[test]
    fn stage_verify_is_silent_for_tier_3() {
        let resolved = sample_resolved_with_deps(); // tier 3
        let digest = digest_hex(Some("sha256"), b"hello").unwrap();
        let mock = MockHttpClient::new();
        mock.insert("https://example.test/x.sha256", format!("{digest}  art\n").into_bytes());

        let mut resolved = resolved;
        resolved.verification = Verification {
            checksum_url_template: Some("https://example.test/x.sha256".into()),
            ..resolved.verification
        };
        let installer = Installer::with_runners(
            InstallerOptions { install_system_packages: false, ..InstallerOptions::default() },
            Arc::new(mock),
            Arc::new(methods::ProcessRunner),
        );
        let warnings = installer.stage_verify(&resolved, &digest, "art", None).unwrap();
        assert!(warnings.is_empty());
    }

    #[test]
    fn captured_dependency_versions_none_when_recording_disabled() {
        // With recording off (the default) the success path records no
        // dependency versions even when the platform/deps would otherwise
        // resolve — keeps ordinary installs and hermetic tests query-free.
        let installer = Installer::with_options(InstallerOptions {
            record_dependency_versions: false,
            ..InstallerOptions::default()
        });
        let resolved = sample_resolved_with_deps();
        assert!(installer.captured_dependency_versions(&resolved).is_none());
    }

    #[test]
    fn captured_dependency_versions_none_when_system_packages_skipped() {
        // Recording on, but system packages were not installed this run, so
        // there is nothing trustworthy to query.
        let installer = Installer::with_options(InstallerOptions {
            record_dependency_versions: true,
            install_system_packages: false,
            ..InstallerOptions::default()
        });
        let resolved = sample_resolved_with_deps();
        assert!(installer.captured_dependency_versions(&resolved).is_none());
    }

    #[test]
    fn captured_dependency_versions_none_for_unknown_platform() {
        // Recording on + system packages installed, but the platform has no
        // wired-up package manager — nothing to query.
        let installer = Installer::with_options(InstallerOptions {
            record_dependency_versions: true,
            install_system_packages: true,
            ..InstallerOptions::default()
        });
        let mut resolved = sample_resolved_with_deps();
        resolved.platform = Platform { os: "haiku".into(), os_version: None, arch: "amd64".into() };
        assert!(installer.captured_dependency_versions(&resolved).is_none());
    }

    #[test]
    fn captured_dependency_versions_none_when_deps_empty() {
        // The common case for a tool that declares no system dependencies.
        let installer = Installer::with_options(InstallerOptions {
            record_dependency_versions: true,
            install_system_packages: true,
            ..InstallerOptions::default()
        });
        let mut resolved = sample_resolved_with_deps();
        resolved.dependencies = Some(vec![]);
        assert!(installer.captured_dependency_versions(&resolved).is_none());
    }
}
