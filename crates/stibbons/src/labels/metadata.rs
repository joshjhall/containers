//! Skill `metadata.yml` parsing and label aggregation.
//!
//! Issue #288 added a machine-readable `metadata.yml` beside each skill's
//! `SKILL.md`. The only part this module cares about is the `labels:` list:
//!
//! ```yaml
//! labels:
//!   - name: status/in-progress
//!     color: "0E8A16"
//!     description: An agent is working on this issue
//! ```
//!
//! [`load_labels`] walks a set of skill roots, reads every `metadata.yml` it
//! finds, and aggregates the label definitions into a de-duplicated, sorted
//! list. When two skills define the same label name with a *different* color or
//! description, the first one encountered wins and a warning is surfaced (the
//! issue explicitly allows "warn and use the first encountered").
//!
//! A label entry with an **empty color** is treated as a *reference*, not a
//! *definition*: some skills (e.g. `orchestrate`) list labels name-only to
//! declare that they depend on them, without owning their color/description.
//! References never override a real definition (regardless of file order) and,
//! if a name is only ever referenced and never defined, it is skipped from the
//! sync with a warning — otherwise a name-only entry would push an empty color
//! onto the tracker and blank out the real label.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// A single label definition as read from a skill `metadata.yml`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct LabelDef {
    /// Label name, e.g. `status/in-progress`.
    pub name: String,
    /// 6-digit hex color, with or without a leading `#`.
    #[serde(default)]
    pub color: String,
    /// Human-readable description.
    #[serde(default)]
    pub description: String,
}

/// The subset of a skill `metadata.yml` we parse. Everything except `labels`
/// is ignored (serde drops unknown fields by default).
#[derive(Debug, Default, serde::Deserialize)]
struct SkillMetadata {
    #[serde(default)]
    labels: Vec<LabelDef>,
}

/// Result of aggregating labels across skill roots.
#[derive(Debug, Default)]
pub struct Aggregate {
    /// De-duplicated labels, sorted by name.
    pub labels: Vec<LabelDef>,
    /// Number of `metadata.yml` files that contributed at least one label.
    pub source_files: usize,
    /// Non-fatal conflict warnings (same name, differing color/description).
    pub warnings: Vec<String>,
}

/// Recursively collect every `metadata.yml` under `root`.
///
/// Roots are shallow trees (`skills/<name>/metadata.yml` or
/// `plugins/<plugin>/skills/<name>/metadata.yml`), so a simple recursive walk
/// is fine. Unreadable directories are skipped silently — a permission blip on
/// one subtree shouldn't abort the whole sync.
fn find_metadata_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(find_metadata_files(&path));
        } else if path.file_name().is_some_and(|n| n == "metadata.yml") {
            out.push(path);
        }
    }
    out
}

/// Load and aggregate labels from every `metadata.yml` under the given roots.
///
/// Roots that do not exist are skipped (reported by the caller). Labels are
/// de-duplicated by name with a first-wins policy; conflicting redefinitions
/// produce a warning rather than an error.
///
/// # Errors
///
/// Returns an error if a `metadata.yml` file exists but cannot be parsed as
/// YAML — a malformed metadata file is a real problem worth surfacing, not
/// something to skip silently.
pub fn load_labels(roots: &[PathBuf]) -> Result<Aggregate, Box<dyn std::error::Error>> {
    // Preserve first-seen order for the warning ("use the first encountered"),
    // but emit the final list sorted by name for stable, reviewable output.
    let mut by_name: BTreeMap<String, LabelDef> = BTreeMap::new();
    let mut warnings = Vec::new();
    let mut source_files = 0usize;

    let mut files: Vec<PathBuf> = Vec::new();
    for root in roots {
        files.extend(find_metadata_files(root));
    }
    // Deterministic processing order so "first encountered" is reproducible.
    files.sort();

    // Names that appeared only as references (no color) so far. Used to warn if
    // a name is referenced but never actually defined anywhere.
    let mut referenced_only: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    for file in &files {
        let text = std::fs::read_to_string(file)?;
        let meta: SkillMetadata = serde_yaml::from_str(&text)
            .map_err(|e| format!("failed to parse {}: {e}", file.display()))?;
        if meta.labels.is_empty() {
            continue;
        }
        let mut contributed = false;
        for label in meta.labels {
            // Name-only entries are references, not definitions: they must not
            // override a real definition or seed an empty-color label.
            if label.color.trim().is_empty() {
                if !by_name.contains_key(&label.name) {
                    referenced_only.insert(label.name.clone());
                }
                continue;
            }
            contributed = true;
            referenced_only.remove(&label.name);
            match by_name.get(&label.name) {
                None => {
                    by_name.insert(label.name.clone(), label);
                }
                Some(existing) => {
                    if canon_color(&existing.color) != canon_color(&label.color)
                        || existing.description != label.description
                    {
                        warnings.push(format!(
                            "label `{}` defined more than once with differing color/description; \
                             keeping the first ({}, \"{}\")",
                            label.name, existing.color, existing.description
                        ));
                    }
                }
            }
        }
        if contributed {
            source_files += 1;
        }
    }

    // Any name that was only ever referenced (never given a color/description)
    // cannot be synced — surface it rather than silently dropping it.
    for name in &referenced_only {
        warnings.push(format!(
            "label `{name}` is referenced by a skill but never defined with a color/description; \
             skipping it"
        ));
    }

    Ok(Aggregate { labels: by_name.into_values().collect(), source_files, warnings })
}

