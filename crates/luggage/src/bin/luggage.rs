//! `luggage` CLI binary.
//!
//! Subcommands: `resolve`, `install`, `reconcile`, and `catalog add-version`.
//! For `resolve`/`install` the host platform is auto-detected from
//! `/etc/os-release` + `std::env::consts::ARCH` when the relevant flags are
//! missing. `reconcile` cross-checks each version's `support_matrix` claims
//! against its `tested[]` evidence.
//!
//! ## Error handling deviation
//!
//! Unlike stibbons (which uses `Box<dyn std::error::Error>`), this binary
//! propagates a typed [`luggage::LuggageError`] through `main` so it can
//! map specific variants to distinct exit codes via
//! [`luggage::LuggageError::exit_code`]. Bash callers can branch on
//! exit code `2` ("we will not install on this host") versus `1`
//! ("something else went wrong") without parsing stderr.

use std::fs::File;
use std::io;
use std::io::{BufWriter, Write as _};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand, ValueEnum};
use containers_common::tooldb::ActivityScore;
use luggage::{
    AddOutcome, Catalog, CatalogSource, CellReport, CellStatus, InstallReport, Installer,
    InstallerOptions, LuggageError, Platform, PolicyPreset, ResolutionPolicy, ResolutionWarning,
    ResolvedInstall, VersionReconciliation, VersionSpec, add_version, reconcile_version,
};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

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
    /// Install a tool — download, verify, run installer, validate.
    Install(InstallArgs),
    /// Reconcile `support_matrix` claims against `tested[]` evidence.
    Reconcile(ReconcileArgs),
    /// Catalog maintenance (write-side helpers for the vendored catalog).
    Catalog {
        #[command(subcommand)]
        command: CatalogCommand,
    },
}

#[derive(Subcommand, Debug)]
enum CatalogCommand {
    /// Add a tool version by cloning the latest existing version entry.
    ///
    /// Used by the version-bump pipeline to keep the vendored catalog in
    /// lockstep with a Dockerfile pin. Additive and idempotent: a version
    /// already present is a no-op, and `default_version` is never changed.
    AddVersion(CatalogAddVersionArgs),
}

/// `luggage catalog add-version <tool>@<version>` arguments.
#[derive(Args, Debug)]
struct CatalogAddVersionArgs {
    /// Catalog tool id with a required `@<version>` suffix (e.g. `rust@1.96.0`).
    tool: String,

    /// Path to the catalog root (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    catalog: PathBuf,

    /// Upstream release date `YYYY-MM-DD` (defaults to today, UTC).
    #[arg(long)]
    released: Option<String>,
}

#[derive(Args, Debug)]
struct ResolveArgs {
    /// Catalog tool id (e.g. `rust`, `node`).
    tool: String,

    #[command(flatten)]
    common: CommonArgs,

    /// Emit JSON instead of human-readable output.
    #[arg(long)]
    json: bool,
}

/// CLI fields shared by `resolve` and `install`.
#[derive(Args, Debug)]
struct CommonArgs {
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

    /// Named policy preset to start from. Defaults to `stibbons`.
    #[arg(long, value_enum)]
    policy: Option<PolicyChoice>,

    /// Allow tools whose activity tier is `dormant` or `abandoned`. Lowers
    /// `min_activity` to `Abandoned` regardless of preset.
    #[arg(long)]
    allow_abandoned: bool,

    /// Allow versions below the tool's `minimum_recommended` (emits a
    /// warning instead of refusing).
    #[arg(long)]
    allow_below_min_recommended: bool,
}

/// `luggage install <tool>[@<version>]` arguments.
#[derive(Args, Debug)]
struct InstallArgs {
    /// Catalog tool id with an optional `@<version>` suffix
    /// (e.g. `rust`, `rust@1.95.0`, `node@22`).
    tool: String,

    #[command(flatten)]
    common: CommonArgs,

    /// Print the substituted install plan as JSON without performing I/O.
    #[arg(long)]
    dry_run: bool,

    /// Reinstall even when the idempotency check thinks the tool is current.
    #[arg(long)]
    force: bool,

