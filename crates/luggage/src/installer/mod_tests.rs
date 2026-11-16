//! Unit tests for the installer orchestration in `installer/mod.rs`.
//!
//! Split out of `mod.rs` so its production code is not buried under ~600
//! lines of inline tests (#1684). Same `#[path]` idiom as
//! `download_tests.rs` and `idempotency_tests.rs`.

use super::*;
use std::time::Duration;

use crate::Platform;
use containers_common::tooldb::{Dependency, InstallMethodKind, Verification};

/// A set-but-non-UTF-8 tuning variable is a hard error naming it, never
/// the "unset → default" fallback `env::var(..).ok()` used to give it;
/// set and unset pass through unchanged (#1358).
#[cfg(unix)]
#[test]
fn tuning_env_value_refuses_non_utf8_instead_of_defaulting() {
    use std::env::VarError;
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt as _;

    assert_eq!(tuning_env_value("X", Err(VarError::NotPresent)).unwrap(), None);
    assert_eq!(tuning_env_value("X", Ok("30".into())).unwrap().as_deref(), Some("30"));

    let corrupt = OsString::from_vec(vec![b'3', 0xff, b'0']);
    let err = tuning_env_value("LUGGAGE_X", Err(VarError::NotUnicode(corrupt))).unwrap_err();
    assert!(matches!(err, LuggageError::Catalog(_)), "got {err:?}");
    assert!(err.to_string().contains("LUGGAGE_X"), "{err}");
}

/// `invoke_env_map` yields an empty map when there is no `invoke` block or
/// it carries no `env`, and the `invoke.env` entries otherwise (#1659).
#[test]
fn invoke_env_map_empty_without_env_and_copies_env_when_present() {
    use containers_common::tooldb::Invoke;

    let mut resolved = sample_resolved_with_deps();
    assert!(invoke_env_map(&resolved).is_empty(), "invoke: None");

    resolved.invoke = Some(Invoke { args: None, env: None });
    assert!(invoke_env_map(&resolved).is_empty(), "invoke.env: None");

    let env = BTreeMap::from([("RUSTUP_HOME".to_string(), "/cache/rustup".to_string())]);
    resolved.invoke = Some(Invoke { args: None, env: Some(env.clone()) });
    assert_eq!(invoke_env_map(&resolved), env);
}

/// A minimal debian/amd64 [`ResolvedInstall`] carrying one dependency,
/// for exercising [`Installer::captured_dependency_versions`]'s gating
/// without touching the catalog or the network.
pub(super) fn sample_resolved_with_deps() -> ResolvedInstall {
    ResolvedInstall {
        tool: "rust".into(),
        version: "1.96.0".into(),
        method_name: "rustup".into(),
        method_kind: Some(InstallMethodKind::ScriptInstaller),
        verification_tier: 3,
        verification: Verification {
            tier: 3,
            algorithm: Some("sha256".into()),
            pinned_checksum: None,
            checksum_url_template: None,
            checksum_manifest: None,
            gpg_key_url: None,
            gpg_keyring: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: None,
        },
        source_url_template: None,
        invoke: None,
        post_install: None,
        dependencies: Some(vec![Dependency {
            tool: "gcc".into(),
            version: None,
            version_constraint: None,
            purpose: None,
            required: None,
            platforms: None,
        }]),
        system_deps: crate::sysdeps::ResolvedSystemDeps {
            packages: vec![crate::sysdeps::SystemPackageDep {
                tool: "gcc".into(),
                package: "gcc".into(),
                purpose: containers_common::tooldb::DependencyPurpose::Both,
            }],
            unmapped: Vec::new(),
        },
        primary_binary: "rustc".into(),
        version_args: vec!["--version".into()],
        binaries: None,
        bin_source_dir: None,
        cache_dirs: None,
        prefix: None,
        strip_components: None,
        build_steps: None,
        platform: Platform {
            os: "debian".into(),
            os_version: Some("12".into()),
            arch: "amd64".into(),
        },
        warnings: Vec::new(),
    }
}

