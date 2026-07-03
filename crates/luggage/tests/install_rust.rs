//! Hermetic end-to-end test for `luggage install rust@1.95.0`.
//!
//! Drives the installer with a stubbed HTTP client and a recording command
//! runner, so we exercise the full pipeline (resolve → plan → download →
//! verify → install method → post-install) without touching the network or
//! the host package manager / filesystem.
//!
//! Invariants we lock in:
//!
//! - Source URL gets `{rustup_target}` substituted from the resolved
//!   platform.
//! - Tier 3 verification fetches the checksum URL via `HttpClient` and
//!   matches it against the artifact's sha256.
//! - The install method runs as `su - <user> -c "..."` with `CARGO_HOME` /
//!   `RUSTUP_HOME` exported and the catalog's invoke args.
//! - All four `post_install` `ComponentAdd` steps run as `rustup component
//!   add <name>` under the same `su -` plumbing.
//! - Symlinks for the rust binary set land in `bin_root`.
//! - `--dry-run` performs no HTTP and no command execution.
//! - A bytes-vs-checksum mismatch produces a tier-3 `VerificationFailed`.
//!
//! Unix-only: the install method itself is unix-only (catalog marks rust
//! on Windows as `unsupported`), so the integration test follows.

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use luggage::installer::download::{HttpClient, MockHttpClient};
use luggage::installer::methods::RecordingRunner;
use luggage::installer::methods::script_installer::RUST_BINARIES;
use luggage::installer::verify::sha::digest_hex;
use luggage::{
    Catalog, CatalogSource, Installer, InstallerOptions, LuggageError, Platform, VersionSpec,
};
use sha2::{Digest as _, Sha256};
use tempfile::TempDir;

const RUSTUP_INIT_BODY: &[u8] = b"#!/bin/sh\necho stub rustup-init\nexit 0\n";
const SOURCE_URL: &str =
    "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init";
const CHECKSUM_URL: &str =
    "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256";

fn testdata_catalog() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata").join("catalog")
}

fn debian_amd64() -> Platform {
    Platform { os: "debian".into(), os_version: Some("13".into()), arch: "amd64".into() }
}

/// Build a `MockHttpClient` wired with the rustup-init body and a
/// matching tier-3 checksum file. `body_override` lets a single test inject
/// a corruption while keeping every other URL stub identical.
fn mock_with(body_override: Option<&[u8]>) -> MockHttpClient {
    let body = body_override.unwrap_or(RUSTUP_INIT_BODY);
    let digest = digest_hex(Some("sha256"), RUSTUP_INIT_BODY).unwrap();
    let checksum = format!("{digest}  rustup-init\n");
    let mock = MockHttpClient::new();
    mock.insert(SOURCE_URL, body.to_vec());
    mock.insert(CHECKSUM_URL, checksum.into_bytes());
    mock
}

/// Hermetic [`InstallerOptions`] — every path lives under `roots`, no
/// system packages, no host writes. Returned alongside the `TempDir` so
/// callers can keep it alive for the duration of the test.
fn options_in(roots: &TempDir) -> InstallerOptions {
    InstallerOptions {
        dry_run: false,
        force: false,
        log_dir: roots.path().join("log"),
        bin_root: roots.path().join("bin"),
        cache_root: roots.path().join("cache"),
        tmp_root: roots.path().join("tmp"),
        user_override: Some("vscode".to_owned()),
        install_system_packages: false,
        record_dependency_versions: false,
        fail_on_unknown_deps: true,
    }
}

/// Resolve `rust@1.95.0` for debian/amd64 against the in-tree testdata
/// catalog. Centralised so every test exercises the same plan.
fn resolve_rust() -> luggage::ResolvedInstall {
    let catalog = Catalog::load(CatalogSource::LocalPath(testdata_catalog())).unwrap();
    catalog
        .resolve("rust", &VersionSpec::Exact("1.95.0".into()), &debian_amd64())
        .expect("resolve rust@1.95.0")
}

