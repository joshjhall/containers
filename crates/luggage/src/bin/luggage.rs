//! `luggage` CLI binary.
//!
//! Single subcommand for now: `luggage resolve <tool> [...]`. The host
//! platform is auto-detected from `/etc/os-release` + `std::env::consts::ARCH`
//! when the relevant flags are missing.
//!
//! ## Error handling deviation
//!
//! Unlike stibbons (which uses `Box<dyn std::error::Error>`), this binary
//! propagates a typed [`luggage::LuggageError`] through `main` so it can
//! map specific variants to distinct exit codes via
//! [`luggage::LuggageError::exit_code`]. Bash callers can branch on
//! exit code `2` ("we will not install on this host") versus `1`
//! ("something else went wrong") without parsing stderr.

use std::io;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use luggage::{Catalog, CatalogSource, LuggageError, Platform, ResolvedInstall, VersionSpec};

/// Luggage — catalog loader and version/platform resolver.
#[derive(Parser, Debug)]
#[command(name = "luggage", version, about, long_about = None)]
struct Cli {
    /// Enable debug-level tracing output.
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Resolve `(tool, version, platform)` into a concrete install plan.
    Resolve(ResolveArgs),
}

#[derive(Args, Debug)]
struct ResolveArgs {
    /// Catalog tool id (e.g. `rust`, `node`).
    tool: String,

    /// Exact or partial version (e.g. `1.95.0`, `1.84`). Mutually exclusive with `--channel`.
    #[arg(long, conflicts_with = "channel")]
    version: Option<String>,

    /// Channel name (e.g. `stable`, `nightly`). Mutually exclusive with `--version`.
    #[arg(long)]
    channel: Option<String>,

    /// Override target OS (defaults to the value from `/etc/os-release`).
    #[arg(long)]
    os: Option<String>,

    /// Override target OS version (defaults to the value from `/etc/os-release`).
    #[arg(long)]
    os_version: Option<String>,

    /// Override target architecture (defaults to mapping `std::env::consts::ARCH`).
    #[arg(long)]
    arch: Option<String>,

    /// Path to a containers-db checkout (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    catalog: PathBuf,

    /// Emit JSON instead of human-readable output.
    #[arg(long)]
    json: bool,
}

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
    }
}

fn cmd_resolve(args: &ResolveArgs) -> Result<(), LuggageError> {
    if !args.catalog.is_dir() {
        return Err(LuggageError::Catalog(format!(
            "catalog path `{}` is not a directory; pass --catalog or set CONTAINERS_DB",
            args.catalog.display()
        )));
    }

    let catalog = Catalog::load(CatalogSource::LocalPath(args.catalog.clone()))?;
    let spec = build_spec(args.version.as_deref(), args.channel.as_deref());
    let platform = build_platform(args)?;

    let resolved = catalog.resolve(&args.tool, &spec, &platform)?;

    if args.json {
        let out = serde_json::to_string_pretty(&resolved)
            .map_err(|source| LuggageError::Parse { path: PathBuf::from("<stdout>"), source })?;
        println!("{out}");
    } else {
        print_human(&resolved);
    }
    Ok(())
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

fn build_platform(args: &ResolveArgs) -> Result<Platform, LuggageError> {
    let detected = detect_platform();

    let os = match (&args.os, &detected) {
        (Some(o), _) => o.clone(),
        (None, Ok(p)) => p.os.clone(),
        (None, Err(e)) => {
            return Err(LuggageError::PlatformDetectionFailed(format!(
                "no --os and auto-detect failed ({e}); pass --os <distro>",
            )));
        }
    };
    let os_version = args
        .os_version
        .clone()
        .or_else(|| detected.as_ref().ok().and_then(|p| p.os_version.clone()));
    let arch = match (&args.arch, &detected) {
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

fn print_human(r: &ResolvedInstall) {
    println!("{}@{} method={} tier={}", r.tool, r.version, r.method_name, r.verification_tier);
    println!(
        "  platform: {}/{}/{}",
        r.platform.os,
        r.platform.os_version.as_deref().unwrap_or("any"),
        r.platform.arch,
    );
    if let Some(url) = &r.source_url_template {
        println!("  source: {url}");
    }
    if let Some(invoke) = &r.invoke
        && let Some(args) = &invoke.args
    {
        println!("  invoke: {}", args.join(" "));
    }
    if let Some(deps) = &r.dependencies {
        let names: Vec<&str> = deps.iter().map(|d| d.tool.as_str()).collect();
        if !names.is_empty() {
            println!("  deps: {}", names.join(", "));
        }
    }
    if let Some(post) = &r.post_install
        && !post.is_empty()
    {
        println!("  post_install: {} step(s)", post.len());
    }
}

fn report_error(err: &LuggageError) {
    eprintln!("error: {err}");
    let mut source = std::error::Error::source(err);
    while let Some(s) = source {
        eprintln!("  caused by: {s}");
        source = s.source();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_default_is_latest() {
        assert_eq!(build_spec(None, None), VersionSpec::Latest);
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

    #[test]
    fn verify_cli() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