/// The build deps `run_stages` removed reach a successful report, along
/// with every other stage output the success arm passes through (#1635).
#[test]
fn report_from_stages_carries_removed_build_deps_on_success() {
    let resolved = sample_resolved_with_deps();
    let warning = verify::VerificationWarning {
        tier: 4,
        tool: "rust".into(),
        version: "1.96.0".into(),
        algorithm: Some("sha256".into()),
        digest: "deadbeef".into(),
        message: "TIER 4 TOFU".into(),
    };
    let deps = vec![InstalledDependency {
        tool: "gcc".into(),
        package: "gcc".into(),
        version: Some("12.2.0".into()),
    }];
    let outcome = StageOutcome {
        version_output: "rustc 1.96.0".into(),
        warnings: vec![warning.clone()],
        dependencies: Some(deps.clone()),
    };
    let (report, result) = Installer::report_from_stages(
        &resolved,
        StageRun {
            removed_build_dependencies: vec!["g++".into(), "make".into()],
            result: Ok(outcome),
        },
        vec!["libfoo".into()],
        None,
        2.5,
    );
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(report.error_class, None);
    assert_eq!(report.version_output.as_deref(), Some("rustc 1.96.0"));
    assert_eq!(report.removed_build_dependencies, vec!["g++".to_string(), "make".into()]);
    assert_eq!(report.skipped_dependencies, vec!["libfoo".to_string()]);
    assert_eq!(report.warnings, vec![warning]);
    assert_eq!(report.dependencies, Some(deps));
    assert_eq!(report.verification_tier, Some(resolved.verification_tier));
    assert!((report.duration_seconds - 2.5).abs() < f64::EPSILON);
}

/// A stage failing after the package stage (here the method) still
/// records the build deps that were removed behind it (#1635).
#[test]
fn report_from_stages_carries_removed_build_deps_on_method_failure() {
    let resolved = sample_resolved_with_deps();
    let err = LuggageError::InstallStageFailed { stage: "spawn", message: "method failed".into() };
    let (report, result) = Installer::report_from_stages(
        &resolved,
        StageRun {
            removed_build_dependencies: vec!["g++".into(), "make".into()],
            result: Err(err),
        },
        Vec::new(),
        None,
        0.0,
    );
    assert!(matches!(result, Err(LuggageError::InstallStageFailed { .. })), "{result:?}");
    assert_eq!(report.error_class, Some(ErrorClass::InstallMethod));
    assert_eq!(report.version_output, None);
    assert_eq!(report.removed_build_dependencies, vec!["g++".to_string(), "make".into()]);
}

/// A plan with no `source_url` must return a typed `Catalog` error rather
/// than panicking. This path used to be an `expect(...)`; the streaming
/// rework turned it into a recoverable error and this pins that.
#[test]
fn missing_source_url_is_a_catalog_error_not_a_panic() {
    let resolved = sample_resolved_with_deps(); // source_url_template: None
    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    let plan = installer.plan(&resolved).unwrap();
    assert!(plan.source_url.is_none(), "fixture must exercise the missing-URL path");
    let err = installer.run_stages(&resolved, plan, None).result.unwrap_err();
    match err {
        LuggageError::Catalog(msg) => {
            assert!(msg.contains("source_url_template"), "got: {msg}");
        }
        other => panic!("expected Catalog, got {other:?}"),
    }
}

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
    // Off by default — only the CLI's --json-report path enables it.
    assert!(!o.record_dependency_versions);
    // Strict by default — unknown dep ids fail closed unless the CLI's
    // --allow-unknown-deps opts out.
    assert!(o.fail_on_unknown_deps);
    // Permissive by default, matching the bash build's
    // REQUIRE_VERIFIED_DOWNLOADS default: TOFU is accepted-with-warning
    // unless the operator opts into refusing it.
    assert!(!o.require_verified_downloads);
}

/// A tier-4 acceptance has to reach the report, not just the console —
/// that is the difference between a recorded security signal and one
/// nobody can find afterwards.
#[test]
fn tofu_warning_reaches_the_install_report() {
    let warning = verify::VerificationWarning {
        tier: 4,
        tool: "python".into(),
        version: "3.13.0".into(),
        algorithm: Some("sha256".into()),
        digest: "deadbeef".into(),
        message: "TIER 4 TOFU: ...".into(),
    };
    let report = InstallReport {
        tool: "python".into(),
        version: "3.13.0".into(),
        already_installed: false,
        log_path: None,
        duration_seconds: 1.0,
        version_output: Some("Python 3.13.0".into()),
        error_class: None,
        dependencies: None,
        skipped_dependencies: Vec::new(),
        warnings: vec![warning.clone()],
        verification_tier: Some(4),
        removed_build_dependencies: Vec::new(),
    };
    let json = serde_json::to_string(&report).unwrap();
    assert!(json.contains("\"warnings\""), "{json}");
    let back: InstallReport = serde_json::from_str(&json).unwrap();
    assert_eq!(back.warnings, vec![warning]);
}