// Serialized: this test writes executable shims and the installer execs them.
// Under parallel test load that write-then-exec races with concurrent forks in
// the same binary, intermittently failing with ETXTBSY. The production fix
// retries that transient; serializing the exec-dependent tests removes the
// race entirely (matching the unit-test convention). See issue #518.
#[test]
#[serial_test::serial]
fn install_rust_runs_full_pipeline() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    let mock = Arc::new(mock_with(None));
    let runner = Arc::new(RecordingRunner::new());

    // Populate cache/cargo/bin with shims so the symlink stage has real
    // targets and so the post-install validation step (which runs
    // `<bin>/rustc --version` after symlinks land) sees the right version.
    let cargo_bin = roots.path().join("cache").join("cargo").join("bin");
    std::fs::create_dir_all(&cargo_bin).unwrap();
    write_version_shim(&cargo_bin.join("rustc"), "rustc 1.95.0 (stub)");
    for name in RUST_BINARIES {
        if *name != "rustc" {
            std::fs::write(cargo_bin.join(name), b"#!/bin/sh\necho stub\n").unwrap();
        }
    }

    let installer = Installer::with_runners(
        options_in(&roots),
        mock as Arc<dyn HttpClient>,
        runner.clone() as Arc<dyn luggage::installer::methods::CommandRunner>,
    );
    let report = installer.run(&resolved).expect("install should succeed");

    assert!(!report.already_installed, "first install should not skip");
    assert_eq!(report.tool, "rust");
    assert_eq!(report.version, "1.95.0");

    // The rustup-init invocation goes through `su` with the catalog's args.
    let calls = runner.calls();
    let su_calls: Vec<_> = calls.iter().filter(|(p, _)| p == "su").collect();
    assert!(
        su_calls.len() >= 5,
        "expected ≥5 su calls (1 install + 4 component_add), got {}",
        su_calls.len(),
    );
    let install_payload = &su_calls[0].1[3];
    assert!(install_payload.contains("CARGO_HOME"));
    assert!(install_payload.contains("RUSTUP_HOME"));
    assert!(install_payload.contains("--default-toolchain"));
    assert!(install_payload.contains("1.95.0"));
    assert!(install_payload.contains("--profile"));

    // Each ComponentAdd post-install step lands as `rustup component add <name>`.
    for component in ["rust-src", "rust-analyzer", "clippy", "rustfmt"] {
        let needle = format!("rustup component add {component}");
        assert!(
            calls.iter().any(|(p, args)| p == "su" && args[3].contains(&needle)),
            "expected a su call running `{needle}`",
        );
    }
}

#[test]
fn dry_run_performs_no_http_or_command_io() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    // Empty mock — any HTTP attempt would fail with DownloadFailed.
    let mock = Arc::new(MockHttpClient::new());
    let runner = Arc::new(RecordingRunner::new());

    let mut opts = options_in(&roots);
    opts.dry_run = true;
    let installer = Installer::with_runners(
        opts,
        mock as Arc<dyn HttpClient>,
        runner.clone() as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    installer.run(&resolved).expect("dry-run should succeed");
    assert!(runner.calls().is_empty(), "dry-run should not invoke any commands");
}

#[test]
fn corrupt_artifact_returns_tier_3_verification_failed() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    // The mock serves a tampered body but the checksum URL still points at
    // the original digest — exactly the failure mode tier 3 detects.
    let mock = Arc::new(mock_with(Some(b"this is not rustup-init")));
    let runner = Arc::new(RecordingRunner::new());

    let installer = Installer::with_runners(
        options_in(&roots),
        mock as Arc<dyn HttpClient>,
        runner as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    let err = installer.run(&resolved).expect_err("verification should fail");
    match err {
        LuggageError::VerificationFailed { tier, tool, version, reason } => {
            assert_eq!(tier, 3);
            assert_eq!(tool, "rust");
            assert_eq!(version, "1.95.0");
            assert!(reason.contains("digest mismatch"), "reason was: {reason}");
        }
        other => panic!("expected VerificationFailed, got {other:?}"),
    }
}

#[test]
fn run_with_report_on_verification_failure_populates_error_class() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    let mock = Arc::new(mock_with(Some(b"this is not rustup-init")));
    let runner = Arc::new(RecordingRunner::new());

    let installer = Installer::with_runners(
        options_in(&roots),
        mock as Arc<dyn HttpClient>,
        runner as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    let (report, result) = installer.run_with_report(&resolved);
    assert!(result.is_err(), "verification should fail");
    assert_eq!(report.tool, "rust");
    assert_eq!(report.version, "1.95.0");
    assert!(!report.already_installed);
    assert!(report.version_output.is_none(), "validate never ran");
    assert_eq!(
        report.error_class,
        Some(luggage::ErrorClass::Verify),
        "tier-3 checksum mismatch is a Verify-stage failure",
    );
    assert!(report.duration_seconds >= 0.0);
}