    /// Per-feature log directory.
    #[arg(long, default_value = "/var/log/luggage")]
    log_dir: PathBuf,

    /// Where the installer symlinks tool binaries.
    #[arg(long, default_value = "/usr/local/bin")]
    bin_root: PathBuf,

    /// Cache root for tool data (`CARGO_HOME` and `RUSTUP_HOME` live under here).
    #[arg(long, default_value = "/cache")]
    cache_root: PathBuf,

    /// Scratch directory for downloads.
    #[arg(long, default_value = "/tmp")]
    tmp_root: PathBuf,

    /// Override the install user (defaults to `$USERNAME`, then `vscode`,
    /// then `root` if the resolved user doesn't exist on the system).
    #[arg(long)]
    user: Option<String>,

    /// Skip system-package installation. Use when the host package
    /// manager is unavailable or already pre-populated.
    #[arg(long)]
    skip_system_packages: bool,

    /// Write a JSON [`InstallReport`] to this path. Emitted on every
    /// exit path — success, skip, dry-run, or failure — so evidence-run
    /// CI can record a row even when the install itself failed.
    #[arg(long, value_name = "PATH")]
    json_report: Option<PathBuf>,
}

/// CLI mirror of [`luggage::PolicyPreset`].
#[derive(Copy, Clone, Debug, Eq, PartialEq, ValueEnum)]
#[clap(rename_all = "lowercase")]
enum PolicyChoice {
    /// Stibbons defaults: refuse below-Maintained, refuse below-min, warn on slow/stale.
    Stibbons,
    /// Igor defaults: accept down to Stale, allow below-min.
    Igor,
    /// Permissive: accept any tier.
    Permissive,
}

impl From<PolicyChoice> for PolicyPreset {
    fn from(value: PolicyChoice) -> Self {
        match value {
            PolicyChoice::Stibbons => Self::Stibbons,
            PolicyChoice::Igor => Self::Igor,
            PolicyChoice::Permissive => Self::Permissive,
        }
    }
}

/// `luggage reconcile [TOOL[@VERSION]]` arguments.
#[derive(Args, Debug)]
struct ReconcileArgs {
    /// Catalog target. Omit to reconcile every tool/version; pass a tool id
    /// (`rust`) for all its versions, or `tool@version` (`rust@1.96.0`) for
    /// a single version.
    target: Option<String>,

    /// Path to a containers-db checkout (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    catalog: PathBuf,

    /// Exit non-zero when any `supported` cell lacks a passing evidence row,
    /// or an `unsupported` cell has one. Use this in CI to block a catalog PR
    /// that claims support it cannot back.
    #[arg(long)]
    gate: bool,

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

/// `luggage catalog add-version <tool>@<version>` — clone the latest existing
/// version entry into a new one and list it in `available[]`.
fn cmd_catalog_add_version(args: &CatalogAddVersionArgs) -> Result<(), LuggageError> {
    let (tool, inline_version) = split_tool_version(&args.tool);
    let version = inline_version.ok_or_else(|| {
        LuggageError::Catalog("specify the version as `tool@version` (e.g. `rust@1.96.0`)".into())
    })?;

    let now = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|e| LuggageError::Catalog(format!("could not format current time: {e}")))?;

    match add_version(&args.catalog, tool, version, args.released.as_deref(), &now)? {
        AddOutcome::AlreadyPresent => {
            println!(
                "{tool}@{version} already present in {}; nothing to do",
                args.catalog.display()
            );
        }
        AddOutcome::Added { template_version, version_path, index_path } => {
            println!("added {tool}@{version} (templated from {tool}@{template_version})");
            println!("  wrote   {}", version_path.display());
            println!("  updated {}", index_path.display());
        }
    }
    Ok(())
}

fn cmd_resolve(args: &ResolveArgs) -> Result<(), LuggageError> {
    let resolved = resolve_for(&args.tool, &args.common)?;
    if args.json {
        let out = serde_json::to_string_pretty(&resolved)
            .map_err(|source| LuggageError::Parse { path: PathBuf::from("<stdout>"), source })?;
        println!("{out}");
    } else {
        print_human(&resolved);
        report_warnings(&resolved.warnings);
    }
    Ok(())
}

