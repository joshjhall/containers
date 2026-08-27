//! `luggage` CLI binary.
//!
//! Subcommands: `resolve`, `install`, `reconcile`, and `catalog add-version`.
//! For `resolve`/`install` the host platform is auto-detected from
//! `/etc/os-release` + `std::env::consts::ARCH` when the relevant flags are
//! missing. `reconcile` cross-checks each version's `support_matrix` claims
//! against its `tested[]` evidence.
//!
//! ## Layout
//!
//! [`cli`] holds the `clap` argument types, [`commands`] the four subcommand
//! handlers, and [`render`] the human-readable output. This module keeps
//! `main` itself plus the plumbing both `resolve` and `install` share —
//! [`resolve_for`] and the `build_*` helpers — so flag semantics stay in one
//! place.
//!
//! ## Error handling deviation
//!
//! Unlike stibbons (which uses `Box<dyn std::error::Error>`), this binary
//! propagates a typed [`luggage::LuggageError`] through `main` so it can
//! map specific variants to distinct exit codes via
//! [`luggage::LuggageError::exit_code`]. Bash callers can branch on
//! exit code `2` ("we will not install on this host") versus `1`
//! ("something else went wrong") without parsing stderr.

mod cli;
mod commands;
mod render;

use std::fs::File;
use std::io;
use std::io::{BufWriter, Write as _};
use std::path::Path;
use std::process::ExitCode;

use clap::Parser;
use containers_common::tooldb::ActivityScore;
use luggage::{
    Catalog, CatalogSource, InstallReport, LuggageError, Platform, PolicyPreset, ResolutionPolicy,
    ResolvedInstall, VersionSpec,
};

use crate::cli::{CatalogCommand, Cli, Commands, CommonArgs};
use crate::commands::{cmd_catalog_add_version, cmd_install, cmd_reconcile, cmd_resolve};
use crate::render::report_error;

fn main() -> ExitCode {
    let cli = Cli::parse();

    let filter = if cli.verbose { "debug" } else { "info" };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(filter)),
        )
        .with_writer(io::stderr)
        .init();

    match cli.command {
        Commands::Resolve(args) => match cmd_resolve(&args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                report_error(&e);
                ExitCode::from(u8::try_from(e.exit_code()).unwrap_or(1))
            }
        },
        Commands::Install(args) => match cmd_install(&args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                report_error(&e);
                ExitCode::from(u8::try_from(e.exit_code()).unwrap_or(1))
            }
        },
        Commands::Reconcile(args) => match cmd_reconcile(&args) {
            // `Ok(true)` = clean (or report mode); `Ok(false)` = gate found
            // failures, which is a non-error non-zero exit so CI can branch.
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::from(1),
            Err(e) => {
                report_error(&e);
                ExitCode::from(u8::try_from(e.exit_code()).unwrap_or(1))
            }
        },
        Commands::Catalog { command } => {
            let CatalogCommand::AddVersion(args) = command;
            match cmd_catalog_add_version(&args) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    report_error(&e);
                    ExitCode::from(u8::try_from(e.exit_code()).unwrap_or(1))
                }
            }
        }
    }
}

/// `true` when the environment asks for strict verification.
///
/// Reads the same two variables, with the same precedence, as
/// `lib/base/checksum-verification.sh`. See [`parse_require_verified`] for the
/// rule and why it is not simply "is `REQUIRE_VERIFIED_DOWNLOADS` set".
fn require_verified_downloads_from_env() -> bool {
    parse_require_verified(
        std::env::var("REQUIRE_VERIFIED_DOWNLOADS").ok().as_deref(),
        std::env::var("PRODUCTION_MODE").ok().as_deref(),
    )
}