// Serialized alongside the other exec-dependent tests: it execs a real shim
// via the post-install validate step, so under parallel load it races the
// write-then-exec ETXTBSY window like the rest. Left un-serialized it ran
// concurrently with the 8-thread/40-iter parallel regression tests below,
// where sustained fork pressure could in theory exhaust the 3-retry/50ms
// budget and spuriously fail. See issue #576 gap 4 (and #518).
#[test]
#[serial_test::serial]
fn run_with_report_on_success_captures_validate_output() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    let mock = Arc::new(mock_with(None));
    let runner = Arc::new(RecordingRunner::new());

    // Pre-populate the cargo bin shims so the install method's symlink
    // step has real targets and validate sees a `rustc --version` line
    // that contains the resolved version.
    let cargo_bin = roots.path().join("cache").join("cargo").join("bin");
    std::fs::create_dir_all(&cargo_bin).unwrap();
    write_version_shim(&cargo_bin.join("rustc"), "rustc 1.95.0 (linked)");
    for name in RUST_BINARIES {
        if *name != "rustc" {
            std::fs::write(cargo_bin.join(name), b"#!/bin/sh\necho stub\n").unwrap();
        }
    }

    let installer = Installer::with_runners(
        options_in(&roots),
        mock as Arc<dyn HttpClient>,
        runner as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    let (report, result) = installer.run_with_report(&resolved);
    result.expect("install should succeed");
    assert!(!report.already_installed);
    assert!(report.error_class.is_none(), "success has no error_class");
    let captured = report.version_output.as_deref().unwrap_or("");
    assert!(captured.contains("1.95.0"), "version_output should include the version: {captured}");
}

#[test]
#[serial_test::serial]
fn idempotent_skip_when_rustc_already_at_target_version() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    let mock = Arc::new(MockHttpClient::new());
    let runner = Arc::new(RecordingRunner::new());

    let bin_root = roots.path().join("bin");
    std::fs::create_dir_all(&bin_root).unwrap();
    write_version_shim(&bin_root.join("rustc"), "rustc 1.95.0 (preinstalled)");

    let installer = Installer::with_runners(
        options_in(&roots),
        mock as Arc<dyn HttpClient>,
        runner.clone() as Arc<dyn luggage::installer::methods::CommandRunner>,
    );
    let report = installer.run(&resolved).expect("idempotency check should pass");
    assert!(report.already_installed, "should report already_installed");
    assert!(runner.calls().is_empty(), "no commands should run on the idempotent path");
}

#[test]
#[serial_test::serial]
fn force_reruns_install_even_when_idempotent_check_matches() {
    let roots = TempDir::new().unwrap();
    let resolved = resolve_rust();
    let mock = Arc::new(mock_with(None));
    let runner = Arc::new(RecordingRunner::new());

    let bin_root = roots.path().join("bin");
    std::fs::create_dir_all(&bin_root).unwrap();
    write_version_shim(&bin_root.join("rustc"), "rustc 1.95.0 (preinstalled)");

    // Populate cargo bin with shims so the symlink stage has real targets.
    // The bin_root rustc above will be replaced by a symlink to this shim
    // by the install method's symlink stage; we keep the same version line
    // so post-install validation still passes.
    let cargo_bin = roots.path().join("cache").join("cargo").join("bin");
    std::fs::create_dir_all(&cargo_bin).unwrap();
    write_version_shim(&cargo_bin.join("rustc"), "rustc 1.95.0 (rebuilt)");
    for name in RUST_BINARIES {
        if *name != "rustc" {
            std::fs::write(cargo_bin.join(name), b"#!/bin/sh\necho stub\n").unwrap();
        }
    }

    let mut opts = options_in(&roots);
    opts.force = true;
    let installer = Installer::with_runners(
        opts,
        mock as Arc<dyn HttpClient>,
        runner.clone() as Arc<dyn luggage::installer::methods::CommandRunner>,
    );
    let report = installer.run(&resolved).expect("force install should succeed");
    assert!(!report.already_installed);
    assert!(!runner.calls().is_empty(), "force should invoke commands");
}

#[test]
fn computed_digest_matches_published_checksum_format() {
    // Belt-and-suspenders: confirm the mock server's checksum file matches
    // what the installer would compute. A test that fails here would expose
    // a subtle bug in either `digest_hex` or the test fixture itself.
    let mut hasher = Sha256::new();
    hasher.update(RUSTUP_INIT_BODY);
    let direct = format!("{:x}", hasher.finalize());
    let via_helper = digest_hex(Some("sha256"), RUSTUP_INIT_BODY).unwrap();
    assert_eq!(direct, via_helper);
}

