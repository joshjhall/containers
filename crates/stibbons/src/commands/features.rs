//! `stibbons features` — list all available container features.
//!
//! Ported from the Go `igor features` command. Features are grouped by
//! [`Category`] in a fixed display order and rendered either as an aligned
//! text table (default) or as markdown. Output goes to a caller-supplied sink
//! so tests can capture it.

use std::error::Error;
use std::fmt::Write as _;
use std::io::Write;

use containers_common::feature::{Category, Feature, Registry};

/// The categories to display, in order, with their section labels. Matches the
/// Go `categoryOrder` exactly.
const CATEGORY_ORDER: &[(Category, &str)] = &[
    (Category::Language, "Languages"),
    (Category::Tool, "Tools"),
    (Category::Cloud, "Cloud & Infrastructure"),
    (Category::Database, "Database Clients"),
    (Category::Ai, "AI/ML"),
];

/// Writes the feature catalog to `out` in the requested `format` (`table` or
/// `markdown`).
///
/// # Errors
///
/// Returns an error for an unknown `format`, or any I/O error from writing.
pub fn run(out: &mut impl Write, format: &str) -> Result<(), Box<dyn Error>> {
    let reg = Registry::new();
    match format {
        "table" => print_table(out, &reg)?,
        "markdown" => print_markdown(out, &reg)?,
        other => return Err(format!("unknown format {other:?} (use table or markdown)").into()),
    }
    Ok(())
}

/// Renders each non-empty category as an aligned, column-padded text table.
fn print_table(out: &mut impl Write, reg: &Registry) -> std::io::Result<()> {
    let mut first = true;
    for (cat, label) in CATEGORY_ORDER {
        let features: Vec<&Feature> = reg.by_category(*cat).collect();
        if features.is_empty() {
            continue;
        }
        if !first {
            writeln!(out)?;
        }
        first = false;

        writeln!(out, "{label}:")?;

        // Rows: [ID, Build Arg, Version Arg, Default, Requires]; header first.
        let mut rows: Vec<[String; 5]> = vec![[
            "ID".into(),
            "Build Arg".into(),
            "Version Arg".into(),
            "Default".into(),
            "Requires".into(),
        ]];
        for f in &features {
            rows.push([
                f.id.clone(),
                f.build_arg.clone(),
                dash_opt(f.version_arg.as_deref()),
                dash_opt(f.default_version.as_deref()),
                dash_slice(&f.requires),
            ]);
        }

        // Compute each column's max width for left-alignment. The last column
        // is not padded (nothing follows it).
        let widths = column_widths(&rows);
        for row in &rows {
            let mut line = String::from("  ");
            for (i, cell) in row.iter().enumerate() {
                if i + 1 == row.len() {
                    line.push_str(cell);
                } else {
                    // Infallible: writing to a String never errors.
                    let _ = write!(line, "{cell:width$}  ", width = widths[i]);
                }
            }
            writeln!(out, "{}", line.trim_end())?;
        }
    }
    Ok(())
}

/// Renders each non-empty category as a markdown `##` section with a table.
fn print_markdown(out: &mut impl Write, reg: &Registry) -> std::io::Result<()> {
    let mut first = true;
    for (cat, label) in CATEGORY_ORDER {
        let features: Vec<&Feature> = reg.by_category(*cat).collect();
        if features.is_empty() {
            continue;
        }
        if !first {
            writeln!(out)?;
        }
        first = false;

        writeln!(out, "## {label}")?;
        writeln!(out)?;
        writeln!(
            out,
            "| ID | Display Name | Build Arg | Version Arg | Default | Requires | Implied By |"
        )?;
        writeln!(
            out,
            "|----|-------------|-----------|-------------|---------|----------|------------|"
        )?;
        for f in &features {
            writeln!(
                out,
                "| {} | {} | {} | {} | {} | {} | {} |",
                f.id,
                f.display_name,
                f.build_arg,
                dash_opt(f.version_arg.as_deref()),
                dash_opt(f.default_version.as_deref()),
                dash_slice(&f.requires),
                dash_slice(&f.implied_by),
            )?;
        }
    }
    Ok(())
}

/// Per-column maximum cell width across all rows.
fn column_widths(rows: &[[String; 5]]) -> [usize; 5] {
    let mut widths = [0usize; 5];
    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.chars().count());
        }
    }
    widths
}

/// Renders an optional string as its value or `-` when absent/empty.
fn dash_opt(s: Option<&str>) -> String {
    match s {
        Some(v) if !v.is_empty() => v.to_string(),
        _ => "-".to_string(),
    }
}

/// Renders a list as a comma-joined string or `-` when empty.
fn dash_slice(items: &[String]) -> String {
    if items.is_empty() { "-".to_string() } else { items.join(", ") }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Capture `features` output for `format` into a String.
    fn render(format: &str) -> String {
        let mut buf = Vec::new();
        run(&mut buf, format).unwrap();
        String::from_utf8(buf).unwrap()
    }

    #[test]
    fn default_format_has_headers_and_known_ids() {
        let out = render("table");

        for header in
            ["Languages:", "Tools:", "Cloud & Infrastructure:", "Database Clients:", "AI/ML:"]
        {
            assert!(out.contains(header), "missing category header {header:?}");
        }
        for id in ["python", "node", "rust", "golang", "docker", "kubernetes"] {
            assert!(out.contains(id), "missing feature ID {id:?} in table output");
        }
        assert!(out.contains("Build Arg"), "missing column header 'Build Arg'");
    }

    #[test]
    fn markdown_format_has_headers_and_columns() {
        let out = render("markdown");

        for header in [
            "## Languages",
            "## Tools",
            "## Cloud & Infrastructure",
            "## Database Clients",
            "## AI/ML",
        ] {
            assert!(out.contains(header), "missing markdown header {header:?}");
        }
        assert!(out.contains('|'), "missing markdown table delimiters");
        assert!(out.contains("|-"), "missing markdown table separator row");
        for col in ["Display Name", "Build Arg", "Version Arg", "Implied By"] {
            assert!(out.contains(col), "missing markdown column {col:?}");
        }
    }

    #[test]
    fn all_registry_features_present() {
        let out = render("table");
        let reg = Registry::new();
        for f in reg.all() {
            assert!(out.contains(&f.id), "feature {:?} missing from output", f.id);
        }
    }

    #[test]
    fn category_grouping_is_ordered() {
        let out = render("table");
        let headers =
            ["Languages:", "Tools:", "Cloud & Infrastructure:", "Database Clients:", "AI/ML:"];
        let mut last = None;
        for h in headers {
            let idx = out.find(h).unwrap_or_else(|| panic!("missing header {h:?}"));
            if let Some(prev) = last {
                assert!(idx > prev, "header {h:?} appears before a preceding category");
            }
            last = Some(idx);
        }
    }

    #[test]
    fn invalid_format_errors() {
        let mut buf = Vec::new();
        let err = run(&mut buf, "csv");
        assert!(err.is_err(), "expected error for invalid format");
    }

    #[test]
    fn table_columns_are_aligned() {
        // Each data line under a section pads its ID column to a common width,
        // so the Build Arg column starts at the same offset across rows.
        let out = render("table");
        // Find the Languages section body: python and python_dev both appear;
        // their INCLUDE_* build args should align.
        let py = out.lines().find(|l| l.trim_start().starts_with("python ")).unwrap();
        assert!(py.contains("INCLUDE_PYTHON"), "row should carry the build arg: {py:?}");
    }
}