/// The value half of [`require_verified_downloads_from_env`], split out so it
/// is testable without mutating process-wide environment state (which would
/// race the rest of the test binary).
///
/// The rule mirrors `lib/base/checksum-verification.sh` exactly, because a
/// security control that refuses TOFU under the bash build but accepts it
/// under luggage would be a silent downgrade for anyone mid-migration:
///
/// - An explicit `REQUIRE_VERIFIED_DOWNLOADS` of `true` or `false` decides it.
/// - Anything else — unset, empty, or an unrecognized value — falls back to
///   `PRODUCTION_MODE` (itself defaulting to `false`). This is the documented
///   contract in `docs/reference/environment-variables.md`: *"defaults to
///   `PRODUCTION_MODE`"*.
///
/// Values are compared case-insensitively after trimming. Note what this
/// deliberately is *not*: presence-based. Build environments routinely export
/// the variable empty, and treating that as consent would start refusing TOFU
/// installs that worked yesterday with nobody having asked for it.
fn parse_require_verified(require_verified: Option<&str>, production_mode: Option<&str>) -> bool {
    match require_verified.map(str::trim) {
        Some(v) if v.eq_ignore_ascii_case("true") => true,
        Some(v) if v.eq_ignore_ascii_case("false") => false,
        // Unset, empty, or unrecognized — defer to PRODUCTION_MODE.
        _ => production_mode.is_some_and(|v| v.trim().eq_ignore_ascii_case("true")),
    }
}

/// Write `report` to `path` as pretty JSON, returning a typed error on
/// I/O or serialization failure so the CLI's error reporter handles it.
fn write_json_report(path: &Path, report: &InstallReport) -> Result<(), LuggageError> {
    let file = File::create(path)
        .map_err(|source| LuggageError::Io { path: path.to_path_buf(), source })?;
    let mut writer = BufWriter::new(file);
    serde_json::to_writer_pretty(&mut writer, report)
        .map_err(|source| LuggageError::Parse { path: path.to_path_buf(), source })?;
    // Trailing newline so the file plays nicely with line-oriented tools.
    writer
        .write_all(b"\n")
        .map_err(|source| LuggageError::Io { path: path.to_path_buf(), source })?;
    writer.flush().map_err(|source| LuggageError::Io { path: path.to_path_buf(), source })?;
    Ok(())
}

/// Resolve `(tool, common)` into a [`ResolvedInstall`]. Shared by both
/// subcommands so flag semantics stay in lockstep.
fn resolve_for(tool: &str, common: &CommonArgs) -> Result<ResolvedInstall, LuggageError> {
    if !common.catalog.is_dir() {
        return Err(LuggageError::Catalog(format!(
            "catalog path `{}` is not a directory; pass --catalog or set CONTAINERS_DB",
            common.catalog.display()
        )));
    }
    let catalog = Catalog::load(CatalogSource::LocalPath(common.catalog.clone()))?;
    let spec = build_spec(common.version.as_deref(), common.channel.as_deref());
    let platform = build_platform(common)?;
    let policy = build_policy(common);
    catalog.resolve_with_policy(tool, &spec, &platform, &policy)
}

fn split_tool_version(s: &str) -> (&str, Option<&str>) {
    s.split_once('@').map_or((s, None), |(t, v)| (t, Some(v)))
}

fn clone_common(c: &CommonArgs) -> CommonArgs {
    CommonArgs {
        version: c.version.clone(),
        channel: c.channel.clone(),
        os: c.os.clone(),
        os_version: c.os_version.clone(),
        arch: c.arch.clone(),
        catalog: c.catalog.clone(),
        policy: c.policy,
        allow_abandoned: c.allow_abandoned,
        allow_below_min_recommended: c.allow_below_min_recommended,
    }
}

/// Build the policy from CLI flags. Precedence:
///
/// 1. `--policy <name>` (or [`ResolutionPolicy::default()`] when absent)
/// 2. `--allow-abandoned` lowers `min_activity` to `Abandoned`
/// 3. `--allow-below-min-recommended` flips the bool on
fn build_policy(common: &CommonArgs) -> ResolutionPolicy {
    let mut policy = common.policy.map_or_else(ResolutionPolicy::default, |choice| {
        ResolutionPolicy::from_preset(PolicyPreset::from(choice))
    });
    if common.allow_abandoned {
        policy.min_activity = ActivityScore::Abandoned;
    }
    if common.allow_below_min_recommended {
        policy.allow_below_min_recommended = true;
    }
    policy
}