/// Regression test for issue #518. Recreates the ETXTBSY race by hammering
/// the write-then-exec path from several threads at once: each iteration
/// writes a fresh `rustc` shim and immediately calls `already_installed`,
/// which execs it. Before the fix, a concurrent fork in this binary would
/// intermittently make that exec fail with ETXTBSY, which `already_installed`
/// swallowed into `false` — so the assertion below would flake. With the
/// bounded retry in place every iteration must observe the just-written
/// version. Deliberately *not* serialized: the cross-thread parallelism is
/// exactly the condition under test.
#[test]
fn already_installed_survives_etxtbsy_under_parallel_write_then_exec() {
    use std::thread;

    use luggage::installer::idempotency::already_installed;

    const THREADS: usize = 8;
    const ITERS: usize = 40;

    let handles: Vec<_> = (0..THREADS)
        .map(|t| {
            thread::spawn(move || {
                for i in 0..ITERS {
                    let dir = TempDir::new().unwrap();
                    let version = format!("1.95.{t}{i}");
                    write_version_shim(
                        &dir.path().join("rustc"),
                        &format!("rustc {version} (regression)"),
                    );
                    assert!(
                        already_installed("rust", &version, dir.path()),
                        "freshly-written shim must be seen as installed despite ETXTBSY \
                         (thread {t}, iter {i})",
                    );
                }
            })
        })
        .collect();

    for h in handles {
        h.join().expect("worker thread panicked");
    }
}

/// Stderr companion to `already_installed_survives_etxtbsy_under_parallel_write_then_exec`.
///
/// The stdout regression above never exercises `already_installed`'s
/// stderr-matching branch under the parallel write-then-exec load that
/// originally motivated #518 — a shim printing the version to stderr closes
/// that gap. Tools like `java -version` really do emit their version banner on
/// stderr, so the ETXTBSY retry must hold for them too, not only stdout tools.
#[test]
fn already_installed_survives_etxtbsy_under_parallel_write_then_exec_stderr() {
    use std::thread;

    use luggage::installer::idempotency::already_installed;

    const THREADS: usize = 8;
    const ITERS: usize = 40;

    let handles: Vec<_> = (0..THREADS)
        .map(|t| {
            thread::spawn(move || {
                for i in 0..ITERS {
                    let dir = TempDir::new().unwrap();
                    let version = format!("1.95.{t}{i}");
                    write_version_shim_stderr(
                        &dir.path().join("rustc"),
                        &format!("rustc {version} (regression)"),
                    );
                    assert!(
                        already_installed("rust", &version, dir.path()),
                        "freshly-written stderr shim must be seen as installed despite \
                         ETXTBSY (thread {t}, iter {i})",
                    );
                }
            })
        })
        .collect();

    for h in handles {
        h.join().expect("worker thread panicked");
    }
}

/// Regression companion to
/// `already_installed_survives_etxtbsy_under_parallel_write_then_exec`, for the
/// *validate* path (issue #576 gap 3). The same write-then-exec race applies to
/// `validate::check`, but there retry exhaustion surfaces as `ValidationFailed`
/// — a more severe outcome than a spurious idempotency skip, since it aborts a
/// real install. Hammering `validate::check` from several threads reproduces the
/// #518 fork pressure directly against that path: with the bounded ETXTBSY
/// retry in place every iteration must validate cleanly and return the captured
/// version. Deliberately *not* serialized — the cross-thread parallelism is the
/// condition under test.
#[test]
fn validate_check_survives_etxtbsy_under_parallel_write_then_exec() {
    use std::collections::BTreeMap;
    use std::thread;

    use luggage::installer::validate::check;

    const THREADS: usize = 8;
    const ITERS: usize = 40;

    let handles: Vec<_> = (0..THREADS)
        .map(|t| {
            thread::spawn(move || {
                for i in 0..ITERS {
                    let dir = TempDir::new().unwrap();
                    let version = format!("1.95.{t}{i}");
                    write_version_shim(
                        &dir.path().join("rustc"),
                        &format!("rustc {version} (regression)"),
                    );
                    let captured = check("rust", &version, dir.path(), &BTreeMap::new())
                        .unwrap_or_else(|e| {
                            panic!(
                                "freshly-written shim must validate despite ETXTBSY \
                                 (thread {t}, iter {i}): {e}"
                            )
                        });
                    assert!(
                        captured.contains(&version),
                        "validate must capture the just-written version (thread {t}, iter {i}), \
                         got: {captured}",
                    );
                }
            })
        })
        .collect();

    for h in handles {
        h.join().expect("worker thread panicked");
    }
}

