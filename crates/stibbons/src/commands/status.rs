//! `stibbons status` — show enabled features and generated-file health.
//!
//! Ported from the Go `igor status` command. Loads `.igor.yml`, resolves the
//! feature dependency graph, and reports which generated files still match
//! their recorded SHA-256 hashes. Drift (a modified or deleted file) is
//! signalled to `main.rs` via the returned [`StatusReport::drift`] flag, which
//! maps to a non-zero process exit code — mirroring the Go `errDriftDetected`
//! sentinel.

use std::error::Error;
use std::io::Write;

use containers_common::config::IgorConfig;
use containers_common::feature::{Feature, Registry, Selection, resolve};
use containers_common::generate::hash_bytes;

use crate::commands::version::detect_containers_version;
use crate::render::STATE_FILE;

/// Outcome of a status run: whether any generated file has drifted.
#[derive(Debug, Clone, Copy)]
pub struct StatusReport {
    /// True when at least one generated file was modified or is missing.
    pub drift: bool,
}

/// Writes the project status to `out` and reports whether drift was detected.
///
/// # Errors
///
/// Returns an error if `.igor.yml` is absent or cannot be parsed, or on any
/// I/O error from writing to `out`.
pub fn run(out: &mut impl Write) -> Result<StatusReport, Box<dyn Error>> {
    if !std::path::Path::new(STATE_FILE).exists() {
        return Err("no .igor.yml found; run 'stibbons init' first".into());
    }
    let cfg = IgorConfig::load(STATE_FILE)?;

    let reg = Registry::new();
    let explicit: std::collections::HashSet<String> = cfg.features.iter().cloned().collect();
    let sel = resolve(&explicit, &reg);

    print_project_header(out, &cfg)?;
    print_feature_status(out, &reg, &sel, &cfg)?;
    let drift = print_file_status(out, &cfg)?;

    Ok(StatusReport { drift })
}

/// Prints the project name/base/user header, preferring the recorded
/// containers ref and falling back to a detected `VERSION` file.
fn print_project_header(out: &mut impl Write, cfg: &IgorConfig) -> std::io::Result<()> {
    let version = cfg.containers_ref.clone().or_else(detect_containers_version);

    if let Some(v) = version {
        writeln!(out, "Project: {} (containers {v})", cfg.project.name)?;
    } else {
        writeln!(out, "Project: {}", cfg.project.name)?;
    }
    writeln!(out, "Base: {}", cfg.project.base_image)?;
    writeln!(out, "User: {}", cfg.project.username)?;
    Ok(())
}

/// Prints the resolved feature list: explicit features with a `✓` (and version
/// where set), auto-resolved features with a `~` and the feature that pulled
/// them in.
fn print_feature_status(
    out: &mut impl Write,
    reg: &Registry,
    sel: &Selection,
    cfg: &IgorConfig,
) -> std::io::Result<()> {
    writeln!(
        out,
        "\nFeatures ({} explicit + {} auto):",
        sel.explicit.len(),
        sel.auto_resolved.len()
    )?;

    for f in reg.all() {
        if !sel.has(&f.id) {
            continue;
        }

        let version = f.version_arg.as_ref().and_then(|arg| cfg.versions.get(arg));

        if sel.explicit.contains(&f.id) {
            match version {
                Some(v) => writeln!(out, "  ✓ {} ({v})", f.id)?,
                None => writeln!(out, "  ✓ {}", f.id)?,
            }
        } else {
            match find_implier(f, sel, reg) {
                Some(implier) => writeln!(out, "  ~ {} (auto: {implier})", f.id)?,
                None => writeln!(out, "  ~ {} (auto)", f.id)?,
            }
        }
    }
    Ok(())
}