/// Wire-compat guard: a run with nothing to warn about must serialize
/// exactly as it did before `warnings` existed, so evidence rows recorded
/// by older and newer builds stay comparable.
#[test]
fn a_report_with_no_warnings_omits_the_field_entirely() {
    let report = InstallReport {
        tool: "rust".into(),
        version: "1.95.0".into(),
        already_installed: false,
        log_path: None,
        duration_seconds: 1.0,
        version_output: Some("rustc 1.95.0".into()),
        error_class: None,
        dependencies: None,
        skipped_dependencies: Vec::new(),
        warnings: Vec::new(),
        verification_tier: None,
        removed_build_dependencies: Vec::new(),
    };
    let json = serde_json::to_string(&report).unwrap();
    assert!(!json.contains("warnings"), "{json}");
    assert!(!json.contains("removed_build_dependencies"), "{json}");
    // And a report written by an older build (no `warnings` key) still
    // deserializes.
    let back: InstallReport = serde_json::from_str(&json).unwrap();
    assert!(back.warnings.is_empty(), "expected empty, got {:?}", back.warnings);
}

/// The skip / dry-run / failure paths never reach verification, so their
/// reports must carry no warnings rather than a stale or invented one.
#[test]
fn non_success_reports_carry_no_warnings() {
    let resolved = sample_resolved_with_deps();
    let skipped = Installer::report_skipped(&resolved, None, 0.0);
    assert!(skipped.warnings.is_empty(), "expected empty, got {:?}", skipped.warnings);

    let err = LuggageError::Catalog("x".into());
    let failed = Installer::report_failure(&resolved, &err, None, 0.0);
    assert!(failed.warnings.is_empty(), "expected empty, got {:?}", failed.warnings);

    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    let plan = installer.plan(&resolved).unwrap();
    let dry = Installer::report_dry_run(plan, None, 0.0);
    assert!(dry.warnings.is_empty(), "expected empty, got {:?}", dry.warnings);
}

/// `plan()` substitutes `{arch}` from the resolved platform into both the
/// source and checksum URLs (#811). Two arches through the same template
/// must yield two different URLs — a call site that dropped `arch` would
/// fail with `TemplateMissingKey`, and one that hard-coded it would make
/// the two plans agree.
#[test]
fn plan_substitutes_arch_from_the_resolved_platform() {
    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    for platform_arch in ["amd64", "arm64"] {
        let mut resolved = sample_resolved_with_deps();
        resolved.version = "1.27.2".into();
        resolved.platform.arch = platform_arch.into();
        resolved.source_url_template =
            Some("https://dl.google.com/go/go{version}.linux-{arch}.tar.gz".into());
        resolved.verification = Verification {
            checksum_url_template: Some(
                "https://dl.google.com/go/go{version}.linux-{arch}.tar.gz.sha256".into(),
            ),
            ..resolved.verification
        };
        let plan = installer.plan(&resolved).unwrap();
        let expected = format!("https://dl.google.com/go/go1.27.2.linux-{platform_arch}.tar.gz");
        assert_eq!(plan.source_url.as_deref(), Some(expected.as_str()));
        assert_eq!(plan.checksum_url, Some(format!("{expected}.sha256")));
    }
}

/// The idempotency skip probes with `resolved.version_args`, not a
/// hard-coded `--version` (#811). Against a go-shaped shim, `["version"]`
/// must skip the install; the default argv, which the shim rejects with
/// exit 2, must not — so the positive cannot be a shim that answers
/// anything. The negative run then proceeds to a real install attempt,
/// whose outcome is irrelevant here (log/cache/tmp all point at the
/// tempdir); only `already_installed` is asserted.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn idempotency_skip_uses_the_resolved_version_args() {
    let dir = tempfile::tempdir().unwrap();
    idempotency::tests::write_subcommand_shim(dir.path(), "go", "go version go1.27.2 linux/arm64");
    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        bin_root: dir.path().to_owned(),
        log_dir: dir.path().join("log"),
        cache_root: dir.path().join("cache"),
        tmp_root: dir.path().join("tmp"),
        ..InstallerOptions::default()
    })
    .unwrap();
    let mut resolved = sample_resolved_with_deps();
    resolved.tool = "go".into();
    resolved.version = "1.27.2".into();
    resolved.primary_binary = "go".into();

    resolved.version_args = vec!["version".into()];
    let (report, result) = installer.run_with_report(&resolved);
    result.unwrap();
    assert!(report.already_installed, "declared argv must confirm the install");

    resolved.version_args = vec!["--version".into()];
    let (report, _) = installer.run_with_report(&resolved);
    assert!(!report.already_installed, "`go --version` exits 2; it must not skip");
}

