//! Human-readable output formatting for the `luggage` CLI.
//!
//! Everything here writes to stdout/stderr and returns nothing — the JSON
//! output paths live in the command handlers, which serialize directly.

use luggage::{
    CellReport, CellStatus, LuggageError, ResolutionWarning, ResolvedInstall, VersionReconciliation,
};

/// per support cell, plus a trailing summary.
pub fn print_reconciliations(reports: &[VersionReconciliation]) {
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

pub fn print_human(r: &ResolvedInstall) {
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

pub fn report_error(err: &LuggageError) {
    eprintln!("error: {err}");
    let mut source = std::error::Error::source(err);
    while let Some(s) = source {
        eprintln!("  caused by: {s}");
        source = s.source();
    }
}

pub fn report_warnings(warnings: &[ResolutionWarning]) {
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
