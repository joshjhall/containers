//! Human-readable output formatting for the `luggage` CLI.
//!
//! Everything here writes to stdout/stderr and returns nothing — the JSON
//! output paths live in the command handlers, which serialize directly.

use luggage::{
    CellReport, CellStatus, EvidenceOrigin, LuggageError, ResolutionWarning, ResolvedInstall,
    VersionReconciliation,
};

/// per support cell, plus a trailing summary.
pub fn print_reconciliations(reports: &[VersionReconciliation]) {
    let mut total_cells = 0usize;
    let mut total_failures = 0usize;
    let mut total_stale = 0usize;
    for r in reports {
        println!("{}@{}  evidence: {}", r.tool, r.version, describe_origin(&r.evidence));
        for cell in &r.cells {
            let osv = cell.os_version.as_deref().unwrap_or("*");
            let coord = format!("{}/{}/{}", cell.os, osv, cell.arch);
            let (mark, detail) = describe_cell(&cell.status);
            println!("  {mark} {coord:<24} claimed={:<11} {detail}", status_word(cell));
            total_cells += 1;
        }
        total_failures += r.gate_failures();
        total_stale += r.stale_warnings();
    }
    println!(
        "\nsummary: {} version(s), {total_cells} cell(s), {total_failures} gate failure(s), \
         {total_stale} stale-evidence warning(s)",
        reports.len()
    );
}

/// Short label for where a version's evidence came from.
fn describe_origin(origin: &EvidenceOrigin) -> String {
    match origin {
        EvidenceOrigin::Published => "published".to_string(),
        EvidenceOrigin::NotPublished => "local (not yet published)".to_string(),
        EvidenceOrigin::Fallback { newest_tested_at: Some(t), .. } => {
            format!("local fallback, possibly stale (newest {t})")
        }
        EvidenceOrigin::Fallback { newest_tested_at: None, .. } => {
            "local fallback, possibly stale (no evidence rows)".to_string()
        }
    }
}

/// One stderr warning per version judged against fallback evidence that has
/// findings: they would have failed the gate, and may be stale rather than
/// real. Printed in JSON mode too, where stdout carries the report.
pub fn report_stale_evidence(reports: &[VersionReconciliation]) {
    for r in reports {
        let n = r.stale_warnings();
        if n == 0 {
            continue;
        }
        if let EvidenceOrigin::Fallback { reason, newest_tested_at } = &r.evidence {
            let newest = newest_tested_at.as_deref().unwrap_or("none recorded");
            eprintln!(
                "warning: {}@{}: {n} uncovered or contradicted cell(s) judged against possibly \
                 stale local evidence (newest tested_at: {newest}); published evidence \
                 unavailable: {reason}. Not counted as gate failures.",
                r.tool, r.version
            );
        }
    }
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