/// Pick a [`VersionSpec`] from the CLI flags.
///
/// `--channel` always wins over `--version` (clap also rejects passing
/// both). `--version` with two or more dots is treated as exact; with
/// fewer dots it becomes [`VersionSpec::Partial`]. With neither flag we
/// default to [`VersionSpec::Latest`].
fn build_spec(version: Option<&str>, channel: Option<&str>) -> VersionSpec {
    if let Some(c) = channel {
        return VersionSpec::Channel(c.to_owned());
    }
    match version {
        None => VersionSpec::Latest,
        Some(v) if v.matches('.').count() >= 2 => VersionSpec::Exact(v.to_owned()),
        Some(v) => VersionSpec::Partial(v.to_owned()),
    }
}

fn build_platform(common: &CommonArgs) -> Result<Platform, LuggageError> {
    let detected = detect_platform();

    let os = match (&common.os, &detected) {
        (Some(o), _) => o.clone(),
        (None, Ok(p)) => p.os.clone(),
        (None, Err(e)) => {
            return Err(LuggageError::PlatformDetectionFailed(format!(
                "no --os and auto-detect failed ({e}); pass --os <distro>",
            )));
        }
    };
    let os_version = common
        .os_version
        .clone()
        .or_else(|| detected.as_ref().ok().and_then(|p| p.os_version.clone()));
    let arch = match (&common.arch, &detected) {
        (Some(a), _) => a.clone(),
        (None, Ok(p)) => p.arch.clone(),
        (None, Err(_)) => translate_arch(std::env::consts::ARCH).to_owned(),
    };

    Ok(Platform { os, os_version, arch })
}

/// Read `/etc/os-release` and translate `std::env::consts::ARCH` into the
/// catalog's vocabulary (`x86_64`→`amd64`, `aarch64`→`arm64`, …).
fn detect_platform() -> Result<Platform, String> {
    let raw = std::fs::read_to_string("/etc/os-release")
        .map_err(|e| format!("read /etc/os-release: {e}"))?;
    let mut id = None;
    let mut version_id = None;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("ID=") {
            id = Some(strip_quotes(rest).to_owned());
        } else if let Some(rest) = line.strip_prefix("VERSION_ID=") {
            version_id = Some(strip_quotes(rest).to_owned());
        }
    }
    let os = id.ok_or_else(|| "/etc/os-release missing ID=".to_string())?;
    let arch = translate_arch(std::env::consts::ARCH).to_owned();
    Ok(Platform { os, os_version: version_id, arch })
}