fn cmd_install(args: &InstallArgs) -> Result<(), LuggageError> {
    // Accept `tool@version` shorthand. Conflict with `--version` is an error.
    let (tool_id, inline_version) = split_tool_version(&args.tool);
    if inline_version.is_some() && args.common.version.is_some() {
        return Err(LuggageError::Catalog(
            "specify the version once: either `tool@version` or `--version`, not both".into(),
        ));
    }
    let common = inline_version.map_or_else(
        || clone_common(&args.common),
        |v| {
            let mut c = clone_common(&args.common);
            c.version = Some(v.to_owned());
            c
        },
    );
    let resolved = resolve_for(tool_id, &common)?;
    report_warnings(&resolved.warnings);

    let opts = InstallerOptions {
        dry_run: args.dry_run,
        force: args.force,
        log_dir: args.log_dir.clone(),
        bin_root: args.bin_root.clone(),
        cache_root: args.cache_root.clone(),
        tmp_root: args.tmp_root.clone(),
        user_override: args.user.clone(),
        install_system_packages: !args.skip_system_packages,
    };
    let installer = Installer::with_options(opts);

    // Dry-run emits the plan to stdout for human inspection. Done before
    // run_with_report so we can short-circuit without spinning up the
    // log directory; run_with_report still produces a report for the
    // --json-report file via the dry-run branch.
    if args.dry_run {
        let plan = installer.plan(&resolved)?;
        let out = serde_json::to_string_pretty(&plan)
            .map_err(|source| LuggageError::Parse { path: PathBuf::from("<stdout>"), source })?;
        println!("{out}");
    }

    let (report, result) = installer.run_with_report(&resolved);

    if let Some(path) = &args.json_report {
        write_json_report(path, &report)?;
    }

    // On success, surface the same human-readable lines the previous
    // implementation printed. On failure, the caller (main) prints the
    // error after we return Err — leave stdout to the report.
    if result.is_ok() && !args.dry_run {
        if report.already_installed {
            println!("{}@{} already installed", report.tool, report.version);
        } else {
            println!("installed {}@{}", report.tool, report.version);
        }
        if let Some(p) = &report.log_path {
            println!("  log: {}", p.display());
        }
    }
    result
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

/// `luggage reconcile [TOOL[@VERSION]]` — cross-check `support_matrix`
/// claims against `tested[]` evidence.
///
/// Returns `Ok(true)` when nothing failed the gate (always the case in report
/// mode), `Ok(false)` when `--gate` found at least one uncovered `supported`
/// cell or a contradicting `unsupported` row.
fn cmd_reconcile(args: &ReconcileArgs) -> Result<bool, LuggageError> {
    if !args.catalog.is_dir() {
        return Err(LuggageError::Catalog(format!(
            "catalog path `{}` is not a directory; pass --catalog or set CONTAINERS_DB",
            args.catalog.display()
        )));
    }
    let catalog = Catalog::load(CatalogSource::LocalPath(args.catalog.clone()))?;
    let reports = collect_reconciliations(&catalog, args.target.as_deref())?;

    if args.json {
        let out = serde_json::to_string_pretty(&reports)
            .map_err(|source| LuggageError::Parse { path: PathBuf::from("<stdout>"), source })?;
        println!("{out}");
    } else {
        print_reconciliations(&reports);
    }

    let total_failures: usize = reports.iter().map(VersionReconciliation::gate_failures).sum();
    if args.gate && total_failures > 0 {
        eprintln!(
            "gate: {total_failures} uncovered or contradicted cell(s) across {} version(s)",
            reports.iter().filter(|r| !r.is_clean()).count()
        );
        return Ok(false);
    }
    Ok(true)
}

/// Build the list of [`VersionReconciliation`]s for the requested target.
///
/// Target selection mirrors `install`'s `tool@version` shorthand:
/// `None` → every tool/version, `Some("rust")` → all versions of rust,
/// `Some("rust@1.96.0")` → that single version.
fn collect_reconciliations(
    catalog: &Catalog,
    target: Option<&str>,
) -> Result<Vec<VersionReconciliation>, LuggageError> {
    let mut out = Vec::new();
    match target {
        None => {
            for id in catalog.tool_ids() {
                push_tool_versions(catalog, id, None, &mut out)?;
            }
        }
        Some(t) => {
            let (tool, version) = split_tool_version(t);
            push_tool_versions(catalog, tool, version, &mut out)?;
        }
    }
    Ok(out)
}

/// Append reconciliations for one tool. When `version` is `Some`, only that
/// exact version literal is emitted (and a miss is an error); otherwise every
/// version of the tool is included in catalog (version) order.
fn push_tool_versions(
    catalog: &Catalog,
    tool: &str,
    version: Option<&str>,
    out: &mut Vec<VersionReconciliation>,
) -> Result<(), LuggageError> {
    let entry = catalog.tool_entry(tool).ok_or_else(|| LuggageError::ToolNotFound(tool.into()))?;
    match version {
        None => {
            for doc in entry.versions.values() {
                out.push(reconcile_version(doc));
            }
        }
        Some(v) => {
            let doc = entry.versions.values().find(|d| d.version == v).ok_or_else(|| {
                LuggageError::VersionNotFound { tool: tool.into(), spec: v.into() }
            })?;
            out.push(reconcile_version(doc));
        }
    }
    Ok(())
}

/// Print a human-readable coverage report: one block per version, one line
/// per support cell, plus a trailing summary.
fn print_reconciliations(reports: &[VersionReconciliation]) {
    let mut total_cells = 0usize;
    let mut total_failures = 0usize;
    for r in reports {
        println!("{}@{}", r.tool, r.version);
        for cell in &r.cells {
            let osv = cell.os_version.as_deref().unwrap_or("*");
            let coord = format!("{}/{}/{}", cell.os, osv, cell.arch);
            let (mark, detail) = describe_cell(&cell.status);
            println!("  {mark} {coord:<24} claimed={:<11} {detail}", status_word(cell));
            total_cells += 1;
        }
        total_failures += r.gate_failures();
    }
    println!(
        "\nsummary: {} version(s), {total_cells} cell(s), {total_failures} gate failure(s)",
        reports.len()
    );
}

/// Lowercase wire word for the claimed status, for the report's `claimed=` column.
const fn status_word(cell: &CellReport) -> &'static str {
    use containers_common::tooldb::SupportStatus;
    match cell.claimed {
        SupportStatus::Supported => "supported",
        SupportStatus::Unsupported => "unsupported",
        SupportStatus::Untested => "untested",
    }
}