/// Canonicalize a hex color for comparison: strip a leading `#` and uppercase.
/// GitHub returns bare hex (`0E8A16`) while GitLab uses `#0E8A16`, and metadata
/// may use either, so all comparisons go through this.
#[must_use]
pub fn canon_color(color: &str) -> String {
    color.trim_start_matches('#').to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn write_skill(root: &Path, name: &str, body: &str) {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("metadata.yml"), body).unwrap();
    }

    #[test]
    fn canon_color_strips_hash_and_uppercases() {
        assert_eq!(canon_color("#0e8a16"), "0E8A16");
        assert_eq!(canon_color("0E8A16"), "0E8A16");
        assert_eq!(canon_color(""), "");
    }

    #[test]
    fn loads_and_sorts_labels() {
        let tmp = TempDir::new().unwrap();
        write_skill(
            tmp.path(),
            "next-issue",
            "name: next-issue\nlabels:\n  - name: severity/high\n    color: \"D93F0B\"\n    description: High\n  - name: effort/small\n    color: \"0E8A16\"\n    description: Small\n",
        );
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert_eq!(agg.source_files, 1);
        let names: Vec<&str> = agg.labels.iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, vec!["effort/small", "severity/high"]);
        assert!(agg.warnings.is_empty());
    }

    #[test]
    fn dedupes_identical_across_files_without_warning() {
        let tmp = TempDir::new().unwrap();
        let dup = "labels:\n  - name: type/feature\n    color: \"1D76DB\"\n    description: New feature\n";
        write_skill(tmp.path(), "a", dup);
        write_skill(tmp.path(), "b", dup);
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert_eq!(agg.labels.len(), 1);
        assert_eq!(agg.source_files, 2);
        assert!(agg.warnings.is_empty(), "identical redefinition should not warn");
    }

    #[test]
    fn conflicting_redefinition_warns_and_keeps_first() {
        let tmp = TempDir::new().unwrap();
        // "a" sorts before "b", so a's magenta wins.
        write_skill(
            tmp.path(),
            "a",
            "labels:\n  - name: type/feature\n    color: \"1D76DB\"\n    description: New feature\n",
        );
        write_skill(
            tmp.path(),
            "b",
            "labels:\n  - name: type/feature\n    color: \"FF0000\"\n    description: Something else\n",
        );
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert_eq!(agg.labels.len(), 1);
        assert_eq!(agg.labels[0].color, "1D76DB");
        assert_eq!(agg.warnings.len(), 1);
    }

    #[test]
    fn empty_labels_list_is_not_a_source() {
        let tmp = TempDir::new().unwrap();
        write_skill(tmp.path(), "docker-development", "name: docker-development\nlabels: []\n");
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert!(agg.labels.is_empty());
        assert_eq!(agg.source_files, 0);
    }

    #[test]
    fn missing_root_is_skipped() {
        let agg = load_labels(&[PathBuf::from("/nonexistent/xyz")]).unwrap();
        assert!(agg.labels.is_empty());
        assert_eq!(agg.source_files, 0);
    }

    #[test]
    fn malformed_yaml_errors() {
        let tmp = TempDir::new().unwrap();
        write_skill(tmp.path(), "bad", "labels:\n  - name: x\n   color: broken indent\n:::\n");
        let err = load_labels(&[tmp.path().to_path_buf()]).unwrap_err();
        assert!(err.to_string().contains("failed to parse"));
    }

    #[test]
    fn name_only_reference_does_not_override_definition() {
        let tmp = TempDir::new().unwrap();
        // "a-orchestrate" references name-only; "b-ship" defines fully. Even
        // though the reference sorts first, the real definition must win and no
        // empty-color label may be produced.
        write_skill(tmp.path(), "a-orchestrate", "labels:\n  - name: status/pr-pending\n");
        write_skill(
            tmp.path(),
            "b-ship",
            "labels:\n  - name: status/pr-pending\n    color: \"E4B100\"\n    description: PR created\n",
        );
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert_eq!(agg.labels.len(), 1);
        assert_eq!(agg.labels[0].color, "E4B100");
        assert_eq!(agg.labels[0].description, "PR created");
        // Only the defining file counts as a source.
        assert_eq!(agg.source_files, 1);
        // No "differing color/description" warning — the reference is not a def.
        assert!(
            agg.warnings.iter().all(|w| !w.contains("defined more than once")),
            "unexpected conflict warning: {:?}",
            agg.warnings
        );
    }

    #[test]
    fn reference_only_never_defined_is_skipped_with_warning() {
        let tmp = TempDir::new().unwrap();
        write_skill(tmp.path(), "orchestrate", "labels:\n  - name: status/orphan\n");
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert!(agg.labels.is_empty(), "reference-only label must not be synced");
        assert_eq!(agg.source_files, 0);
        assert!(agg.warnings.iter().any(|w| w.contains("never defined")));
    }

    #[test]
    fn finds_nested_plugin_layout() {
        let tmp = TempDir::new().unwrap();
        // plugins/<plugin>/skills/<name>/metadata.yml
        let nested = tmp.path().join("workflow").join("skills");
        write_skill(
            &nested,
            "next-issue",
            "labels:\n  - name: status/on-hold\n    color: \"D93F0B\"\n    description: Deferred\n",
        );
        let agg = load_labels(&[tmp.path().to_path_buf()]).unwrap();
        assert_eq!(agg.labels.len(), 1);
        assert_eq!(agg.labels[0].name, "status/on-hold");
    }
}