fn strip_quotes(s: &str) -> &str {
    let s = s.trim();
    s.strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .or_else(|| s.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
        .unwrap_or(s)
}

const fn translate_arch(arch: &str) -> &str {
    match arch.as_bytes() {
        b"x86_64" => "amd64",
        b"aarch64" => "arm64",
        _ => arch,
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::cli::PolicyChoice;

    #[test]
    fn spec_default_is_latest() {
        assert_eq!(build_spec(None, None), VersionSpec::Latest);
    }

    /// The env var is opt-IN by value, never by presence. Build environments
    /// commonly export it empty; treating that as consent would start
    /// refusing TOFU installs that worked yesterday, with no one having asked
    /// for it.
    #[test]
    fn require_verified_env_is_opt_in_by_value_not_presence() {
        assert!(parse_require_verified(Some("true"), None));
        assert!(parse_require_verified(Some("TRUE"), None));
        assert!(parse_require_verified(Some(" true "), None));

        assert!(!parse_require_verified(None, None), "unset");
        assert!(!parse_require_verified(Some(""), None), "set-but-empty");
        assert!(!parse_require_verified(Some("false"), None));
        assert!(
            !parse_require_verified(Some("1"), None),
            "bash compares against `true`, not truthiness"
        );
    }

    /// Parity with `lib/base/checksum-verification.sh`: when
    /// `REQUIRE_VERIFIED_DOWNLOADS` is not an explicit true/false, the
    /// decision defers to `PRODUCTION_MODE`. Without this, a production build
    /// that only sets `PRODUCTION_MODE=true` would refuse TOFU under the bash
    /// build but silently accept it under luggage — a downgrade of a security
    /// control, invisible at the point it matters.
    #[test]
    fn production_mode_is_the_fallback_when_require_verified_is_not_explicit() {
        for unset_ish in [None, Some(""), Some("   "), Some("yes")] {
            assert!(
                parse_require_verified(unset_ish, Some("true")),
                "PRODUCTION_MODE=true should decide when rvd={unset_ish:?}"
            );
            assert!(
                !parse_require_verified(unset_ish, Some("false")),
                "PRODUCTION_MODE=false should decide when rvd={unset_ish:?}"
            );
            assert!(
                !parse_require_verified(unset_ish, None),
                "PRODUCTION_MODE unset defaults false when rvd={unset_ish:?}"
            );
        }
    }

    /// An explicit value wins over the fallback in both directions — notably
    /// `REQUIRE_VERIFIED_DOWNLOADS=false` must be able to opt a production
    /// build back out, exactly as the bash `!= "true" && != "false"` guard
    /// allows.
    #[test]
    fn explicit_require_verified_overrides_production_mode() {
        assert!(parse_require_verified(Some("true"), Some("false")));
        assert!(!parse_require_verified(Some("false"), Some("true")));
    }

    #[test]
    fn spec_channel_wins_over_version() {
        // clap also enforces conflicts_with at the parser layer; this is the runtime fallback.
        let s = build_spec(Some("1.0.0"), Some("nightly"));
        assert_eq!(s, VersionSpec::Channel("nightly".into()));
    }

    #[test]
    fn spec_partial_one_dot() {
        assert_eq!(build_spec(Some("1.84"), None), VersionSpec::Partial("1.84".into()));
    }

    #[test]
    fn spec_partial_zero_dots() {
        assert_eq!(build_spec(Some("1"), None), VersionSpec::Partial("1".into()));
    }

    #[test]
    fn spec_exact_two_dots() {
        assert_eq!(build_spec(Some("1.84.1"), None), VersionSpec::Exact("1.84.1".into()));
    }

    #[test]
    fn translate_arch_known() {
        assert_eq!(translate_arch("x86_64"), "amd64");
        assert_eq!(translate_arch("aarch64"), "arm64");
        assert_eq!(translate_arch("riscv64"), "riscv64");
    }

    #[test]
    fn strip_quotes_handles_double_and_single() {
        assert_eq!(strip_quotes("\"debian\""), "debian");
        assert_eq!(strip_quotes("'debian'"), "debian");
        assert_eq!(strip_quotes("debian"), "debian");
    }

    fn common_with(
        policy: Option<PolicyChoice>,
        allow_abandoned: bool,
        below_min: bool,
    ) -> CommonArgs {
        CommonArgs {
            version: None,
            channel: None,
            os: None,
            os_version: None,
            arch: None,
            catalog: PathBuf::from("/tmp"),
            policy,
            allow_abandoned,
            allow_below_min_recommended: below_min,
        }
    }

    #[test]
    fn build_policy_defaults_to_stibbons() {
        let p = build_policy(&common_with(None, false, false));
        assert_eq!(p, ResolutionPolicy::stibbons());
    }

    #[test]
    fn build_policy_uses_chosen_preset() {
        let p = build_policy(&common_with(Some(PolicyChoice::Permissive), false, false));
        assert_eq!(p, ResolutionPolicy::permissive());
        let p = build_policy(&common_with(Some(PolicyChoice::Igor), false, false));
        assert_eq!(p, ResolutionPolicy::igor());
    }

    #[test]
    fn build_policy_allow_abandoned_overrides_min_activity() {
        let p = build_policy(&common_with(Some(PolicyChoice::Stibbons), true, false));
        assert_eq!(p.min_activity, ActivityScore::Abandoned);
        // Other fields preserved from preset.
        assert!(!p.allow_below_min_recommended);
        assert!(p.warn_on_slow_or_stale);
    }

    #[test]
    fn build_policy_allow_below_min_overrides_bool() {
        let p = build_policy(&common_with(None, false, true));
        assert!(p.allow_below_min_recommended);
        assert_eq!(p.min_activity, ActivityScore::Maintained);
    }

    #[test]
    fn split_tool_version_handles_bare_tool() {
        assert_eq!(split_tool_version("rust"), ("rust", None));
    }

    #[test]
    fn split_tool_version_handles_at_suffix() {
        assert_eq!(split_tool_version("rust@1.95.0"), ("rust", Some("1.95.0")));
    }

    #[test]
    fn split_tool_version_handles_partial_suffix() {
        assert_eq!(split_tool_version("rust@1.84"), ("rust", Some("1.84")));
    }
}