/// Finds which selected feature caused `f` to be auto-included: an explicit
/// implier first, then any selected feature that `requires` it.
fn find_implier<'a>(f: &Feature, sel: &Selection, reg: &'a Registry) -> Option<&'a str> {
    for implier in &f.implied_by {
        if sel.has(implier)
            && let Some(other) = reg.get(implier)
        {
            return Some(&other.id);
        }
    }

    for other in reg.all() {
        if sel.has(&other.id) && other.requires.iter().any(|req| req == &f.id) {
            return Some(&other.id);
        }
    }

    None
}

/// Prints the generated-file health section and returns whether any file has
/// drifted. Skips the state file (`.igor.yml`), which is always rewritten and
/// so never matches the templated hash.
fn print_file_status(out: &mut impl Write, cfg: &IgorConfig) -> std::io::Result<bool> {
    if cfg.generated.is_empty() {
        return Ok(false);
    }

    // `cfg.generated` is a BTreeMap, so keys are already sorted.
    let paths: Vec<&String> = cfg.generated.keys().filter(|p| p.as_str() != STATE_FILE).collect();
    if paths.is_empty() {
        return Ok(false);
    }

    writeln!(out, "\nGenerated files:")?;

    let mut drift = false;
    for path in paths {
        let expected = &cfg.generated[path];
        match check_file(path, expected) {
            FileState::Unchanged => writeln!(out, "  ✓ {path} (unchanged)")?,
            FileState::Modified => {
                writeln!(out, "  ! {path} (modified)")?;
                drift = true;
            }
            FileState::Missing => {
                writeln!(out, "  ✗ {path} (missing)")?;
                drift = true;
            }
        }
    }
    Ok(drift)
}

/// Drift classification for a single generated file.
enum FileState {
    Unchanged,
    Modified,
    Missing,
}

/// Compares a file's on-disk SHA-256 against `expected_hash`.
fn check_file(path: &str, expected_hash: &str) -> FileState {
    match std::fs::read(path) {
        Ok(data) if hash_bytes(&data) == expected_hash => FileState::Unchanged,
        Ok(_) => FileState::Modified,
        Err(_) => FileState::Missing,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use containers_common::feature::Category;

    fn feat(id: &str) -> Feature {
        Feature { id: id.to_string(), category: Category::Tool, ..Feature::default() }
    }

    #[test]
    fn find_implier_prefers_implied_by() {
        let reg = Registry::new();
        // dev_tools implies bindfs (and cron via bindfs). bindfs is auto here.
        let explicit: std::collections::HashSet<String> =
            std::iter::once("dev_tools".to_string()).collect();
        let sel = resolve(&explicit, &reg);
        let bindfs = reg.get("bindfs").unwrap();

        assert_eq!(find_implier(bindfs, &sel, &reg), Some("dev_tools"));
    }

    #[test]
    fn find_implier_falls_back_to_requires() {
        let reg = Registry::new();
        // kotlin requires java; select kotlin explicitly so java is auto.
        let explicit: std::collections::HashSet<String> =
            std::iter::once("kotlin".to_string()).collect();
        let sel = resolve(&explicit, &reg);
        let java = reg.get("java").unwrap();

        // java has no implied_by, so the implier is found via kotlin's requires.
        assert_eq!(find_implier(java, &sel, &reg), Some("kotlin"));
    }

    #[test]
    fn find_implier_none_when_unrelated() {
        let reg = Registry::new();
        let sel = Selection {
            explicit: std::iter::once("python".to_string()).collect(),
            auto_resolved: std::collections::HashSet::new(),
        };
        // A synthetic feature nothing selects should have no implier.
        let orphan = feat("orphan");
        assert_eq!(find_implier(&orphan, &sel, &reg), None);
    }

    #[test]
    fn check_file_detects_states() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("f.txt");
        std::fs::write(&path, b"hello").unwrap();
        let good = hash_bytes(b"hello");
        let p = path.to_str().unwrap();

        assert!(matches!(check_file(p, &good), FileState::Unchanged));
        assert!(matches!(check_file(p, "deadbeef"), FileState::Modified));
        assert!(matches!(
            check_file(tmp.path().join("nope").to_str().unwrap(), &good),
            FileState::Missing
        ));
    }
}