/// The idempotency pre-check honors
/// [`InstallerOptions::version_probe_timeout`] rather than the 10s default
/// (#1358). A hung shim with a 1s option must give up well inside the
/// default; `dry_run` stops the run right after the pre-check, so the
/// elapsed time is the probe's alone.
#[cfg(unix)]
#[test]
#[serial_test::serial]
fn idempotency_precheck_honors_the_version_probe_timeout_option() {
    let dir = tempfile::tempdir().unwrap();
    idempotency::tests::write_sleeping_shim(dir.path(), "tool");
    let installer = Installer::with_options(InstallerOptions {
        dry_run: true,
        install_system_packages: false,
        bin_root: dir.path().to_owned(),
        log_dir: dir.path().join("log"),
        version_probe_timeout: Duration::from_secs(1),
        ..InstallerOptions::default()
    })
    .unwrap();
    let mut resolved = sample_resolved_with_deps();
    resolved.version = "1.0.0".into();
    resolved.primary_binary = "tool".into();

    let started = Instant::now();
    let (report, _) = installer.run_with_report(&resolved);
    let elapsed = started.elapsed();
    assert!(!report.already_installed, "a timed-out probe must not skip");
    assert!(
        elapsed < idempotency::VERSION_PROBE_TIMEOUT / 2,
        "the 1s option must bound the pre-check, took {elapsed:?}"
    );
    idempotency::tests::assert_probe_child_gone(dir.path(), "tool");
}

/// `sample_resolved_with_deps` with a pinless tier-2 verification — an
/// entry the guard always refuses, whatever the strictness.
fn pinless_tier_2_resolved() -> ResolvedInstall {
    let mut resolved = sample_resolved_with_deps();
    resolved.verification_tier = 2;
    resolved.verification =
        Verification { tier: 2, pinned_checksum: None, ..resolved.verification };
    resolved.source_url_template = Some("https://example.test/artifact.tar.gz".into());
    resolved
}

/// Strict mode must refuse a TOFU install *before* the download, the way
/// `lib/features/python.sh` does — an operator who said "no unverified
/// downloads" should not pay for the fetch that is about to be rejected.
/// `plan()` is pure and every stage runs after it, so a refusal here
/// precedes the download and every other side effect.
#[test]
fn strict_mode_refuses_tofu_before_downloading() {
    let mut resolved = sample_resolved_with_deps();
    resolved.verification_tier = 4;
    resolved.verification = Verification { tier: 4, tofu: Some(true), ..resolved.verification };
    resolved.source_url_template = Some("https://example.test/get-pip.py".into());

    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        require_verified_downloads: true,
        ..InstallerOptions::default()
    })
    .unwrap();
    match installer.plan(&resolved).unwrap_err() {
        LuggageError::VerificationFailed { tier, .. } => assert_eq!(tier, 4),
        other => panic!("expected a pre-download tier-4 refusal, got {other:?}"),
    }
}

/// A tier-2 entry with no pin can never verify, so it must be refused
/// before the download (#891) — at plan time, as above.
#[test]
fn pinless_tier_2_is_refused_before_downloading() {
    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    match installer.plan(&pinless_tier_2_resolved()).unwrap_err() {
        LuggageError::Catalog(msg) => assert!(msg.contains("pinned_checksum"), "got: {msg}"),
        other => panic!("expected a pre-download Catalog refusal, got {other:?}"),
    }
}

/// A pin that is present but not a hex digest can never verify either, so
/// it too is refused at plan time, before the download (#1041).
#[test]
fn malformed_pin_tier_2_is_refused_before_downloading() {
    let mut resolved = pinless_tier_2_resolved();
    resolved.verification.pinned_checksum = Some("not-a-digest".into());

    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    match installer.plan(&resolved).unwrap_err() {
        LuggageError::VerificationFailed { tier: 2, reason, .. } => {
            assert!(reason.contains("not a hex digest"), "got: {reason}");
        }
        other => panic!("expected a pre-download tier-2 refusal, got {other:?}"),
    }
}

