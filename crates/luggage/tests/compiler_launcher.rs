//! The opt-in compiler launcher (`LUGGAGE_COMPILER_LAUNCHER`, #1594) from the
//! outside: the `luggage install` CLI reading the variable, and an
//! [`Installer`] carrying `InstallerOptions::compiler_launcher` through the
//! stages into a `source-build`'s steps and its feature log (#1614).
//!
//! The source-build unit tests drive `run()` with a hand-built
//! `MethodContext`, so they cannot see the stage that builds that context
//! from `InstallerOptions` — dropping that one field assignment used to pass
//! every test. Here the whole `run_with_report` pipeline runs with only its
//! external effects faked: HTTP via [`MockHttpClient`], the build steps via
//! [`RecordingRunner`]. Only the validate probe really executes, as a shell
//! shim in a tempdir `bin_root`.
//!
//! The catalog names both compilers (`CC=gcc-13`, `CXX=g++-13`), which beat
//! anything inherited or found on `PATH`, so every expected value is a literal
//! that holds on any host.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Write as _;
use std::os::unix::ffi::OsStringExt as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::Arc;

use containers_common::tooldb::{BuildStep, InstallMethodKind, Invoke, Verification};
use luggage::installer::download::{HttpClient, MockHttpClient};
use luggage::installer::methods::{CommandRunner, RecordingRunner, StreamingCall};
use luggage::sysdeps::ResolvedSystemDeps;
use luggage::{Installer, InstallerOptions, Platform, ResolvedInstall};
use tempfile::TempDir;

const SOURCE_URL: &str = "https://example.test/pkg-1.0.tar.gz";
const LAUNCHER_ENV: &str = "LUGGAGE_COMPILER_LAUNCHER";

/// A gzipped tarball holding `pkg-1.0/configure`.
fn source_tarball() -> Vec<u8> {
    let body: &[u8] = b"#!/bin/sh\n";
    let mut header = tar::Header::new_gnu();
    header.set_path("pkg-1.0/configure").unwrap();
    header.set_size(body.len() as u64);
    header.set_mode(0o755);
    header.set_cksum();
    let mut builder = tar::Builder::new(Vec::new());
    builder.append(&header, body).unwrap();
    let raw = builder.into_inner().unwrap();
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gz.write_all(&raw).unwrap();
    gz.finish().unwrap()
}

/// A tier-4 TOFU `source-build` of `pkg@1.0` whose catalog env names both
/// compilers, with one `make` step.
fn resolved(prefix: &str) -> ResolvedInstall {
    ResolvedInstall {
        tool: "pkg".into(),
        version: "1.0".into(),
        method_name: "source".into(),
        method_kind: Some(InstallMethodKind::SourceBuild),
        verification_tier: 4,
        verification: Verification {
            tier: 4,
            algorithm: None,
            pinned_checksum: None,
            checksum_url_template: None,
            checksum_manifest: None,
            gpg_key_url: None,
            gpg_keyring: None,
            signature_url_template: None,
            sigstore_identity: None,
            sigstore_issuer: None,
            tofu: Some(true),
        },
        source_url_template: Some(SOURCE_URL.into()),
        invoke: Some(Invoke {
            args: None,
            env: Some(BTreeMap::from([
                ("CC".to_owned(), "gcc-13".to_owned()),
                ("CXX".to_owned(), "g++-13".to_owned()),
            ])),
        }),
        post_install: None,
        dependencies: None,
        system_deps: ResolvedSystemDeps { packages: Vec::new(), unmapped: Vec::new() },
        primary_binary: "pkg".into(),
        version_args: vec!["--version".into()],
        binaries: None,
        bin_source_dir: None,
        cache_dirs: None,
        prefix: Some(prefix.to_owned()),
        strip_components: Some(1),
        build_steps: Some(vec![BuildStep { command: "make".into(), args: None }]),
        platform: Platform {
            os: "debian".into(),
            os_version: Some("13".into()),
            arch: "amd64".into(),
        },
        warnings: Vec::new(),
    }
}

/// What one install recorded: every build step's call and the feature log.
struct Run {
    calls: Vec<StreamingCall>,
    log: String,
}