/// Build a `Dependency` for a catalog tool id with no metadata. Used to
/// inject an id luggage has no system-package mapping for.
fn dep(tool: &str) -> containers_common::tooldb::Dependency {
    containers_common::tooldb::Dependency {
        tool: tool.into(),
        version: None,
        version_constraint: None,
        purpose: None,
        required: None,
        platforms: None,
    }
}

/// Non-strict `plan()` surfaces an unrecognized dependency id in
/// `skipped_dependencies` instead of erroring — and does so without touching
/// a real package manager (plan is pure). Proves the `--allow-unknown-deps`
/// opt-out path threads the skip through to the report shape.
#[test]
fn plan_surfaces_skipped_deps_when_not_strict() {
    let roots = TempDir::new().unwrap();
    let mut resolved = resolve_rust();
    // Append an id with no mapping; the four real rust deps stay known.
    let mut deps = resolved.dependencies.take().unwrap_or_default();
    deps.push(dep("frobnicator"));
    resolved.dependencies = Some(deps);

    let mut opts = options_in(&roots);
    opts.fail_on_unknown_deps = false;
    let installer = Installer::with_runners(
        opts,
        Arc::new(MockHttpClient::new()) as Arc<dyn HttpClient>,
        Arc::new(RecordingRunner::new()) as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    let plan = installer.plan(&resolved).expect("plan should not error in non-strict mode");
    assert!(
        plan.skipped_dependencies.iter().any(|d| d == "frobnicator"),
        "expected frobnicator in skipped_dependencies, got {:?}",
        plan.skipped_dependencies,
    );
    // The known deps still translate to packages, untouched.
    assert!(plan.system_packages.contains(&"gcc".to_owned()));
}

/// Strict mode (the production default) turns an unrecognized dependency id
/// into a hard `UnknownDependency` error before any download or shell-out.
/// The empty mock would fail download, so reaching `UnknownDependency` proves
/// the gate fires in the system-packages stage, ahead of everything else.
#[test]
fn strict_install_errors_on_unknown_dependency() {
    let roots = TempDir::new().unwrap();
    let mut resolved = resolve_rust();
    let mut deps = resolved.dependencies.take().unwrap_or_default();
    deps.push(dep("frobnicator"));
    resolved.dependencies = Some(deps);

    // Strict default, and turn the system-package stage on so the gate runs.
    let mut opts = options_in(&roots);
    opts.install_system_packages = true;
    opts.fail_on_unknown_deps = true;
    let installer = Installer::with_runners(
        opts,
        Arc::new(MockHttpClient::new()) as Arc<dyn HttpClient>,
        Arc::new(RecordingRunner::new()) as Arc<dyn luggage::installer::methods::CommandRunner>,
    );

    let (report, result) = installer.run_with_report(&resolved);
    match result.expect_err("strict mode must reject the unknown dep") {
        LuggageError::UnknownDependency { ids, .. } => {
            assert!(ids.contains("frobnicator"), "ids was: {ids}");
        }
        other => panic!("expected UnknownDependency, got {other:?}"),
    }
    assert_eq!(
        report.error_class,
        Some(luggage::ErrorClass::Infra),
        "UnknownDependency maps to the Infra error class",
    );
}

/// Write an executable shim at `path` that prints `line` to stdout.
///
/// `line` is single-quote-escaped so a version string containing an
/// apostrophe can't break the surrounding shell quoting.
fn write_version_shim(path: &Path, line: &str) {
    write_version_shim_impl(path, line, false);
}

/// Stderr variant of [`write_version_shim`]: emits `line` on stderr so the
/// `already_installed` stderr-matching branch is exercised under load.
fn write_version_shim_stderr(path: &Path, line: &str) {
    write_version_shim_impl(path, line, true);
}

fn write_version_shim_impl(path: &Path, line: &str, to_stderr: bool) {
    use std::fs;
    use std::os::unix::fs::PermissionsExt as _;
    let escaped = line.replace('\'', "'\\''");
    let redirect = if to_stderr { " >&2" } else { "" };
    fs::write(path, format!("#!/bin/sh\necho '{escaped}'{redirect}\n")).unwrap();
    let mut perms = fs::metadata(path).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).unwrap();
}