/// A hex pin of the wrong width for its algorithm can never verify, so it
/// is refused at plan time too, before the download (#1311).
#[test]
fn wrong_length_pin_tier_2_is_refused_before_downloading() {
    let mut resolved = pinless_tier_2_resolved();
    resolved.verification.algorithm = Some("sha256".into());
    resolved.verification.pinned_checksum = Some("9f86d081".into());

    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    match installer.plan(&resolved).unwrap_err() {
        LuggageError::VerificationFailed { tier: 2, reason, .. } => {
            assert!(reason.contains("is 8 hex characters"), "got: {reason}");
        }
        other => panic!("expected a pre-download tier-2 refusal, got {other:?}"),
    }
}

/// The plan-time width check must let a correct non-default width
/// through, in both postures — a guard that only knew 64 would refuse
/// every sha512 entry before it was ever downloaded. `InstallPlan` does
/// not carry the algorithm or pin (dispatch reads them from `resolved`),
/// so the tier is all there is to check in the plan.
#[test]
fn sha512_width_pin_on_sha512_entry_is_planned() {
    let mut resolved = pinless_tier_2_resolved();
    resolved.verification.algorithm = Some("sha512".into());
    resolved.verification.pinned_checksum = Some("ab".repeat(64));

    for strict in [false, true] {
        let installer = Installer::with_options(InstallerOptions {
            install_system_packages: false,
            require_verified_downloads: strict,
            ..InstallerOptions::default()
        })
        .unwrap();
        let plan = installer.plan(&resolved).unwrap_or_else(|e| panic!("strict={strict}: {e:?}"));
        assert_eq!(plan.verification_tier, 2, "strict={strict}");
    }
}

/// The pin's width depends on the algorithm, so a tier-2 entry whose
/// algorithm the digest layer cannot compute is refused at plan time with
/// that layer's own error rather than once the download has started.
#[test]
fn uncomputable_algorithm_tier_2_is_refused_before_downloading() {
    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: false,
        ..InstallerOptions::default()
    })
    .unwrap();
    for algorithm in ["md5", "sha384"] {
        let mut resolved = pinless_tier_2_resolved();
        resolved.verification.algorithm = Some(algorithm.into());
        resolved.verification.pinned_checksum = Some("ab".repeat(32));
        // The digest layer's own error, not merely the same variant: `plan()`
        // has other `NotImplemented` sources that would otherwise satisfy it.
        let expected = verify::sha::Algorithm::parse(Some(algorithm)).unwrap_err();
        let err = installer.plan(&resolved).unwrap_err();
        assert_eq!(format!("{err:?}"), format!("{expected:?}"), "{algorithm}");
    }
}

/// A guard-refused entry must install no system packages (#1042).
///
/// The fixture also carries an *unmapped* dependency under strict
/// `fail_on_unknown_deps`, which makes the system-packages stage fail with
/// `UnknownDependency` before it would shell out to a package manager. So
/// the error that comes back names whichever ran first: the guard's
/// `Catalog` refusal means the stage never started, and `UnknownDependency`
/// means it ran ahead of the guard. Neither order touches the host.
#[test]
fn refused_entry_installs_no_system_packages() {
    let mut resolved = pinless_tier_2_resolved();
    resolved.system_deps.unmapped = vec!["frobnicator".into()];

    let installer = Installer::with_options(InstallerOptions {
        install_system_packages: true,
        fail_on_unknown_deps: true,
        log_dir: tempfile::tempdir().unwrap().keep(),
        ..InstallerOptions::default()
    })
    .unwrap();
    let (report, result) = installer.run_with_report(&resolved);
    match result.unwrap_err() {
        LuggageError::Catalog(msg) => assert!(msg.contains("pinned_checksum"), "got: {msg}"),
        other => panic!("expected the guard to refuse before system packages, got {other:?}"),
    }
    assert_eq!(report.error_class, Some(ErrorClass::Unknown));
}

/// `--dry-run` must report the refusal a real install would, not a
/// success (#1042). The dry-run branch returns before `run_stages`, so it
/// only sees the guard because the guard runs in `plan()`.
#[test]
fn dry_run_reports_the_guard_refusal() {
    let installer = Installer::with_options(InstallerOptions {
        dry_run: true,
        install_system_packages: false,
        log_dir: tempfile::tempdir().unwrap().keep(),
        ..InstallerOptions::default()
    })
    .unwrap();
    let (report, result) = installer.run_with_report(&pinless_tier_2_resolved());
    match result.unwrap_err() {
        LuggageError::Catalog(msg) => assert!(msg.contains("pinned_checksum"), "got: {msg}"),
        other => panic!("expected a dry-run Catalog refusal, got {other:?}"),
    }
    assert_eq!(report.error_class, Some(ErrorClass::Unknown));
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