/// Install `pkg@1.0` end to end with `launcher` in `InstallerOptions`.
fn install(launcher: Option<&str>) -> Run {
    let root = TempDir::new().unwrap();
    let r = root.path();
    let bin_root = r.join("bin");
    fs::create_dir_all(&bin_root).unwrap();
    // The validate probe: `pkg --version` from `bin_root`.
    let shim = bin_root.join("pkg");
    fs::write(&shim, "#!/bin/sh\necho 'pkg 1.0'\n").unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();

    let opts = InstallerOptions {
        bin_root,
        cache_root: r.join("cache"),
        log_dir: r.join("log"),
        tmp_root: r.join("tmp"),
        user_override: Some("root".into()),
        // The shim is already in `bin_root`; without this the idempotency
        // precheck would skip the install.
        force: true,
        install_system_packages: false,
        compiler_launcher: launcher.map(str::to_owned),
        ..InstallerOptions::default()
    };
    let http = MockHttpClient::new();
    http.insert(SOURCE_URL, source_tarball());
    let runner = Arc::new(RecordingRunner::new());
    let installer = Installer::with_runners(
        opts,
        Arc::new(http) as Arc<dyn HttpClient>,
        runner.clone() as Arc<dyn CommandRunner>,
    )
    .unwrap();

    let prefix = r.join("prefix").display().to_string();
    let (report, result) = installer.run_with_report(&resolved(&prefix));
    result.unwrap_or_else(|e| panic!("install failed: {e:?}\nreport: {report:?}"));

    let log = fs::read_to_string(r.join("log/pkg-1.0.log")).expect("feature log");
    Run { calls: runner.streaming_calls(), log }
}

fn compilers(call: &StreamingCall) -> (Option<&str>, Option<&str>) {
    (call.env.get("CC").map(String::as_str), call.env.get("CXX").map(String::as_str))
}

/// `InstallerOptions::compiler_launcher` reaches the build steps: set, each
/// compiler is wrapped; unset, the catalog's compilers pass through untouched.
/// The unset run is the control — without it a `ccache` could have come from
/// anywhere but the option.
#[test]
fn installer_option_reaches_the_source_build_steps() {
    let on = install(Some("ccache"));
    assert_eq!(on.calls.len(), 1, "{:?}", on.calls);
    assert_eq!(compilers(&on.calls[0]), (Some("ccache gcc-13"), Some("ccache g++-13")));

    let off = install(None);
    assert_eq!(off.calls.len(), 1, "{:?}", off.calls);
    assert_eq!(compilers(&off.calls[0]), (Some("gcc-13"), Some("g++-13")));
}

/// The launcher note lands in the per-build feature log — the file an
/// operator reads to see whether a slow build was cached — not only in
/// `tracing`. With no launcher, no note is written.
#[test]
fn launcher_note_is_written_to_the_feature_log() {
    let on = install(Some("ccache"));
    assert!(
        on.log.contains("compiler launcher: ccache (CC=`ccache gcc-13`, CXX=`ccache g++-13`)"),
        "feature log is missing the launcher note:\n{}",
        on.log
    );

    let off = install(None);
    assert!(!off.log.contains("compiler launcher"), "no launcher, no note:\n{}", off.log);
}

// ---- the CLI reading LUGGAGE_COMPILER_LAUNCHER -------------------------

fn catalog_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/fixtures-catalog")
}

/// `luggage install rust@1.95.0 --dry-run` with `LUGGAGE_COMPILER_LAUNCHER`
/// set to `value`, passed to the child only.
fn cli_install(value: &OsStr) -> Output {
    let workdir = TempDir::new().unwrap();
    let dir = workdir.path().to_str().unwrap();
    Command::new(env!("CARGO_BIN_EXE_luggage"))
        .args(["install", "rust@1.95.0", "--os", "debian", "--os-version", "13"])
        .args(["--arch", "amd64", "--dry-run", "--log-dir", dir, "--bin-root", dir])
        .args(["--cache-root", dir, "--tmp-root", dir])
        .arg("--catalog")
        .arg(catalog_dir())
        .env(LAUNCHER_ENV, value)
        .output()
        .expect("spawn luggage")
}

/// A valid launcher runs the dry-run to success; one that is malformed, or
/// not UTF-8 at all, aborts before any work and names the variable rather
/// than silently building uncached. The valid run is the control.
#[test]
fn cli_refuses_a_malformed_or_non_utf8_launcher() {
    let ok = cli_install(OsStr::new("ccache"));
    assert_eq!(
        ok.status.code(),
        Some(0),
        "a valid launcher must not abort: {}",
        String::from_utf8_lossy(&ok.stderr)
    );

    let non_utf8 = OsString::from_vec(b"cc\xffache".to_vec());
    for bad in [OsString::from("ccache;id"), non_utf8] {
        let out = cli_install(&bad);
        assert_ne!(out.status.code(), Some(0), "{LAUNCHER_ENV}={bad:?} must abort the install");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains(LAUNCHER_ENV), "{bad:?}: stderr: {stderr}");
        assert!(
            out.stdout.is_empty(),
            "{bad:?}: no plan may be printed: {}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}