/// Map a [`CellStatus`] to a status glyph and a human detail string.
fn describe_cell(status: &CellStatus) -> (&'static str, String) {
    match status {
        CellStatus::Covered { tested_at, .. } => ("OK ", format!("covered (tested {tested_at})")),
        CellStatus::Uncovered => ("MISS", "no passing evidence row".to_string()),
        CellStatus::Contradiction { tested_at } => {
            ("BAD ", format!("CONTRADICTION: passing row exists (tested {tested_at})"))
        }
        CellStatus::Promotable { tested_at } => {
            ("INFO", format!("promotable: passing row exists (tested {tested_at})"))
        }
        CellStatus::NoEvidenceNeeded => ("-  ", "no evidence required".to_string()),
    }
}

/// Split a `tool[@version]` string into `(tool, Option<version>)`.
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

fn report_warnings(warnings: &[ResolutionWarning]) {
    for w in warnings {
        match w {
            ResolutionWarning::SlowOrStaleActivity { score } => {
                eprintln!(
                    "warning: tool activity is `{score:?}` — pinning is fine but expect fewer upstream releases"
                );
            }
            ResolutionWarning::BelowMinimumRecommended { version, minimum } => {
                eprintln!(
                    "warning: resolved version `{version}` is below `minimum_recommended` `{minimum}`",
                );
            }
        }
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
