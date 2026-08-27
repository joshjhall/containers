//! Subcommand handlers for the `luggage` CLI.
//!
//! Each `cmd_*` function is the body of one subcommand; `main` maps their
//! results onto exit codes. The shared plumbing they call — `resolve_for`,
//! the `build_*` helpers — lives in `main`, and output formatting in
//! [`crate::render`].

use std::path::PathBuf;

use luggage::{
    AddOutcome, Catalog, CatalogSource, Installer, InstallerOptions, LuggageError,
    VersionReconciliation, add_version, reconcile_version,
};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::cli::{CatalogAddVersionArgs, InstallArgs, ReconcileArgs, ResolveArgs};
use crate::render::{print_human, print_reconciliations, report_warnings};
use crate::{
    clone_common, require_verified_downloads_from_env, resolve_for, split_tool_version,
    write_json_report,
};

/// `luggage catalog add-version <tool>@<version>` — clone the latest existing
/// version entry into a new one and list it in `available[]`.
pub fn cmd_catalog_add_version(args: &CatalogAddVersionArgs) -> Result<(), LuggageError> {
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

pub fn cmd_resolve(args: &ResolveArgs) -> Result<(), LuggageError> {
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

pub fn cmd_install(args: &InstallArgs) -> Result<(), LuggageError> {
    // Accept `tool@version` shorthand. Conflict with `--version` is an error.
    let (tool_id, inline_version) = split_tool_version(&args.tool);
    if inline_version.is_some() && args.common.version.is_some() {
        return Err(LuggageError::Catalog(
            "specify the version once: either `tool@version` or `--version`, not both".into(),
        ));
    }
    // ...and with `--channel` likewise. clap's `conflicts_with = "channel"` on
    // `--version` cannot catch this: the inline version is parsed by hand, out
    // of clap's sight. Without this guard `build_spec` silently prefers the
    // channel and the pinned version is discarded with no error — the user
    // asked for an exact version and would get whatever the channel resolves
    // to instead.
    if inline_version.is_some() && args.common.channel.is_some() {
        return Err(LuggageError::Catalog(
            "specify the version once: either `tool@version` or `--channel`, not both".into(),
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
        // Capturing dependency versions only matters for the evidence row,
        // which is the JSON report's sole consumer — so tie it to that flag.
        record_dependency_versions: args.json_report.is_some(),
        fail_on_unknown_deps: !args.allow_unknown_deps,
        require_verified_downloads: args.require_verified_downloads
            || require_verified_downloads_from_env(),
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

/// `luggage reconcile [TOOL[@VERSION]]` — cross-check `support_matrix`
/// claims against `tested[]` evidence.
///
/// Returns `Ok(true)` when nothing failed the gate (always the case in report
/// mode), `Ok(false)` when `--gate` found at least one uncovered `supported`
/// cell or a contradicting `unsupported` row.
pub fn cmd_reconcile(args: &ReconcileArgs) -> Result<bool, LuggageError> {
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
